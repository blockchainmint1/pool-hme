
## MAJOR UPDATE MOMENT — 2026-10-01
Fix prepared: `stratum-socket-fix.sh` (CHECK → BUILD → INSTALL CONFIRM → ROLLBACK CONFIRM). Adds NULL/closed-socket guard at top of `socket_nextjson` (marker SOCKETFIX-20261001). Built only in a copy under /root/stratum-fix-<ts>; original tree untouched. Undo binary: `/var/stratum/stratum.pre-socketfix`. Source archives (exact running + patched) saved to `/var/backups/stratum-source/` — the yiimp/stratum source is NOT in this repo; only patches in `zcu-yiimp-patch/` and the public ZCU reference repo.
