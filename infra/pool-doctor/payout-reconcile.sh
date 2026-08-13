#!/usr/bin/env bash
# payout-reconcile.sh v3 -- READ ONLY, schema-correct for THIS box.
#
#   curl -fsSL https://pool.honest.money/install/payout-reconcile.sh | sudo bash 2>&1 | tee /tmp/reconcile.txt
#   ADDR=D...  curl -fsSL ... | sudo -E bash     # trace one DOGE payout address
#
# v2 fixes from the 13 Aug run:
#   * workers has no `hashrate` column on this build -> detect the real one
#   * doge_payout_ledger uses `doge_address`, not `address`; `tx`, not `txid`
#   * NEW section 10: WHY no earnings rows exist (the actual leak). Yiimp credits
#     miners in loop2/blocknotify when a block matures. earnings is nearly empty
#     while blocks are full -> the crediting daemon is the failure point, and
#     doge_payout_ledger keys off earning_id so DOGE capture starves with it.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
FOCUS="${ADDR:-}"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
col() { # col <table> <candidate...> -> echoes first existing column
  local t=$1; shift
  local all; all=$(MYN "SELECT GROUP_CONCAT(column_name) FROM information_schema.columns
                        WHERE table_schema='yiimpfrontend' AND table_name='$t'")
  local c; for c in "$@"; do echo ",$all," | grep -qi ",$c," && { echo "$c"; return; }; done
  echo ""
}

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

echo "payout-reconcile v3 $(date -u '+%F %T UTC')  focus=${FOCUS:-none}"

hr "0. schema recon"
for T in shares blocks earnings accounts payouts workers doge_payout_ledger; do
  printf '  %-20s %s\n' "$T:" "$(MYN "SELECT IFNULL(GROUP_CONCAT(column_name ORDER BY ordinal_position),'** MISSING **')
      FROM information_schema.columns WHERE table_schema='yiimpfrontend' AND table_name='$T'")"
done
WHR=$(col workers hashrate speed difficulty)
LADDR=$(col doge_payout_ledger doge_address address addr)
LTX=$(col doge_payout_ledger tx txid tx_hash)
echo "  resolved: workers.<rate>=${WHR:-none}  ledger.<addr>=${LADDR:-none}  ledger.<tx>=${LTX:-none}"

hr "1. WHO IS MINING -- live worker attribution"
if [ -n "$WHR" ]; then
  MY "SELECT a.username, COUNT(DISTINCT w.id) workers, ROUND(SUM(w.$WHR),3) rate_units,
          ROUND(100*SUM(w.$WHR)/(SELECT SUM($WHR) FROM workers),2) pct_of_pool
       FROM workers w JOIN accounts a ON a.id=w.userid
       GROUP BY a.username ORDER BY rate_units DESC LIMIT 15"
else
  MY "SELECT a.username, COUNT(*) workers FROM workers w JOIN accounts a ON a.id=w.userid
       GROUP BY a.username ORDER BY workers DESC LIMIT 15"
fi

hr "2. SHARE ALLOCATION -- share rows by account, last 60 min"
MY "SELECT a.username, COUNT(*) share_rows, ROUND(SUM(s.difficulty),2) sum_diff,
        ROUND(100*SUM(s.difficulty)/(SELECT SUM(difficulty) FROM shares
              WHERE time>UNIX_TIMESTAMP()-3600),2) pct_of_shares,
        SUM(s.valid=0) invalid
     FROM shares s LEFT JOIN accounts a ON a.id=s.userid
     WHERE s.time > UNIX_TIMESTAMP()-3600
     GROUP BY a.username ORDER BY sum_diff DESC LIMIT 15"
echo "  ^ NULL username = shares credited to nobody."

hr "3. MINED -- LTC/DOGE blocks, 14d, by day"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(b.time)) d, COUNT(*) blocks,
        ROUND(SUM(b.amount),4) mined, GROUP_CONCAT(DISTINCT b.category) categories
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time>UNIX_TIMESTAMP()-14*86400
     GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"

