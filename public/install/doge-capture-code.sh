#!/usr/bin/env bash
# doge-capture-code v2 -- READ-ONLY.
#
# Dumps the PHP capture path used by `php yaamp/yiic.php dogePayout capture`
# so we can repoint its share attribution at the durable doge_share_archive
# table instead of the volatile `shares` table (~7 min retention).
#
# Usage:
#   curl -fsSL https://pool.honest.money/install/doge-capture-code.sh | sudo bash
set -uo pipefail

echo "doge-capture-code v2  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  READ-ONLY"
echo

DBUSER=""; DBPASS=""
if [ -r /var/web/serverconfig.php ]; then
  DBUSER=$(grep -oP "define\('YAAMP_DBUSER',\s*'\K[^']+" /var/web/serverconfig.php | head -1)
  DBPASS=$(grep -oP "define\('YAAMP_DBPASSWORD',\s*'\K[^']+" /var/web/serverconfig.php | head -1)
fi
SQLT() { mysql -u"$DBUSER" -p"$DBPASS" yiimpfrontend -t -e "$1" 2>&1; }

PHP=/var/web/yaamp/commands/DogePayoutCommand.php

echo "===== 1. archiver health ====="
systemctl is-active doge-share-archive.timer 2>/dev/null | sed 's/^/  timer: /'
echo "  archive schema:"
SQLT "DESCRIBE doge_share_archive;" | sed 's/^/  /'
echo "  archive size / growth:"
SQLT "SELECT COUNT(*) rows_now, FROM_UNIXTIME(MIN(minute_ts)) oldest,
             FROM_UNIXTIME(MAX(minute_ts)) newest,
             ROUND((MAX(minute_ts)-MIN(minute_ts))/60,1) span_min
      FROM doge_share_archive;" | sed 's/^/  /'
echo "  rows archived per minute, last 10 minutes:"
SQLT "SELECT FROM_UNIXTIME(minute_ts) minute, COUNT(*) users, SUM(shares_n) shares, ROUND(SUM(diff_sum)) diff
      FROM doge_share_archive
      WHERE minute_ts > UNIX_TIMESTAMP() - 600
      GROUP BY minute_ts ORDER BY minute_ts;" | sed 's/^/  /'
echo

echo "===== 2. capture function in $PHP ====="
echo "  --- function signatures ---"
grep -n "function " "$PHP" | sed 's/^/  /'
echo
echo "  --- capture body (lines 480-620) ---"
sed -n '480,620p' "$PHP" | cat -n | awk '{printf "  %d\t%s\n", $1+479, substr($0, index($0,$2))}' 2>/dev/null || sed -n '480,620p' "$PHP"
echo

echo "===== 3. the worker-join fallback (lines 1460-1500) ====="
sed -n '1460,1500p' "$PHP"
echo

echo "===== 4. would the archive satisfy recent DOGE blocks? ====="
SQLT "SELECT b.height, FROM_UNIXTIME(b.time) block_time,
       (SELECT COALESCE(SUM(a.shares_n),0) FROM doge_share_archive a
         WHERE a.minute_ts BETWEEN b.time - 3600 AND b.time) arch_shares_prior_60min,
       (SELECT COALESCE(SUM(a.diff_sum),0) FROM doge_share_archive a
         WHERE a.minute_ts BETWEEN b.time - 3600 AND b.time) arch_diff_prior_60min
      FROM blocks b
      WHERE b.coin_id=(SELECT id FROM coins WHERE symbol='DOGE')
      ORDER BY b.time DESC LIMIT 10;" | sed 's/^/  /'

echo
echo "inspect-only -- nothing was changed."
