---
name: Stratum source trees on AWS box
description: Which /home/ubuntu tree builds the running stratum binary, and what each tree has been patched with; what's actually in prod vs. only-in-a-tree.
type: reference
---

# Stratum source trees on `stratum.pool.honest.money`

Snapshot: 2026-07-20.

## Running binary

- Path: `/var/stratum/stratum`
- Modified: **2026-07-19 17:13:18 UTC** (size 6,812,448)
- Systemd unit: `stratum-aws-scrypt` (see `mem://infra/stratum-schema`)

## Which tree it's built from

**`/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum`** is the source of truth.
- Its own `./stratum` binary: 2026-07-17 02:19, 6,812,696 bytes (last in-tree build before latest deploy)
- `/var/stratum/stratum` is 2 days newer → built from LIVE-FINAL and copied to `/var/stratum/`.

The other trees are stale copies/experiments — **do not build or edit them expecting live effect**:
- `/home/ubuntu/aws/LIVE/live-aux-issue-doge` — clean-ish scratch tree, closest to pristine
- `/home/ubuntu/aws/LIVE/perfect1` — has an alternate `coind_aux.cpp` (merkle narrowing) that is NOT in the running binary
- `/home/ubuntu/yiimp-install-only-do-not-run-commands-from-this-folder` — pristine `bitweb-project/yiimp @ 3fbeb3ed` (Nov 2023), reference only

## Source drift vs. pristine (files that differ)

Pristine = `yiimp-install-only-do-not-run-commands-from-this-folder/stratum` (upstream `3fbeb3ed`).

| File | LIVE-FINAL (prod) | live-aux-issue-doge | perfect1 | What it is |
|---|---|---|---|---|
| `db.cpp` | ✅ differs | ✅ differs | ✅ differs | ZCU added to `submitauxblock` allowlist |
| `coinbase.cpp` | ✅ differs | ✅ differs | ✅ differs | Pre-existing dev customization (all trees) |
| `coind_submit.cpp` | ✅ differs | ✅ differs | ✅ differs | Pre-existing dev customization (all trees) |
| `coind_template.cpp` | ✅ differs | ✅ differs | ✅ differs | Pre-existing dev customization (all trees) |
| `coind.cpp` | ✅ **only in LIVE-FINAL** | — | — | ZCU `getblocktemplate` short-circuit — **IN RUNNING BINARY** |
| `coind_aux.cpp` | — | — | ✅ only in perfect1 | Merkle-narrowing experiment — **NOT in running binary** |

Also drifting in `live-aux-issue-doge` but not aux-relevant: `client.cpp/h`, `client_submit.cpp`, `share.cpp`, `user.cpp`, `util.cpp` (+ `util.cpp.bak`).

## Implications for DOGE 20% acceptance rate

- The running binary has **ZCU allowlist (db.cpp) + ZCU `getblocktemplate` short-circuit (coind.cpp)**.
- It does **NOT** have the `coind_aux.cpp` merkle-narrowing patch we thought we'd shipped — that only exists in `perfect1/` and was never built into `/var/stratum/stratum`.
- So DOGE rejects can't be blamed on merkle narrowing (it's not deployed). Look elsewhere: chain-merkle slot collision between DOGE and ZCU chainIDs, or job/share race.

## Rule for future edits

Edit **`/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum`** only. Rebuild there, then copy the `stratum` binary to `/var/stratum/stratum` and `systemctl restart stratum-aws-scrypt`. Ignore all other trees unless intentionally comparing.