hr "4. CREDITED -- earnings rows (the yiimp crediting path)"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(e.create_time)) d, COUNT(*) rows_,
        ROUND(SUM(e.amount),4) credited, SUM(e.status=0) unconfirmed
     FROM earnings e JOIN coins c ON c.id=e.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND e.create_time>UNIX_TIMESTAMP()-14*86400
     GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"
MY "SELECT c.symbol,
        ROUND((SELECT SUM(b.amount) FROM blocks b WHERE b.coin_id=c.id
               AND b.time>UNIX_TIMESTAMP()-14*86400),2) mined_14d,
        ROUND(IFNULL((SELECT SUM(e.amount) FROM earnings e WHERE e.coinid=c.id
               AND e.create_time>UNIX_TIMESTAMP()-14*86400),0),2) credited_14d,
        ROUND((SELECT IFNULL(SUM(l.amount),0) FROM doge_payout_ledger l
               WHERE c.symbol='DOGE' AND l.created_at>UNIX_TIMESTAMP()-14*86400),2) ledgered_14d
     FROM coins c WHERE c.symbol IN ('LTC','DOGE')"

hr "5. BLOCKS WITH NO CREDIT (most recent 40)"
MY "SELECT c.symbol, b.height, FROM_UNIXTIME(b.time) found, ROUND(b.amount,2) reward,
        b.category, b.confirmations, IFNULL(e.n,0) earning_rows
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT blockid, COUNT(*) n FROM earnings GROUP BY blockid) e ON e.blockid=b.id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time>UNIX_TIMESTAMP()-14*86400
       AND IFNULL(e.n,0)=0
     ORDER BY b.time DESC LIMIT 40"

hr "6. PAID -- payout rows by day + DOGE ledger by day/status"
MY "SELECT c.symbol, DATE(FROM_UNIXTIME(p.time)) d, COUNT(*) n, SUM(p.completed=1) done,
        ROUND(SUM(p.amount),4) amount
     FROM payouts p JOIN coins c ON c.id=p.idcoin
     WHERE p.time>UNIX_TIMESTAMP()-21*86400 GROUP BY c.symbol, d ORDER BY c.symbol, d DESC"
MY "SELECT DATE(FROM_UNIXTIME(created_at)) d, status, COUNT(*) n, ROUND(SUM(amount),2) doge
     FROM doge_payout_ledger WHERE created_at>UNIX_TIMESTAMP()-21*86400
     GROUP BY d, status ORDER BY d DESC, doge DESC"

hr "7. STILL OWED right now"
MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) unpaid_balance
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE') GROUP BY c.symbol"
MY "SELECT c.symbol, a.username, ROUND(a.balance,6) balance, ROUND(c.payout_min,6) payout_min,
        IF(a.balance>=c.payout_min,'ELIGIBLE','below threshold') state
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE')
     ORDER BY a.balance DESC LIMIT 20"

hr "8. WALLET REALITY"
for D in litecoind dogecoind; do
  detect "$D"; CLI="$D_BIN/${D%d}-cli -conf=$D_CONF"
  echo "-- $D ($CLI)"
  $CLI getwalletinfo 2>&1 | grep -E '"balance"|immature|unlocked_until|txcount' | sed 's/^/     /'
  echo "     last 8 SENDS only:"
  $CLI listtransactions "*" 100 0 2>/dev/null \
    | grep -E '"category": "send"' -A0 >/dev/null 2>&1
  $CLI listtransactions "*" 100 0 2>/dev/null | python3 - <<'PY' 2>/dev/null | sed 's/^/       /'
import sys,json,datetime
try: t=json.load(sys.stdin)
except Exception: t=[]
s=[x for x in t if x.get("category")=="send"][-8:]
for x in s:
    print(datetime.datetime.utcfromtimestamp(x.get("time",0)).strftime("%F %T"),
          round(x.get("amount",0),4), x.get("address","")[:36], x.get("txid","")[:20])
if not s: print("** NO SEND TRANSACTIONS in last 100 wallet tx **")
PY
done

