#!/usr/bin/env bash
# mining-canary.sh -- READ ONLY. 20-second proof that LTC/DOGE/TXC/ISK mining
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
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-CHECK}"
WATCH_MINS="${2:-10}"
UNIT=stratum-aws-scrypt
LOG=/var/stratum/logs/stratum-current.log
# stratum opens a NEW log file on restart; follow the freshest MAIN log.
# client-*.log only holds per-miner chatter -- coin names never appear there,
# which made section 5 report lines=0 for everything.
NEWEST=$(ls -t /var/stratum/logs/stratum*.log 2>/dev/null | head -1)
[ -z "${NEWEST:-}" ] && NEWEST=$(ls -t /var/stratum/logs/*.log 2>/dev/null | grep -v '/client-' | head -1)
[ -z "${NEWEST:-}" ] && NEWEST=$(ls -t /var/stratum/logs/*.log 2>/dev/null | head -1)
[ -n "${NEWEST:-}" ] && LOG="$NEWEST"
STATE=/var/lib/pool-canary
BASE="$STATE/baseline.env"
PORT=3433
mkdir -p "$STATE"

MY() { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql yiimpfrontend -t -e "$1" 2>&1; }

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hr()   { printf '\n===== %s\n' "$*"; }

echo "mining-canary v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

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

echo "  active=$ACTIVE  NRestarts=$NRESTARTS  up=${UPSEC}s  since=$SINCE"
[ "$ACTIVE" = "active" ] && ok "stratum is running" || bad "stratum is NOT active ($ACTIVE)"
if [ "$CRASHES" -eq 0 ]; then ok "no crashes or restarts in the last 30 min"
elif [ "$HARDCRASH" -gt 0 ]; then bad "$HARDCRASH SEGV/core-dump in the last 30 min -- CRASH LOOP"
elif [ "$CRASHES" -ge 3 ]; then bad "$CRASHES restart events in the last 30 min -- CRASH LOOP"
else warn "$CRASHES restart event(s) in the last 30 min, none of them SEGV -- expected if YOU restarted it (up=${UPSEC}s)"; fi
[ "$DEADLOCK" -eq 0 ] && ok "no 'dead lock' in current log" \
                      || bad "$DEADLOCK 'dead lock, exiting' lines -- an aux child is killing stratum"
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
     WHERE c.symbol IN ('LTC','DOGE','TXC','ISK')
     GROUP BY 1 ORDER BY min_ago" | sed 's/^/  /'

for S in TXC ISK; do
  AGO=$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-MAX(b.time))/60)
            FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='$S'")
  AGO=${AGO:-9999}
  # we are the ONLY pool on TXC/ISK: healthy is ~1 block / 3 min
  if   [ "$AGO" -le 15 ]; then ok "$S found a block ${AGO}m ago (healthy, target ~3m)"
  elif [ "$AGO" -le 30 ]; then warn "$S dry for ${AGO}m -- watch it"
  else bad "$S dry for ${AGO}m -- we are the only pool, this is a REGRESSION not variance"; fi
done

##############################################################################
hr "5. aux list sanity -- who is stratum actually merge-mining right now?"
##############################################################################
for NAME in Litecoin Dogecoin Texitcoin Iskander "Zero Chill"; do
  N=$(tail -n 5000 "$LOG" 2>/dev/null | grep -ic "$NAME" || true)
  E=$(tail -n 5000 "$LOG" 2>/dev/null | grep -i "$NAME" | grep -ic 'error' || true)
  printf '  %-12s lines=%-5s errors=%s\n' "$NAME" "$N" "$E"
done
AUXTOT=$(tail -n 5000 "$LOG" 2>/dev/null | grep -icE 'Litecoin|Dogecoin|Texitcoin|Iskander|Zero Chill' || true)
AUXTOT=$(echo "${AUXTOT:-0}" | head -1 | tr -dc '0-9'); AUXTOT=${AUXTOT:-0}
if [ "$AUXTOT" -eq 0 ]; then
  warn "no coin names in the last 5000 lines of $LOG (last write: $(stat -c %y "$LOG" 2>/dev/null | cut -d. -f1)) -- log may have rotated; aux counts above are not evidence"
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
hr "6. baseline compare"
##############################################################################
NOW_HEIGHTS=$(MY "SELECT GROUP_CONCAT(CONCAT(s,'=',h) ORDER BY s) FROM (
   SELECT c.symbol s, MAX(b.height) h FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE c.symbol IN ('LTC','DOGE','TXC','ISK') GROUP BY 1) x")
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
