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
| Stratum server host                  | `ubuntu@stratum.pool.honest.money` (AWS EC2 · `ip-172-31-83-232`)                 |
| Stratum binaries & runtime files     | `/var/stratum/` on the host                                                    |
| Stratum config (rendered, LIVE)      | `/var/stratum/scrypt.conf` — the `config/` dir is retired (`config.UNUSED-20260715`) |
| Stratum config (source of truth)     | Ansible: `infra/stratum-stack/` · template `scrypt.conf.j2`                    |
| Stratum log                          | `/var/stratum/scrypt.log` (systemd `StandardOutput`/`StandardError=append:`) — there is NO `/var/stratum/log/` dir |
| Systemd unit                         | `stratum-aws-scrypt.service`                                                   |
| Stratum port (scrypt / LTC)          | `3433`                                                                         |
| Public stratum URL                   | `stratum+tcp://stratum.pool.honest.money:3433` (only hostname that resolves + accepts TCP 3433) |
| DEAD stratum hostnames               | `pool.texitcoin.org` (repointed to the website CDN 185.158.133.1 on 29 Aug 2026 — TCP 3433 CLOSED) and `stratum.pool.texitcoin.org` (NXDOMAIN, never created). Any miner still configured with these is OFFLINE. |

| Yiimp frontend DB                    | MySQL `yiimpfrontend` on the same host                                         |
| Yiimp DB credentials                | `/var/web/serverconfig.php` (`YAAMP_DBUSER` / `YAAMP_DBPASSWORD`); parse as root, never use placeholders |
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
| `scrypt.conf`                     | **Live** runtime config (rendered from Ansible). `config/` is retired.  |
| `config.UNUSED-20260715/`         | Old config dir — NOT read by the running service. Do not edit.          |
| `logs/`                           | Per-coin/rotated artifacts. **Not** the main log.                       |
| `scrypt.log`                      | Live log; grep here for `set_difficulty`, `aux submit`, `SCRYPT summary diag` |

## 2b. Coin daemons — exact binaries, configs, datadirs, wallets (NOT on $PATH)

There is **no `litecoin-cli` / `dogecoin-cli` on `$PATH`**. Always use the full
path plus `-conf=`. Copy-paste these:

```bash
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -datadir=/home/ubuntu/.litecoin"
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf -datadir=/home/ubuntu/.dogecoin"
$LCLI getblockcount; $DCLI getblockcount
```

| Coin | Daemon executable | CLI executable | Config / datadir | Wallet file | systemd unit |
| ---- | ----------------- | -------------- | ---------------- | ----------- | ------------ |
| LTC | `/home/ubuntu/litecoin-0.21.4/bin/litecoind` | `/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli` | `/home/ubuntu/.litecoin/litecoin.conf` / `/home/ubuntu/.litecoin` | `wallets/pool/wallet.dat` (`wallet=pool` in conf — Core 0.17+ layout, **not** datadir root) | `litecoind.service` |
| DOGE | `/home/ubuntu/dogecoin-1.14.9/bin/dogecoind` | `/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli` | `/home/ubuntu/.dogecoin/dogecoin.conf` / `/home/ubuntu/.dogecoin` | `wallet.dat` at datadir root (1.14 legacy layout) | `dogecoind.service` |

Notes:
- Wallet passphrase for both lives in `/etc/pool-wallets/passphrase.env` (`WALLET_PASSPHRASE`), mode 600.
- LTC uses a **named** wallet, so RPCs may need `-rpcwallet=pool`, and a rotation
  can't just recreate `wallet.dat` — the daemon refuses to start with a missing
  named wallet (see `infra/wallet-rotation/04-rotate-ltc.sh` temp-conf dance).
- LTC block rewards pay `coins.master_wallet` for the `LTC` row in the
  `yiimpfrontend` DB — rotating the seed without updating that row sends rewards
  to an address the old seed controls.
- `systemctl start litecoind` can exit **non-zero** with `Can't open PID file …
  Operation not permitted` while the daemon actually started fine. Never treat
  that exit code as failure — poll `$LCLI getwalletinfo` instead.
- Confirmed from live processes on 2026-08-29: both daemons use the exact paths,
  configs, and datadirs above. Do not rediscover them with `find`; consult this
  section and use the full command paths.
