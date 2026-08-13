# Project Memory

## Core
"texacoin" / similar always means TEXITcoin.
Pool is part of the honest.money ecosystem. Footer must link honest.money + Terms + Privacy + Manifesto (draft if missing).
Learn about TEXITcoin chain + Omni L2 at texitcoin.org/build.
Infrastructure paths, hosts, config locations, and diagnostic commands are documented in `docs/infrastructure.md` — read/update it instead of re-discovering.
Stratum host: `ubuntu@stratum.pool.honest.money` (AWS EC2). Never call it "pool2" or "pool2.iskandercoin.com" — that name is retired.
**Live stratum config = `/var/stratum/scrypt.conf`** (cwd `/var/stratum`, invoked as `./stratum scrypt`). The Ansible template in `infra/stratum-stack/` has NOT been rolled out; edit `/var/stratum/scrypt.conf` directly and `systemctl restart stratum-aws-scrypt`. Ignore all `config.sample/scrypt.conf` files in `/home/ubuntu/aws/LIVE/*/` — stale.
Fleet: 1200 Antminer L9s across 6× **Foghashing BC40** containers (200 L9s each), single Conroe TX site. Each container has a Beelink mini-PC doing NAT/DHCP. All share one WAN IP (209.34.50.105) — healthy full-fleet = ~1200 established TCP sessions on :3433 from that IP, ~200 per container. Scrypt merged mining: LTC, DOGE, ISK, TXC, ZCU (only TXC/ISK/ZCU are pool-found).
Scrypt stratum listens on TCP **3433** (not 3333). Miners connect: `stratum+tcp://stratum.pool.honest.money:3433`.
Mansfield site (WAN 97.154.36.156, 48× L9) is on **Verizon Wireless cellular** (`myvzw.com` rDNS) — structural ~25% hashrate loss vs wired due to RTT/jitter/reconnects. Not a stratum bug.
User has no SSH on their laptop — ship yiimp-api updates via `bash infra/yiimp-api/build-bundle.sh` + Publish, then user runs `curl -fsSL https://pool.honest.money/install/yiimp-api.sh | sudo bash` on the box.
**Live stratum log = `/var/stratum/scrypt.log`.** `/var/stratum/logs/stratum-current.log` is a rotated snapshot and can be hours stale — never grep it for live errors. Repeated `error getblocktemplate` there means stratum cannot build jobs and blocks WILL stop, even while sockets/shares/NRestarts look perfect.
**Share counting IS working** — DB `shares` table reflects submissions correctly (valid/invalid/stale counts populate). The `SCRYPT summary diag active=0 valid=0` log line is a broken/stale in-memory counter, NOT a broken pipeline. Do NOT diagnose share-counting bugs from that log line — always cross-check `SELECT ... FROM shares WHERE time > UNIX_TIMESTAMP()-300`.
**Conroe uplink monitoring**: healthy = ~325+ sessions from 209.34.50.105 (or 13.217.211.175 via haproxy). If per-site session breakdown shows ONLY Mansfield (97.154.36.156) + McKinney (99.107.246.68) and no Conroe IP, Conroe uplink is DOWN — call the site before debugging code.

Coin daemon CLIs are NOT on $PATH: LTC `/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf` (wallet `wallets/pool/wallet.dat`, `wallet=pool`); DOGE `/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf` (wallet.dat at datadir root).
DOGE payout cycle must stay on a ~10-minute cron — Yiimp deletes `shares` when the parent LTC round credits, so a daily run strands blocks as `no_shares`. Batching is `MIN_PAYOUT_DOGE`, not the interval.
`auxpow_rpc_mode = 1` allowlist in stratum `db.cpp` is `ISK || TXC || ZCU` — DOGE must NEVER be in it (mode 1 = ~20% DOGE accept).

## Memories
- [Infrastructure doc](docs/infrastructure.md) — Full stratum host / paths / config / diagnostic reference (in-repo, not a mem:// file)
- [yiimp-api deploy](mem://infra/yiimp-api-deploy.md) — How to publish updates to the yiimp-api service (bundle → publish → curl-pipe installer); DB is `yiimpfrontend`; hashstats schema notes
- [Stratum port](mem://infra/stratum-port.md) — Scrypt stratum listens on TCP 3433 on stratum.pool.honest.money
- [Stratum schema & paths](mem://infra/stratum-schema.md) — Authoritative: binary `/var/stratum/stratum`, live config `/var/stratum/scrypt.conf`, systemd `stratum-aws-scrypt`; workers.difficulty NOT difficulty_actual; shares.error int NOT reject_reason. Read before SQL or config edits.
- [Mansfield-only isolation](mem://infra/mansfield-isolation.md) — iptables apply/extend/lift pattern for restricting 3433 to Mansfield + Conroe haproxy during hashpower debugging, with sleep-based auto-revert timer.
- [Stratum build & ZCU aux patch](mem://infra/stratum-build.md) — Parallel-make link race on algos/sha3 libs; always verify `stratum` mtime before install; `coind_create_job()` early-return patch for ZCU merge-mining.
- [Stratum source trees](mem://infra/stratum-source-trees.md) — **Authoritative** as of 2026-07-20: running `/var/stratum/stratum` (2026-07-19 17:13) is built from `LIVE-FINAL/`. `perfect1/` has an unused `coind_aux.cpp` merkle-narrowing patch; `live-aux-issue-doge/` is stale scratch. Edit LIVE-FINAL only.
- [ZCU reference repo](mem://infra/zcu-reference-repo.md) — github.com/blockchainmint1/pool-yiimp-zcu (public): the "last good" ZCU-aware stratum source. ZCU kept OUT of templ->auxs, submitted out-of-band from the LTC parent with a full-256 target gate via scrypt_submitAuxBlock, ZCUAUXCOMMIT coinbase output. Read before any ZCU work.
- [ZCU good binary](mem://infra/zcu-good-binary.md) — sha a9cde1777ae8 (4 Jun) is the last ZCU-capable stratum, saved at /var/stratum/stratum.bak.20260715-050518 + matching source in /root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src. ZCU died 13 Jul (environmental), binary swapped 15 Jul. Read before any ZCU restore.
- [ZCU forward-port](mem://infra/zcu-forwardport.md) — Merge base is the ZCU tree + only 2 LIVE edits (client.cpp diff clamp, db.cpp DOGE+ZCU allowlist union). LIVE regressed on util.cpp log mutex and coind_aux.cpp aux snapshot — do not take LIVE's version.

- [Canary versioning](mem://infra/canary-versioning.md) — bump CANARY_VERSION + add a VERSION LOG entry in mining-canary.sh on EVERY change; banner version proves whether the site was republished.
- [Fleet topology](mem://infra/fleet-topology.md) — 6× Foghashing BC40 containers @ 200 L9s each = 1200 total, Beelink NAT per container, shared WAN 209.34.50.105.
- [Coin daemon paths](mem://infra/coin-daemon-paths.md) — litecoin-cli/dogecoin-cli full paths, datadirs, wallet file layout, systemd units, passphrase file
- [DOGE payout cadence](mem://infra/doge-payout-cadence.md) — Why the DOGE cycle runs every 10 min (Yiimp share purge), the 246 stranded blocks, float-sweep destination
- [NiceHash/MRR shim](mem://infra/nicehash-proxy.md) — Rental verification fails on the subscribe-reply diff of 16 + 6-11s first job; nicehash-proxy on port 3533 fixes both without touching scrypt.conf
- [Pool snapshot/rollback](mem://infra/pool-snapshot.md) — `pool-snapshot.sh` SAVE/VERIFY/RESTORE; run SAVE+VERIFY before any stratum binary swap
