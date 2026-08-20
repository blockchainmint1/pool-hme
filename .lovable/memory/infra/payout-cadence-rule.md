---
name: Payout cadence + the 3 things that break payouts
description: Why LTC/DOGE payouts die and the canonical restore procedure (payout-restore.sh)
type: feature
---
Payouts stop for exactly three reasons, in this order:

1. **Cadence.** DOGE cycle must run `*/10 * * * *`. Daily/hourly is fatal, not
   slow — yiimp deletes the round's `shares` rows when the parent LTC round
   credits, so a late cycle credits nobody. yiimp `YAAMP_PAYMENTS_FREQ` = 1800.
2. **Wallet lock.** Post seed-rotation both wallets are encrypted; every
   `sendmany`/`sendtoaddress` fails without a `walletpassphrase` unlock
   (`03-patch-payout-cron.sh` for DOGE, `08-ltc-unlock.sh` for LTC).
3. **loop2 is a daemon.** It reads `serverconfig.php` once at boot — changing
   the frequency without restarting `loop2` changes nothing.

Canonical tool: `infra/wallet-rotation/17-payout-restore.sh`
(`/install/payout-restore.sh`) — no-arg CHECK, `CONFIRM` to apply. Never
re-apply `10-payout-schedule.sh` (the daily schedule) — it is the regression.