- A journal line saying `Unknown key name 'StartLimitIntervalSec' in section
  'Service'` means systemd re-read the unit and ignored a misplaced directive.
  It does **not** mean the daemon restarted. Confirm with the unit's `Active:
  active (running) since ...` timestamp and main PID.
- **LTC `getblocktemplate` needs BOTH rules since MWEB:** call it with
  `'{"rules":["mweb","segwit"]}'`. Calling with `["segwit"]` alone returns
  `error code: -8 ... must be called with the segwit & mweb rule sets`. That
  error from a hand-run CLI test is a **test artifact**, not proof the stratum
  is broken — the stratum sends its own ruleset.



### Hot-wallet rotation log

| Coin | Date       | New pool address                     | Old seed kept at                                  |
| ---- | ---------- | ------------------------------------ | ------------------------------------------------- |
| DOGE | 2026-07-2x | `DJvCw7eu1PBMjp8N99QsLxUohpVq6EEyjU` (sweep dest + `coins.master_wallet` since 2026-08-04) | swept — old `DBBv9bpnNV6tjJDM8q6MpiVPPhjpvatCJT` is **orphaned**, never reuse |
| LTC  | 2026-07-28 | `LTyp1No4skV378NbYrR7p6d7wRzDCHgFAa` | `~/.litecoin/wallets/pool.old-seed-20260728-085324` (swept 2026-08-xx) |

`coins.master_wallet` is where yiimp sweeps **pool profit** (not block rewards —
those follow the wallet's own coinbase address). After any seed rotation, re-point
it with `infra/wallet-rotation/11-doge-master-wallet.sh` (verifies `ismine` first).


Rotation blips the share error rate to 30–50% for the 2–3 minutes the daemon is
down (all `error=21`, stale/job-not-found). It settles back under ~1% within
5 minutes. That is expected, not a regression.


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
  SERVERCONFIG=/var/web/serverconfig.php
  eval "$(sed -n "s/.*define( *'\''YAAMP_DBUSER'\'' *, *'\''\([^'\'']*\)'\'').*/DBU='\''\1'\''/p;s/.*define( *'\''YAAMP_DBPASSWORD'\'' *, *'\''\([^'\'']*\)'\'').*/DBP='\''\1'\''/p" "$SERVERCONFIG")"
  test -n "${DBU:-}" && test -n "${DBP:-}" || { echo "DB credentials not found in $SERVERCONFIG"; exit 1; }
  mysql -u "$DBU" -p"$DBP" yiimpfrontend -e "
    SELECT
      COUNT(*) AS workers,
      ROUND(AVG(difficulty)) AS avg_d,
      MIN(difficulty) AS min_d,
      MAX(difficulty) AS max_d,
      SUM(CASE WHEN difficulty <= 1 THEN 1 ELSE 0 END) AS at_start_diff
    FROM workers WHERE algo=\"scrypt\";"
'
```

### Authoritative Yiimp DB shell pattern

Do not write `<db_host>`, `<db_user>`, or `<db_password>` in commands intended
for the host: Bash treats angle brackets as redirection. The canonical local DB
credentials are PHP constants in `/var/web/serverconfig.php`. Existing pool
doctor scripts parse that file. For a one-off query, run the whole parse and
query under `sudo bash -c` so the password is neither displayed nor copied into
shell history.

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

1. **The box** — `stratum.pool.honest.money` (AWS EC2). Goal: own the AWS
   account / SSH keys / systemd units / Ansible repo outright. Until then,
   treat every change as reversible and log it here.
2. **The pool** — stratum binary, coin daemons, Yiimp DB, payout logic.
   All config source-of-truth moves into `infra/stratum-stack/` in this
   repo (or a sibling repo we control). Nothing lives only on the box.
3. **The miners** — 1200 L9s currently pointed at
   `stratum+tcp://pool.texitcoin.org:3433`. At cutover we will reconfigure
   them to `stratum+tcp://stratum.pool.texitcoin.org:3433`, so we can retire
   the current host on our own schedule.
4. **The front-end** — `pool.honest.money` is *this* TanStack app. It talks
   to the back end via server functions / server routes in `src/routes/api/`.

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

### 2026-08-29 — DOGE payout scheduler lock ownership

- `/var/web/doge-payout-cycle.sh` exclusively owns its internal lock at
  `/var/web/runtime/doge-payout/doge-payout-cycle.lock`.
