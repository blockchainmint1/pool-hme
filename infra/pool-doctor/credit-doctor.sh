#!/usr/bin/env bash
# credit-doctor.sh v3 -- READ-ONLY. v2 proved BackendBlockFind2 inserts DOGE
# block rows fine; the earnings never appear. v3 dumps BackendBlockNew (the
# function BackendBlockFind2 calls, which is what actually splits the reward
# into `earnings`) and tests the leading hypothesis: the merged-mining DOGE
# block row is created from listsinceblock AFTER the shares for that round
# were already consumed/deleted by the LTC parent find -> nothing to split.
#   curl -fsSL https://pool.honest.money/install/credit-doctor.sh | sudo bash 2>&1 | tee /tmp/credit.txt
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEB=$(dirname "$SERVERCONFIG")
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
B="$WEB/yaamp/core/backend/blocks.php"
echo "credit-doctor v3 $(date -u '+%F %T UTC')  web=$WEB db_user=${DBU:-UNRESOLVED}"

hr "1. BackendBlockNew -- THE reward splitter (writes earnings)"
awk '/function BackendBlockNew/,/^}/' "$B" 2>/dev/null | sed 's/^/     /'

hr "2. BackendBlocksUpdate -- maturity + the 'unable to find immature block' path"
awk '/function BackendBlocksUpdate/,/^}/' "$B" 2>/dev/null | sed 's/^/     /'

hr "3. who DELETEs shares (if the parent find eats them, aux gets nothing)"
grep -rn "DELETE FROM shares\|delete from shares\|'shares'" "$WEB" --include=*.php 2>/dev/null | grep -vi backup | head -20 | sed 's/^/     /'

hr "4. are there shares still on disk for the rounds of recent DOGE blocks?"
for H in $(MYN "SELECT b.time FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='DOGE' AND b.userid IS NOT NULL ORDER BY b.id DESC LIMIT 4"); do
  echo "  -- DOGE block found at $(date -u -d @"$H" '+%F %T') (unix $H)"
  MY "SELECT COUNT(*) shares_in_round, MIN(FROM_UNIXTIME(time)) oldest, MAX(FROM_UNIXTIME(time)) newest,
             COUNT(DISTINCT userid) users, ROUND(SUM(difficulty),2) sumdiff
      FROM shares WHERE time BETWEEN $H-3600 AND $H;"
done

hr "5. shares table right now: is anything ever removed?"
MY "SELECT COUNT(*) rows_, FROM_UNIXTIME(MIN(time)) oldest, FROM_UNIXTIME(MAX(time)) newest,
           COUNT(DISTINCT coinid) coinids, SUM(coinid=0 OR coinid IS NULL) coinid_zero FROM shares;"
MY "SELECT coinid, COUNT(*) n, FROM_UNIXTIME(MAX(time)) newest FROM shares GROUP BY coinid ORDER BY n DESC LIMIT 8;"
echo "  ^ if coinid is the LTC id only, aux DOGE blocks have no shares keyed to them."

hr "6. coin config (v2's conf_avg column does not exist here)"
MY "SHOW COLUMNS FROM coins;" | awk 'NR<4 || /symbol|algo|rpcencoding|payout|enable|reward|conf/'
MY "SELECT id,symbol,enable,auto_ready,installed,visible,algo,rpcencoding,txfee,payout_min,
           IFNULL(errors,'') errors, block_height, target_height
    FROM coins WHERE symbol IN ('LTC','DOGE');"

hr "7. the 'unable to find immature block' blocks -- do the txs exist on-chain?"
MY "SELECT b.id,c.symbol,b.height,b.category,b.confirmations,LEFT(b.blockhash,20) blockhash,b.userid
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.height IN (6307970,6307980,3150040,3158667);"
echo "  (yiimp calls gettransaction on the coinbase tx; if the wallet no longer"
echo "   holds it -- e.g. after the wallet rotation/sweep -- the block can never mature.)"

hr "8. wallet rotation timeline vs. the credit stoppage"
MY "SELECT DATE(FROM_UNIXTIME(b.time)) d, c.symbol, COUNT(*) blocks_,
           SUM(b.category='generate') mature, SUM(b.userid IS NOT NULL) with_user
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.time > UNIX_TIMESTAMP()-21*86400 AND c.symbol IN ('LTC','DOGE')
    GROUP BY d,c.symbol ORDER BY d DESC LIMIT 30;"
MY "SELECT DATE(created) d, COUNT(*) n FROM earnings
    GROUP BY d ORDER BY d DESC LIMIT 15;"

hr "9. stuck LTC payout rows (completed=0, empty errmsg = never attempted)"
MY "SELECT p.id,p.account_id,a.username,p.amount,FROM_UNIXTIME(p.time) t,p.completed,
           IFNULL(p.tx,'') tx, IFNULL(p.errmsg,'') errmsg
    FROM payouts p LEFT JOIN accounts a ON a.id=p.account_id
    WHERE p.completed=0 ORDER BY p.id DESC LIMIT 10;"

echo
echo "read-only -- nothing was modified."
