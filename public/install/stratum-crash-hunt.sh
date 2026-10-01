#!/usr/bin/env bash
# stratum-crash-hunt.sh -- READ ONLY by default. Answers:
#   "Why does the scrypt stratum keep dying (SEGV, NRestarts=11) and what did
#    each crash cost us in blocks?"
#
#   run:   curl -fsSL "https://pool.honest.money/install/stratum-crash-hunt.sh?v=$(date +%s)" | sudo bash
#   save:  ... | sudo bash -s SAVE   (also copies evidence to /root/crash-evidence-<ts>/,
#                                     touches nothing the pool uses)
set -u
MODE="${1:-CHECK}"
UNIT=stratum-aws-scrypt
BIN=/var/stratum/stratum
MY()  { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql yiimpfrontend -t -e "$1" 2>&1; }
H() { echo; echo "===== $*"; }
echo "stratum-crash-hunt v1  $(date -u '+%F %T') UTC  mode=$MODE"

H "1. every stratum death systemd still remembers"
journalctl -u $UNIT --no-pager -o short-iso 2>/dev/null \
  | grep -E "Main process exited|restart counter|dead lock|Killed|Failed with result" | tail -40
echo "  NRestarts=$(systemctl show $UNIT -p NRestarts --value)  since=$(systemctl show $UNIT -p ActiveEnterTimestamp --value)"
CRASHES=$(journalctl -u $UNIT --no-pager -o short-unix 2>/dev/null | grep "Main process exited" | awk '{print int($1)}')
echo "  crash count in journal: $(echo "$CRASHES" | grep -c . )"

H "2. kernel segfault records (which address/library faulted)"
journalctl -k --no-pager -o short-iso 2>/dev/null | grep -iE "stratum.*segfault|segfault.*stratum|traps:.*stratum" | tail -15
dmesg -T 2>/dev/null | grep -iE "stratum.*(segfault|general protection)" | tail -5

H "3. core dumps"
if command -v coredumpctl >/dev/null; then
  coredumpctl list --no-pager 2>/dev/null | grep -i stratum | tail -15 || echo "  none for stratum"
else
  echo "  systemd-coredump not installed"
fi
echo "  core_pattern: $(cat /proc/sys/kernel/core_pattern)"
echo "  core limit for unit: $(systemctl show $UNIT -p LimitCORE --value)"
ls -la /var/stratum/core* /var/lib/systemd/coredump/*stratum* 2>/dev/null | tail -5
if command -v coredumpctl >/dev/null && command -v gdb >/dev/null; then
  echo "  --- backtrace of newest stratum core ---"
  timeout 60 coredumpctl gdb --no-pager -1 "$BIN" -- -batch -ex "thread apply all bt 8" 2>/dev/null \
    | grep -E "^#|^Thread" | head -60
else
  echo "  (gdb not installed -- no backtrace; core list above is still useful)"
fi

H "4. binary identity (did a crash follow a binary swap?)"
ls -la --time-style=+%F_%T "$BIN"; md5sum "$BIN"

H "5. last 25 stratum log lines before each crash (what was it doing?)"
for T in $CRASHES; do
  TS=$(date -u -d @"$T" '+%F %T')
  HOURF=/var/stratum/logs/stratum-$(date -u -d @"$T" '+%Y%m%d')-$(printf '%02d' $(( $(date -u -d @"$T" +%-H) / 3 * 3 )))0000-*.log
  F=$(ls $HOURF 2>/dev/null | head -1)
  echo "--- crash at $TS UTC  log=${F:-not retained}"
  [ -n "$F" ] && tail -n 25 "$F" | cut -c1-220 | sed 's/^/    /'
done

H "6. what each crash cost: TXC/ISK/DOGE blocks in the 30 min before vs after"
for T in $CRASHES; do
  echo "--- crash at $(date -u -d @"$T" '+%F %T') UTC"
  MYT "SELECT c.symbol,
     SUM(b.time BETWEEN $T-1800 AND $T) before_30m,
     SUM(b.time BETWEEN $T AND $T+1800) after_30m,
     FROM_UNIXTIME(MIN(CASE WHEN b.time>$T THEN b.time END)) first_after
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('TXC','ISK','DOGE','LTC') AND b.time BETWEEN $T-1800 AND $T+7200
     GROUP BY c.symbol;"
done

H "7. memory/host pressure at crash times"
journalctl -k --no-pager --since "-14d" 2>/dev/null | grep -iE "oom|out of memory" | tail -5 || true
echo "  stratum RSS now: $(ps -o rss= -C stratum | awk '{s+=$1} END {printf "%.0f MB", s/1024}')"

if [ "$MODE" = "SAVE" ]; then
  D=/root/crash-evidence-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$D"
  journalctl -u $UNIT --no-pager --since "-14d" > "$D/journal-stratum.txt" 2>&1
  journalctl -k --no-pager --since "-14d" > "$D/journal-kernel.txt" 2>&1
  cp -a /var/stratum/logs/stratum-*.log "$D/" 2>/dev/null
  command -v coredumpctl >/dev/null && coredumpctl list --no-pager > "$D/coredumps.txt" 2>&1
  echo; echo "SAVED evidence to $D"
fi
echo; echo "DONE. Paste everything above back to the chat."