- Cron and manual wrappers must use the separate
  `/var/web/runtime/doge-payout/doge-payout-wrapper.lock`. Wrapping the cycle
  with its own internal lock makes every child invocation self-deadlock and
  report “already running.”
- The active cron is root, every 10 minutes, and logs to
  `/var/web/runtime/doge-payout/cycle.log`.
- Do not pipe an interactive cycle through `tail`: it buffers until process
  exit and makes a healthy long-running backlog drain look hung. Use `tee` for
  live output.

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

### 2026-07-16 — Conroe HAProxy burn-in + fleet-wide share-counting bug

**HAProxy burn-in (PASSED).** Single L9 (`conroe-A`) pointed at
`13.217.211.175:3433` (EC2 HAProxy, `/opt/haproxy-conroe/`). Stratum sees
the session as coming from the EC2 IP as expected:

```
172.31.83.232:3433 ← 13.217.211.175:20796
```

Vardiff climbed correctly through the proxy: `131072 → 688128 → 1048576`
(cap), spm ramped to ~33 before we changed the worker suffix. After the
suffix change, session reconnected cleanly as `worker=conroe-A`, vardiff
restarted at `131072` and began climbing again (spm=84.62 in the first
sample). The proxy path is transparent to vardiff and reconnect logic.

**Fleet-wide share-counting bug (NEW, higher priority than the NAT story).**
Every `SCRYPT client diag` line during burn-in shows
`valid=0 invalid=0 dup=0 low=0 stale=0 other=0` and
`accepted_ghs=0.000`, despite `spm` climbing to 25–33 shares/min. Pool
summary confirms it is not specific to Conroe:

```
SCRYPT summary diag clients=380 active=0 accepted_ghs=0.000
                    valid=0 invalid=0 dup=0 low=0 stale=0 other=0
```

Shares are being submitted (spm > 0) but nothing is being *classified* —
not accepted, not rejected, not stale. They are dropped somewhere between
the network read and the counters. This affects **all 380 clients**, not
just the double-NAT'd ones.

**Reframing §9 numbers.** The earlier "Conroe is delivering ~10% of
capacity because of double-NAT" conclusion was partly wrong. The
double-NAT is a real problem (HAProxy fixes it), but the ~9.5 TH/s
credited vs ~19.2 TH/s expected is mostly this share-counting bug — the
`hashrate` table only counts what the stratum *classifies* as valid, and
right now the stratum classifies nothing. Some blocks still land because
the parent chain check happens on a different path from `valid++`.

**Where to look next (stratum build, not proxy, not NAT):**

1. Diff the current running binary against `LIVE2` / `TXC3` / `live3` in
   `/var/stratum/` — one of those older builds was counting shares
   correctly before the last rebuild. Snapshot which build we're on now
   (`sha256sum /var/stratum/stratum`) before rolling back.
2. Enable higher log verbosity if the build supports it, or add a
   printf around the share-classify path in the source tree once we
   locate it.
3. `active=0` with `clients=380` is the most specific signal — find
   where `active` gets incremented and work backward.

**Action items (updated):**

1. ~~Deploy on-site HAProxy stratum proxy in Conroe~~ — burn-in passed
   on EC2. Next: replicate on the on-site N100/Protectli, cut all 1200
   L9s over. Config lives in `infra/haproxy-conroe/`.
2. ~~Split usernames per tank/container~~ — convention confirmed working:
   `<wallet>.<container>-<tank>-<unit>` (e.g. `.conroe-A`). Roll out to
   the full fleet as part of cutover.
3. **Fix stratum share classification** — new top priority; this is
   what's actually costing hashrate credit fleet-wide.
4. Longer TCP keepalive on miners (unchanged).
5. Ask landlord about DMZ / public IP (unchanged, still parallel).
6. ZCU `getblocktemplate` (unchanged, still low priority).



## 11. Doctors (read-only diagnostics)

Two curl-pipe scripts, source in `infra/pool-doctor/`, served from
`public/install/`. Both change nothing — safe to run any time.

```bash
curl -fsSL https://pool.honest.money/install/payout-doctor.sh | sudo bash
curl -fsSL https://pool.honest.money/install/zcu-doctor.sh    | sudo bash
```

