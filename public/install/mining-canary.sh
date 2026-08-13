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
NRESTARTS=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
SINCE=$(systemctl show "$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)
UPSEC=$(ps -o etimes= -p "$(systemctl show "$UNIT" -p MainPID --value)" 2>/dev/null | tr -d ' ')
UPSEC=${UPSEC:-0}
CRASHES=$(journalctl -u "$UNIT" --since '-30 min' --no-pager 2>/dev/null \
          | grep -cE 'SEGV|Failed with result')
DEADLOCK=$(grep -c 'dead lock' "$LOG" 2>/dev/null || echo 0)

echo "  active=$ACTIVE  NRestarts=$NRestarts  up=${UPSEC}s  since=$SINCE"
[ "$ACTIVE" = "active" ] && ok "stratum is running" || bad "stratum is NOT active ($ACTIVE)"
[ "$CRASHES" -eq 0 ] && ok "no crashes in the last 30 min" \
                     || bad "$CRASHES crash/restart events in the last 30 min -- CRASH LOOP"
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
ZCU_LIVE=$(tail -n 2000 "$LOG" 2>/dev/null | grep -ic 'Zero Chill\|ZCU' || true)
if [ "$ZCU_LIVE" -gt 0 ]; then
  bad "ZCU is in the live aux rotation ($ZCU_LIVE recent lines) -- this is the 13 Aug crash path"
  echo "       disarm:  sudo pkill -f '/opt/zcu-adapter/adapter.py'"
else
  ok "ZCU is out of the aux rotation (adapter down) -- crash path disarmed"
fi
if ss -ltn 2>/dev/null | grep -q ':8749'; then
  bad "ZCU adapter is LISTENING on :8749 -- stratum can pick ZCU up again at any moment"
else
  ok "nothing listening on :8749"
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
  DR=$(( NRestarts - BASE_RESTARTS ))
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
