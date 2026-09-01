#!/usr/bin/env bash
# mining-canary.sh -- READ ONLY. ~35-second proof that LTC/DOGE/TXC/ISK mining
# is still healthy. Run BEFORE and AFTER every change. Exit 0 = pass, 1 = fail.
#
#   baseline:  curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash -s BASELINE
#   check:     curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash
#   watch:     curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash -s WATCH 10
#
# Why this exists: on 13 Aug 2026 the ZCU adapter put ZCU back in the aux
# rotation, a failed aux submit tripped stratum's deadlock detector, and the
# WHOLE scrypt stratum crash-looped for 90 minutes -- taking LTC, DOGE, TXC and
# ISK with it. Shares/min looked perfect the entire time. Nothing but the
# service restart counter and the block cadence would have caught it.
#
# ---------------------------------------------------------------------------
# VERSION LOG -- bump CANARY_VERSION on EVERY change, newest entry first.
# If the banner does not show the version you expect, the site has not been
# republished yet (public/install/ is served from the published build).
#
#   v9  2026-09-01  False-positive cleanup after the first ARMED v6 run:
#                     * section 4 ZCU gate flag now reads /etc/zcu-adapter-v6.env
#                       (v6's real flag). v8 read the retired /etc/zcu-gate.env,
#                       so an ARMED v6 printed "gate DISARMED, cadence not
#                       judged" while ZCU was sealing blocks.
#                     * section 5 v6 mode + counters now come from the same
#                       sources as the adapter's own STATUS: ZCU_DRY_RUN in
#                       /etc/zcu-adapter-v6.env and the JSONL capture at
#                       /var/log/zcu-v6-capture.jsonl (counted by "kind").
#                       v8 looked for a state.json that v6 never writes, so it
#                       printed mode=UNKNOWN and every counter as n/a.
#                     * section 4d: "ZCU aux submit skip duplicate ...
#                       reason=accepted" lines are the adapter correctly
#                       de-duplicating a hash geth ALREADY accepted -- wins,
#                       not losses. They no longer count as "blocks we MINED
#                       and LOST" and get their own informational line.
#   v8  2026-09-01  FULL-STACK release. v7 only judged mining; three real
#                   incidents lived outside it, so the canary now also checks:
#                     * section 5 rewritten for adapter v6: recognises the v6
#                       process + its state counters (forwarded / would_forward
#                       / geth_fail / self_disarm / shed) and reports ARMED vs
#                       SHADOW. v7 mis-flagged v6 as the legacy crash path.
#                     * new 5c: the ZCU -> yiimp block-sync bridge. Discovers
#                       the REAL unit name (1 Sep: reset-failed said "Unit not
#                       loaded" while the job existed under another name),
#                       flags disabled units, and counts INSERTED_ZCU_BLOCK in
#                       the last hour. A frozen homepage with a healthy chain
#                       is a sync-bridge fault, never a mining fault.
#                     * new 5d: payouts + wallets -- loop2 alive, DOGE cycle on
#                       the mandatory */10 cadence, LTC/DOGE wallet lock state
#                       and balances, payouts with no txid, last payout per coin.
#                     * new 5e: host + public surface -- disk, load, memory,
#                       OOM kills in 24h, pool API + site status HTTP codes,
#                       nicehash-watcher state.
#   v7  2026-08-30  DEEP DIVE release. "One DOGE block in 24h" needed evidence,
#                   not vibes, so the canary now measures LUCK instead of just
#                   liveness:
#                     * new section 4c: expected-vs-actual finds per coin over
#                       1h/24h/7d from hashrate x window / network difficulty.
#                       Under 25% of expectation on a >=5-block expectation is
#                       a REGRESSION, not variance. This is the only section
#                       that can tell "the pool is fine, luck was bad" apart
#                       from "high-difficulty submits are being dropped".
#                     * new section 4d: parent-chain submit evidence -- counts
#                       block-candidate / submitblock / submitauxblock / accept
#                       / reject lines per coin over the whole live log, so a
#                       FOUND-but-REJECTED block can never look like bad luck.
#                     * new section 4e: reject + stale rate and share-difficulty
#                       spread over 10 min (a vardiff collapse silently costs
#                       real work), plus daemon tip vs our last recorded block.
#                     * false positives fixed: the 30s log sample is skipped
#                       when the live log was just rotated, and the TXC/ISK dry
#                       thresholds moved to WARN 15m / FAIL 25m (8/15 fired on
#                       a healthy pool during normal variance).
#   v6  2026-08-13  ZCU added to section 4 block cadence (and to the baseline