- **payout-doctor** walks the whole LTC/DOGE payout chain: `YAAMP_PAYMENTS_FREQ`,
  loop2/cron, `payouts` rows + errmsg histogram, unpaid `accounts` balances,
  block maturity, LTC wallet `unlocked_until` + `ltc-unlock.timer`, dogecoind
  wallet, `/etc/cron.d/yiimp-doge-payout-cycle`, `doge_payout_ledger`, and the
  last on-chain sends from each wallet.
- **zcu-doctor** proves what the ZCU geth node answers (`eth_blockNumber`,
  `eth_getWork`, `eth_chainId`) versus what the stratum asks for
  (`getblocktemplate`, `getauxblock`, `validateaddress`), plus ZCU lines in
  `scrypt.log` and the aux-submit counts per coin for contrast.

## 12. ZCU outage post-mortem — 13 Aug 2026 (READ BEFORE TOUCHING ZCU)

**Incident:** 05:07–06:33 UTC. TXC and ISK stopped finding blocks for ~90
minutes. `stratum-aws-scrypt` crash-looped 11 times (mix of
`status=1/FAILURE` and `status=11/SEGV`). Two ISK blocks (87057, 87058)
were found on-chain but never recorded in `blocks` and had to be
backfilled by hand.

**Root cause:** the ZCU `getblocktemplate` adapter shim
(`/opt/zcu-adapter/adapter.py`, installed 05:13) made a previously-dead
ZCU start answering RPC. Stratum immediately put ZCU back into the live
aux rotation. When a share qualified as a ZCU aux block, the submit was
rejected with `ERROR Zero Chill Units scrypt: invalid auxpow parent work`,
the submit path spun, and stratum's own deadlock detector killed the
**entire process** — `scrypt dead lock, exiting...` — taking LTC, DOGE,
TXC and ISK down with it, roughly every 6 minutes.

**Hard rules, learned the expensive way:**

1. **"Which files does my script touch" is NOT a safety argument** for a
   shared multi-coin process. Making a dead component *alive* changes
   stratum's behaviour even when stratum's files are never modified. The
   only valid safety argument is: *what happens to the other four coins
   if this new thing fails?*
2. **A failing aux child can kill the whole stratum.** Aux submit
   failures are not isolated to their coin. One bad child = fleet-wide
   outage.
3. **ZCU must never enter the aux rotation** until `createAuxBlock` →
   `submitAuxBlock` is proven end-to-end **out of band**, against a real
   share, with stratum not involved. The unsolved problem is that our
   synthesized parent work does not match what the EVM chain's
   `submitAuxBlock` expects.
4. **`coins.enable=0` does NOT remove a coin from stratum.** Stratum reads
   its coin list from `/var/stratum/scrypt.conf`, not the DB. The DB flag
   only stops yiimp's web/loop side. To disarm ZCU without editing the
   live config, **stop the adapter** so its RPC stops answering.
5. **When hashrate looks wrong, read `journalctl -u stratum-aws-scrypt`
   FIRST.** In this incident three rounds were wasted on the yiimp
   estimator, load average and the `coins` table while the crash loop sat
   in the very first log that should have been pulled. Steady shares/min
   plus dead block cadence plus a restarting service = crash loop, always.

**Fast triage for "are the rigs actually gone?":**

```bash
sudo ss -tn state established '( sport = :3433 )' | wc -l   # ~1200+ = fleet present
sudo journalctl -u stratum-aws-scrypt --since '-30 min' --no-pager \
  | grep -cE 'SEGV|Failed with result'                      # >0 = crash loop
# LIVE log is /var/stratum/scrypt.log -- logs/stratum-current.log is a rotated
# snapshot and can be hours stale. Grepping the stale file hid 90 min of
# 'error getblocktemplate' on 14 Aug 2026.
sudo grep -c 'dead lock' /var/stratum/scrypt.log
sudo tail -n 0 -F /var/stratum/scrypt.log | grep -i 'error getblocktemplate'
```

A low TH/s reading with steady shares/min is the yiimp estimator sawtooth,
not lost hashpower. Do not place an emergency NiceHash rental on that
number alone — check the socket count first.

## 13. ZCU restoration — gate + forward-ported binary (staged 13 Aug 2026)