hr "9. WHY NO EARNINGS -- the crediting daemon (this is the leak)"
echo "-- yiimp loop/blocknotify services:"
systemctl list-units --type=service --all 2>/dev/null \
  | grep -Ei 'yiimp|loop|blocknotify|stratum' | sed 's/^/   /'
for U in yiimp-loop2 loop2 yiimp-loop1 loop1 yiimp-blocknotify; do
  systemctl is-active "$U" >/dev/null 2>&1 && {
    echo "   -- $U: $(systemctl is-active $U), since $(systemctl show -p ActiveEnterTimestamp --value $U)"
    journalctl -u "$U" -n 15 --no-pager 2>/dev/null | sed 's/^/      /'; }
done
echo "-- cron entries touching yiimp loops:"
grep -rhE 'loop|yiimp|blocknotify' /etc/cron.d/* /var/spool/cron/crontabs/* 2>/dev/null \
  | grep -v '^\s*#' | sed 's/^/   /'
echo "-- newest earnings row per coin (when did crediting die?):"
MY "SELECT c.symbol, COUNT(*) rows_, FROM_UNIXTIME(MAX(e.create_time)) newest,
        FROM_UNIXTIME(MIN(e.create_time)) oldest
     FROM earnings e JOIN coins c ON c.id=e.coinid GROUP BY c.symbol ORDER BY newest DESC"
echo "-- MATURE blocks (conf>=240 DOGE / >=100 LTC) still uncredited = money owed to miners:"
MY "SELECT c.symbol, COUNT(*) mature_uncredited, ROUND(SUM(b.amount),2) owed
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN (SELECT blockid, COUNT(*) n FROM earnings GROUP BY blockid) e ON e.blockid=b.id
     WHERE c.symbol IN ('LTC','DOGE') AND b.category='generate' AND IFNULL(e.n,0)=0
     GROUP BY c.symbol"
echo "-- coin config that gates crediting:"
MY "SELECT symbol, enable, auto_ready, installed, ROUND(payout_min,6) payout_min,
        ROUND(txfee,6) txfee, IFNULL(LEFT(errors,40),'') errors
     FROM coins WHERE symbol IN ('LTC','DOGE')"
echo "-- share retention (a block older than 'oldest' can never be attributed):"
MY "SELECT c.symbol, COUNT(*) rows_, FROM_UNIXTIME(MIN(s.time)) oldest,
        FROM_UNIXTIME(MAX(s.time)) newest
     FROM shares s LEFT JOIN coins c ON c.id=s.coinid GROUP BY c.symbol ORDER BY rows_ DESC LIMIT 8"

if [ -n "$FOCUS" ]; then
  hr "10. TRACE $FOCUS"
  MY "SELECT id, username, coinid, ROUND(balance,6) balance, doge_payout_address
       FROM accounts WHERE username LIKE '%$FOCUS%' OR doge_payout_address='$FOCUS'"
  MY "SELECT p.id, c.symbol, p.amount, p.completed, LEFT(IFNULL(p.tx,''),24) tx,
          LEFT(IFNULL(p.errmsg,''),40) errmsg, FROM_UNIXTIME(p.time) t
       FROM payouts p JOIN coins c ON c.id=p.idcoin
       JOIN accounts a ON a.id=p.account_id
       WHERE a.username LIKE '%$FOCUS%' OR a.doge_payout_address='$FOCUS'
       ORDER BY p.id DESC LIMIT 20"
  if [ -n "$LADDR" ]; then
    TXSEL="''"; [ -n "$LTX" ] && TXSEL="LEFT(IFNULL($LTX,''),24)"
    MY "SELECT id, $LADDR addr, ROUND(amount,2) amount, status,
            $TXSEL tx, LEFT(IFNULL(error,''),40) error,
            FROM_UNIXTIME(created_at) created, FROM_UNIXTIME(paid_at) paid
         FROM doge_payout_ledger WHERE $LADDR='$FOCUS'
         ORDER BY created_at DESC LIMIT 25"
    MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) doge
         FROM doge_payout_ledger WHERE $LADDR='$FOCUS' GROUP BY status"
  fi
fi

echo
echo "read-only -- nothing was modified."
