# Project Memory

## Core
"texacoin" / similar always means TEXITcoin.
Pool is part of the honest.money ecosystem. Footer must link honest.money + Terms + Privacy + Manifesto (draft if missing).
Learn about TEXITcoin chain + Omni L2 at texitcoin.org/build.
Infrastructure paths, hosts, config locations, and diagnostic commands are documented in `docs/infrastructure.md` — read/update it instead of re-discovering.
Stratum host: `ubuntu@stratum.pool.honest.money` (AWS EC2). Never call it "pool2" or "pool2.iskandercoin.com" — that name is retired.
**Live stratum config = `/var/stratum/scrypt.conf`** (cwd `/var/stratum`, invoked as `./stratum scrypt`). The Ansible template in `infra/stratum-stack/` has NOT been rolled out; edit `/var/stratum/scrypt.conf` directly and `systemctl restart stratum-aws-scrypt`. Ignore all `config.sample/scrypt.conf` files in `/home/ubuntu/aws/LIVE/*/` — stale.
Fleet: 1200 Antminer L9s across 6 containers, single TX site. Scrypt merged mining: LTC, DOGE, ISK, TXC, ZCU (only TXC/ISK/ZCU are pool-found).
Scrypt stratum listens on TCP **3433** (not 3333). Miners connect: `stratum+tcp://stratum.pool.honest.money:3433`.
Mansfield site (WAN 97.154.36.156, 48× L9) is on **Verizon Wireless cellular** (`myvzw.com` rDNS) — structural ~25% hashrate loss vs wired due to RTT/jitter/reconnects. Not a stratum bug.
User has no SSH on their laptop — ship yiimp-api updates via `bash infra/yiimp-api/build-bundle.sh` + Publish, then user runs `curl -fsSL https://pool.honest.money/install/yiimp-api.sh | sudo bash` on the box.

## Memories
- [Infrastructure doc](docs/infrastructure.md) — Full stratum host / paths / config / diagnostic reference (in-repo, not a mem:// file)
- [yiimp-api deploy](mem://infra/yiimp-api-deploy.md) — How to publish updates to the yiimp-api service (bundle → publish → curl-pipe installer); DB is `yiimpfrontend`; hashstats schema notes
- [Stratum port](mem://infra/stratum-port.md) — Scrypt stratum listens on TCP 3433 on stratum.pool.honest.money
- [Stratum schema & paths](mem://infra/stratum-schema.md) — Authoritative: binary `/var/stratum/stratum`, live config `/var/stratum/scrypt.conf`, systemd `stratum-aws-scrypt`; workers.difficulty NOT difficulty_actual; shares.error int NOT reject_reason. Read before SQL or config edits.
- [Mansfield-only isolation](mem://infra/mansfield-isolation.md) — iptables apply/extend/lift pattern for restricting 3433 to Mansfield + Conroe haproxy during hashpower debugging, with sleep-based auto-revert timer.
