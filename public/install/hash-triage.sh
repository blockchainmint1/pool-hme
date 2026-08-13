#!/usr/bin/env bash
# hash-triage.sh v1 -- READ ONLY (unless ROLLBACK_ZCU is passed).
#
#   curl -fsSL "https://pool.honest.money/install/hash-triage.sh?v=$(date +%s)" | sudo bash 2>&1 | tee /tmp/hash.txt
#   rollback ZCU adapter only:  ... | sudo bash -s ROLLBACK_ZCU
#
# Why: pool hashrate sagged from ~19 TH/s to ~14-16 TH/s and TXC/ISK went dry for
# ~50 min after 05:07 UTC 13 Aug, right around the credit-fix (loop2 restart, 05:05)
# and the ZCU adapter GBT shim + block-sync backfill (05:13-05:51). Client count is
# still 1232, so rigs are CONNECTED -- this checks whether they are getting WORK.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
MODE="${1:-REPORT}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
LOG=${LOG:-/var/log/stratum/debug.log}
[ -f "$LOG" ] || LOG=/var/stratum/scrypt.log
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
echo "hash-triage v1  $(date -u '+%F %T UTC')  log=$LOG  db_user=${DBU:-UNRESOLVED}"

hr "1. box load -- is the ZCU backfill starving stratum/mysql?"
uptime
echo "-- top 8 by cpu"
ps -eo pcpu,pmem,etimes,comm --sort=-pcpu | head -9
echo "-- mysql threads running"
mysql -u"${DBU:-}" -p"${DBP:-}" -N -B -e "SHOW GLOBAL STATUS LIKE 'Threads_running'" 2>/dev/null | grep -v Warning
echo "-- zcu block-sync"
systemctl is-active zcu-mainnet-yiimp-block-sync.service 2>/dev/null
journalctl -u zcu-mainnet-yiimp-block-sync.service -n 3 --no-pager 2>/dev/null | tail -3

hr "2. is stratum still SENDING WORK? (new job / block notifications, last 10 min)"
awk -v cut="$(date -u -d '10 minutes ago' '+%s')" '{print}' /dev/null
tail -n 400000 "$LOG" 2>/dev/null | grep -icE 'new block|coind_getauxblock|job' | sed 's/^/  job-ish log lines (tail 400k): /'
echo "-- last 15 interesting lines"
tail -n 200000 "$LOG" 2>/dev/null | grep -iE 'Shared Mining Found Block|Solo Mining|error getblocktemplate|timeout|unable|disconnect' | tail -15

hr "3. share flow -- shares per minute, last 20 min (THE decisive metric)"
MY "SELECT FROM_UNIXTIME(time - time%60) minute, COUNT(*) shares, ROUND(SUM(difficulty),0) diff
    FROM shares WHERE time > UNIX_TIMESTAMP()-1200 GROUP BY 1 ORDER BY 1 DESC LIMIT 20"

hr "4. block cadence -- minutes since last block per symbol (TXC/ISK should be ~3)"
MY "SELECT c.symbol, MAX(b.height) height, FROM_UNIXTIME(MAX(b.time)) last_block,
        ROUND((UNIX_TIMESTAMP()-MAX(b.time))/60,1) min_ago, COUNT(*) blocks_24h
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE b.time > UNIX_TIMESTAMP()-86400 GROUP BY c.symbol ORDER BY min_ago"

hr "5. connected miners vs reported hashrate"
MY "SELECT COUNT(*) workers, COUNT(DISTINCT userid) accounts FROM workers"
MY "SELECT FROM_UNIXTIME(time) t, ROUND(hashrate/1e12,2) th_s, workers
    FROM hashrate ORDER BY time DESC LIMIT 12" 2>/dev/null

hr "6. ZCU RPC latency -- a slow adapter blocks stratum's coin-refresh thread"
for m in getblocktemplate getauxblock getinfo; do
  s=$(date +%s%N)
  out=$(timeout 8 curl -s --max-time 8 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$m\",\"params\":[]}" http://127.0.0.1:8749/ 2>&1 | head -c 160)
  e=$(date +%s%N); printf '  %-18s %6s ms  %s\n' "$m" "$(( (e-s)/1000000 ))" "$out"
done

hr "7. verdict hints"
echo "  * shares/min steady + block cadence normal  -> nothing broke; the TH/s number is the yiimp estimator sawtooth."
echo "  * shares/min collapsed                      -> rigs connected but not working: stratum job flow. Roll back ZCU adapter."
echo "  * getblocktemplate > 2000 ms                -> the shim is stalling stratum's refresh loop. Roll back ZCU adapter."
echo "  * load average > 8 / mysql threads > 20     -> the ZCU backfill is starving the box. Stop the backfill timer."

if [ "$MODE" = "ROLLBACK_ZCU" ]; then
  hr "ROLLBACK: restoring pre-shim adapter + stopping ZCU backfill"
  BK=$(ls -1t /var/backups/zcu-adapter.py.* 2>/dev/null | head -1)
  if [ -n "$BK" ]; then cp "$BK" /opt/zcu-adapter/adapter.py && systemctl restart zcu-adapter && echo "  adapter restored from $BK"; else echo "  no adapter backup found"; fi
  systemctl stop zcu-mainnet-yiimp-block-sync.timer 2>/dev/null; systemctl stop zcu-mainnet-yiimp-block-sync.service 2>/dev/null
  echo "  zcu block-sync timer+service stopped (stratum NOT touched)"
else
  hr "nothing was modified -- rerun with: | sudo bash -s ROLLBACK_ZCU  to undo the ZCU changes"
fi
echo; echo "hash-triage done."
