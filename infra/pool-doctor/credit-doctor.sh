#!/usr/bin/env bash
# credit-doctor.sh -- why does yiimp stop writing `earnings` rows for mature blocks?
# READ-ONLY. Nothing is modified. Run:
#   curl -fsSL https://pool.honest.money/install/credit-doctor.sh | sudo bash
set -uo pipefail
VER="credit-doctor v1"
echo "$VER $(date -u '+%F %T UTC')"

# ---------- locate yiimp web root + db creds -------------------------------
WEB=""
for c in /var/web /var/www/yiimp/web /var/stratum/web /home/ubuntu/yiimp/web; do
  [ -f "$c/serverconfig.php" ] && WEB="$c" && break
done
if [ -z "$WEB" ]; then
  WEB="$(dirname "$(find /var /home/ubuntu -maxdepth 6 -name serverconfig.php 2>/dev/null | head -1)")"
fi
echo "  webroot: ${WEB:-NOT FOUND}"

CFG=""
for c in "$WEB/serverconfig.php" "$WEB/../serverconfig.php"; do [ -f "$c" ] && CFG="$c" && break; done
DBH=$(grep -oP "dbhost\s*=\s*['\"]\K[^'\"]+" "$CFG" 2>/dev/null | head -1)
DBN=$(grep -oP "dbname\s*=\s*['\"]\K[^'\"]+" "$CFG" 2>/dev/null | head -1)
DBU=$(grep -oP "dbuser\s*=\s*['\"]\K[^'\"]+" "$CFG" 2>/dev/null | head -1)
DBP=$(grep -oP "dbpass\s*=\s*['\"]\K[^'\"]+" "$CFG" 2>/dev/null | head -1)
[ -z "${DBN:-}" ] && DBN=yiimpfrontend
[ -z "${DBH:-}" ] && DBH=127.0.0.1
if [ -z "${DBU:-}" ]; then
  SC=$(ls /var/stratum/config/*.conf 2>/dev/null | head -1)
  DBU=$(grep -oP '^\s*user\s*=\s*\K\S+' "$SC" 2>/dev/null | head -1)
  DBP=$(grep -oP '^\s*password\s*=\s*\K\S+' "$SC" 2>/dev/null | head -1)
fi
Q() { mysql -h"$DBH" -u"$DBU" -p"$DBP" "$DBN" -e "$1" 2>&1 | grep -v "Using a password"; }
echo "  db: $DBU@$DBH/$DBN"

echo
echo "===== 1. the loop scripts (what actually credits)"
for u in yiimp-loop2 yiimp-blocks yiimp-main; do
  EX=$(systemctl cat $u 2>/dev/null | grep -m1 '^ExecStart=' | cut -d= -f2-)
  echo "-- $u ExecStart: ${EX:-<none>}"
  SH=$(echo "$EX" | grep -oP '\S+\.sh' | head -1)
  [ -f "$SH" ] && sed -n '1,30p' "$SH" | sed 's/^/     /'
done

echo
echo "===== 2. real output of one loop2 pass (the silent lines in journal)"
LOOP2SH=$(systemctl cat yiimp-loop2 2>/dev/null | grep -m1 '^ExecStart=' | grep -oP '\S+\.sh' | head -1)
PHPDIR=""
if [ -f "$LOOP2SH" ]; then
  PHPDIR=$(grep -oP 'cd\s+\K\S+' "$LOOP2SH" | head -1)
  echo "  loop2 script: $LOOP2SH   phpdir: ${PHPDIR:-?}"
fi
CRON="$WEB/../yaamp/../"
for d in "$PHPDIR" "$WEB/yaamp/scripts" "$WEB/../yaamp/scripts" /var/web/yaamp/scripts; do
  [ -d "$d" ] && { echo "  scripts dir: $d"; ls "$d" | head -20 | sed 's/^/     /'; break; }
done

echo
echo "===== 3. yiimp crediting source -- the gate that decides earnings"
SRC=$(grep -rl "function BackendBlockFound\|function BackendBlocksUpdate" /var /home/ubuntu --include=*.php 2>/dev/null | head -3)
echo "  candidates: ${SRC:-none found}"
for f in $SRC; do
  echo "-- $f"
  awk '/function BackendBlocksUpdate|function BackendBlockFound/,/^}/' "$f" | head -80 | sed 's/^/     /'
done

echo
echo "===== 4. do blocks rows carry the fields crediting needs?"
Q "SELECT b.id,b.height,c.symbol,b.category,b.confirmations,b.userid,b.workerid,
          b.difficulty_user,b.amount,b.price,b.algo,b.time
   FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE c.symbol IN ('LTC','DOGE') ORDER BY b.id DESC LIMIT 12;"
echo "  ^ userid/difficulty_user = 0 or NULL means yiimp cannot split the reward."
Q "SELECT c.symbol,
          SUM(b.userid IS NULL OR b.userid=0) AS no_userid,
          SUM(b.difficulty_user IS NULL OR b.difficulty_user=0) AS no_diffuser,
          SUM(b.price IS NULL OR b.price=0) AS no_price,
          COUNT(*) AS n
   FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE b.time > UNIX_TIMESTAMP()-14*86400 AND c.symbol IN ('LTC','DOGE')
   GROUP BY c.symbol;"

echo
echo "===== 5. coin rows in full (crediting reads a lot of these columns)"
Q "SELECT id,symbol,name,enable,auto_ready,installed,visible,rpcport,rpcuser IS NOT NULL AS has_rpcuser,
          conf_avg,txfee,payout_min,reward,reward_mul,mature_blocks,IFNULL(errors,'') AS errors
   FROM coins WHERE symbol IN ('LTC','DOGE')\G" 2>/dev/null || \
Q "SELECT * FROM coins WHERE symbol IN ('LTC','DOGE')\G"

echo
echo "===== 6. settings / flags that disable crediting"
Q "SHOW TABLES LIKE 'settings';"
Q "SELECT * FROM settings WHERE param LIKE '%earn%' OR param LIKE '%block%' OR param LIKE '%payout%' OR param LIKE '%disable%';" 2>/dev/null
echo "-- yiimp debug/log files (last 40 lines each):"
for L in /var/log/yiimp/debug.log /var/log/yiimp.log "$WEB/../log/debug.log" /var/stratum/log/debug.log /var/log/syslog; do
  [ -f "$L" ] || continue
  echo "-- $L"
  grep -iE "earning|block|credit|error|exception" "$L" 2>/dev/null | tail -25 | sed 's/^/     /'
done

echo
echo "===== 7. the 28 LTC earnings we DID get -- what was different?"
Q "SELECT e.id,e.blockid,b.height,b.category,b.confirmations,b.userid,b.difficulty_user,
          e.amount,e.status,FROM_UNIXTIME(e.create_time) AS created
   FROM earnings e LEFT JOIN blocks b ON b.id=e.blockid ORDER BY e.id DESC LIMIT 15;"

echo
echo "===== 8. share retention vs block age (can a mature block still be split?)"
Q "SELECT 'shares kept (hours)' AS k,
          ROUND((MAX(time)-MIN(time))/3600,1) AS v FROM shares;"
Q "SELECT c.symbol, COUNT(*) AS mature_uncredited,
          ROUND(SUM(b.amount),2) AS owed,
          FROM_UNIXTIME(MIN(b.time)) AS oldest, FROM_UNIXTIME(MAX(b.time)) AS newest
   FROM blocks b JOIN coins c ON c.id=b.coin_id
   LEFT JOIN earnings e ON e.blockid=b.id
   WHERE e.id IS NULL AND b.category='generate'
     AND ((c.symbol='DOGE' AND b.confirmations>=240) OR (c.symbol='LTC' AND b.confirmations>=100))
   GROUP BY c.symbol;"
echo "  NOTE: DOGE rows here overlap doge_payout_ledger -- DOGE is paid by the custom"
echo "        ledger, not by earnings. LTC has no such fallback: LTC uncredited = real loss."

echo
echo "===== 9. LTC payout pipeline (balances exist but are they being sent?)"
Q "SELECT FROM_UNIXTIME(MAX(p.time)) AS last_ltc_payout FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE c.symbol='LTC';"
Q "SELECT id,account_id,FROM_UNIXTIME(time) AS t,completed,amount,tx,IFNULL(errmsg,'') AS errmsg
   FROM payouts WHERE completed=0 ORDER BY id DESC LIMIT 10;"
systemctl list-timers --all 2>/dev/null | grep -iE "payout|ltc|doge" | sed 's/^/     /'
echo "-- ltc-unlock.service is 'inactive dead' -- check its timer:"
systemctl status ltc-unlock.timer 2>/dev/null | head -8 | sed 's/^/     /'

echo
echo "read-only -- nothing was modified."
