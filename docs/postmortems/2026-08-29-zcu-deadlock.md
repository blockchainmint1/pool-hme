# Post-mortem: 2026-08-29 ZCU adapter deadlock → full stratum outage

Status: root cause identified (design defect), remediation pending (ZCU removal from rotation, then structural fix before re-enable).

## Timeline (UTC)

- **14:53** — geth flushes trie cache cleanly; ZCU chain healthy.
- **15:12:27** — last ZCU seal before the incident (block 26932). NOTE: geth then seals 26933 at **15:15:11** — geth was *never* sick.
- **~15:03–15:07** — zcu-gate adapter repeatedly serves a frozen template (`height=1`, same hash) while continuing to ACK.
- **13:58–15:04** — simultaneous `error getblocktemplate` for LTC, DOGE, TXC, ISK — shared refresh path starving.
- **15:20:26** — dying process: ~1,232 clients connected, `active=0`, `accepted_ghs=0` — sockets alive, work dead.
- **15:23:34** — `/var/stratum/logs/stratum-20260829-150000-pid2443993.log`: `scrypt dead lock, exiting...`
- **15:23:35** — systemd: main PID 2443993 exit `status=1/FAILURE`. Not OOM, not a signal, not manual.
- **15:23:40** — systemd auto-restarts stratum (new PID 2766200). TXC/ISK recover.
- **15:23:46** — `zcu-gate.service` restarted by systemd as part of the same dependency bounce.
- **Post-restart** — DOGE `getauxblock` templates flowing (chainid=98, advancing heights); LTC/DOGE nonetheless enter a long find drought; ZCU never seals again.

## Root cause

Two design defects in the ZCU gate adapter (`zcu-gate.sh` Python adapter), compounding:

1. **The adapter cannot report failure.** `m_getblocktemplate` substitutes `height=0/1` and a placeholder template when geth doesn't answer, instead of returning an RPC error. The stratum sees a "healthy" child serving garbage work.
2. **Target gating happens inside the adapter round-trip, synchronously, on a single Python event loop.** Every share is forwarded for a ZCU target check. Under fleet load (~2,100 shares/min) the adapter saturates itself; because it never errors, it back-pressures the stratum's shared coin-refresh path until the process-wide deadlock watchdog fires — taking down LTC, DOGE, TXC, ISK, and ZCU together.

Geth was healthy throughout (sealed 26933 four minutes after "ZCU died", RPC answering `0x6935` 13h later). This was purely an adapter architecture failure.

## What it cost

- ~5 min full fleet outage (deadlock → restart).
- ZCU production lost from 15:12 onward (~13h+ before detection — the always-ACK adapter hid it from the canary).
- LTC/DOGE find drought post-restart (statistically anomalous; under investigation whether residual adapter load contributed).
- An apparent "hashrate cliff" (clients connected but `active=0`) that was initially misread as a stats problem.

## What did NOT cause it (ruled out with evidence)

- **Geth** — sealed continuously, no errors, RPC healthy.
- **DNS / `pool.texitcoin.org` shutdown** — happened ~15:41, after the crash. No runtime dependency exists.
- **Hashrate-display / yiimp-api v0.7.x work** — began ~15:56, after the crash.
- **DOGE payout archive / PHP / cron changes** — web-side only; cannot affect stratum block finding.
- **NiceHash watcher** — reads the API only; no stratum write path.
- **OOM / signal / manual restart** — journal shows none.

## Lessons (permanent)

1. A child aux adapter must **fail loudly**. Never substitute placeholder/stale templates when the backend is unreachable — return an RPC error.
2. **Target gating belongs in the stratum, before the RPC call** — never inside a blocking per-share adapter round-trip.
3. Yiimp's aux refresh is a **shared, process-wide path** with a process-wide deadlock watchdog. One blocking child kills all coins. Any child integration needs bounded timeouts and bounded concurrency.
4. "Adapter up" ≠ "coin mining". Canary must verify **per-coin seals advancing**, not adapter health.
5. Connected sockets ≠ hashing. `active=0` with 1,232 clients is the deadlock signature.
6. The internal watchdog exit (`scrypt dead lock, exiting...`, status 1) is Yiimp *intentionally* dying to force a systemd restart — it's a symptom, not the cause.
7. Post-restart, per-coin droughts must be compared against expectation (luck-vs-regression math) before blaming software — but a <25%-of-expectation 24h rate on the money coin warrants investigation, not patience.

## Recovery / return-to-service plan for ZCU

1. Pre-removal snapshot: `pre-zcu-removal-backup.sh` → `/var/backups/pre-zcu-removal-<ts>/`.
2. Remove ZCU from aux rotation (Ansible `scrypt.conf.j2` + `--tags config,systemd`; never sed live config), restart `stratum-aws-scrypt`, stop/disable `zcu-gate`.
3. Verify LTC/DOGE/TXC/ISK find rates normalize over 12h.
4. Structural adapter fix before any re-enable:
   - target check in stratum / pre-filter before RPC,
   - fail-loud on geth errors (no fake templates),
   - hard timeouts + bounded concurrency on all geth calls,
   - shadow mode 24h proving seals advance and parent/TXC/ISK rates stay at expectation,
   - deadman armed to disarm ZCU *alone* on silence.
5. Only then re-enable in rotation.

## Key evidence locations (on stratum host)

- Old-process log (deadlock): `/var/stratum/logs/stratum-20260829-150000-pid2443993.log`
- Post-restart log: `/var/stratum/logs/*pid2766200*.log`
- Live config: `/var/stratum/scrypt.conf`; binary `/var/stratum/stratum`
- Snapshot: `/var/backups/pre-zcu-removal-<ts>/` with `MANIFEST.sha256`
