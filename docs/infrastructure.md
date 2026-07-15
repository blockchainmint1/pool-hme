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

#### Root cause (confirmed 2026-07-15 ~13:08 UTC)

**The Conroe L9s are behind a single stratum proxy at `209.34.50.105`.**
Socket census on port 3433:

```
977 209.34.50.105    ← Conroe (proxied)
 48 97.154.36.156
 21 99.107.246.68
  1 98.199.83.99
  1 70.105.29.38
  1 65.130.245.188
  1 47.27.209.30
  1 38.158.167.79
```

Because ~93% of the fleet arrives as **one TCP connection / one user**
(`ltc1q8gwep085vk...`), Yiimp's per-worker `speed` accounting for that user
collapses to a near-zero value (`speed 0.000009` spammed once per second)
and any dashboard reading per-worker hashrate looks broken.

Log-event distribution in the last 5000 lines was entirely aux-submit
evaluations (one per aux chain per share):

```
~1667 TXC aux submit
~1667 ISK aux submit
~1666 DOGE aux submit
```

Blocks land because ~9.5 TH/s on the current network is enough to solve
TXC and ISK regularly. But — see the correction below — this is not the
"nothing lost, just reporting" story it initially looked like.

#### Correction — real hashpower shortfall (confirmed 2026-07-15 ~13:15 UTC)

The `hashrate` table is Yiimp's own accepted-work total, not a UI artifact.
Pool-wide hashrate history for scrypt:

```
10:15  6.88 TH/s
10:30  7.98
...
12:45  7.63
13:00  9.57   ← Conroe scale-up shows here
```

- Expected from 1200 × ~16 GH/s L9s: **~19.2 TH/s**.
- Actual credited: **~9.5 TH/s** (about half).
- Conroe delta: **+1.5 TH/s** for a batch that should have added ~16 TH/s.
  Conroe is contributing roughly 10% of its capacity.

#### Correction #2 — double-NAT through leased-space ISP CPE (2026-07-15 ~13:30 UTC)

Per-IP worker+vardiff breakdown from the DB:

```
209.34.50.105   976 workers   avg_d 736k   min 131k   max 1048k   ← Conroe
 97.154.36.156   48 workers   avg_d 914k
 99.107.246.68   21 workers   avg_d 742k
 (six more IPs, 1 worker each)
```

Every one of the 976 Conroe workers has an independent, real per-worker
`difficulty` row. So the "one TCP connection / one user" framing was
wrong — there are 976 distinct L9 → :3433 TCP sessions all egressing
through **one public IP via PAT**.

Actual Conroe topology (per operator, 2026-07-15):

```text
20× L9  →  access switch
10× access switches per container  →  container switch
container switch  →  Omada ER605 (NAT #1, one per container, 6 total)
6× ER605  →  Omada SG2218 (L2 aggregation)
SG2218  →  ISP CPE (NAT #2, landlord-owned)  →  fiber
```

The site is **leased space** — we do not control the ISP CPE, cannot put
it in bridge mode, and cannot get a public IP handoff on our own. All 6
ER605s are PAT'd behind a single public IP (`209.34.50.105`) on that
landlord CPE, so every miner is **double-NAT'd**. Failure modes stack:

1. **ISP CPE session table** — one shared public IP is holding ~1000
   long-lived stratum flows plus DNS/NTP/monitoring for the whole site.
   Consumer/SMB CPEs commonly cap at a few thousand conntrack entries;
   at capacity, new connections drop and existing ones get evicted
   mid-share → reconnect storm → lost shares.
2. **ER605 NAT + SPI CPU** under 1000-ish small-packet stratum sessions.
3. **Session churn** — evictions on either NAT force miner reconnects;
   in-flight shares are lost, vardiff resets, effective hashrate falls.

Net effect matches the observed "~10% of expected hashpower credited"
— most work is generated by the ASICs but never reaches :3433.

#### Chosen fix — on-site stratum proxy (HAProxy)

We do **not** control the ISP CPE and cannot swap it. The fix is to make
the WAN carry as few flows as possible by terminating stratum on the LAN.