**Status (13 Aug 11:16 UTC):** Forward-ported binary is **LIVE** on
`/var/stratum/stratum` (rollback at `/var/stratum/stratum.rollback`); canary
ALL GREEN after the swap. Gate is **LIVE in dry-run** as systemd unit
`zcu-gate` on :8749. ZCU is still **out of the aux rotation** — the last
step is `zcu-rotate.sh ON`.

### How ZCU enters/leaves the rotation

Not via `scrypt.conf`. yiimp's scrypt stratum builds its aux-child list from
the **`coins` table**. `infra/pool-doctor/zcu-rotate.sh` is the only supported
way to flip it:

```bash
curl -fsSL "https://pool.honest.money/install/zcu-rotate.sh?v=$(date +%s)" | sudo bash -s STATUS
curl -fsSL "https://pool.honest.money/install/zcu-rotate.sh?v=$(date +%s)" | sudo bash -s ON    # coins.enable=1, rpcport=8749, restart
curl -fsSL "https://pool.honest.money/install/zcu-rotate.sh?v=$(date +%s)" | sudo bash -s OFF   # rollback, ~5s
```

`ON` refuses unless the gate is on :8749, geth on :8747, the live binary has
ZCU symbols, and a junk submit ACKs `true`. It auto-reverts if `dead lock`
appears in the 30s sample after restart.

### Gate is a systemd unit (v2)

`zcu-gate.service`, env in `/etc/zcu-gate.env`, `Restart=always`, logs to
`/var/log/zcu-gate.log`. v1's `nohup` launch silently died and `START` was an
unrecognised mode that did nothing — both fixed in v2.


### The fix (two parts)

1. **Gate adapter** (`zcu-gate.sh`, source `infra/pool-doctor/zcu-gate.sh`):
   Sits on port 8749 between stratum and geth (8747). Scrypt-checks every
   `submitauxblock` offline against the target recorded at `createauxblock`
   time. Misses are ACKed `true` and dropped — geth never sees them. Only
   target-meeting blobs (~3 in 17,000) are forwarded. Even a forwarded
   blob that geth rejects still returns `true` to stratum. The deadlock
   path (submit error → stratum kills itself) is **structurally unreachable**.
   Rate-limited to 6 forwards/min. `ZCU_DRY_RUN=1` makes it forward nothing
   (pure shadow) while still ACKing every submit.

2. **Forward-ported binary** (`zcu-forwardport.sh` v4): ZCU-capable binary
   built from the 3 Jun `PROD4B` source tree with two LIVE-side fixes
   forward-ported: (a) NiceHash difficulty clamp in `client.cpp`, (b)
   `db.cpp` allowlist changed to `ISK || TXC || ZCU` so DOGE stays at
   `auxpow_rpc_mode=0` (the ~20% DOGE accept bug). The ZCU tree's
   thread-safety fixes (log-reopen mutex, aux snapshot under lock,
   commitment output) are preserved.

   Staged at: `/root/ZCU-FWDPORT-20260813T110125Z/stratum`
   Build log:  `/root/ZCU-FWDPORT-20260813T110125Z/build.log`

### VERIFY proof (13 Aug 2026)

17,143 captured blobs were scrypt-checked offline. 3 met the ZCU aux
target. The auxpow blob format and parent-work maths are **both correct**.
The only defect was stratum submitting every share to geth with no filter —
geth rejected ~99.98% and a rejection is what tripped the deadlock detector.
The gate is that filter.

### Deployment sequence (maintenance window)

**Preconditions:** AMI snapshot taken. `pool-snapshot.sh SAVE + VERIFY`
completed. Canary baseline clean.

```bash
# 1. Install the gate (no restart, zero downtime — current binary ignores ZCU)
curl -fsSL "https://pool.honest.money/install/zcu-gate.sh?v=$(date +%s)" | sudo bash -s INSTALL
#    Self-tests: junk submit must return {"result": true ...}

# 2. Swap the binary (brief restart, ~5s downtime)
sudo cp -a /var/stratum/stratum /var/stratum/stratum.rollback
sudo install -m755 /root/ZCU-FWDPORT-20260813T110125Z/stratum /var/stratum/stratum
sudo systemctl restart stratum-aws-scrypt

# 3. Canary — NRestarts must stay 0, TXC/ISK blocks must continue
curl -fsSL "https://pool.honest.money/install/mining-canary.sh?v=$(date +%s)" | sudo bash

# 4. Monitor the gate — watch for WINNER / ACCEPTED lines
sudo tail -f /var/log/zcu-gate.log
curl -fsSL "https://pool.honest.money/install/zcu-gate.sh?v=$(date +%s)" | sudo bash -s STATUS
```

