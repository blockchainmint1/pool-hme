#!/usr/bin/env bash
# zcu-sync-lag.sh -- prove (or disprove) that ZCU blocks arrive in the DB in batches.
#
#   run:  curl -fsSL "https://pool.honest.money/install/zcu-sync-lag.sh?v=$(date +%s)" | sudo bash
#
# WHY: LTC/DOGE/TXC/ISK blocks are written by stratum the instant they are found,
# so the site is real-time for them. ZCU is different: geth seals the block and a
# SEPARATE oneshot unit (zcu-mainnet-yiimp-block-sync, driven by zcu-sync.timer)
# copies it into the yiimp DB. That makes ZCU inherently batchy -- everything
# sealed between two timer ticks lands in one lump.
#
# This script is READ ONLY. It touches nothing: no stratum, no geth, no config.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

VER="v2"
SYNC_UNIT=zcu-mainnet-yiimp-block-sync
echo "zcu-sync-lag $VER  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  READ-ONLY"

q() { timeout 10 mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 1. tips
echo
echo "===== 1. chain tip vs database tip"
GAUTH=()
# shellcheck disable=SC1091
[ -f /etc/zcu-adapter-v6.env ] && . /etc/zcu-adapter-v6.env 2>/dev/null || true
[ -n "${GETH_USER:-}" ] && GAUTH=(-u "$GETH_USER:${GETH_PASS:-}")
HEX=$(curl -s --max-time 5 "${GAUTH[@]}" -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  http://127.0.0.1:8747 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | head -1)
if [ -n "${HEX:-}" ]; then TIP=$((HEX)); else TIP=""; fi
DBH=$(q "SELECT COALESCE(MAX(b.height),0) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'")
echo "  geth tip : ${TIP:-unreachable}"
echo "  yiimp DB : ${DBH:-?}"
if [ -n "${TIP:-}" ] && [ -n "${DBH:-}" ]; then
  GAP=$((TIP - DBH))
  echo "  gap      : $GAP blocks"
  if [ "$GAP" -gt 2000 ]; then
    echo "  NOTE  still BACKFILLING history -- the DB is walking forward from an old"
    echo "        height, so recent blocks will not appear until the backfill catches up."
  elif [ "$GAP" -gt 20 ]; then
    echo "  NOTE  more than one timer interval behind -- sync is slower than block production."
  else
    echo "  OK    within one sync interval"
  fi
fi

# ---------------------------------------------------------------- 2. timer
echo
echo "===== 2. what actually writes ZCU into the DB"
echo "  sync unit   : $(systemctl is-active $SYNC_UNIT 2>/dev/null) / $(systemctl is-enabled $SYNC_UNIT 2>/dev/null)"
echo "  last finish : $(systemctl show $SYNC_UNIT -p ExecMainExitTimestamp --value 2>/dev/null)"
echo "  timer       : $(systemctl is-enabled zcu-sync.timer 2>/dev/null) / $(systemctl is-active zcu-sync.timer 2>/dev/null)"
INT=$(systemctl show zcu-sync.timer -p TimersMonotonic --value 2>/dev/null)
echo "  schedule    : ${INT:-<no timer installed>}"
systemctl list-timers zcu-sync.timer --no-pager 2>/dev/null | head -3 | sed 's/^/    /'
if ! systemctl is-active --quiet zcu-sync.timer 2>/dev/null; then
  echo "  FAIL  no active timer -- ZCU only syncs when a human runs the unit."
  echo "        fix: curl -fsSL https://pool.honest.money/install/zcu-sync-timer.sh | sudo bash -s INSTALL 30"
fi

# ---------------------------------------------------------------- 3. batching
echo
echo "===== 3. batch fingerprint (rows inserted per DB minute, last 2h)"
echo "  if ZCU rows cluster into a few minutes while other coins spread evenly,"
echo "  the delay is the sync timer -- not missed blocks."
q "SELECT c.symbol,
          FROM_UNIXTIME(b.time - (b.time % 60)) AS minute,
          COUNT(*) AS rows_in_minute,
          MIN(b.height) AS from_h, MAX(b.height) AS to_h
     FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='ZCU' AND b.time > UNIX_TIMESTAMP() - 7200
    GROUP BY 2 ORDER BY 2 DESC LIMIT 25" | sed 's/^/    /'

echo
echo "  -- per-coin rows in the last 2h (for contrast)"
q "SELECT c.symbol, COUNT(*) AS blocks_2h,
          FROM_UNIXTIME(MAX(b.time)) AS newest
     FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.time > UNIX_TIMESTAMP() - 7200
    GROUP BY 1 ORDER BY 2 DESC" | sed 's/^/    /'

# ---------------------------------------------------------------- 4. seal vs store
echo
echo "===== 4. real seal rate from geth vs stored rate"
SEALED=$(journalctl -u zcu-mainnet-geth --since '-2 hours' --no-pager 2>/dev/null | grep -c 'Successfully sealed')
echo "  geth 'Successfully sealed' in last 2h : $SEALED"
STORED=$(q "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU' AND b.time > UNIX_TIMESTAMP() - 7200")
echo "  ZCU rows written to DB in last 2h     : ${STORED:-?}"
if [ -n "${STORED:-}" ] && [ "$SEALED" -gt 0 ]; then
  if [ "$STORED" -lt "$SEALED" ]; then
    echo "  => the chain is ahead of the site. Blocks ARE being found; the DB lags."
  else
    echo "  => DB is keeping up (or replaying backfill history)."
  fi
fi

# ---------------------------------------------------------------- 5. live watch
echo
echo "===== 5. 3-minute live watch (does the DB move in steps?)"
for i in 1 2 3 4 5 6; do
  H=$(q "SELECT COALESCE(MAX(b.height),0) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'")
  T=$(curl -s --max-time 5 "${GAUTH[@]}" -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    http://127.0.0.1:8747 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | head -1)
  printf '    %s  db=%s  geth=%s\n' "$(date -u '+%H:%M:%S')" "${H:-?}" "$([ -n "${T:-}" ] && echo $((T)) || echo '?')"
  [ "$i" -lt 6 ] && sleep 30
done
echo "  flat then jump = batching (expected). Flat then flat = sync is stuck."

echo
echo "echo
# ---------------------------------------------------------------- 6. worker behavior / restart proof
echo "===== 6. is each run restarting or capped?"
echo "  service invocation id : $(systemctl show $SYNC_UNIT -p InvocationID --value 2>/dev/null)"
echo "  active since          : $(systemctl show $SYNC_UNIT -p ActiveEnterTimestamp --value 2>/dev/null)"
echo "  main pid              : $(systemctl show $SYNC_UNIT -p MainPID --value 2>/dev/null)"
echo "  executions (last 2h)  : $(journalctl -u $SYNC_UNIT --since '-2 hours' --no-pager 2>/dev/null | grep -c 'Starting\|Started')"
echo "  inserts (last 2h)     : $(journalctl -u $SYNC_UNIT --since '-2 hours' --no-pager 2>/dev/null | grep -c 'INSERTED_ZCU_BLOCK')"
echo "  recent run boundaries + inserts:"
journalctl -u "$SYNC_UNIT" --since '-30 min' --no-pager -o short-iso 2>/dev/null \
  | grep -E 'Starting|Started|Finished|Deactivated|INSERTED_ZCU_BLOCK|Traceback|error' \
  | tail -80 | sed 's/^/    /'

SYNC_SCRIPT=$(systemctl show "$SYNC_UNIT" -p ExecStart --value 2>/dev/null | grep -oE '/[^ ;]+\.(py|sh)' | head -1)
echo "  worker script         : ${SYNC_SCRIPT:-not discovered}"
if [ -n "${SYNC_SCRIPT:-}" ] && [ -r "$SYNC_SCRIPT" ]; then
  echo "  cursor/batch clues (read-only source inspection):"
  grep -nEi 'limit|range\(|max\(|height|cursor|batch|sleep|return|break|sys\.exit' "$SYNC_SCRIPT" 2>/dev/null \
    | head -80 | sed 's/^/    /'
fi

echo
echo "  DB insertion groups by auto-increment id (newest 40 ZCU rows):"
q "SELECT MIN(id),MAX(id),COUNT(*),MIN(height),MAX(height),FROM_UNIXTIME(MIN(time)),FROM_UNIXTIME(MAX(time))
     FROM (SELECT b.id,b.height,b.time FROM blocks b JOIN coins c ON c.id=b.coin_id
           WHERE c.symbol='ZCU' ORDER BY b.id DESC LIMIT 40) x
    GROUP BY FLOOR(id/1000) ORDER BY MAX(id) DESC" 2>/dev/null | sed 's/^/    /'

echo
if [ -n "${TIP:-}" ] && [ -n "${DBH:-}" ] && [ "$DBH" -lt "$TIP" ]; then
  echo "  VERDICT: timer activity does not equal freshness. DB is $((TIP-DBH)) blocks behind."
  echo "           If each invocation inserts the same small count, the worker is batch-capped;"
  echo "           if DB height resets or repeats, its cursor/start-height logic is defective."
fi

echo "zcu-sync-lag $VER done.""
