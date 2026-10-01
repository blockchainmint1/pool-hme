#!/usr/bin/env bash
# txc-gap-hunt.sh -- READ ONLY. Answers one question:
#   "Why does TXC go ~20-25 minutes without a block roughly every hour?"
#
#   run:  curl -fsSL "https://pool.honest.money/install/txc-gap-hunt.sh?v=$(date +%s)" | sudo bash
#
# At ~3 min average, a 20+ min gap should happen about 1 in 800 blocks
# (e^-6.7). Seeing one every hour is a schedule, not luck. This lines the
# long gaps up against the clock, against ISK (same parent shares), and
# against everything that runs on a timer on this box. Makes NO changes.
set -u
MY()  { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql yiimpfrontend -t -e "$1" 2>&1; }
H() { echo; echo "===== $*"; }
echo "txc-gap-hunt v1  $(date -u '+%F %T') UTC"

GAPSQL() { # $1=symbol $2=min_gap_minutes
cat <<SQL
SELECT FROM_UNIXTIME(prev_t) AS gap_start_utc, FROM_UNIXTIME(t) AS gap_end_utc,
       ROUND((t-prev_t)/60,1) AS gap_min, MINUTE(FROM_UNIXTIME(prev_t)) AS start_min_of_hour
FROM (SELECT b.time t, LAG(b.time) OVER (ORDER BY b.time) prev_t
      FROM blocks b JOIN coins c ON c.id=b.coin_id
      WHERE c.symbol='$1' AND b.time > UNIX_TIMESTAMP()-48*3600) x
WHERE prev_t IS NOT NULL AND t-prev_t > $2*60 ORDER BY prev_t;
SQL
}

H "1. TXC gaps > 12 min, last 48h (times UTC)"
MYT "$(GAPSQL TXC 12)"
H "2. ISK gaps > 12 min, last 48h -- same times as TXC = shared cause (stratum/parent); different = TXC-only"
MYT "$(GAPSQL ISK 12)"
H "3. ZCU gaps > 12 min, last 48h"
MYT "$(GAPSQL ZCU 12)"

H "4. which minute of the hour do TXC gaps START? (a spike = scheduled job)"
MYT "SELECT FLOOR(start_min/5)*5 AS minute_bucket, COUNT(*) gaps FROM (
  SELECT MINUTE(FROM_UNIXTIME(prev_t)) start_min FROM (
    SELECT b.time t, LAG(b.time) OVER (ORDER BY b.time) prev_t
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='TXC' AND b.time > UNIX_TIMESTAMP()-48*3600) x
  WHERE prev_t IS NOT NULL AND t-prev_t > 12*60) y GROUP BY 1 ORDER BY 1;"

H "5. TXC + ISK difficulty over time (a retarget swing would show here)"
MYT "SELECT c.symbol, FROM_UNIXTIME(MIN(b.time)) hour_start, COUNT(*) blocks,
  ROUND(MIN(b.difficulty),0) min_diff, ROUND(MAX(b.difficulty),0) max_diff
  FROM blocks b JOIN coins c ON c.id=b.coin_id
  WHERE c.symbol IN ('TXC','ISK') AND b.time > UNIX_TIMESTAMP()-12*3600
  GROUP BY c.symbol, FLOOR(b.time/3600) ORDER BY c.symbol, hour_start;"

H "6. everything scheduled on this box"
echo "--- /etc/crontab"; grep -v '^#' /etc/crontab | sed '/^\s*$/d'
for f in /etc/cron.d/*; do echo "--- $f"; grep -v '^#' "$f" | sed '/^\s*$/d'; done
echo "--- /etc/cron.hourly:"; ls /etc/cron.hourly 2>/dev/null
for u in root ubuntu www-data; do echo "--- crontab -u $u"; crontab -l -u "$u" 2>/dev/null | grep -v '^#' | sed '/^\s*$/d'; done
echo "--- systemd timers"; systemctl list-timers --all --no-pager 2>/dev/null | head -40

H "7. stratum log rotation (hourly files are normal; look for a stall at each rollover)"
ls -la --time-style=+%F_%T /var/stratum/logs 2>/dev/null | tail -8
echo "--- restarts / deadlocks in 24h"
journalctl -u stratum-aws-scrypt --since "-24h" --no-pager 2>/dev/null | grep -Ei "start|stop|dead lock|exit" | tail -15

H "8. TXC + ISK daemons -- restarts, RPC speed, stuck-template errors"
for s in $(systemctl list-units --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'texit|txc|iskand|isk'); do
  echo "--- $s  $(systemctl show "$s" -p ActiveEnterTimestamp -p NRestarts --value | tr '\n' ' ')"
  journalctl -u "$s" --since "-24h" --no-pager 2>/dev/null | grep -Ei "start|stop|error|queue|timeout" | tail -6
done
echo "--- stratum log: TXC/ISK error lines in the live log (last 3000)"
tail -n 3000 /var/stratum/scrypt.log 2>/dev/null | grep -Ei "texit|iskand" | grep -Ei "error|fail|timeout|queue|reject" | tail -15

H "9. CPU / disk spikes that could freeze things (sar if installed)"
command -v sar >/dev/null && sar -u 2>/dev/null | tail -30 || echo "sar not installed -- skipped"
echo; echo "DONE. Paste everything above back to the chat."
