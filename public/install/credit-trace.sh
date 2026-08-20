#!/usr/bin/env bash
# credit-trace.sh v1 -- READ-ONLY. The coinid patch is already applied and
# earnings STILL stopped (258m stale, 410 uncredited blocks). So the reward
# splitter is dying somewhere else. This walks the five remaining candidates
# in the order they can each independently produce "no earnings, ever":
#
#   A. wrong tree      loop2 executes a DIFFERENT blocks.php than the one we
#                      patched (/var/web) -> the fix is cosmetic.
#   B. no shares       shares table empty/stale -> $total_hash_power == 0 ->
#                      BackendBlockNew() returns before writing earnings.
#   C. no worker rows  shares exist but userid/workerid don't resolve to
#                      accounts -> nothing to credit them to.
#   D. loop2 not doing it  loop2 alive but erroring / not reaching the block
#                      pass (php fatal, db error, lock file, coin disabled).
#   E. blocks unlinked blocks rows have coin_id/height but no category or a
#                      category loop2 skips.
#
#   curl -fsSL "https://pool.honest.money/install/credit-trace.sh?v=$(date +%s)" | sudo bash 2>&1 | tee /tmp/credit-trace.txt
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEB=$(dirname "$SERVERCONFIG")
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
echo "credit-trace v1 $(date -u '+%F %T UTC')  web=$WEB db=${DBU:-UNRESOLVED}"

##############################################################################
hr "A. is the patched file the one loop2 actually runs?"
echo "  -- loop2 processes and their cwd / script path"
for p in $(pgrep -f 'loop2' 2>/dev/null); do
  echo "   pid $p"
  echo "     cmd : $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)"
  echo "     cwd : $(readlink -f /proc/$p/cwd 2>/dev/null)"
done
echo "  -- every blocks.php on the box, newest first (patched = has the marker)"
find / -xdev -name blocks.php -path '*backend*' 2>/dev/null | while read -r f; do
  m=$(grep -c POOL_MERGED_SHARE_FIX "$f" 2>/dev/null || echo 0)
  printf '   %s  marker=%s  mtime=%s\n' "$f" "$m" "$(date -u -r "$f" '+%F %T' 2>/dev/null)"
done
echo "  -- php opcache would also serve a stale copy:"
php -i 2>/dev/null | grep -iE 'opcache.enable|opcache.validate_timestamps' | sed 's/^/   /'

##############################################################################
hr "B. shares: is the stratum still feeding the splitter?"
MY "SELECT COUNT(*) rows_, FROM_UNIXTIME(MIN(time)) oldest, FROM_UNIXTIME(MAX(time)) newest,
           FLOOR((UNIX_TIMESTAMP()-MAX(time))/60) newest_age_min,
           COUNT(DISTINCT userid) users, ROUND(SUM(difficulty),2) sumdiff FROM shares;"
MY "SELECT algo, coinid, COUNT(*) n, FROM_UNIXTIME(MAX(time)) newest
    FROM shares GROUP BY algo, coinid ORDER BY n DESC LIMIT 10;"
echo "  ^ newest_age_min above ~10 = stratum is NOT writing shares -> nothing to split."

##############################################################################
hr "C. do those shares resolve to real accounts?"
MY "SELECT SUM(s.userid IS NULL OR s.userid=0) orphan_userid,
           SUM(s.userid IS NOT NULL AND a.id IS NULL) userid_no_account,
           COUNT(*) total
    FROM shares s LEFT JOIN accounts a ON a.id = s.userid
    WHERE s.time > UNIX_TIMESTAMP()-7200;"
MY "SELECT COUNT(*) workers_now, FROM_UNIXTIME(MAX(time)) newest_worker FROM workers;"

##############################################################################
hr "D. loop2 health -- is it reaching the block pass at all?"
systemctl --no-pager --lines=0 status yiimp-loop2 2>/dev/null | head -8 | sed 's/^/   /'
echo "  -- last 40 loop2 journal lines"
journalctl -u yiimp-loop2 -n 40 --no-pager 2>/dev/null | sed 's/^/   /'
echo "  -- php errors / fatals in the yiimp logs (last 30)"
for L in /var/log/yiimp/debug.log /var/web/log/debug.log /var/log/php*.log /var/log/nginx/error.log; do
  [ -f "$L" ] && { echo "   --- $L"; tail -200 "$L" 2>/dev/null | grep -iE 'fatal|error|exception|unable to insert earning' | tail -30 | sed 's/^/     /'; }
done
echo "  -- stale lock files would make loop2 skip work silently"
ls -la /tmp/*.lock /var/web/*.lock /var/run/yiimp* 2>/dev/null | sed 's/^/   /'

##############################################################################
hr "E. the 410 uncredited blocks -- what do they actually look like?"
MY "SELECT c.symbol, b.category, COUNT(*) n,
           MIN(FROM_UNIXTIME(b.time)) oldest, MAX(FROM_UNIXTIME(b.time)) newest,
           SUM(b.userid IS NULL) no_user, SUM(b.amount=0 OR b.amount IS NULL) zero_amount
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    LEFT JOIN earnings e ON e.blockid=b.id
    WHERE b.time > UNIX_TIMESTAMP()-86400 AND e.id IS NULL
    GROUP BY c.symbol, b.category ORDER BY n DESC;"
echo "  -- 5 most recent uncredited rows in full"
MY "SELECT b.id, c.symbol, b.height, b.category, b.confirmations, b.amount, b.difficulty_user,
           b.userid, b.workerid, FROM_UNIXTIME(b.time) found
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    LEFT JOIN earnings e ON e.blockid=b.id
    WHERE e.id IS NULL ORDER BY b.id DESC LIMIT 5;"

hr "F. earnings: last write per coin (what stopped, and when)"
MY "SELECT c.symbol, COUNT(*) n, FROM_UNIXTIME(MAX(e.create_time)) newest,
           FLOOR((UNIX_TIMESTAMP()-MAX(e.create_time))/60) age_min
    FROM earnings e JOIN coins c ON c.id=e.coinid GROUP BY c.symbol ORDER BY newest DESC;"
MY "SELECT status, COUNT(*) n, FROM_UNIXTIME(MIN(create_time)) oldest, FROM_UNIXTIME(MAX(create_time)) newest
    FROM earnings GROUP BY status;"

hr "G. coin rows loop2 will/won't touch"
MY "SELECT id,symbol,enable,auto_ready,installed,visible,algo,payout_min,
           block_height,target_height,IFNULL(LEFT(errors,60),'') errors
    FROM coins WHERE algo='scrypt' OR symbol IN ('LTC','DOGE','TXC','ISK','ZCU');"

echo
echo "READ THIS FIRST: section A marker=0 on the loop2 tree, or section B"
echo "newest_age_min > 10, explains everything downstream. Fix that one only."
echo "done."
