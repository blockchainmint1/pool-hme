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
CANARY_VERSION="v6"
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
  if   [ "$AGO" -le 8 ];  then ok "$S found a block ${AGO}m ago (healthy, target ~3m)"
  elif [ "$AGO" -le 15 ]; then warn "$S dry for ${AGO}m -- 5x the target interval, watch it"; CADENCE_OK=0
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
if [ "$NEW" -eq 0 ]; then
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
SHADOW=0; REAL=0; GATE=0
pgrep -f '/opt/zcu-adapter/adapter-capture.py' >/dev/null 2>&1 && SHADOW=1
pgrep -f '/opt/zcu-adapter/adapter-gate.py' >/dev/null 2>&1 && GATE=1
pgrep -f '/opt/zcu-adapter/adapter.py' >/dev/null 2>&1 && REAL=1
LISTEN=0; ss -ltn 2>/dev/null | grep -q ':8749' && LISTEN=1

if [ "$REAL" -eq 1 ]; then
  bad "REAL ZCU adapter (adapter.py) is running -- this is the 13 Aug crash path"
  echo "       disarm:  sudo pkill -f '/opt/zcu-adapter/adapter.py'"
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
  ZERR=$(tail -n 2000 "$LOG" 2>/dev/null | grep -i 'Zero Chill\|ZCU' | grep -ic 'dead lock\|parent work\|auxpow payload' || true)
  ZERR=$(echo "${ZERR:-0}" | head -1 | tr -dc '0-9'); ZERR=${ZERR:-0}
  if [ "$ZERR" -gt 0 ]; then
    bad "ZCU submit/validation errors present ($ZERR) -- STOP the adapter: curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STOP"
  else
    ok "no ZCU submit-rejection or deadlock lines"
  fi

elif [ "$LISTEN" -eq 1 ]; then
  bad "something is LISTENING on :8749 but it is neither the shadow nor a known adapter -- identify it before doing anything else"
else
  ok "ZCU fully out of the rotation (nothing on :8749)"
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