#                   height set). Only judged when the gate is ARMED; a dry ZCU
#                   with accepted gate blocks is reported as a yiimp-sync issue,
#                   never as a mining failure. Limits WARN 30m / FAIL 60m.
#   v5  2026-08-13  New section 5b: ZCU chain progress -- geth tip delta between
#                   canary runs, yiimp DB lag vs geth (what the homepage reads),
#                   block-sync failure detection, and ambiguous-auxpow counter.
#   v4  2026-08-13  Two false FAILs killed the verdict while the pool was
#                   objectively healthy (TXC/ISK blocks 2m old):
#                   (a) 'dead lock' was counted over the WHOLE log, so lines
#                       from the 13 Aug outage still FAILed a stratum that has
#                       been up 2.6h with NRestarts=0. Now age-scoped: only
#                       FAILs when deadlock lines are recent AND the service
#                       actually restarted / is young; otherwise WARN historic.
#                   (b) coin-name detection only matched long names. yiimp logs
#                       job/aux lines by symbol and other tokens, so a perfectly
#                       cycling loop showed "ZERO coin names". Pattern widened
#                       and cross-checked against block cadence -- if TXC/ISK
#                       found blocks recently the loop IS cycling, so it is at
#                       most a WARN about log verbosity, never a FAIL.
#   v3  2026-08-13  Version banner + version log. Section 4b now also flags a
#                   log file that is being written but contains no coin names.
#   v2  2026-08-13  Read the LIVE log (/var/stratum/scrypt.log), not the stale
#                   rotated logs/stratum-current.log. New section 4b: 30s live
#                   sample, hard FAIL on 'error getblocktemplate',
#                   createauxblock/getauxblock errors, 'unable to find the
#                   wallet for coinid', or zero log lines. TXC/ISK dry
#                   thresholds tightened to WARN >8m / FAIL >15m (was 15/30) --
#                   a 20m dry spell used to print ALL GREEN.
#   v1  2026-08-13  Initial: service restarts/SEGV/deadlock, socket count,
#                   share flow, block cadence, aux-list sanity, baseline diff.
# ---------------------------------------------------------------------------
CANARY_VERSION="v9"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-CHECK}"
WATCH_MINS="${2:-10}"
UNIT=stratum-aws-scrypt
LOG=/var/stratum/logs/stratum-current.log
# stratum opens a NEW log file on restart; follow the freshest MAIN log.
# client-*.log only holds per-miner chatter -- coin names never appear there,
# which made section 5 report lines=0 for everything.
# NOTE (14 Aug 2026): the *live* file stratum writes to is /var/stratum/scrypt.log.
# logs/stratum-current.log is a rotated snapshot and can be hours stale -- grepping
# it is how we missed 90 minutes of 'error getblocktemplate'. Always pick the
# most-recently-written candidate, scrypt.log included.
NEWEST=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | head -1)
[ -z "${NEWEST:-}" ] && NEWEST=$(ls -t /var/stratum/logs/*.log 2>/dev/null | grep -v '/client-' | head -1)
[ -z "${NEWEST:-}" ] && NEWEST=$(ls -t /var/stratum/logs/*.log 2>/dev/null | head -1)
[ -n "${NEWEST:-}" ] && LOG="$NEWEST"
LOGAGE=$(( $(date -u +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) ))
STATE=/var/lib/pool-canary
BASE="$STATE/baseline.env"
PORT=3433
# v4: yiimp logs jobs/aux by symbol and short tokens, not just long coin names.
# Matching only long names made a healthy loop look dead.
COINPAT='litecoin|dogecoin|texitcoin|iskander|zero *chill|\bLTC\b|\bDOGE\b|\bTXC\b|\bISK\b|\bZCU\b|getblocktemplate|createauxblock|getauxblock|new block|block found|coind|job'
mkdir -p "$STATE"

MY() { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql yiimpfrontend -t -e "$1" 2>&1; }

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hr()   { printf '\n===== %s\n' "$*"; }

echo "mining-canary $CANARY_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

##############################################################################
hr "1. stratum process health  (THE check that would have caught 13 Aug)"
##############################################################################
ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null)
NRESTARTS=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null); NRESTARTS=${NRESTARTS:-?}
SINCE=$(systemctl show "$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)
UPSEC=$(ps -o etimes= -p "$(systemctl show "$UNIT" -p MainPID --value)" 2>/dev/null | tr -d ' ')
UPSEC=${UPSEC:-0}
CRASHES=$(journalctl -u "$UNIT" --since '-30 min' --no-pager 2>/dev/null \
          | grep -cE 'SEGV|Failed with result' || true)
CRASHES=$(echo "${CRASHES:-0}" | head -1 | tr -dc '0-9'); CRASHES=${CRASHES:-0}
HARDCRASH=$(journalctl -u "$UNIT" --since '-30 min' --no-pager 2>/dev/null \
          | grep -cE 'SEGV|core-dump' || true)
HARDCRASH=$(echo "${HARDCRASH:-0}" | head -1 | tr -dc '0-9'); HARDCRASH=${HARDCRASH:-0}
DEADLOCK=$(grep -c 'dead lock' "$LOG" 2>/dev/null || true)
DEADLOCK=$(echo "${DEADLOCK:-0}" | head -1 | tr -dc '0-9'); DEADLOCK=${DEADLOCK:-0}
# v4: 'dead lock, exiting' KILLS stratum. So if the process has been up a long
# time with no restarts, any such lines are historic (13 Aug) and must not FAIL
# a currently-healthy pool. Only recent lines on a young/restarted service are
# evidence of a live deadlock.
DEADLOCK_RECENT=$(tail -n 20000 "$LOG" 2>/dev/null | grep -c 'dead lock' || true)
DEADLOCK_RECENT=$(echo "${DEADLOCK_RECENT:-0}" | head -1 | tr -dc '0-9'); DEADLOCK_RECENT=${DEADLOCK_RECENT:-0}

echo "  active=$ACTIVE  NRestarts=$NRESTARTS  up=${UPSEC}s  since=$SINCE"
[ "$ACTIVE" = "active" ] && ok "stratum is running" || bad "stratum is NOT active ($ACTIVE)"
if [ "$CRASHES" -eq 0 ]; then ok "no crashes or restarts in the last 30 min"
elif [ "$HARDCRASH" -gt 0 ]; then bad "$HARDCRASH SEGV/core-dump in the last 30 min -- CRASH LOOP"
elif [ "$CRASHES" -ge 3 ]; then bad "$CRASHES restart events in the last 30 min -- CRASH LOOP"
else warn "$CRASHES restart event(s) in the last 30 min, none of them SEGV -- expected if YOU restarted it (up=${UPSEC}s)"; fi
if [ "$DEADLOCK" -eq 0 ]; then
  ok "no 'dead lock' in current log"
elif [ "$DEADLOCK_RECENT" -gt 0 ] && { [ "$CRASHES" -gt 0 ] || [ "$UPSEC" -lt 1800 ]; }; then
  bad "$DEADLOCK_RECENT recent 'dead lock, exiting' lines + service restarted/young -- an aux child is killing stratum NOW"
else
  warn "$DEADLOCK 'dead lock' lines in the log, but stratum has been up ${UPSEC}s with NRestarts=$NRESTARTS -- historic (pre-restart), not a live deadlock"
fi
[ "$UPSEC" -gt 600 ] && ok "uptime > 10 min" || warn "stratum started ${UPSEC}s ago -- too young to judge"

##############################################################################
hr "2. is the fleet actually attached?"
##############################################################################
SOCKS=$(ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | wc -l)
WORKERS=$(MY "SELECT COUNT(*) FROM workers")
echo "  established sockets on :$PORT = $SOCKS   workers rows = ${WORKERS:-?}"
if [ "$SOCKS" -ge 800 ]; then ok "fleet present ($SOCKS connections)"
elif [ "$SOCKS" -ge 300 ]; then warn "only $SOCKS connections -- partial site outage?"
else bad "$SOCKS connections -- fleet is genuinely gone, check the sites"; fi

##############################################################################
hr "3. share flow (rigs are doing work)"
##############################################################################
SPM=$(MY "SELECT COUNT(*) FROM shares WHERE time > UNIX_TIMESTAMP()-180")
SPM=${SPM:-0}
echo "  shares in last 180s = $SPM  (~$((SPM/3))/min)"
[ "$SPM" -gt 900 ] && ok "share flow healthy" || bad "share flow collapsed ($SPM in 3 min)"

##############################################################################
hr "4. block cadence -- the metric that ACTUALLY detects a broken aux list"
##############################################################################
MYT "SELECT c.symbol, MAX(b.height) height,
     FROM_UNIXTIME(MAX(b.time)) last_block,
     ROUND((UNIX_TIMESTAMP()-MAX(b.time))/60,1) min_ago
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE','TXC','ISK','ZCU')
     GROUP BY 1 ORDER BY min_ago" | sed 's/^/  /'

CADENCE_OK=1   # v4: ground truth that the job/aux loop is cycling
for S in TXC ISK; do
  AGO=$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-MAX(b.time))/60)
            FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='$S'")
  AGO=${AGO:-9999}
  # we are the ONLY pool on TXC/ISK: healthy is ~1 block / 3 min.
  # Tightened 14 Aug 2026: 20m dry used to print WARN and the run still said
  # "ALL GREEN". At 3m target, 10m dry is already a >3-sigma event.
  # v7: 8/15 fired on a pool that was objectively fine. Target is ~3m, but the
  # find process is Poisson: a 12m dry spell happens by chance several times a
  # day. WARN at 15m, FAIL at 25m (still ~8x the target interval).
  if   [ "$AGO" -le 15 ];  then ok "$S found a block ${AGO}m ago (healthy, target ~3m)"
  elif [ "$AGO" -le 25 ]; then warn "$S dry for ${AGO}m -- 5x the target interval, watch it"; CADENCE_OK=0
  else bad "$S dry for ${AGO}m -- we are the only pool, this is a REGRESSION not variance"; CADENCE_OK=0; fi

done

# --- ZCU (v6). Judged differently from TXC/ISK on purpose:
#   * ZCU only counts when the gate is ARMED (dry_run=0). Disarmed = by design,
#     so a dry ZCU is expected and must never colour the verdict.
#   * The yiimp `blocks` row only appears after zcu-mainnet-yiimp-block-sync
#     runs, so a lagging DB is a SYNC problem, not a mining problem. We use the
#     geth tip as ground truth and the DB only to judge homepage freshness.
#   * Observed cadence on 13 Aug 2026 restoration: ~4 blocks / 10 min. Limits
#     are deliberately loose (WARN 30m, FAIL 60m) to match the 60m deadman.
ZARMED=$(grep -s '^ZCU_DRY_RUN=' /etc/zcu-gate.env 2>/dev/null | cut -d= -f2 | tr -dc '0-9')
if [ "${ZARMED:-1}" != "0" ]; then
  echo "  ZCU  gate is DISARMED (dry_run=${ZARMED:-?}) -- no ZCU blocks expected, cadence not judged"
else
  ZAGO=$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-MAX(b.time))/60)
             FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'")
  case "$ZAGO" in ''|*[!0-9]*) ZAGO=9999 ;; esac
  ZACC=$(grep -c 'ZCU BLOCK ACCEPTED' /var/log/zcu-gate.log 2>/dev/null | tr -dc '0-9'); ZACC=${ZACC:-0}
  if   [ "$ZAGO" -le 30 ]; then ok "ZCU found a block ${ZAGO}m ago (gate ARMED, accepted-total=$ZACC)"
  elif [ "$ZAGO" -le 60 ]; then warn "ZCU dry for ${ZAGO}m with the gate ARMED -- check forwards: grep -i 'WINNER\|REJECTED' /var/log/zcu-gate.log | tail -20"
  else
    if [ "$ZACC" -gt 0 ]; then
      warn "no ZCU block row for ${ZAGO}m but the gate has $ZACC accepted block(s) -- almost certainly the yiimp sync, not mining: sudo systemctl start zcu-mainnet-yiimp-block-sync"
    else
      bad "ZCU dry for ${ZAGO}m with the gate ARMED and ZERO accepted blocks -- winners are not reaching geth"
    fi
  fi
fi


##############################################################################
hr "4b. coin RPC health -- getblocktemplate (the 13/14 Aug miss)"
##############################################################################
# A stalled getblocktemplate means stratum cannot build a new job for that coin,
# so blocks stop even though sockets, shares/min and NRestarts all look perfect.
# This is EXACTLY the failure the canary reported ALL GREEN through, so it is a
# hard FAIL here, measured on a live 30s sample of the file stratum is writing.
echo "  live log: $LOG  (last write ${LOGAGE}s ago)"
if [ "$LOGAGE" -gt 300 ]; then
  bad "stratum has not written to $LOG in ${LOGAGE}s -- the log is stale, RPC sample below is meaningless"
fi

SAMPLE=$(mktemp)
timeout 30 tail -n 0 -F "$LOG" > "$SAMPLE" 2>/dev/null
NEW=$(wc -l < "$SAMPLE" | tr -dc '0-9'); NEW=${NEW:-0}
GBT=$(grep -ci 'error getblocktemplate' "$SAMPLE" || true)
GBT=$(echo "${GBT:-0}" | head -1 | tr -dc '0-9'); GBT=${GBT:-0}
AUXERR=$(grep -ci 'error createauxblock\|error getauxblock' "$SAMPLE" || true)
AUXERR=$(echo "${AUXERR:-0}" | head -1 | tr -dc '0-9'); AUXERR=${AUXERR:-0}
WALLET=$(grep -ci 'unable to find the wallet' "$SAMPLE" || true)
WALLET=$(echo "${WALLET:-0}" | head -1 | tr -dc '0-9'); WALLET=${WALLET:-0}
RPCTO=$(grep -ci 'rpc timeout\|connect error\|couldn.t connect' "$SAMPLE" || true)
RPCTO=$(echo "${RPCTO:-0}" | head -1 | tr -dc '0-9'); RPCTO=${RPCTO:-0}

echo "  30s sample: ${NEW} new lines   gbt-errors=$GBT  aux-errors=$AUXERR  wallet-errors=$WALLET  rpc-conn-errors=$RPCTO"
# v7: a log that was rotated seconds before the sample legitimately shows 0 new
# lines in the OLD handle. Do not FAIL on that -- it is the rotation, not stratum.
LOGBORN=$(stat -c %W "$LOG" 2>/dev/null); [ "${LOGBORN:-0}" -gt 0 ] 2>/dev/null || LOGBORN=$(stat -c %Z "$LOG" 2>/dev/null || echo 0)
LOGBORNAGE=$(( $(date -u +%s) - ${LOGBORN:-0} ))
if [ "$NEW" -eq 0 ] && [ "$LOGBORNAGE" -lt 120 ]; then
  warn "0 new lines in 30s but $LOG is only ${LOGBORNAGE}s old -- log just rotated, sample is not evidence of a stall"
elif [ "$NEW" -eq 0 ]; then
  bad "stratum wrote ZERO lines in 30s -- it is not looping, treat as stalled"

elif [ "$GBT" -eq 0 ]; then
  ok "no getblocktemplate errors in the last 30s"
else
  bad "$GBT 'error getblocktemplate' in 30s -- stratum cannot build jobs, blocks WILL stop"
  grep -i 'error getblocktemplate' "$SAMPLE" | tail -5 | sed 's/^/       /'
  # which coins are affected? synchronized errors across ALL coins = shared
  # refresh loop is blocked (a shim/adapter), one coin = that coin's daemon.
  HITS=$(grep -ioE "$COINPAT" "$SAMPLE" | sort -u | tr '\n' ' ')
  echo "       coins named in this sample: ${HITS:-none}"
fi
[ "$AUXERR" -eq 0 ] || bad "$AUXERR aux-block RPC errors in 30s -- an aux child is failing, this is the deadlock precursor"
[ "$WALLET" -eq 0 ] || bad "$WALLET 'unable to find the wallet for coinid' in 30s -- a coin has no usable wallet, payouts and block credit will break"
[ "$RPCTO" -eq 0 ] || warn "$RPCTO RPC connect/timeout lines in 30s -- a coin daemon is slow or down"
# v4: this used to hard-FAIL on "no coin names", which fired on a pool that was
# finding TXC/ISK blocks every 2 minutes -- yiimp simply does not print long
# coin names on every job line. Block cadence is the ground truth for "is the
# loop cycling"; log verbosity is not. So: FAIL only when cadence is ALSO bad.
COINNAMES=$(grep -icE "$COINPAT" "$SAMPLE" || true)
COINNAMES=$(echo "${COINNAMES:-0}" | head -1 | tr -dc '0-9'); COINNAMES=${COINNAMES:-0}
if [ "$NEW" -gt 200 ] && [ "$COINNAMES" -eq 0 ]; then
  if [ "$CADENCE_OK" -eq 1 ]; then
    warn "$NEW lines in 30s and no coin/job tokens matched -- log verbosity only; TXC/ISK block cadence proves the job loop IS cycling"
  else
    bad "$NEW lines written in 30s, ZERO coin/job tokens AND blocks are dry -- the job/aux loop is not cycling"
  fi
fi
rm -f "$SAMPLE"

##############################################################################
hr "4c. LUCK vs REGRESSION -- expected finds from our own hashrate (v7)"
##############################################################################
# The question "we only mined ONE DOGE block in 24h, is something broken?"
# cannot be answered by liveness checks. It is arithmetic:
#
#   expected blocks = hashrate(H/s) * window(s) / (network_difficulty * 2^32)
#
# If actual is close to expected, the pool is fine and luck was bad. If actual
# is a small fraction of expected on a large expectation, high-difficulty work
# is being lost somewhere between the miner and the daemon -- a REGRESSION.
#
# Hashrate source, best first:
#   1. measured share window (exact, but only ~10 min of `shares` is retained)
#   2. hashstats averages for the 24h / 7d windows
HS_NOW=$(MY "SELECT ROUND(SUM(CASE WHEN valid=1 THEN difficulty ELSE 0 END)*4294967296
              / GREATEST(UNIX_TIMESTAMP()-MIN(time),1))
             FROM shares WHERE time > UNIX_TIMESTAMP()-600")
HS_NOW=$(echo "${HS_NOW:-0}" | tr -dc '0-9'); HS_NOW=${HS_NOW:-0}
HS_24=$(MY "SELECT ROUND(AVG(hashrate)) FROM hashstats WHERE time > UNIX_TIMESTAMP()-86400")
HS_24=$(echo "${HS_24:-0}" | tr -dc '0-9'); [ "${HS_24:-0}" -gt 0 ] 2>/dev/null || HS_24=$HS_NOW
HS_7D=$(MY "SELECT ROUND(AVG(hashrate)) FROM hashstats WHERE time > UNIX_TIMESTAMP()-604800")
HS_7D=$(echo "${HS_7D:-0}" | tr -dc '0-9'); [ "${HS_7D:-0}" -gt 0 ] 2>/dev/null || HS_7D=$HS_24
awk -v a="$HS_NOW" -v b="$HS_24" -v c="$HS_7D" \
  'BEGIN{printf "  hashrate: now %.2f TH/s   24h avg %.2f TH/s   7d avg %.2f TH/s\n",a/1e12,b/1e12,c/1e12}'
if [ "$HS_NOW" -eq 0 ]; then
  warn "no share work in the last 10 min -- luck maths below is meaningless"
fi

printf '  %-5s %-13s %6s %8s %6s %8s %6s %8s\n' \
  COIN NET_DIFF exp1h act1h exp24h act24h exp7d act7d
for S in LTC DOGE TXC ISK; do
  ND=$(MY "SELECT difficulty FROM coins WHERE symbol='$S' LIMIT 1")
  case "${ND:-0}" in ''|0|0.0*) ND=0 ;; esac
  A1=$(MY  "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id
            WHERE c.symbol='$S' AND b.time > UNIX_TIMESTAMP()-3600")
  A24=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id
            WHERE c.symbol='$S' AND b.time > UNIX_TIMESTAMP()-86400")
  A7=$(MY  "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id
            WHERE c.symbol='$S' AND b.time > UNIX_TIMESTAMP()-604800")
  A1=${A1:-0}; A24=${A24:-0}; A7=${A7:-0}
  read -r E1 E24 E7 VERDICT <<EOF
$(awk -v nd="${ND:-0}" -v h1="$HS_NOW" -v h24="$HS_24" -v h7="$HS_7D" \
      -v a1="$A1" -v a24="$A24" -v a7="$A7" 'BEGIN{
    if (nd <= 0) { print "n/a n/a n/a nodiff"; exit }
    w = nd * 4294967296;
    e1  = h1  * 3600   / w;
    e24 = h24 * 86400  / w;
    e7  = h7  * 604800 / w;
    v = "ok";
    if (e24 >= 5 && a24 < 0.25 * e24)      v = "fail24";
    else if (e24 >= 5 && a24 < 0.5 * e24)  v = "warn24";
    else if (e7  >= 20 && a7 < 0.5 * e7)   v = "warn7";
    printf "%.2f %.2f %.2f %s", e1, e24, e7, v;
  }')
EOF
  printf '  %-5s %-13s %6s %8s %6s %8s %6s %8s\n' \
    "$S" "${ND:-?}" "${E1:-?}" "$A1" "${E24:-?}" "$A24" "${E7:-?}" "$A7"
  case "${VERDICT:-}" in
    fail24) bad  "$S found $A24 block(s) in 24h but our own hashrate says ~$E24 -- under 25% of expectation is a REGRESSION, not luck" ;;
    warn24) warn "$S found $A24 in 24h vs ~$E24 expected -- below half of expectation; watch the next few hours before acting" ;;
    warn7)  warn "$S 7-day finds ($A7) are below half of the ~$E7 our hashrate should produce -- long-run shortfall" ;;
    nodiff) warn "$S has no network difficulty in the coins table -- cannot judge luck for it" ;;
    *)      [ "${E24:-n/a}" = "n/a" ] || ok "$S finds are in line with expectation ($A24 in 24h vs ~$E24)" ;;
  esac
done
echo "  note: a SINGLE coin short while the others are on target is luck or a"
echo "        chain-specific problem. LTC and DOGE short TOGETHER means the"
echo "        shared parent path (coinbase, template, submit) -- read 4d."

##############################################################################
hr "4d. parent-chain submit evidence -- did we FIND and then LOSE a block?"
##############################################################################
# A found-but-rejected block looks exactly like bad luck in the blocks table,
# because no row is ever written. The only trace is in the stratum log.
LOGS=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | grep -v '/client-' | head -3)
echo "  scanning: $(echo "$LOGS" | tr '\n' ' ')"
CAND=$(grep -hicE 'block found|found block|submitblock|submitauxblock' $LOGS 2>/dev/null | awk '{t+=$1} END{print t+0}')
CAND=$(echo "${CAND:-0}" | tr -dc '0-9'); CAND=${CAND:-0}
REJL=$(grep -hiE 'rejected|rejct|stale block|duplicate|inconclusive|bad-txns|high-hash|prev-blk-not-found' $LOGS 2>/dev/null | grep -icE 'block|submit' || true)
REJL=$(echo "${REJL:-0}" | head -1 | tr -dc '0-9'); REJL=${REJL:-0}
echo "  submit/found lines in the live logs: $CAND    reject-flavoured block lines: $REJL"
if [ "$REJL" -gt 0 ]; then
  warn "$REJL block-submit rejection line(s) found -- these are blocks we MINED and LOST. Newest 8:"
  grep -hiE 'rejected|stale block|duplicate|inconclusive|bad-txns|high-hash|prev-blk-not-found' $LOGS 2>/dev/null \
    | grep -iE 'block|submit' | tail -8 | cut -c1-200 | sed 's/^/       /'
else
  ok "no block-submit rejections in the retained logs -- nothing was found and thrown away"
fi
# CDataStream / serialization breakage is the exact 20 Aug signature of a
# bech32 LTC parent coinbase killing every aux child at once.
CDS=$(grep -hic 'CDataStream\|end of data' $LOGS 2>/dev/null | awk '{t+=$1} END{print t+0}')
CDS=$(echo "${CDS:-0}" | tr -dc '0-9'); CDS=${CDS:-0}
[ "${CDS:-0}" -gt 0 ] && bad "$CDS 'CDataStream / end of data' line(s) -- auxpow serialization is breaking. Check the LTC parent coinbase is LEGACY P2PKH (must start with L..., iswitness:false)" \
                      || ok "no auxpow serialization errors"
# the parent coinbase itself -- one query, the single most expensive mistake
MYT "SELECT symbol, master_wallet, enable, auto_ready FROM coins
     WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU') ORDER BY symbol" | sed 's/^/  /'
LTCW=$(MY "SELECT master_wallet FROM coins WHERE symbol='LTC' LIMIT 1")
case "${LTCW:-}" in
  L*) ok "LTC parent coinbase is legacy P2PKH ($LTCW)" ;;
  ltc1*) bad "LTC parent coinbase is BECH32 ($LTCW) -- this breaks DOGE/TXC/ISK/ZCU merged mining. Revert to the legacy L... address NOW" ;;
  *) warn "LTC parent coinbase looks unusual: ${LTCW:-<empty>}" ;;
esac

##############################################################################
hr "4e. work quality -- rejects, vardiff spread, daemon tips"
##############################################################################
MYT "SELECT COUNT(*) shares_10m,
      SUM(valid=1) valid, SUM(valid<>1) invalid,
      ROUND(100*SUM(valid<>1)/GREATEST(COUNT(*),1),2) reject_pct,
      ROUND(MIN(difficulty),3) min_diff,
      ROUND(AVG(difficulty),3) avg_diff,
      ROUND(MAX(difficulty),3) max_diff
     FROM shares WHERE time > UNIX_TIMESTAMP()-600" | sed 's/^/  /'
RPCT=$(MY "SELECT ROUND(100*SUM(valid<>1)/GREATEST(COUNT(*),1))
           FROM shares WHERE time > UNIX_TIMESTAMP()-600")
RPCT=$(echo "${RPCT:-0}" | tr -dc '0-9'); RPCT=${RPCT:-0}
if   [ "$RPCT" -le 3 ];  then ok "reject rate ${RPCT}% -- normal"
elif [ "$RPCT" -le 10 ]; then warn "reject rate ${RPCT}% -- elevated; stale jobs or a bad container"
else bad "reject rate ${RPCT}% -- we are throwing away real work, this directly costs blocks"; fi
# a vardiff collapse costs finds without touching shares/min
AVGD=$(MY "SELECT ROUND(AVG(difficulty)) FROM shares WHERE time > UNIX_TIMESTAMP()-600")
AVGD=$(echo "${AVGD:-0}" | tr -dc '0-9'); AVGD=${AVGD:-0}
[ "$AVGD" -lt 8192 ] && warn "average share difficulty is only $AVGD -- vardiff may have collapsed; the pool does the same work but pays far more submit overhead" \
                     || ok "average share difficulty $AVGD looks sane"
# daemon tip vs our newest recorded block: are we even on the right chain tip?
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -datadir=/home/ubuntu/.litecoin -rpcwallet=pool"
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -datadir=/home/ubuntu/.dogecoin"
for pair in "LTC:$LCLI" "DOGE:$DCLI"; do
  S=${pair%%:*}; CLI=${pair#*:}
  BIN=${CLI%% *}
  [ -x "$BIN" ] || { warn "$S cli not found at $BIN -- skipping tip check"; continue; }
  TIP=$(sudo -u ubuntu $CLI getblockcount 2>/dev/null | tr -dc '0-9')
  CONN=$(sudo -u ubuntu $CLI getconnectioncount 2>/dev/null | tr -dc '0-9')
  OURS=$(MY "SELECT MAX(b.height) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='$S'")
  OURS=$(echo "${OURS:-0}" | tr -dc '0-9'); OURS=${OURS:-0}
  if [ -z "${TIP:-}" ]; then
    bad "$S daemon did not answer getblockcount -- stratum cannot build templates for it"
  else
    echo "  $S daemon tip=$TIP peers=${CONN:-?}   our newest recorded block=$OURS (behind by $((TIP-OURS)))"
    [ "${CONN:-0}" -ge 3 ] && ok "$S daemon has ${CONN} peers" || bad "$S daemon has only ${CONN:-0} peers -- it may be mining on an isolated tip"
  fi
done


##############################################################################
hr "5. aux list sanity -- who is stratum actually merge-mining right now?"
##############################################################################
for NAME in Litecoin Dogecoin Texitcoin Iskander "Zero Chill"; do
  N=$(tail -n 5000 "$LOG" 2>/dev/null | grep -ic "$NAME" || true)
  E=$(tail -n 5000 "$LOG" 2>/dev/null | grep -i "$NAME" | grep -ic 'error' || true)
  printf '  %-12s lines=%-5s errors=%s\n' "$NAME" "$N" "$E"
done
AUXTOT=$(tail -n 5000 "$LOG" 2>/dev/null | grep -icE "$COINPAT" || true)
AUXTOT=$(echo "${AUXTOT:-0}" | head -1 | tr -dc '0-9'); AUXTOT=${AUXTOT:-0}
if [ "$AUXTOT" -eq 0 ]; then
  warn "no coin/job tokens in the last 5000 lines of $LOG (last write: $(stat -c %y "$LOG" 2>/dev/null | cut -d. -f1)) -- yiimp may only be logging miner chatter here; judge the loop by section 4 block cadence, not by these counts"
fi
ZCU_LIVE=$(tail -n 2000 "$LOG" 2>/dev/null | grep -ic 'Zero Chill\|ZCU' || true)
ZCU_LIVE=$(echo "${ZCU_LIVE:-0}" | head -1 | tr -dc '0-9'); ZCU_LIVE=${ZCU_LIVE:-0}
SHADOW=0; REAL=0; GATE=0; V6=0; V6MODE=""
pgrep -f 'adapter-capture.py' >/dev/null 2>&1 && SHADOW=1
pgrep -f 'adapter-gate.py' >/dev/null 2>&1 && GATE=1
pgrep -f 'zcu-adapter-v6|adapter-v6.py' >/dev/null 2>&1 && V6=1
# v8: only treat a bare adapter.py as the 13-Aug crash path when it is NOT v6.
pgrep -f '/opt/zcu-adapter/adapter\.py' >/dev/null 2>&1 && REAL=1
[ "$V6" -eq 1 ] && REAL=0
LISTEN=0; ss -ltn 2>/dev/null | grep -q ':8749' && LISTEN=1

V6STATE=/var/lib/zcu-adapter-v6/state.json
if [ "$V6" -eq 1 ]; then
  DRY=$(grep -o '"dry_run"[: ]*[a-z0-9]*' "$V6STATE" 2>/dev/null | grep -o '[01]\|true\|false' | head -1)
  case "$DRY" in 0|false) V6MODE=ARMED;; 1|true) V6MODE=SHADOW;; *) V6MODE=UNKNOWN;; esac
fi

if [ "$REAL" -eq 1 ]; then
  bad "legacy ZCU adapter (adapter.py, pre-v6) is running -- this is the 13 Aug crash path"
  echo "       disarm:  sudo pkill -f '/opt/zcu-adapter/adapter.py'"
elif [ "$V6" -eq 1 ]; then
  ok "ZCU adapter v6 running (mode=$V6MODE) -- O(1) enqueue-or-shed, hard timeouts, self-disarm"
  for k in forwarded would_forward geth_fail self_disarm shed; do
    V=$(grep -o "\"$k\"[: ]*[0-9]*" "$V6STATE" 2>/dev/null | grep -o '[0-9]*$' | head -1)
    printf '       %-14s %s\n' "$k" "${V:-n/a}"
  done
  GF=$(grep -o '"geth_fail"[: ]*[0-9]*' "$V6STATE" 2>/dev/null | grep -o '[0-9]*$' | head -1); GF=${GF:-0}
  SD=$(grep -o '"self_disarm"[: ]*[0-9]*' "$V6STATE" 2>/dev/null | grep -o '[0-9]*$' | head -1); SD=${SD:-0}
  [ "${GF:-0}" -gt 0 ] && warn "geth_fail=$GF -- adapter could not reach geth; check: systemctl status zcu-mainnet-geth"
  [ "${SD:-0}" -gt 0 ] && bad "adapter SELF-DISARMED ($SD) -- ZCU submits are being dropped; investigate before re-arming"
  if [ "$ZCU_LIVE" -gt 0 ]; then
    ok "ZCU is in the aux rotation ($ZCU_LIVE recent lines) -- expected"
  else
    warn "adapter is up but no ZCU lines in the log -- stratum has not picked ZCU back up"
  fi
elif [ "$GATE" -eq 1 ] || [ "$SHADOW" -eq 1 ]; then
  if [ "$GATE" -eq 1 ]; then
    ok "ZCU adapter on :8749 is the GATE (target-checked, always-ACK) -- only winners reach geth, submitauxblock never returns an error"
  else
    ok "ZCU adapter on :8749 is the SHADOW (capture-only, always-ACK) -- submits cannot be rejected, deadlock path disarmed"
  fi
  if [ "$ZCU_LIVE" -gt 0 ]; then
    ok "ZCU is in the aux rotation ($ZCU_LIVE recent lines) -- expected"
  else
    warn "adapter is up but no ZCU lines in the log yet -- stratum has not picked ZCU back up"
  fi
  if [ "$GATE" -eq 1 ]; then
    MISS=$(grep -c '"kind": "gated_miss"' /var/log/zcu-capture.jsonl 2>/dev/null | tr -dc '0-9'); MISS=${MISS:-0}
    FWD=$(grep -c 'FORWARDING to geth' /var/log/zcu-gate.log 2>/dev/null | tr -dc '0-9'); FWD=${FWD:-0}
    ACC=$(grep -c 'ZCU BLOCK ACCEPTED' /var/log/zcu-gate.log 2>/dev/null | tr -dc '0-9'); ACC=${ACC:-0}
    REJ=$(grep -c 'geth REJECTED a gated winner' /var/log/zcu-gate.log 2>/dev/null | tr -dc '0-9'); REJ=${REJ:-0}
    echo "       gated misses dropped: $MISS   forwarded: $FWD   accepted: $ACC   rejected: $REJ"
    [ "$REJ" -gt 0 ] && warn "geth rejected $REJ gated winner(s) -- stratum was still ACKed, but investigate before trusting the gate"
  else
    CAP=$(grep -c 'CAPTURED' /var/log/zcu-shadow.log 2>/dev/null | tr -dc '0-9'); CAP=${CAP:-0}
    echo "       captured submits so far: $CAP   (VERIFY once >= 3)"
  fi
elif [ "$LISTEN" -eq 1 ]; then
  bad "something is LISTENING on :8749 but it is neither the shadow nor a known adapter -- identify it before doing anything else"
else
  ok "ZCU fully out of the rotation (nothing on :8749)"
fi

if [ "$V6" -eq 1 ] || [ "$GATE" -eq 1 ] || [ "$SHADOW" -eq 1 ]; then
  ZERR=$(tail -n 2000 "$LOG" 2>/dev/null | grep -i 'Zero Chill\|ZCU' | grep -ic 'dead lock\|parent work\|auxpow payload' || true)
  ZERR=$(echo "${ZERR:-0}" | head -1 | tr -dc '0-9'); ZERR=${ZERR:-0}
  if [ "$ZERR" -gt 0 ]; then
    bad "ZCU submit/validation errors present ($ZERR) -- disarm: curl -fsSL https://pool.honest.money/install/zcu-adapter-v6.sh | sudo bash -s SHADOW"
  else
    ok "no ZCU submit-rejection or deadlock lines"
  fi
fi

##############################################################################
hr "5b. ZCU chain progress (is ZCU actually producing blocks?)"
##############################################################################
# v5: the gate can be perfectly healthy while the CHAIN goes nowhere. This
# section compares the geth tip now vs the tip stored in the canary state file
# on the previous run, and the lag between geth and the yiimp DB (which is what
# the homepage reads).
ZSTATE=/var/lib/mining-canary-zcu.tip
GETH_TIP_HEX=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  http://127.0.0.1:8747 2>/dev/null | grep -o '"result":"0x[0-9a-fA-F]*"' | grep -o '0x[0-9a-fA-F]*')
if [ -z "$GETH_TIP_HEX" ]; then
  warn "ZCU geth on :8747 did not answer eth_blockNumber -- check: systemctl status zcu-mainnet-geth"
else
  GETH_TIP=$((GETH_TIP_HEX))
  echo "       geth tip: $GETH_TIP"
  if [ -f "$ZSTATE" ]; then
    PREV_TIP=$(cut -d' ' -f1 "$ZSTATE"); PREV_TS=$(cut -d' ' -f2 "$ZSTATE")
    PREV_TIP=${PREV_TIP:-0}; PREV_TS=${PREV_TS:-0}
    AGO=$(( $(date -u +%s) - PREV_TS )); AGOM=$(( AGO / 60 ))
    DELTA=$(( GETH_TIP - PREV_TIP ))
    echo "       since last canary run (${AGOM}m ago): +$DELTA blocks"
    if [ "$AGOM" -ge 20 ] && [ "$DELTA" -le 0 ]; then
      warn "ZCU tip has NOT advanced in ${AGOM}m -- either the gate is forwarding nothing or geth is rejecting winners; check: grep -i 'WINNER\|REJECTED' /var/log/zcu-gate.log | tail -20"
    elif [ "$DELTA" -gt 0 ]; then
      ok "ZCU chain is advancing (+$DELTA blocks)"
    fi
  else
    echo "       (no previous tip recorded -- this run establishes the reference)"
  fi
  mkdir -p /var/lib 2>/dev/null
  echo "$GETH_TIP $(date -u +%s)" > "$ZSTATE" 2>/dev/null || true

  # DB lag -- this is what the homepage/API shows
  DBH=$(MY "SELECT COALESCE(MAX(b.height),0) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'")
  DBH=$(echo "${DBH:-0}" | tr -dc '0-9'); DBH=${DBH:-0}
  LAG=$(( GETH_TIP - DBH ))
  echo "       yiimp DB ZCU height: $DBH   (lag $LAG behind geth)"
  if [ "$LAG" -gt 25 ]; then
    warn "homepage is $LAG blocks behind the chain -- run: sudo systemctl start zcu-mainnet-yiimp-block-sync"
  else
    ok "yiimp DB is in step with the ZCU chain"
  fi
  SYNCSTATE=$(systemctl is-failed zcu-mainnet-yiimp-block-sync 2>/dev/null)
  [ "$SYNCSTATE" = "failed" ] && bad "zcu-mainnet-yiimp-block-sync is FAILED -- homepage will freeze: sudo systemctl reset-failed zcu-mainnet-yiimp-block-sync && sudo systemctl start zcu-mainnet-yiimp-block-sync"
  AMB=$(grep -c 'ambiguous yiimp auxpow payload' /var/log/zcu-gate.log 2>/dev/null | tr -dc '0-9'); AMB=${AMB:-0}
  [ "$AMB" -gt 0 ] && warn "$AMB winner(s) rejected as 'ambiguous auxpow payload' -- geth saw 2 candidate blobs and refused to guess; harmless unless the count grows faster than accepted blocks"
fi

##############################################################################
hr "5c. ZCU -> yiimp block-sync bridge (what the homepage reads) [v8]"
##############################################################################
# 1 Sep 2026: geth was sealing, the adapter was armed, and the homepage was
# still frozen -- because the sync unit was disabled during the Aug 30 removal
# and 'reset-failed' errored with "Unit not loaded". Discover the real unit
# name instead of assuming one.
SYNC_UNITS=$(systemctl list-unit-files --all 2>/dev/null | awk '/zcu/ && /(sync|block)/ {print $1" "$2}')
if [ -z "$SYNC_UNITS" ]; then
  warn "no ZCU sync unit found by name -- check: ls /etc/systemd/system | grep -i zcu"
else
  echo "$SYNC_UNITS" | while read -r U S; do
    A=$(systemctl is-active "$U" 2>/dev/null)
    printf '       %-46s state=%-9s active=%s\n' "$U" "$S" "$A"
  done
  DIS=$(echo "$SYNC_UNITS" | awk '$2=="disabled"{print $1}' | tr '\n' ' ')
  [ -n "$DIS" ] && warn "disabled sync unit(s): $DIS -- enable with: sudo systemctl enable --now $DIS"
fi
SYNC_LAST=$(journalctl -u 'zcu*sync*' -n 1 --no-pager -o short-iso 2>/dev/null | tail -1)
[ -n "$SYNC_LAST" ] && echo "       last sync log line: $SYNC_LAST"
SYNC_ERR=$(journalctl -u 'zcu*sync*' --since '-60 min' --no-pager 2>/dev/null | grep -ciE 'traceback|error|ZCU_ROW_NOT_EXACTLY_ONE' | head -1)
SYNC_ERR=$(echo "${SYNC_ERR:-0}" | tr -dc '0-9'); SYNC_ERR=${SYNC_ERR:-0}
[ "$SYNC_ERR" -gt 0 ] && warn "$SYNC_ERR error lines from the sync job in the last hour"
SYNC_INS=$(journalctl -u 'zcu*sync*' --since '-60 min' --no-pager 2>/dev/null | grep -c 'INSERTED_ZCU_BLOCK' | head -1)
SYNC_INS=$(echo "${SYNC_INS:-0}" | tr -dc '0-9'); SYNC_INS=${SYNC_INS:-0}
echo "       ZCU blocks inserted into yiimp in the last hour: $SYNC_INS"

##############################################################################
hr "5d. payouts + wallets (the other way the pool 'works' but earns nothing) [v8]"
##############################################################################
# Payouts die for exactly 3 reasons: cadence, wallet lock, loop2 not restarted.
LOOP2=$(systemctl is-active yiimp-loop2 2>/dev/null || echo n/a)
[ "$LOOP2" = "active" ] && ok "yiimp-loop2 active (payout engine running)" || bad "yiimp-loop2 is $LOOP2 -- no payouts will be sent"
DOGECRON=$(crontab -l 2>/dev/null | grep -i 'doge-payout-cycle' | head -2; cat /etc/cron.d/* 2>/dev/null | grep -i 'doge-payout-cycle' | head -2)
if echo "$DOGECRON" | grep -q '\*/10'; then
  ok "DOGE payout cycle is on the required */10 cadence"
elif [ -n "$DOGECRON" ]; then
  bad "DOGE payout cycle cadence is WRONG (daily/hourly credits nobody -- shares are deleted at round close):"; echo "$DOGECRON" | sed 's/^/         /'
else
  warn "no doge-payout-cycle cron found -- verify: crontab -l | grep doge"
fi
for W in litecoin dogecoin; do
  CLI=$(ls /home/ubuntu/${W}-*/bin/${W%coin}coin-cli 2>/dev/null | head -1)
  [ -z "$CLI" ] && CLI=$(command -v ${W}-cli 2>/dev/null)
  [ -z "$CLI" ] && { echo "       $W: cli not found (skipped)"; continue; }
  WI=$(sudo -u ubuntu "$CLI" getwalletinfo 2>/dev/null)
  BAL=$(echo "$WI" | grep -o '"balance": *[0-9.]*' | grep -o '[0-9.]*$')
  UNL=$(echo "$WI" | grep -c 'unlocked_until')
  UNTIL=$(echo "$WI" | grep -o '"unlocked_until": *[0-9]*' | grep -o '[0-9]*$')
  printf '       %-9s balance=%-16s' "$W" "${BAL:-?}"
  if [ "${UNL:-0}" -eq 0 ]; then echo "wallet not encrypted"
  elif [ "${UNTIL:-0}" -eq 0 ]; then echo "LOCKED"; bad "$W wallet is LOCKED -- sendmany will fail, payouts stall"
  else echo "unlocked"; fi
done
PENDING=$(MY "SELECT CONCAT(COUNT(*),' rows / ',IFNULL(ROUND(SUM(amount),4),0)) FROM payouts WHERE tx IS NULL OR tx=''")
echo "       payouts with no txid: ${PENDING:-n/a}"
LASTPAY=$(MY "SELECT CONCAT(c.symbol,' ',FROM_UNIXTIME(MAX(p.time))) FROM payouts p JOIN coins c ON c.id=p.coin_id GROUP BY c.symbol ORDER BY c.symbol")
[ -n "$LASTPAY" ] && echo "$LASTPAY" | sed 's/^/       last payout: /'

##############################################################################
hr "5e. host + public surface [v8]"
##############################################################################
df -h / /var 2>/dev/null | tail -n +2 | awk '{printf "       disk %-10s %s used of %s (%s)\n",$6,$3,$2,$5}'
DFP=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
[ "${DFP:-0}" -ge 90 ] && bad "root filesystem ${DFP}% full" || ok "disk headroom OK (${DFP}% used on /)"
read -r L1 _ < /proc/loadavg; echo "       load1=$L1  mem: $(free -m | awk '/Mem:/{print $3"M/"$2"M used"}')"
OOM=$(journalctl -k --since '-24 hours' --no-pager 2>/dev/null | grep -ci 'out of memory\|oom-kill' | head -1)
OOM=$(echo "${OOM:-0}" | tr -dc '0-9'); [ "${OOM:-0}" -gt 0 ] && bad "$OOM OOM-kill events in the last 24h" || ok "no OOM kills in 24h"
for U in api.stratum.pool.honest.money/api/v1/pool/summary pool.honest.money/api/status; do
  C=$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 8 "https://$U" 2>/dev/null)
  printf '       %-50s %s\n' "$U" "${C:-no answer}"
  echo "$C" | grep -q '^200' || warn "$U did not return 200"