### Rollback (always available)

```bash
# Stop the gate — drops ZCU from the rotation immediately (safe, no deadlock)
curl -fsSL "https://pool.honest.money/install/zcu-gate.sh?v=$(date +%s)" | sudo bash -s STOP

# Restore the old binary
sudo install -m755 /var/stratum/stratum.rollback /var/stratum/stratum
sudo systemctl restart stratum-aws-scrypt
```

### Conservative option

Deploy the gate with `ZCU_DRY_RUN=1` first (forwards nothing, pure shadow
mode). Verify canary is clean for 30–60 min. Then stop the gate and reinstall
without `DRY_RUN` to start forwarding real winners.

### Service persistence and RPC compatibility

The gate runs as the enabled `zcu-gate.service` systemd unit and survives a
reboot. It translates both yiimp's lowercase `scrypt_*auxblock` calls and the
native EVM `eth_blocknumber` height call. Bitcoin-style `gettransaction` is
intentionally unsupported: ZCU is an EVM chain, and fabricating wallet
transaction data would risk incorrect accounting. Those calls are harmless
to mining and remain visible in the STATUS unhandled-method breakdown.

## 14. ZCU steady state — monitoring after restoration (13 Aug 2026)

ZCU went live again at 12:28 UTC on 13 Aug 2026: gate ARMED, winners forwarding,
geth tip advanced 19386 → 19390 in ~10 minutes with LTC/DOGE/TXC/ISK untouched.
The following three pieces are the permanent steady-state monitoring.

### mining-canary.sh v5 — section 5b "ZCU chain progress"
Records the geth tip in `/var/lib/mining-canary-zcu.tip` on every run and reports:
- tip delta since the previous canary run (WARN if 0 after ≥20m)
- yiimp DB ZCU height vs geth tip (WARN if lag > 25 — this is what the homepage shows)
- `zcu-mainnet-yiimp-block-sync` in a failed state (FAIL)
- count of `ambiguous yiimp auxpow payload` rejects

### zcu-deadman.sh v2 — retuned, NOT removed
The deadman stays installed permanently. Do not uninstall it because "ZCU works now":
the flood path that took the fleet down for 90 minutes on 13 Aug can re-open on a geth
restart, a reorg, or an unhandled RPC shape. It costs nothing while idle.
- dry-spell trigger raised **15m → 60m** (the 15m value was a plane-ride setting and
  false-positives on ordinary TXC/ISK variance)
- hard triggers unchanged and never relaxed: stratum restart count increased,
  new `dead lock, exiting` lines, stratum unit not active
- new in v2: Telegram **notify** on every geth-accepted ZCU block and every
  rejected gated winner, not just on a trip. Creds inherited from
  `/etc/nicehash-watcher.env`; state counters in `/var/lib/zcu-deadman/`.

### zcu-sync-timer.sh v1 — homepage freshness
`zcu-mainnet-yiimp-block-sync` is a `Type=oneshot` unit that shipped with **no timer**,
so the yiimp DB only advanced when someone ran it by hand — that is why the site showed
a 13 July height while the chain was at 19390. This installs `zcu-sync.timer` which runs
the existing sync unit every 120s. It touches nothing else.

```bash
curl -fsSL "https://pool.honest.money/install/zcu-sync-timer.sh?v=$(date +%s)" | sudo bash -s INSTALL
curl -fsSL "https://pool.honest.money/install/zcu-deadman.sh?v=$(date +%s)"    | sudo bash -s INSTALL
curl -fsSL "https://pool.honest.money/install/mining-canary.sh?v=$(date +%s)"  | sudo bash -s CHECK
```

### Known-benign
`ambiguous yiimp auxpow payload: 2 candidates` — geth found two plausible auxpow blobs
in one submit and refused to guess. Observed 1 reject in 5 forwards on 13 Aug; the next
submit of the same hash was accepted. Only investigate if the reject count grows faster
than accepted blocks. Future hardening: have the gate pick the candidate whose coinbase
commits to the ZCU aux merkle root before forwarding.
