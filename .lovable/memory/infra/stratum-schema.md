---
name: Stratum schema, paths & configs
description: Authoritative stratum binary/config paths on stratum.pool.honest.money and exact yiimpfrontend column names. Read before writing SQL against pool DB or editing stratum config.
type: reference
---

# Stratum host: `ubuntu@stratum.pool.honest.money`

## Binary + runtime layout (verified 2026-07-16)

- **Binary:** `/var/stratum/stratum`
- **Invocation:** `/var/stratum/stratum <algo>` (e.g. `stratum scrypt`)
- **Working dir (cwd):** `/var/stratum` — configs are read as **relative paths from cwd**
- **Live config for scrypt:** `/var/stratum/scrypt.conf` ← **THIS is the file the running process reads**
  - NOT `/var/stratum/config/scrypt.conf` (that path was retired; old contents live in `/var/stratum/config.UNUSED-20260715/`)
- **Logs:** `/var/stratum/scrypt.log` (stdout/stderr) + `/var/stratum/logs/scrypt-YYYYMMDD-HHMMSS-pid<pid>.log`
- **systemd unit:** `stratum-aws-scrypt.service`
- **Scrypt stratum port:** TCP 3433
- **DB:** MariaDB `yiimpfrontend` on 127.0.0.1:3306. **SQL runs inside the `mysql` client, not in bash.** Always wrap queries as `mysql ... -e "SELECT ...;"` (or pipe a heredoc). Never paste bare `SELECT ...` at the shell prompt — bash parses `(` as a syntax error.
- **DB auth on this box (verified 2026-07-17):** MariaDB `root` uses `unix_socket` auth — `mysql -u root -p...` fails with `ERROR 1698 (28000): Access denied`. **Always use `sudo mysql <db> -e "..."`** (no `-u`, no `-p`). Example: `sudo mysql yiimpfrontend -e "SELECT ... FROM blocks WHERE coin_id=(SELECT id FROM coins WHERE symbol='ZCU') LIMIT 5;"`. If a script needs a non-root user, read creds from yiimp config files, not `-u root`.

## ⚠️ NO Ansible template deployed on the live box

`infra/stratum-stack/ansible/roles/stratum/templates/scrypt.conf.j2` exists in the **Lovable repo** but has NOT been rolled out to `stratum.pool.honest.money`. The live box was set up manually. Multiple stale copies of `config.sample/scrypt.conf` exist in `/home/ubuntu/aws/LIVE/*/stratum/config.sample/` from historical checkouts — **ignore them all**.

**To change live stratum config:** edit `/var/stratum/scrypt.conf` directly and `sudo systemctl restart stratum-aws-scrypt`. (Long-term: adopt the Ansible role, but not today.)

## yiimpfrontend schema (verified column names)

### `workers` table
- `id`, `userid`, `algo`, `pid`, `ip`, `name` (wallet), `worker`, `password`, `version`
- `difficulty` — vardiff's current per-session target/ceiling (e.g. 131072, 1048576). **NOT `difficulty_actual`**
- `subscribe`, `time`, `pool_id`
- **NO `last_share` column** on this build (verified 2026-07-16 via `ERROR 1054`). For "recently active worker" checks, join `shares` and filter on `shares.time > UNIX_TIMESTAMP()-N`. Do not `WHERE last_share > ...` — the query will error out.

### `shares` table
- `id`, `userid`, `workerid`, `algo`, `pid`, `time`
- `valid` — 0/1
- `difficulty` — per-share credited diff (vardiff-adjusted, small, e.g. 50-80 in current fleet)
- `share_diff` — miner's claimed hash diff of the nonce found (huge number)
- `error` — int reject code, **NOT `reject_reason`**. Codes: 21=stale, 22=duplicate, 23=low-diff, 24=high-hash/bad-nonce, 25=other
- `algo`, `blockhash`, `height`, `category`
- `coinid` — int FK to `coins.id`. **Column name is `coinid` (no underscore)**, NOT `coin_id`. Verified 2026-07-17 via `DESC shares`. **On merged-mining scrypt, every share row has `coinid = LTC`** — shares are credited against the parent chain only. Aux chains (DOGE/TXC/ISK/ZCU) never appear in `shares`; they only surface in `blocks` when a share happens to meet the aux's child_diff. So `GROUP BY coinid` on `shares` for scrypt will always return one row (LTC) — that's healthy, not a bug. For per-aux health use: (1) `aux submit skip` log lines to confirm wiring, (2) `blocks` table grouped by `coin_id` for end-to-end proof.

### `blocks` table
- Has `coin_id` (FK → `coins.id`) — this is where per-chain block finds are recorded. (Yes, `blocks` uses `coin_id` with underscore while `shares` uses `coinid` without — the schema is inconsistent.)
- Verified 2026-07-17: pool has found 78 LTC, 169 DOGE, 2987 TXC, 2928 ISK, 2490 ZCU blocks. Merged submission end-to-end works for all 5 chains.

## Stratum log line formats

- LTC parent templating: BOTH formats exist on this build (verified 2026-07-17):
  - `LTC template mweb length=N` — new template built (every ~20s)
  - `LTC <height> - diff <N> job <id> to X/Y/Z clients, hash H/T in Nms` — job pushed to miners (every ~20s, interleaved)
  - Either count is a valid parent-chain-healthy signal.
- Per-share aux evaluation: `XXX aux submit skip target parent_diff=P child_diff=C hash=H` — normal, one per aux per share. Child_diff clusters observed 2026-07-17:
  - TXC + ISK: ~128k / ~138k (paired, roughly equal counts)
  - DOGE: ~35M-58M (varies with DOGE net diff)
  - ZCU: intermediate tier


## Known 2026-07-16 findings

- **Mansfield site (48× L9, WAN IP 97.154.36.156)** is on **Verizon Wireless cellular** (`myvzw.com` rDNS). ~207-557 GH/s vs 768 GH/s nameplate; the ~25% gap is structural cellular-link loss (RTT + reconnect storms + vardiff resets to starting_diff on every reconnect).
- Mansfield fleet firmware: `xminer-1.2.7` (third-party, all 48 sessions identical version+password+wallet). No devfee/wallet-swap detected.
- Starting diff on reconnect: 131072. Ramps to 1048576 within ~5 min.
- `ss -K state established "dst <IP>"` kills **all** connections to that IP — do NOT use to test single-socket reconnect. Use `ss -K state established "dst <IP>:<PORT>"` with a specific peer port instead.
