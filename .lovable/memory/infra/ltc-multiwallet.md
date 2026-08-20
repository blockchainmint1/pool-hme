---
name: LTC is multi-wallet — always pass -rpcwallet=pool
description: Litecoin Core 0.21.4 on the stratum box loads wallets `pool` (holds all mining funds) and `rental`; any litecoin-cli call without -rpcwallet hits the empty default wallet and reads 0
type: feature
---
Litecoin Core 0.21.4 on `stratum.pool.honest.money` runs multi-wallet:

- `pool` — the mining wallet. Holds ALL the LTC (231.8 spendable + immature
  coinbase as of 2026-08-20). Owns yiimp's `coins.master_wallet`
  `LTyp1No4skV378NbYrR7p6d7wRzDCHgFAa`.
- `rental` — empty, 0 txs.
- `pool.old-seed-20260728-085324/` — pre-rotation wallet file, not loaded.

**Rule:** every `litecoin-cli` invocation in scripts MUST include
`-rpcwallet=pool`. Without it the CLI talks to the default wallet, which is
empty, and balances silently read `0`. This caused cold-sweep v1 to report
`LTC spendable=0` while 231.8 LTC sat in `pool`. Fixed in cold-sweep v2.

Dogecoin Core 1.14 is single-wallet — no `-rpcwallet` needed (and it does not
support the flag).

**Also:** yiimp marks LTC blocks `orphan` in the `blocks` table while the chain
shows them as valid `generate` txs with confirmations climbing. That is a yiimp
bookkeeping artifact from the wallet rotation, not lost money — verify against
the chain with `orphan-doctor.sh` before believing the DB.
