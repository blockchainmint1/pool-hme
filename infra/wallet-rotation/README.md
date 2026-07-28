# Pool wallet rotation — cutting off the old operator

## Why

Every pool wallet on `stratum.pool.honest.money` is an **HD wallet with no
passphrase**:

| Wallet | Path | Seed id | Type |
|---|---|---|---|
| DOGE | `~/.dogecoin/wallet.dat` | `b588baff670bb72f4e644ff718f16d078e407bf1` | HD, unencrypted |
| LTC  | `~/.litecoin/wallets/pool/wallet.dat` | `41996688cdd0a0a01f370d09aa5c635502b17567` | HD, unencrypted |
| TXC  | `~/.texitcoin/wallets/pool/wallet.dat` | tbd | HD, unencrypted |
| ISK  | `~/.iskander/wallets/pool/wallet.dat` | tbd | HD, unencrypted |

Stale `authorized_keys` archived to `/root/ssh-forensics/` show three keys that
had access until at least 2026-06-02:

```
ssh-rsa  txc-mining-pool
ssh-rsa  txc-mining-pool
ssh-rsa  godthebest
```

`godthebest` is a personal key comment. Assume all four seeds are compromised.

**An HD seed derives every address the wallet will ever use.** Encrypting the
existing files protects them from here on but does not revoke a seed that was
already copied. Only generating new seeds does that.

## Reward flow (why there is no "pool address" to change)

- **DOGE**: stratum calls `getauxblock` on the local dogecoind. *dogecoind*
  builds the aux block and pays the coinbase to a fresh address from its own
  keypool. Stratum never chooses the address.
- **LTC**: stratum calls `getblocktemplate` on the local litecoind and the
  coinbase pays into litecoind's `pool` wallet. Again no address in
  `scrypt.conf` — the grep comes back empty by design.

So rotation = replace the daemon wallet, not edit a config value.

## Order of operations

Chosen path: **rotate seeds now, sweep later.** Balances stay in the old
wallets until everything is confirmed running on the new seeds and all immature
coinbases have matured.

| # | Script | Status | What it does | Mining impact |
|---|---|---|---|---|
| 0 | — | **required** | Create cold DOGE + LTC addresses on hardware you control. Send a test tx **from** them to prove you can spend. | none |
| 1 | `01-sweep.sh` | **deferred** | Sweep balances to cold — run later, once new seeds are proven and old coinbases have matured | none |
| 2 | `02-rotate-seed.sh` | **run now** | New encrypted wallet per daemon (DOGE, then LTC), old file retained | ~60s daemon restart |
| 3 | `03-patch-payout-cron.sh` | **run now** | Teach `doge-payout-cycle.sh` to unlock before `payoutSend` | none |
| 4 | `04-auto-sweep.sh` | **skipped** | Cron keeping the hot wallet at a float — revisit after step 1 | none |
| 5 | `05-revoke.sh` | **run now** | Remove stale key files; prints the AWS IAM checklist | none |

### TXC / ISK / ZCU

Not rotated. Their coinbase destinations are fixed at the chain level, so a new
local seed changes nothing about where rewards land and risks breaking payouts.
Only DOGE (`getauxblock` → local keypool) and LTC (`getblocktemplate` → local
`pool` wallet) derive their payout addresses from a rotatable seed.

Best window is immediately after a payout cycle finishes — the cron runs every
5 minutes, so check the lock file is clear first.

**Keep the old wallet files.** All current balances plus immature coinbases
still belong to the old seed. `02` moves the old file aside rather than
deleting it; `01` is re-run against it later to sweep everything out.


## Safety model

Every script is dry-run by default and prints exactly what it would do. Each
requires an explicit confirmation phrase argument to act:

```bash
sudo ./01-sweep.sh                      # dry run, prints plan
sudo ./01-sweep.sh CONFIRM_SWEEP        # executes
```

None of them touch the stratum, the `yiimpfrontend` database, or
`doge_payout_ledger`. Script `03` is the only one that edits a live file, and
it writes a timestamped backup first.

## Passphrase handling

`02` writes the new passphrase to `/etc/pool-wallets/passphrase.env`, mode
`600`, owner `root`. The payout cron reads it from there. Store a copy in your
password manager **before** running `02` — if that file is lost and you have no
copy, the hot wallet float is unrecoverable.

The cold wallet's seed must never exist on this box in any form.