done
NHW=$(systemctl is-active nicehash-watcher 2>/dev/null || echo n/a)
echo "       nicehash-watcher: $NHW"




##############################################################################
hr "6. baseline compare"
##############################################################################
NOW_HEIGHTS=$(MY "SELECT GROUP_CONCAT(CONCAT(s,'=',h) ORDER BY s) FROM (
   SELECT c.symbol s, MAX(b.height) h FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE c.symbol IN ('LTC','DOGE','TXC','ISK','ZCU') GROUP BY 1) x")
if [ "$MODE" = "BASELINE" ]; then
  { echo "BASE_TS=$(date -u +%s)"
    echo "BASE_HEIGHTS='$NOW_HEIGHTS'"
    echo "BASE_RESTARTS=$NRESTARTS"
    echo "BASE_SOCKS=$SOCKS"; } > "$BASE"
  echo "  baseline saved to $BASE"
  echo "  $NOW_HEIGHTS"
elif [ -f "$BASE" ]; then
  # shellcheck disable=SC1090
  . "$BASE"
  MINS=$(( ( $(date -u +%s) - BASE_TS ) / 60 ))
  echo "  baseline was ${MINS}m ago"
  echo "    then: $BASE_HEIGHTS"
  echo "    now:  $NOW_HEIGHTS"
  DR=$(( ${NRESTARTS:-0} - ${BASE_RESTARTS:-0} ))
  [ "$DR" -le 0 ] && ok "no new stratum restarts since baseline" \
                  || bad "$DR new stratum restarts since baseline -- YOUR LAST CHANGE BROKE IT"
  if [ "$MINS" -ge 10 ] && [ "$BASE_HEIGHTS" = "$NOW_HEIGHTS" ]; then
    bad "not a single block on any coin in ${MINS}m -- mining is stalled"
  fi
else
  warn "no baseline yet -- run with BASELINE before your next change"
fi

##############################################################################
if [ "$MODE" = "WATCH" ]; then
  hr "7. watching for $WATCH_MINS minutes"
  R0=$NRESTARTS
  for i in $(seq 1 "$WATCH_MINS"); do
    sleep 60
    R=$(systemctl show "$UNIT" -p NRestarts --value)
    T=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id
            WHERE c.symbol IN ('TXC','ISK') AND b.time > UNIX_TIMESTAMP()-${i}*60")
    printf '  +%2dm  restarts=%s (+%s)  TXC/ISK blocks=%s\n' "$i" "$R" "$((R-R0))" "${T:-0}"
    [ "$R" -gt "$R0" ] && { bad "stratum restarted during watch -- revert your last change"; break; }
  done
fi

hr "verdict"
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL GREEN -- LTC/DOGE/TXC/ISK mining is healthy. Safe to proceed."
else
  echo "  FAILURES ABOVE -- do NOT make another change. Revert the last one first."
fi
exit "$FAIL"
