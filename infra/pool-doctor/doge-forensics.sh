#!/usr/bin/env bash
# doge-forensics.sh v2 -- READ ONLY, schema-aware.
#
#   curl -fsSL https://pool.honest.money/install/doge-forensics.sh | sudo bash 2>&1 | tee /tmp/doge-forensics.txt
#   ADDR=D... curl -fsSL .../doge-forensics.sh | sudo bash    # also trace one payout address
#
# v1 assumed doge_payout_ledger had `txid` and `address`. It does not. v2 reads
# the real schema first and only queries columns that exist.
#
# The headline from v1 that DID work:
#   14d mined 960,685 DOGE  vs  14d ledgered 360,227 DOGE
# ~600k of block rewards never entered the ledger at all -> that IS the 426k
# float sitting in the hot wallet. So the question is no longer "why no sends"
# (sends work, 11:55 today) but "why does capture skip ~60% of blocks".
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
CYCLE=${CYCLE:-/var/web/doge-payout-cycle.sh}
RUNDIR=${RUNDIR:-/var/web/runtime/doge-payout}
LOG=${LOG:-/var/web/runtime/doge-payout/cron-wrapper.log}
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }

echo "doge-forensics v2 $(date -u '+%F %T UTC')"

hr "0. actual ledger schema (so we stop guessing)"
MY "SHOW CREATE TABLE doge_payout_ledger\G" 2>/dev/null | sed 's/^/   /'
COLS=$(MYN "SELECT GROUP_CONCAT(column_name) FROM information_schema.columns
            WHERE table_schema='yiimpfrontend' AND table_name='doge_payout_ledger'")
echo "   columns: $COLS"
has() { echo ",$COLS," | grep -qi ",$1,"; }
# resolve optional columns
TXCOL=""; for c in txid tx_hash tx txhash; do has "$c" && { TXCOL=$c; break; }; done
ADDRCOL=""; for c in address addr username account payout_address; do has "$c" && { ADDRCOL=$c; break; }; done
PAIDCOL=""; for c in paid_at paidat paid_time; do has "$c" && { PAIDCOL=$c; break; }; done
echo "   using: txid=${TXCOL:-none}  address=${ADDRCOL:-none}  paid_at=${PAIDCOL:-none}"

hr "1. is the cycle running? (v1 said yes: 1006 cron lines / 7d, lock free)"
grep -rh 'doge-payout' /etc/cron.d/* 2>/dev/null | grep -v '^\s*#' | sed 's/^/   /'
ls -la "$RUNDIR" 2>/dev/null | sed 's/^/   /'
echo "   -- last 60 lines of $LOG:"
[ -f "$LOG" ] && tail -n 60 "$LOG" | sed 's/^/   /' || echo "   ** $LOG missing **"
echo "   -- capture outcome keywords across every doge log:"
grep -ohE 'no_shares|no shares|captured|skip|already|insufficient|error|immature' \
  "$LOG" "$RUNDIR"/*.log /var/log/doge-payout-cycle.log 2>/dev/null \
  | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -15 | sed 's/^/   /'

hr "2. THE GAP: every DOGE block in 14d and whether the ledger ever saw it"
MY "SELECT b.id block_id, b.height, FROM_UNIXTIME(b.time) found,
        ROUND(b.amount,2) reward, b.category, b.confirmations,
        IFNULL(l.n,0) ledger_rows, ROUND(IFNULL(l.doge,0),2) ledger_doge
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT block_id, COUNT(*) n, SUM(amount) doge
                FROM doge_payout_ledger GROUP BY block_id) l ON l.block_id=b.id
     WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-14*86400
     ORDER BY b.time DESC LIMIT 80"
echo "-- summary: blocks WITH vs WITHOUT ledger rows (14d)"
MY "SELECT IF(IFNULL(l.n,0)=0,'ORPHANED (no ledger rows = float)','captured') state,
        COUNT(*) blocks, ROUND(SUM(b.amount),2) doge
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT block_id, COUNT(*) n FROM doge_payout_ledger GROUP BY block_id) l
       ON l.block_id=b.id
     WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-14*86400
     GROUP BY state"
echo "-- same split, per day (when did capture start missing blocks?)"
MY "SELECT DATE(FROM_UNIXTIME(b.time)) d,
        SUM(IFNULL(l.n,0)>0) captured, SUM(IFNULL(l.n,0)=0) orphaned,
        ROUND(SUM(IF(IFNULL(l.n,0)=0,b.amount,0)),2) doge_stranded
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT block_id, COUNT(*) n FROM doge_payout_ledger GROUP BY block_id) l
       ON l.block_id=b.id
     WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-21*86400
     GROUP BY d ORDER BY d DESC"

hr "3. WHY capture skips them: were there shares in the window?"
echo "   cycle window settings:"
grep -nE '^(TOKEN_WINDOW_HOURS|BLOCK_LIMIT|SHARE_WINDOW_MINUTES|MIN_PAYOUT_DOGE|MAX_TOTAL_SEND_DOGE|MAX_BATCHES_PER_RUN)=' "$CYCLE" | sed 's/^/      /'
echo "   how capture selects shares (the SQL inside the cycle):"
grep -nE 'shares|SHARE_WINDOW|coinid|algo' "$CYCLE" 2>/dev/null | head -25 | sed 's/^/      /'
echo "   live share table depth right now (how long shares survive):"
MY "SELECT c.symbol, COUNT(*) rows_, FROM_UNIXTIME(MIN(s.time)) oldest,
        FROM_UNIXTIME(MAX(s.time)) newest
     FROM shares s LEFT JOIN coins c ON c.id=s.coinid GROUP BY c.symbol ORDER BY rows_ DESC LIMIT 10"
echo "   ^ if 'oldest' is only minutes old, any block older than that CANNOT be"
echo "     attributed -- Yiimp purges shares when the parent LTC round credits."

hr "4. ledger totals (schema-correct)"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) doge,
        FROM_UNIXTIME(MIN(created_at)) oldest, FROM_UNIXTIME(MAX(updated_at)) last_touch
     FROM doge_payout_ledger GROUP BY status ORDER BY doge DESC"
if [ -n "$PAIDCOL" ]; then
  MY "SELECT DATE(FROM_UNIXTIME($PAIDCOL)) d, COUNT(*) n, ROUND(SUM(amount),2) doge
       FROM doge_payout_ledger WHERE $PAIDCOL IS NOT NULL
         AND $PAIDCOL > UNIX_TIMESTAMP()-21*86400 GROUP BY d ORDER BY d DESC"
fi

hr "5. wallet vs obligations"
echo "   spendable : $($DCLI getbalance 2>&1 | head -1)"
$DCLI getwalletinfo 2>/dev/null | grep -E '"balance"|immature|unlocked_until|txcount' | sed 's/^/   /'
MYN "SELECT CONCAT('   owed (ledger not paid): ', ROUND(IFNULL(SUM(amount),0),2))
      FROM doge_payout_ledger WHERE status<>'paid'"
echo "   -> spendable minus owed = unallocated FLOAT from orphaned blocks."

hr "6. who is unpaid"
if [ -n "$ADDRCOL" ]; then
  MY "SELECT $ADDRCOL addr, COUNT(*) rows_, ROUND(SUM(amount),2) doge,
          FROM_UNIXTIME(MIN(created_at)) waiting_since
       FROM doge_payout_ledger WHERE status<>'paid'
       GROUP BY $ADDRCOL ORDER BY doge DESC LIMIT 15"
else
  echo "   no address column on the ledger -- payees live elsewhere; showing joinable ids:"
  MY "SELECT * FROM doge_payout_ledger WHERE status<>'paid' ORDER BY created_at DESC LIMIT 10"
fi
echo "-- yiimp account balances for DOGE (the other place money waits):"
MY "SELECT username, ROUND(balance,4) balance FROM accounts
     WHERE coinid=(SELECT id FROM coins WHERE symbol='DOGE') AND balance>0
     ORDER BY balance DESC LIMIT 15"

if [ -n "${ADDR:-}" ] && [ -n "$ADDRCOL" ]; then
  hr "7. trace for $ADDR"
  MY "SELECT * FROM doge_payout_ledger WHERE $ADDRCOL='$ADDR'
       ORDER BY created_at DESC LIMIT 30"
fi

echo
echo "read-only -- nothing was modified."
