#!/usr/bin/env bash
# payout-reconcile.sh -- READ ONLY. Answers exactly two questions, per coin:
#
#   1. ARE SHARES ALLOCATED CORRECTLY?   your share of hashrate  vs  your share of credits
#   2. ARE MINERS PAID ON A CADENCE?     mined -> credited -> paid, per day, per address
#
#   curl -fsSL https://pool.honest.money/install/payout-reconcile.sh | sudo bash 2>&1 | tee /tmp/reconcile.txt
#   ADDR=D...  curl -fsSL ... | sudo bash     # focus the trace on one payout address
#
# The money can only be in one of five places. This prints all five so the leak
# is obvious:
#   A. block reward mined but never credited            -> hot-wallet float
#   B. credited to an account balance, never paid       -> accounts.balance
#   C. queued as a payout row, never sent               -> payouts.completed=0
#   D. ledgered (DOGE custom path), never sent          -> doge_payout_ledger
#   E. actually sent on-chain                           -> daemon listtransactions
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
FOCUS="${ADDR:-}"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

echo "payout-reconcile $(date -u '+%F %T UTC')  focus=${FOCUS:-none}"

hr "0. schema recon (so every query below is column-correct)"
for T in shares blocks earnings accounts payouts doge_payout_ledger; do
  printf '  %-20s %s\n' "$T:" "$(MYN "SELECT IFNULL(GROUP_CONCAT(column_name ORDER BY ordinal_position),'** MISSING **')
      FROM information_schema.columns WHERE table_schema='yiimpfrontend' AND table_name='$T'")"
done

hr "1. WHO IS MINING -- hashrate share by account (should mirror reward share)"
MY "SELECT a.username,
        COUNT(DISTINCT w.id) workers,
        ROUND(SUM(w.hashrate)/1e9,3) ths,
        ROUND(100*SUM(w.hashrate)/(SELECT SUM(hashrate) FROM workers),2) pct_of_pool
     FROM workers w JOIN accounts a ON a.id=w.userid
     GROUP BY a.username ORDER BY ths DESC LIMIT 15"

hr "2. SHARE ALLOCATION -- share rows by account, last 60 min (live attribution)"
MY "SELECT a.username, COUNT(*) share_rows, ROUND(SUM(s.difficulty),2) sum_diff,
        ROUND(100*SUM(s.difficulty)/(SELECT SUM(difficulty) FROM shares
              WHERE time>UNIX_TIMESTAMP()-3600),2) pct_of_shares,
        SUM(s.valid=0) invalid
     FROM shares s LEFT JOIN accounts a ON a.id=s.userid
     WHERE s.time > UNIX_TIMESTAMP()-3600
     GROUP BY a.username ORDER BY sum_diff DESC LIMIT 15"
echo "  ^ pct_of_shares here MUST match pct_of_pool above. If a row has username NULL,"
echo "    those shares are attributed to nobody -- that is silent reward theft by the pool."

hr "3. MINED -- every LTC/DOGE block, 14d, by day"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(b.time)) d, COUNT(*) blocks,
        ROUND(SUM(b.amount),4) mined, GROUP_CONCAT(DISTINCT b.category) categories
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time>UNIX_TIMESTAMP()-14*86400
     GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"

hr "4. CREDITED -- earnings rows against those blocks (the yiimp path)"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(e.create_time)) d, COUNT(*) rows_,
        ROUND(SUM(e.amount),4) credited, SUM(e.status=0) unconfirmed
     FROM earnings e JOIN coins c ON c.id=e.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND e.create_time>UNIX_TIMESTAMP()-14*86400
     GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"
