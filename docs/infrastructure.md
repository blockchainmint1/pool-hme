# HME Pool — Infrastructure & Settings Reference

> Living doc. When we discover where something lives, or change a setting,
> update this file in the same commit. If it isn't in here, assume we'll
> forget it by next week.
>
> Part of the [honest.money](https://honest.money) ecosystem · TEXITcoin pool ops.

---

## 1. Sites of truth

| Concern                              | Where it actually lives                                                        |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| Pool frontend (this repo)            | TanStack Start app · `src/routes/`                                             |
| Stratum server host                  | `ubuntu@pool2.iskandercoin.com` (AWS EC2 · `ip-172-31-83-232`)                 |
| Stratum binaries & runtime files     | `/var/stratum/` on the host                                                    |
| Stratum config (rendered)            | `/var/stratum/config/scrypt.conf` (fallback: `/var/stratum/scrypt.conf`)       |
| Stratum config (source of truth)     | Ansible: `infra/stratum-stack/` · template `scrypt.conf.j2`                    |
| Stratum log                          | `/var/stratum/scrypt.log`                                                      |
| Systemd unit                         | `stratum-aws-scrypt.service`                                                   |
| Stratum port (scrypt / LTC)          | `3433`                                                                         |
| Public stratum URL (today)           | `stratum+tcp://pool.texitcoin.org:3433`                                        |
| Public stratum URL (future)          | `stratum+tcp://stratum.pool.texitcoin.org:3433`                                |
| Yiimp frontend DB                    | MySQL `yiimpfrontend` on the same host                                         |
| Yiimp DB user                        | `stratum` (password in `~/.my.cnf` / Ansible vault — not here)                 |
| Vardiff report script (workstation)  | `./infra/stratum-stack/scripts/vardiff-report.sh` (NOT on the box)             |

## 2. `/var/stratum/` file map

Everything here is a binary or a runtime artifact. Never `sed` a live file —
render from Ansible and reload the unit.

| File                              | Purpose                                                                 |
| --------------------------------- | ----------------------------------------------------------------------- |
| `stratum`                         | Current active stratum binary (running under systemd)                   |
| `stratum.bak.YYYYMMDD-HHMMSS`     | Timestamped rollback copies                                             |
| `stratum.4c-r1.prev`              | Last previous build (4-coin r1 line)                                    |
| `live1`, `live3`, `live3-V`       | Prior live builds kept for quick swap                                   |
| `LIVE2`, `TXC3`                   | Named build snapshots (TXC3 = TEXITcoin-aware build)                    |
| `aws`                             | AWS-tuned build                                                         |
| `3h-logs`, `3h-logs-updated`      | Build variants with 3-hour log rotation                                 |
| `config/scrypt.conf`              | Rendered runtime config (from Ansible)                                  |
| `scrypt.log`                      | Live log; grep here for `set_difficulty`, `aux submit`, `SCRYPT summary diag` |

## 3. Scrypt merged-mining coin set

All five share a single scrypt work unit. Only TXC / ISK / ZCU are actually
*found* by this pool — LTC and DOGE come in as auxpow credit.

| Symbol | Name        | Role                                    |
| ------ | ----------- | --------------------------------------- |
| LTC    | Litecoin    | Parent chain · miners register wallet   |
| DOGE   | Dogecoin    | Merge-mined via LTC · miners register wallet |
| ISK    | Iskander    | Merge-mined · pool-found                |
| TXC    | TEXITcoin   | Merge-mined · pool-found · primary coin |
| ZCU    | Zero Chill U | Merge-mined · pool-found               |

DB check for which coins are actually enabled:

```sql
SELECT id, name, symbol, algo, enable, auto_ready, rpcencoding, rpchost, rpcport
FROM coins
WHERE algo='scrypt' AND (enable=1 OR auto_ready=1)
ORDER BY symbol;
```

## 4. Miner fleet

| Item              | Value                                          |
| ----------------- | ---------------------------------------------- |
| Model             | Antminer L9                                    |
| Count             | 1200 units                                     |
| Containers        | 6                                              |
| Location          | Single site (TX)                               |
| Expected clients on stratum | ~1050 concurrent (from `SCRYPT summary diag`) |

Miner-version distribution and per-worker hashrate: pulled from the stratum
active connection table; will move to a live server function once the stratum
moves to `stratum.pool.texitcoin.org`.

## 5. Difficulty / vardiff (current known state)

- `scrypt.conf.j2` sets initial `difficulty = 0.25`, `diff_min = 65536`.
- Vardiff is supposed to bump each worker up to `diff_min` on connect.
- **Confirmed 2026-07-15:** vardiff is working in the DB even if
  `mining.set_difficulty` is not showing clearly in `scrypt.log`.
- Snapshot from the stratum host during the Conroe L9 incident:
  `workers=1050`, `avg_d=578074`, `min_d=131072`, `max_d=1048576`,
  `at_start_diff=0`.
- `aux submit skip target parent_diff=… child_diff=…` is normal merged-mining
  filtering for shares that are not strong enough to submit as aux blocks. Do
  not treat that line by itself as a rejected miner share.
- Do **not** hand-edit difficulty on the box. Adjust `scrypt.conf.j2` and
  re-run:
  ```bash
  ansible-playbook infra/stratum-stack/playbook.yml --tags config,systemd
  ```

## 6. Useful diagnostic one-liners

```bash
# Is the stratum sending difficulty at all?
sudo grep -E 'set_difficulty|mining\.set_difficulty' /var/stratum/scrypt.log | tail -10

# What does the pool think its client count / accepted hashrate is?
sudo grep 'SCRYPT summary diag' /var/stratum/scrypt.log | tail -3

# Which miners are actually connected on port 3433?
sudo ss -tn state established sport = :3433 | awk 'NR>1{split($5,a,":");print a[1]}' | sort | uniq -c | sort -rn | head

# Vardiff snapshot from the DB (from the box):
sudo bash -c '
  CONF=/var/stratum/config/scrypt.conf
  [ -f "$CONF" ] || CONF=/var/stratum/scrypt.conf
  U=$(awk -F"= *" "/^username/{print \$2; exit}" "$CONF")
  P=$(awk -F"= *" "/^password/{print \$2}" "$CONF" | tail -1)
  D=$(awk -F"= *" "/^database/{print \$2; exit}" "$CONF")
  mysql -u "$U" -p"$P" "$D" -e "
    SELECT
      COUNT(*) AS workers,
      ROUND(AVG(difficulty)) AS avg_d,
      MIN(difficulty) AS min_d,
      MAX(difficulty) AS max_d,
      SUM(CASE WHEN difficulty <= 1 THEN 1 ELSE 0 END) AS at_start_diff
    FROM workers WHERE algo=\"scrypt\";"
'
```

## 7. Change-management rules

1. **No `sed` on the live box.** Edit the Ansible template, run the playbook.
2. **No rebuilds without a snapshot.** Copy the current binary to
   `stratum.bak.YYYYMMDD-HHMMSS` before replacing.
3. **Restart, don't reload, after a coin-list change.** Cold `stop → sleep 5
   → start` clears cached auxpow state; `systemctl reload` does not.
4. **Log everything unusual in this file.** If we spent more than 15 minutes
   finding a path or a setting, it belongs here.

## 8. Related project docs

- [Manifesto](../src/routes/manifesto.tsx) — why this pool exists
- [Terms of Service](../src/routes/terms.tsx) — plain-language pool rules
- [Privacy](../src/routes/privacy.tsx) — data we collect / don't
- Build docs for the TEXITcoin chain and Omni L2: <https://texitcoin.org/build>

## 8b. Takeover plan (in progress)

We are in the process of taking **full control** of the entire stack:

1. **The box** — `pool2.iskandercoin.com` (AWS EC2). Goal: own the AWS
   account / SSH keys / systemd units / Ansible repo outright. Until then,
   treat every change as reversible and log it here.
2. **The pool** — stratum binary, coin daemons, Yiimp DB, payout logic.
   All config source-of-truth moves into `infra/stratum-stack/` in this
   repo (or a sibling repo we control). Nothing lives only on the box.
3. **The miners** — 1200 L9s currently pointed at
   `stratum+tcp://pool.texitcoin.org:3433`. At cutover we will reconfigure
   them to a **new stratum IP / hostname we control** (target:
   `stratum.pool.texitcoin.org`), so we can retire the current host on our
   own schedule.
4. **The front-end** — `pool.texitcoin.org` becomes *this* TanStack app
   (currently served at `pool.honest.money` preview). It will talk to the
   back end via server functions / server routes in `src/routes/api/`.

Learning goals while we still have limited access:
- Enumerate every config file, cron job, systemd unit, and daemon on the
  box. Record here.
- Snapshot the Yiimp DB schema (coins, workers, shares, blocks, payments,
  accounts) and check it in under `docs/schema/`.
- Identify every external endpoint / IP the stratum talks to (coin RPCs,
  DNS seeds, monitoring) so we can reproduce them in the new environment.
- Diff the various `/var/stratum/` binaries (`live1`, `live3`, `LIVE2`,
  `TXC3`, `aws`, `3h-logs*`) — figure out which source tree each came
  from and where that source lives.

## 9. Incident notes

### 2026-07-15 — Conroe L9 scale-up incident

- Yesterday the scrypt pool was operating normally.
- A large additional batch of Antminer L9s was brought online in Conroe; the
  problem started after that scale-up.
- Current status as recorded during troubleshooting: **TXC and ISK blocks are
  still being made**.
- **ZCU has still not produced blocks**, but this is explicitly lower priority
  and should be handled later after the main L9/throughput issue is stable.
- Current working conclusion: this is not simply an initial-difficulty/vardiff
  problem. The DB shows all connected L9 workers have been assigned real
  vardiff values and none remain at the `0.25` start difficulty.
- Do not lose the context that this has already consumed ~12 hours of
  troubleshooting; prefer recording exact paths, command output, and conclusions
  here rather than re-discovering them in chat.