Plan: run **HAProxy in TCP mode** on a small Linux box at the Conroe
site (Intel N100 mini-PC, Protectli, or even a Raspberry Pi 5 to start).
All 1200 L9s point at the on-site proxy's LAN IP on :3433. HAProxy
opens a small pool of upstream TCP connections to
`stratum.pool.texitcoin.org:3433` and multiplexes shares over them.

Why this helps under the leased-CPE constraint:

- The ISP CPE stops seeing ~1000 concurrent WAN flows and instead sees
  a handful of long-lived HAProxy → cloud stratum connections.
- ER605 NAT still exists on the LAN side of HAProxy but the WAN NAT
  (the one we can't touch) is off the critical path.
- HAProxy owns TCP keepalive / timeout policy — we can set aggressive
  keepalives toward miners and long, stable keepalives upstream so a
  transient WAN blip doesn't cascade into a full-fleet reconnect storm.
- Survives short internet flaps: miners stay connected to the LAN
  proxy; HAProxy reconnects upstream when the WAN returns.
- Sets up option 2 later (full on-site stratum + local coin daemons).

Sketch (details go in §10 when we build it):

```haproxy
frontend stratum_in
    bind :3433
    mode tcp
    timeout client 10m
    default_backend stratum_out

backend stratum_out
    mode tcp
    option tcp-check
    timeout server 10m
    timeout connect 5s
    server pool1 stratum.pool.texitcoin.org:3433 check inter 5s
```

#### Action items (revised, leased-space constraint)

1. **Deploy on-site HAProxy stratum proxy in Conroe.** Chosen fix. Point
   all 1200 L9s at the LAN VIP. Details in §10 (to be written when we
   build it).
2. **Split usernames per tank/container for diagnostics.** All L9s
   currently share one LTC username, so per-tank hashrate is invisible
   even though per-worker rows exist. Worker-suffix convention:
   `ltc1q…worker.<container>-<tank>-<unit>` (Yiimp splits on `.`,
   payout stays on the wallet). Independent of the proxy — makes the
   *next* incident diagnosable in minutes.
3. **Longer TCP keepalive on the miners** so reconnect churn drops when
   either NAT does evict.
4. **Ask the landlord** (parallel, low urgency now that HAProxy is the
   plan): dedicated public IP / DMZ passthrough / a /29 we can assign
   ourselves. Not blocking, but changes the long-term topology if they
   say yes.
5. **Cutover alignment (§8b).** Do the HAProxy deploy and username
   split *before* re-homing Conroe to `stratum.pool.texitcoin.org:3433`,
   otherwise the cutover will look like it broke things when the
   underlying issue is still Conroe's LAN/WAN path.
6. **ZCU `getblocktemplate` is broken** (`Zero Chill Units error
   getblocktemplate result`). Separate ticket, low priority per operator.



#### Log vocabulary lesson (do not repeat)

This build of the stratum does **not** emit `mining.subscribe`,
`mining.authorize`, or `share accepted/rejected` lines. Grepping for those
returned 0 and misled us for hours. In this build:

- Accepted shares appear as `<COIN> aux submit …` lines (one per aux chain).
- Client connect appears as `[ip] <user>, <algo>, using N workers`.
- Per-user reported speed appears as `[ip] <user>, <algo>, speed <n>`.

When diagnosing a new build, first enumerate the event vocabulary:

```bash
sudo tail -n 5000 /var/stratum/scrypt.log \
  | awk '{print $2, $3, $4}' | sort | uniq -c | sort -rn | head -20
```

#### Correct peer-IP census command

```bash
sudo ss -Htn state established sport = :3433 \
  | awk '{print $4}' | sed 's/:[0-9]*$//' \
  | sort | uniq -c | sort -rn | head -10
```

(The earlier `awk 'NR>1{split($5,…)}'` version parsed the wrong column on
this box's `ss` output and reported everything as blank.)

#### Yiimp DB — `workers` has no `hashrate` column

Per-worker `workers` row stores `difficulty`, not `hashrate`. Pool-wide
hashrate history is in the `hashrate` table:

```sql
SELECT FROM_UNIXTIME(time) t,
       ROUND(hashrate/1e12,2)     TH_s,
       ROUND(hashrate_bad/1e12,2) TH_bad
FROM hashrate WHERE algo='scrypt'
ORDER BY time DESC LIMIT 12;
```

To confirm columns on any table before querying:
`SHOW COLUMNS FROM <table>;`

