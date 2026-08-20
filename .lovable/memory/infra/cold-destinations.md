---
name: Cold payout destinations (owner-controlled)
description: Owner's personal DOGE/LTC addresses that all pool profit sweeps to, plus the hot-float architecture rule
type: feature
---
Owner-controlled destinations (stored on the box in `/etc/pool-wallets/cold.env`):

- DOGE: `DNW32nET5ZVmzTj9BR8yHB5ovHNSG4wLSj`
- LTC:  `ltc1qmt2nj9hpkrg6f2r4plyt2ymnt4mhmf5aukyrzz`

(Older DOGE personal address `DMA7AvFzJWGEnJhUtkSMcGiCnJCCohYKFG` was the 14-doge-float-sweep destination; superseded.)

**Architecture rule:** the pool coinbase CANNOT pay a cold address directly — the
pool wallet must hold funds to send miner payouts from. Correct shape is a small
hot float on the box + continuous sweep of everything above
(miner liabilities + reserve) to the owner's addresses.

Tooling: `infra/wallet-rotation/16-cold-sweep.sh`
(`/install/cold-sweep.sh`) — SETUP / STATUS / DRAIN [CONFIRM] / INSTALL (cron
every 6h) / UNINSTALL. Reserves default `RESERVE_DOGE=25000`, `RESERVE_LTC=0.5`.