echo "-- THE GAP: mined vs credited, 14d totals"
MY "SELECT c.symbol,
        ROUND((SELECT SUM(b.amount) FROM blocks b WHERE b.coin_id=c.id
               AND b.time>UNIX_TIMESTAMP()-14*86400),2) mined_14d,
        ROUND((SELECT SUM(e.amount) FROM earnings e WHERE e.coinid=c.id
               AND e.create_time>UNIX_TIMESTAMP()-14*86400),2) credited_14d,
        ROUND((SELECT IFNULL(SUM(l.amount),0) FROM doge_payout_ledger l
               WHERE c.symbol='DOGE' AND l.created_at>UNIX_TIMESTAMP()-14*86400),2) ledgered_14d
     FROM coins c WHERE c.symbol IN ('LTC','DOGE')"

hr "5. WHICH BLOCKS GOT NO CREDIT (the actual leak, most recent 40)"
MY "SELECT c.symbol, b.height, FROM_UNIXTIME(b.time) found, ROUND(b.amount,2) reward,
        b.category, b.confirmations, IFNULL(e.n,0) earning_rows
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT blockid, COUNT(*) n FROM earnings GROUP BY blockid) e ON e.blockid=b.id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time>UNIX_TIMESTAMP()-14*86400
       AND IFNULL(e.n,0)=0
     ORDER BY b.time DESC LIMIT 40"

hr "6. PAID -- payout rows by day (yiimp path)"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(p.time)) d, COUNT(*) n, SUM(p.completed=1) done,
        ROUND(SUM(p.amount),4) amount
     FROM payouts p JOIN coins c ON c.id=p.idcoin
     WHERE p.time>UNIX_TIMESTAMP()-21*86400 GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"
echo "-- DOGE custom ledger, by day and status"
MY "SELECT DATE(FROM_UNIXTIME(created_at)) d, status, COUNT(*) n, ROUND(SUM(amount),2) doge
     FROM doge_payout_ledger WHERE created_at>UNIX_TIMESTAMP()-21*86400
     GROUP BY d, status ORDER BY d DESC, doge DESC"

hr "7. STILL OWED -- money sitting in balances / queues right now"
MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) unpaid_balance
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE') GROUP BY c.symbol"
MY "SELECT c.symbol, a.username, ROUND(a.balance,6) balance, ROUND(c.payout_min,6) payout_min,
        IF(a.balance>=c.payout_min,'ELIGIBLE','below threshold') state
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE')
     ORDER BY a.balance DESC LIMIT 20"

hr "8. WALLET REALITY -- whole wallet, not one address"
for D in litecoind dogecoind; do
  detect "$D"; CLI="$D_BIN/${D%d}-cli -conf=$D_CONF"
  echo "-- $D ($CLI)"
  $CLI getwalletinfo 2>&1 | grep -E '"balance"|immature|unlocked_until|txcount' | sed 's/^/     /'
  echo "     sends in last 20 tx:"
  $CLI listtransactions "*" 20 0 2>/dev/null \
    | grep -E '"category"|"amount"|"time"' | paste - - - | tail -8 | sed 's/^/       /'
done
echo "  ^ getwalletinfo balance is the WHOLE wallet across every address."
echo "    A block explorer view of a single receive address will always read low."

if [ -n "$FOCUS" ]; then
  hr "9. TRACE $FOCUS"
  MY "SELECT id, username, coinid, ROUND(balance,6) balance FROM accounts WHERE username LIKE '%$FOCUS%'"
  MY "SELECT p.id, c.symbol, p.amount, p.completed, LEFT(IFNULL(p.tx,''),24) tx,
          LEFT(IFNULL(p.errmsg,''),40) errmsg, FROM_UNIXTIME(p.time) t
       FROM payouts p JOIN coins c ON c.id=p.idcoin
       JOIN accounts a ON a.id=p.account_id WHERE a.username LIKE '%$FOCUS%'
       ORDER BY p.id DESC LIMIT 20"
  MY "SELECT id, address, ROUND(amount,2) amount, status, LEFT(IFNULL(txid,''),24) txid,
          FROM_UNIXTIME(created_at) created FROM doge_payout_ledger
       WHERE address='$FOCUS' ORDER BY created_at DESC LIMIT 20"
fi

echo
echo "read-only -- nothing was modified."
