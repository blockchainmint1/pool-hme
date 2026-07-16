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
- **DB:** MariaDB `yiimpfrontend` on 127.0.0.1:3306

## ⚠️ NO Ansible template deployed on the live box

`infra/stratum-stack/ansible/roles/stratum/templates/scrypt.conf.j2` exists in the **Lovable repo** but has NOT been rolled out to `stratum.pool.honest.money`. The live box was set up manually. Multiple stale copies of `config.sample/scrypt.conf` exist in `/home/ubuntu/aws/LIVE/*/stratum/config.sample/` from historical checkouts — **ignore them all**.

**To change live stratum config:** edit `/var/stratum/scrypt.conf` directly and `sudo systemctl restart stratum-aws-scrypt`. (Long-term: adopt the Ansible role, but not today.)

## yiimpfrontend schema (verified column names)

### `workers` table
- `id`, `userid`, `algo`, `pid`, `ip`, `name` (wallet), `worker`, `password`, `version`
- `difficulty` — vardiff's current per-session target/ceiling (e.g. 131072, 1048576). **NOT `difficulty_actual`**
- `subscribe`, `time`, `last_share`, `pool_id`

### `shares` table
- `id`, `userid`, `workerid`, `algo`, `pid`, `time`
- `valid` — 0/1
- `difficulty` — per-share credited diff (vardiff-adjusted, small, e.g. 50-80 in current fleet)
- `share_diff` — miner's claimed hash diff of the nonce found (huge number)
- `error` — int reject code, **NOT `reject_reason`**. Codes: 21=stale, 22=duplicate, 23=low-diff, 24=high-hash/bad-nonce, 25=other
- `algo`, `blockhash`, `height`, `category`

## Known 2026-07-16 findings

- **Mansfield site (48× L9, WAN IP 97.154.36.156)** is on **Verizon Wireless cellular** (`myvzw.com` rDNS). ~207-557 GH/s vs 768 GH/s nameplate; the ~25% gap is structural cellular-link loss (RTT + reconnect storms + vardiff resets to starting_diff on every reconnect).
- Mansfield fleet firmware: `xminer-1.2.7` (third-party, all 48 sessions identical version+password+wallet). No devfee/wallet-swap detected.
- Starting diff on reconnect: 131072. Ramps to 1048576 within ~5 min.
- `ss -K state established "dst <IP>"` kills **all** connections to that IP — do NOT use to test single-socket reconnect. Use `ss -K state established "dst <IP>:<PORT>"` with a specific peer port instead.
