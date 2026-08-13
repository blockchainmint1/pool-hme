---
name: ZCU forward-port direction
description: Merge ZCU stratum tree + 2 small LIVE edits — do NOT port ZCU into LIVE; LIVE regressed on util.cpp and coind_aux.cpp
type: feature
---
zcu-restore-plan v2 diff (13 Aug 2026) of the 3 Jun ZCU tree
(`/root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src`) vs
`/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum` — 10 differing files, but only
THREE are real LIVE-side improvements.

**Merge base = the ZCU tree.** Apply into it:
1. `client.cpp` — clamp suggested diff to `g_stratum_min_diff` / `g_stratum_max_diff` (NiceHash).
2. `db.cpp` — `auxpow_rpc_mode = 1` allowlist must be `ISK || TXC || ZCU`, with **DOGE REMOVED**. CORRECTION (13 Aug, v2): DOGE at mode 1 is the ~20%-acceptance bug; taking DOGE OUT of this list is the working DOGE fix. LIVE already has ISK/TXC/ZCU; the 3 Jun ZCU tree still has ISK/TXC/DOGE, so the port both adds ZCU and drops DOGE. Never "union" these lists.
3. `coind.cpp` — LIVE's generic `is_evm_address()` is superseded; the ZCU tree's `coind_validate_zcu_address_string()` does the same job. No port needed.

**Do NOT take LIVE's version of:**
- `util.cpp` — ZCU tree has the `pthread_mutex_t g_log_reopen_mutex` around `reopen_logs_if_needed()`; LIVE lost it (log-corruption race).
- `coind_aux.cpp` — ZCU tree malloc-snapshots `coind->aux` under the coind mutex; LIVE stores a raw `&coind->aux` pointer into the template (torn read / use-after-free across threads).
- `job.h`, `coind.h`, `coind_template.cpp`, `coinbase.cpp`, `coind_submit.cpp` — this is the ZCU feature itself plus whitespace churn.

Tool: `infra/pool-doctor/zcu-forwardport.sh` (PLAN read-only / BUILD scratch compile in `/root/ZCU-FWDPORT-<ts>`). It never writes `/var/stratum` and never restarts the service.
