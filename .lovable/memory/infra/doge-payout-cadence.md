---
name: DOGE payout cadence
description: Why the DOGE payout cycle must run every ~10 min, never daily — Yiimp deletes shares when the parent LTC round credits
type: feature
---
The DOGE payout cycle (`/var/web/doge-payout-cycle.sh`, cron `/etc/cron.d/yiimp-doge-payout-cycle`) MUST run frequently — currently `*/10 * * * *`.

**Never move it to a daily/hourly schedule.** Yiimp treats `shares` as a consumable round ledger:
- `yaamp/core/backend/blocks.php` → `DELETE FROM shares WHERE coinid=<algo coin>` every time a parent (LTC) round is credited
- `yaamp/core/backend/system.php` → additional age-based purge

A merged DOGE block can only be attributed to miners while its parent-round share rows still exist — minutes, not hours. Running daily (the 06:15 UTC schedule from `10-payout-schedule.sh`) stranded ~246 blocks (~2.46M DOGE) as `no_shares`; widening `TOKEN_WINDOW_HOURS` does NOT help because the shares are already gone. Those blocks are unrecoverable.

Batching is controlled by `MIN_PAYOUT_DOGE` (200), not by the cron interval — miners still get consolidated transfers, not dust.

Fix scripts: `infra/wallet-rotation/13-doge-capture-cadence.sh` (cadence), `14-doge-float-sweep.sh` (move stranded float out of the hot wallet; keeps unpaid ledger + `accounts.doge_balance` + reserve behind).

Applied 2026-08-05. Float sweep destination (owner's personal wallet): `DMA7AvFzJWGEnJhUtkSMcGiCnJCCohYKFG`.
