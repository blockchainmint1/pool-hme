## What your dump told us

**Wallet keys**
- Only `/home/ubuntu/.dogecoin/wallet.dat` exists at depth ≤4. `litecoind` runs with `-conf=/home/ubuntu/.litecoin/litecoin.conf`, so its wallet is almost certainly `/home/ubuntu/.litecoin/wallet.dat` or `.litecoin/wallets/wallet.dat` — the find just missed it (or the datadir is elsewhere in the conf). Worth one more targeted check.
- No `litecoin-cli` / `dogecoin-cli` on PATH, but the binaries exist next to the daemons (`/home/ubuntu/litecoin-0.21.4/bin/`, `/home/ubuntu/dogecoin-1.14.9/bin/`). Use the full path; don't install anything.
- `coins` table has no `wallet` column in this schema — the pool addresses live in the stratum config and/or `coins.master_wallet`/`coins.rpcuser`-adjacent columns. We'll read `SHOW COLUMNS FROM coins` once rather than guessing again.

**Registration contract (now fully known)**
1. POST only, IP rate-limited, captcha.
2. Format pre-check: LTC = `ltc1…` bech32 or `[LM3]…` base58; DOGE = `[DA9]…` base58 (mainnet mode).
3. Authoritative check: `validateaddress` RPC on each daemon.
4. Duplicate check against `doge_address_links`.
5. Transaction: insert zero-balance row in `accounts` (username = LTC address, coinid/coinsymbol = LTC) → mint token → insert `doge_address_links`.
6. Token = `strtoupper(substr(bin2hex(random_bytes(16)),0,24))` → 24 hex chars, uppercase. Every token ever issued is burned into `doge_token_history` (UNIQUE key) so it can never be reissued.
7. Miner passes `dogelink=<TOKEN>` as the stratum password; `DogePayoutCommand::scanTokens` sets `token_last_seen` from `workers.password`, and payouts require `token_required` + a fresh `token_last_seen`.

Nothing in the payout path reads the *web form* — it only reads those three tables. So we can reimplement registration on our side without touching the payout pipeline at all.

## Plan

### 1. Write-scoped DB user (new, does not disturb anything)
Create `yiimp_reg` with the minimum grants:
```
SELECT, INSERT           ON yiimpfrontend.accounts
SELECT, INSERT, UPDATE   ON yiimpfrontend.doge_address_links
SELECT, INSERT           ON yiimpfrontend.doge_token_history
SELECT                   ON yiimpfrontend.coins
```
No DELETE anywhere. Separate credential from `yiimp_api` (which stays SELECT-only), stored as `MYSQL_REG_USER` / `MYSQL_REG_PASSWORD` in `/etc/yiimp-api/env`.

### 2. `yiimp-api` v0.5.0 — registration endpoints
- `GET  /api/v1/doge/registration/lookup?ltc=<addr>` — returns whether an LTC address already has a link, and the DOGE address masked. Never returns the token.
- `POST /api/v1/doge/register` — body `{ ltc_address, doge_address, captcha }`.
  Pipeline mirrors the PHP exactly, in order: rate-limit (IP, 10/hr) → format regex → duplicate check → `validateaddress` via LTC and DOGE RPC → transaction (accounts insert → token mint with history burn → link insert) → return the token **once**.
- `GET /api/v1/doge/token/status?token=<t>` — returns `active`, `token_last_seen`, and whether the token has been seen by the stratum in the payout window, so miners can self-verify their `dogelink=` is landing. No addresses returned.
- Reuse the existing regex whitelists; add a Zod-style validator on the body; 24h in-memory + DB-backed rate-limit table is overkill — IP bucket in memory matches the PHP behaviour closely enough.
- RPC creds read from the existing daemon confs at service start (same way the PHP `WalletRPC` does), never from client input.

### 3. Captcha
The PHP uses a simple arithmetic/session captcha. On our side, an HMAC-signed challenge: server issues `{question, nonce, expires, sig}`, client returns the answer plus the signed blob. Stateless, no session store, no third-party dependency.

### 4. New route `src/routes/register.tsx` on pool.honest.money
- Two-field form (LTC mining address, DOGE payout address) + captcha, matching the existing site design tokens.
- On success: full-width token panel with copy button, the exact miner config line (`-u <LTC> -p dogelink=<TOKEN>`), and a hard warning that the token is shown once.
- Error states map 1:1 to the PHP flash messages so behaviour is familiar.
- Its own `head()` metadata; index.tsx and the mining page swap their `pool.texitcoin.org/site/dogeRegister` links to `/register`.

### 5. Safety around the 41 existing rows
- Before any write path goes live, take a fresh dump of `accounts`, `doge_address_links`, `doge_token_history` (we already have `/var/backups/doge-links-20260728-033329`).
- New endpoint is additive only — it never updates or deletes an existing link; a duplicate LTC or DOGE address returns a conflict error, exactly like the PHP.
- Ship behind an env flag `DOGE_REGISTER_ENABLED=0` by default so the deploy is inert until you flip it and test with one throwaway address pair.

### 6. Verification
- Register one test LTC/DOGE pair, confirm the row lands in all three tables with the same shape as the existing 41.
- Point a single miner at it with the new token, confirm `scanTokens` picks up `token_last_seen`.
- Then flip the old PHP page to a redirect.

## Technical notes
- `accounts` insert must set `coinid`/`coinsymbol` from the LTC row in `coins`, `balance=0`, `donation=0`, `hostaddr` = client IP — otherwise the wallet page and payout join break.
- Token collision handling: check `doge_address_links` for an active token, then rely on the `doge_token_history` UNIQUE key as the real guard, retrying up to 100 times. Same as PHP.
- All writes inside a single MySQL transaction with the link insert last, so a failed link never leaves an orphan account row.
