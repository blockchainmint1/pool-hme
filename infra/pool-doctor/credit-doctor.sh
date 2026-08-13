#!/usr/bin/env bash
# credit-doctor.sh v2 -- why does yiimp stop writing `earnings` rows?
# READ-ONLY. v2 fixes: DB creds read from YAAMP_DBUSER/YAAMP_DBPASSWORD like
# payout-reconcile does, and we now dump BackendBlockFind2 (the function that
# actually creates earnings at block-find time) instead of BackendBlocksUpdate.
#   curl -fsSL https://pool.honest.money/install/credit-doctor.sh | sudo bash 2>&1 | tee /tmp/credit.txt
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEB=$(dirname "$SERVERCONFIG")
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
echo "credit-doctor v2 $(date -u '+%F %T UTC')  web=$WEB db_user=${DBU:-UNRESOLVED}"

hr "1. BackendBlockFind2 -- the function that WRITES earnings at find time"
F="$WEB/yaamp/core/backend/blocks.php"
[ -f "$F" ] || F=$(grep -rl "function BackendBlockFind2" "$WEB" --include=*.php 2>/dev/null | head -1)
echo "  file: $F"
awk '/function BackendBlockFind2/,/^}/' "$F" 2>/dev/null | sed 's/^/     /'

hr "2. every place earnings rows are INSERTed"
grep -rn "INSERT INTO earnings\|new db_earnings\|db_earnings(" "$WEB" --include=*.php 2>/dev/null | grep -v '/backup' | head -20 | sed 's/^/     /'

hr "3. do blocks rows carry what crediting needs?"
MY "SELECT b.id,b.height,c.symbol,b.category,b.confirmations,b.userid,b.workerid,
           b.difficulty_user,b.amount,b.price,b.algo,b.solo,FROM_UNIXTIME(b.time) AS found
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol IN ('LTC','DOGE') ORDER BY b.id DESC LIMIT 14;"
MY "SELECT c.symbol,
           SUM(b.userid IS NULL OR b.userid=0)            AS no_userid,
           SUM(b.difficulty_user IS NULL OR b.difficulty_user=0) AS no_diffuser,
           SUM(b.price IS NULL OR b.price=0)              AS no_price,
           SUM(b.algo IS NULL OR b.algo='')               AS no_algo,
           COUNT(*) AS n
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.time > UNIX_TIMESTAMP()-14*86400 AND c.symbol IN ('LTC','DOGE')
    GROUP BY c.symbol;"
echo "  ^ userid=0 / difficulty_user=0 means the reward can never be split."

hr "4. blocks WITH earnings vs WITHOUT -- what is different about the 28 that worked?"
MY "SELECT e.id,e.blockid,c.symbol,b.height,b.category,b.userid,b.difficulty_user,b.algo,
           e.amount,e.status,FROM_UNIXTIME(e.create_time) AS created
    FROM earnings e LEFT JOIN blocks b ON b.id=e.blockid
    LEFT JOIN coins c ON c.id=e.coinid ORDER BY e.id DESC LIMIT 15;"

hr "5. coin config in full"
MY "SELECT id,symbol,name,enable,auto_ready,installed,visible,algo,rpcencoding,
           conf_avg,txfee,payout_min,IFNULL(errors,'') AS errors,
           block_height,target_height,IFNULL(reward,0) AS reward
    FROM coins WHERE symbol IN ('LTC','DOGE');"

hr "6. algo mismatch check -- shares.algo vs coins.algo vs blocks.algo"
MY "SELECT 'shares' src, algo, COUNT(*) n FROM shares GROUP BY algo
    UNION ALL SELECT 'blocks', algo, COUNT(*) FROM blocks WHERE time>UNIX_TIMESTAMP()-14*86400 GROUP BY algo;"

hr "7. share retention vs maturity window"
MY "SELECT FROM_UNIXTIME(MIN(time)) oldest_share, FROM_UNIXTIME(MAX(time)) newest_share,
           ROUND((MAX(time)-MIN(time))/3600,1) hours_kept, COUNT(*) rows_ FROM shares;"
MY "SELECT c.symbol, COUNT(*) mature_uncredited, ROUND(SUM(b.amount),2) owed,
           FROM_UNIXTIME(MIN(b.time)) oldest, FROM_UNIXTIME(MAX(b.time)) newest
    FROM blocks b JOIN coins c ON c.id=b.coin_id LEFT JOIN earnings e ON e.blockid=b.id
    WHERE e.id IS NULL AND b.category='generate'
      AND ((c.symbol='DOGE' AND b.confirmations>=240) OR (c.symbol='LTC' AND b.confirmations>=100))
    GROUP BY c.symbol;"
echo "  NOTE: DOGE overlaps doge_payout_ledger (paid outside earnings). LTC has no fallback."

hr "8. LTC payout pipeline"
MY "SELECT FROM_UNIXTIME(MAX(p.time)) last_ltc_payout, COUNT(*) n
    FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE c.symbol='LTC';"
MY "SELECT id,account_id,idcoin,FROM_UNIXTIME(time) t,completed,amount,IFNULL(tx,'') tx,IFNULL(errmsg,'') errmsg
    FROM payouts WHERE completed=0 ORDER BY id DESC LIMIT 10;"
echo "-- ltc-unlock last run:"
journalctl -u ltc-unlock.service -n 6 --no-pager 2>/dev/null | sed 's/^/     /'
echo "-- payout cron/timers:"
systemctl list-timers --all 2>/dev/null | grep -iE "payout|ltc|doge" | sed 's/^/     /'
crontab -l 2>/dev/null | grep -iE "payout|doge|ltc" | sed 's/^/     /'

hr "9. yiimp debuglog -- crediting-relevant lines only (ZCU trace spam filtered)"
grep -viE "ZCU_1F_TRACE" /var/log/yiimp/debug.log 2>/dev/null | tail -40 | sed 's/^/     /'
echo "-- earnings/credit mentions in the last 200k of debuglog:"
tail -c 200000 /var/log/yiimp/debug.log 2>/dev/null | grep -iE "earning|credit|payout|unable to find|not found" | tail -25 | sed 's/^/     /'

echo
echo "read-only -- nothing was modified."
