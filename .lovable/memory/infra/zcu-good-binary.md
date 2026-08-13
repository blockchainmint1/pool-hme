---
name: The ZCU-capable stratum binary (found 13 Aug 2026)
description: sha a9cde1777ae8 is the last stratum build with native ZCU support; where copies live, when it was swapped out, and why ZCU actually died on 13 Jul
type: feature
---

# The ZCU-capable binary

`zcu-archaeology.sh` (13 Aug 2026) settled this.

## The binary
- **sha256 prefix `a9cde1777ae8`**, built **2026-06-04 08:35**
- Symbol counts: `new=14` (reference-tree ZCU symbols: `scrypt_submitAuxBlock`,
  `ZCUAUXCOMMIT`, `zcu_submit_from_ltc_parent`, ...), `aux=48`, `zcu=18`
- Copies on the box:
  - `/var/stratum/stratum.bak.20260715-050518`  <- **this was the LIVE binary**
  - `/tmp/stratum.golden-20260604-083509`, `/tmp/stratum.golden-20260604-084905`
  - `/root/zcuyiimp-baseline/config-live-evidence/var-stratum-binaries/stratum`
  - `/root/ZCU-PROD-YIIMP-PROD4A-.../work/candidate-source/zcu-yiimp-clean-source/stratum/stratum`
  - `/root/ZCU-PROD-YIIMP-PROD4B-.../apply/stratum-new` and `.../work/stratum-build-src/stratum`

A slightly newer sibling exists: **`db069c3539fd`** (3 Jun 11:53, `new=14 aux=48 zcu=19`)
at `/root/ZCU-PROD-STRATUM-4C-R1-.../stage/stratum` and
`/opt/zcu-mainnet/yiimp-zcu-1g-20260603-221016/stratum.before-1g-...`. It was NOT
the one running; `a9cde` was.

## Matching source
`/root/ZCU-PROD-YIIMP-PROD4B-20260603T110519Z/work/stratum-build-src/` — contains the
ZCU code in `client_submit.cpp` and `coind_submit.cpp` (the reference design:
ZCU out of `auxs[]`, `zcu_submit_from_ltc_parent()`, full-256 gate, `ZCUAUXCOMMIT`).
Same design as GitHub `blockchainmint1/pool-yiimp-zcu` / `headsortales/hme-yiimp`.

## Timeline — ZCU did NOT die from a code change
- ZCU last block: **2026-07-13 04:21:05** (height 18574), from `blocks` table.
- Binary swap: **2026-07-15 05:05** (`a9cde` -> `70400a79a811`, `zcu=0`).
- So ZCU stopped **2 days before** the ZCU binary was replaced.
- Root cause of 13 Jul is therefore **environmental** (oversized logs / disk /
  undersized EC2 instance), not the stratum source. The 15-20 Jul rebuilds then
  removed ZCU support entirely, which is why no adapter/shim could bring it back.

Every binary dated 15 Jul or later has `zcu=0`, including the live
`/var/stratum/stratum` (`2beb1f26ca60`, 20 Jul 11:10).

## Rule
Do NOT port ZCU from GitHub and do NOT write more Python adapters. The correct
restore path is: diff `PROD4B/work/stratum-build-src` against the current
`LIVE-FINAL` tree, forward-port only the 15-20 Jul fixes that are genuinely in
the binary (the DOGE 100%-accept fix was `auxpow_rpc_mode` CONFIG, not code),
rebuild, and swap in behind a maintenance window.
