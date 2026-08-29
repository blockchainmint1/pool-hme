#!/usr/bin/env bash
# doge-capture-code v1 -- READ-ONLY.
#
# Dumps the PHP capture path used by `php yaamp/yiic.php dogePayout capture`
# so we can repoint its share attribution at the durable doge_share_archive
# table instead of the volatile `shares` table (~7 min retention).
#
# Also confirms the archiver timer is alive and the archive is growing.
#
# Usage:
#   curl -fsSL https://pool.honest.money/install/doge-capture-code.sh | sudo bash
set -uo pipefail

echo "doge-capture-code v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  READ-ONLY"
echo

# --- DB creds (authoritative source: /var/web/serverconfig.php) -------------
DBUSER=""; DBPASS=""
if [ -r /var/web/serverconfig.php ]; then
  DBUSER=$(grep -oP "define\('YAAMP_DBUSER',\s*'\K[^']+" /var/web/serverconfig.php | head -1)
  DBPASS=$(grep -oP "define\('YAAMP_DBPASSWORD',\s*'\K[^']+" /var/web/serverconfig.php | head -1)
fi
SQL() { mysql -u"$DBUSER" -p"$DBPASS" yiimpfrontend -N -e "$1" 2>/dev/null; }
SQLT() { mysql -u"$DBUSER" -p"$DBPASS" yiimpfrontend -t -e "$1" 2>/dev/null; }

echo "===== 1. archiver health (must be ticking every minute) ====="
systemctl is-active doge-share-archive.timer 2>/dev/null | sed 's/^/  timer: /'
systemctl list-timers doge-share-archive.timer --no-pager 2>/dev/null | tail -2 | sed 's/^/  /'
echo "  archive size / growth:"
SQLT "SELECT COUNT(*) rows_now, FROM_UNIXTIME(MIN(ts)) oldest, FROM_UNIXTIME(MAX(ts)) newest,
             ROUND(TIMESTAMPDIFF(SECOND,FROM_UNIXTIME(MIN(ts)),FROM_UNIXTIME(MAX(ts)))/60,1) span_min
      FROM doge_share_archive;"
echo "  rows archived in each of the last 5 minutes:"
SQLT "SELECT FROM_UNIXTIME(FLOOR(ts/60)*60) minute, COUNT(*) rows
      FROM doge_share_archive
      WHERE ts > UNIX_TIMESTAMP() - 300
      GROUP BY 1 ORDER BY 1;"
echo

echo "===== 2. where does the dogePayout command live? ====="
CMD=$(grep -rl "class.*DogePayout\|function actionCapture\|dogePayout" /var/web/yaamp/commands /var/web/yaamp/yiic.php 2>/dev/null | head -5)
if [ -z "$CMD" ]; then
  CMD=$(grep -rl "actionCapture" /var/web --include='*.php' 2>/dev/null | grep -i doge | head -5)
fi
if [ -z "$CMD" ]; then
  CMD=$(grep -rl "doge_payout_ledger" /var/web --include='*.php' 2>/dev/null | head -8)
fi
echo "$CMD" | sed 's/^/  /'
echo

for f in $CMD; do
  echo "===== 3. $f : capture-related code ====="
  # print the capture/scan functions plus any SQL touching shares
  awk '
    /function action(Scan|Capture|CaptureTokens|ScanTokens)/ { infn=1; depth=0 }
    infn { print; n=gsub(/{/,"{"); depth+=n; n=gsub(/}/,"}"); depth-=n; if (depth<=0 && $0 ~ /}/) infn=0 }
  ' "$f" | head -160
  echo
  echo "  --- every line in this file mentioning the shares table ---"
  grep -n "shares" "$f" | sed 's/^/  /'
  echo
done

echo "===== 4. block vs share timing sanity (post-archive) ====="
SQLT "SELECT height, FROM_UNIXTIME(time) block_time,
       (SELECT COUNT(*) FROM doge_share_archive a
         WHERE a.ts BETWEEN b.time - 3600 AND b.time) arch_shares_prior_60min
      FROM blocks b
      WHERE b.coin_id=(SELECT id FROM coins WHERE symbol='DOGE')
      ORDER BY b.time DESC LIMIT 8;"

echo
echo "inspect-only -- nothing was changed."
