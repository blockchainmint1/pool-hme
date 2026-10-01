#!/usr/bin/env bash
# home-miner-payouts.sh v1 -- READ ONLY. Are small home miners earning and getting paid?
#   curl -fsSL "https://pool.honest.money/install/home-miner-payouts.sh?v=$(date +%s)" | sudo bash
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SC=/var/web/serverconfig.php
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SC" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool"
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
echo "home-miner-payouts v1 $(date -u '+%F %T UTC')"

hr "1. server wallets (is money piling up?)"
echo "  LTC : $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "  DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
MY "SELECT symbol, payout_min, txfee, enable FROM coins WHERE symbol IN ('LTC','DOGE')"
grep -nE "YAAMP_PAYMENTS_FREQ|YAAMP_PAYMENTS_MINI" "$SC" | sed 's/^/  /'

hr "2. what the pool owes miners (accounts.balance)"
MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) owed,
        SUM(a.balance < c.payout_min) below_min, ROUND(SUM(IF(a.balance<c.payout_min,a.balance,0)),6) owed_below_min
    FROM accounts a JOIN coins c ON c.id=a.coinid
    WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE') GROUP BY c.symbol"

hr "3. every miner seen in 7 days: hashrate share vs LTC earned vs paid"
MY "SELECT LEFT(a.username,34) addr,
        (SELECT COUNT(*) FROM workers w WHERE w.userid=a.id) workers_now,
        ROUND((SELECT SUM(s.difficulty) FROM shares s WHERE s.userid=a.id AND s.valid=1),0) live_sharediff,
        ROUND((SELECT IFNULL(SUM(e.amount),0) FROM earnings e WHERE e.userid=a.id AND e.create_time>UNIX_TIMESTAMP()-7*86400),8) earned_7d,
        ROUND(a.balance,8) balance, ROUND((SELECT IFNULL(SUM(p.amount),0) FROM payouts p WHERE p.account_id=a.id),8) paid_total,
        (SELECT FROM_UNIXTIME(MAX(p.time)) FROM payouts p WHERE p.account_id=a.id) last_payout,
        FROM_UNIXTIME(a.last_earning) last_earning
    FROM accounts a JOIN coins c ON c.id=a.coinid
    WHERE c.symbol='LTC' AND (a.last_earning>UNIX_TIMESTAMP()-7*86400
       OR EXISTS (SELECT 1 FROM workers w WHERE w.userid=a.id))
    ORDER BY earned_7d ASC LIMIT 40"

hr "4. earnings per coin per day, small miners only (not the pool's own address)"
MY "SELECT DATE(FROM_UNIXTIME(e.create_time)) d, c.symbol, COUNT(DISTINCT e.userid) miners, ROUND(SUM(e.amount),6) amt
    FROM earnings e JOIN coins c ON c.id=e.coinid JOIN accounts a ON a.id=e.userid
    WHERE e.create_time>UNIX_TIMESTAMP()-7*86400 AND a.username<>'LdSHVgxVWbP5kGKzmZMm8aEXe2wprwwr32'
    GROUP BY d, c.symbol ORDER BY d DESC, c.symbol"

hr "5. payouts sent in 14 days"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(p.time)) d, COUNT(*) n, ROUND(SUM(p.amount),6) amt, SUM(p.completed=0) not_sent
    FROM payouts p JOIN coins c ON c.id=p.idcoin
    WHERE p.time>UNIX_TIMESTAMP()-14*86400 GROUP BY 1,2 ORDER BY 2 DESC,1"

hr "6. DOGE side ledger"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) doge, FROM_UNIXTIME(MAX(updated_at)) last_touch FROM doge_payout_ledger GROUP BY status"
MY "SELECT LEFT(username,34) addr, ROUND(doge_balance,4) doge_balance FROM accounts WHERE doge_balance>0 ORDER BY doge_balance DESC LIMIT 25" 
echo "  -- doge cycle cron + last log lines --"
cat /etc/cron.d/yiimp-doge-payout-cycle 2>/dev/null | sed 's/^/  /'
tail -n 15 /var/web/runtime/doge-payout/cron-wrapper.log 2>/dev/null | sed 's/^/  /'

echo; echo "read-only: nothing was modified."
