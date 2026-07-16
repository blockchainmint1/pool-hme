---
name: Live yiimp source tree
description: Which of the ~10 yiimp copies on the stratum box actually built the running `/var/stratum/stratum` binary. Patch this tree, not the others.
type: reference
---
Multiple yiimp source trees exist on `stratum.pool.honest.money`. The running binary `/var/stratum/stratum` was built from:

**`/home/ubuntu/aws/LIVE/yiimp/live-aux-issue-doge/stratum/`**

Evidence: file mtimes align with current deployment (Apr 10 2026 build); `stratum.cpp`, `client.cpp`, `client_core.cpp`, `util.cpp` all present here and referenced in `strings /var/stratum/stratum` build paths.

Ignore these older/dead copies:
- `/root/zcuyiimp-baseline/stratum` (baseline reference)
- `/root/ZCU-PROD-YIIMP-*` (backups)
- `/home/ubuntu/TXC-project/stratum` (older TXC branch)
- `/home/ubuntu/yiimp-install-only-do-not-run-commands-from-this-folder/stratum`
- `/home/ubuntu/aws/live-TXC-proj/stratum`
- `/home/ubuntu/aws/LIVE/test/yiimp-pool-completecode/stratum`

## Worker-name persistence

The `INSERT INTO workers` statement in the binary references both `name` and `worker` columns as separate parameters — so the schema and SQL support the `wallet.worker` split. When the `worker` column ends up empty despite miners auth-ing as `wallet.workername`, the bug is in the C++ splitting/assignment (likely in `client.cpp` handling of `mining.authorize`/`mining.submit`), not the SQL.
