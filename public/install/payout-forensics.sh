#!/usr/bin/env bash
# payout-forensics.sh v1 -- READ ONLY. Two questions, one page:
#
#   Q1  why is nothing being PAID OUT to miners?
#   Q2  are the dedicated coinbase wallets actually receiving block rewards?
#
#   curl -fsSL "https://pool.honest.money/install/payout-forensics.sh?v=$(date +%s)" | sudo bash 2>&1 | tee /tmp/payout-forensics.txt
#
# Nothing is modified. No coins move. No config is written.
set -uo pipefail
VERSION=v1
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEB=$(dirname "$SERVERCONFIG")

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
VERDICT=""; note() { VERDICT="${VERDICT}$1"$'\n'; }

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

echo "payout-forensics $VERSION  $(date -u '+%F %T UTC')  host=$(hostname)  db_user=${DBU:-UNRESOLVED}"
[ -z "${DBU:-}" ] && { echo "FATAL: could not read YAAMP_DBUSER from $SERVERCONFIG"; exit 1; }

detect litecoind; LCONF=$D_CONF; LBIN=$D_BIN
LCLI="$LBIN/litecoin-cli -conf=$LCONF -rpcwallet=pool"
detect dogecoind; DCLI="$D_BIN/dogecoin-cli -conf=$D_CONF"

##############################################################################
hr "Q2a. what yiimp thinks the coinbase addresses are"
MY "SELECT symbol, LEFT(master_wallet,42) master_wallet, payout_min, txfee, enable, auto_ready, installed
    FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU') ORDER BY symbol"

hr "Q2b. does the LOCAL WALLET actually own those addresses?"
for S in LTC DOGE; do
  MW=$(MYN "SELECT master_wallet FROM coins WHERE symbol='$S'")
  if [ -z "$MW" ]; then echo "  $S : (no master_wallet set!)"; note "Q2 FAIL: $S has no master_wallet -- rewards go nowhere yiimp tracks."; continue; fi
  if [ "$S" = LTC ]; then AI=$($LCLI getaddressinfo "$MW" 2>&1); RCV=$($LCLI getreceivedbyaddress "$MW" 0 2>&1)
  else AI=$($DCLI getaddressinfo "$MW" 2>&1); RCV=$($DCLI getreceivedbyaddress "$MW" 0 2>&1); fi
  MINE=$(printf '%s' "$AI" | grep -oE '"ismine": *(true|false)' | awk '{print $2}')
  WIT=$(printf '%s'  "$AI" | grep -oE '"iswitness": *(true|false)' | awk '{print $2}')
  LBL=$(printf '%s'  "$AI" | grep -oE '"labels": *\[[^]]*\]' | tr -d '\n ' | head -c 60)
  printf '  %-4s %s\n       ismine=%s iswitness=%s received=%s %s\n' "$S" "$MW" "${MINE:-?}" "${WIT:-?}" "${RCV:-?}" "${LBL:-}"
  [ "${MINE:-false}" != true ] && note "Q2 FAIL: $S master_wallet is NOT ismine on this box -- yiimp cannot see or spend the reward."
  [ "$S" = LTC ] && [ "${WIT:-}" = true ] && note "Q2 FAIL: LTC coinbase is segwit -- this breaks TXC/ISK/DOGE auxpow. Revert to legacy P2PKH."
done

hr "Q2c. where did the LAST 10 LTC coinbases actually pay?"
$LCLI listtransactions "*" 400 0 2>/dev/null \
  | tr -d ' "' | grep -E '^(address|category|amount|confirmations|generated):' \
  | paste -d'|' - - - - - 2>/dev/null | grep -i generate | tail -10 | sed 's/^/  /'
echo "  -- addresses seen on generate txs (count):"
$LCLI listtransactions "*" 400 0 2>/dev/null | python3 -c '
import sys,json
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
from collections import Counter
c=Counter(x.get("address","(none)") for x in t if x.get("category") in ("generate","immature"))
for a,n in c.most_common(6): print(f"     {n:5d}  {a}")
' 2>/dev/null

hr "Q2d. same for DOGE"
$DCLI listtransactions "*" 400 0 2>/dev/null | python3 -c '
import sys,json
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
from collections import Counter
c=Counter(x.get("address","(none)") for x in t if x.get("category") in ("generate","immature"))
for a,n in c.most_common(6): print(f"     {n:5d}  {a}")
' 2>/dev/null

##############################################################################
hr "Q1a. who is owed what (top 12)"
MY "SELECT c.symbol, LEFT(u.username,24) miner, ROUND(a.balance,6) owed, c.payout_min,
           CASE WHEN a.balance >= c.payout_min THEN 'DUE' ELSE 'below-min' END due
    FROM accounts a JOIN coins c ON c.id=a.coinid LEFT JOIN users u ON u.id=a.userid
    WHERE a.balance>0 ORDER BY a.balance DESC LIMIT 12"

hr "Q1b. does each owed account have a payout ADDRESS yiimp will send to?"
MY "SELECT c.symbol, COUNT(*) accts,
           SUM(CASE WHEN a.coinid IS NULL OR u.coinid IS NULL THEN 1 ELSE 0 END) no_coin,
           SUM(CASE WHEN u.username IS NULL OR u.username='' THEN 1 ELSE 0 END) no_addr
    FROM accounts a JOIN coins c ON c.id=a.coinid LEFT JOIN users u ON u.id=a.userid
    WHERE a.balance>0 GROUP BY c.symbol"

hr "Q1c. payout config the runner reads"
grep -aoE "define\( *'YAAMP_(PAYMENTS_FREQ|PAYMENT[A-Z_]*|ALLOW_[A-Z_]*)' *, *[^)]*\)" "$SERVERCONFIG" 2>/dev/null | sed 's/^/  /'
echo "  runner unit : yiimp-loop2 = $(systemctl is-active yiimp-loop2 2>/dev/null || echo absent) (uptime $(systemctl show yiimp-loop2 -p ActiveEnterTimestamp --value 2>/dev/null))"
pgrep -af 'loop2|runPayouts' | sed 's/^/  proc: /' || note "Q1 FAIL: no payment runner process at all."

hr "Q1d. payouts table -- has money EVER left, and what failed?"
MY "SELECT c.symbol, p.completed, COUNT(*) n, ROUND(SUM(p.amount),6) amount, FROM_UNIXTIME(MAX(p.time)) newest
    FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY 1,2 ORDER BY 1,2"
MY "SELECT c.symbol, FROM_UNIXTIME(p.time) t, ROUND(p.amount,6) amt, p.completed,
           LEFT(IFNULL(p.tx,'(no tx)'),26) tx, LEFT(IFNULL(p.errmsg,''),40) err
    FROM payouts p JOIN coins c ON c.id=p.idcoin ORDER BY p.time DESC LIMIT 12"
LASTP=$(MYN "SELECT IFNULL(ROUND((UNIX_TIMESTAMP()-MAX(time))/3600,1),-1) FROM payouts")
echo "  hours since newest payout row: $LASTP"
awk -v h="$LASTP" 'BEGIN{ if (h<0 || h>24) exit 1 }' || note "Q1 FAIL: no payout row written in ${LASTP}h -- the runner is not even attempting sends."

hr "Q1e. can the wallets sign right now?"
echo "  LTC : $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "  DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "  LTC loaded wallets: $($LBIN/litecoin-cli -conf=$LCONF listwallets 2>&1 | tr -d '\n ')"
echo "  LTC root-RPC (must NOT be -19):"
RPCU=$(sed -n 's/^rpcuser=//p' "$LCONF" | head -1); RPCP=$(sed -n 's/^rpcpassword=//p' "$LCONF" | head -1)
RPCPORT=$(sed -n 's/^rpcport=//p' "$LCONF" | head -1); RPCPORT=${RPCPORT:-9332}
curl -s --user "$RPCU:$RPCP" -H 'content-type:text/plain' \
  --data '{"jsonrpc":"1.0","id":"f","method":"getbalance","params":[]}' \
  "http://127.0.0.1:$RPCPORT/" | head -c 200 | sed 's/^/    /'; echo
curl -s --user "$RPCU:$RPCP" -H 'content-type:text/plain' \
  --data '{"jsonrpc":"1.0","id":"f","method":"getbalance","params":[]}' \
  "http://127.0.0.1:$RPCPORT/" | grep -q '"code":-19' && \
  note "Q1 FAIL: LTC root RPC still returns -19 -- yiimp cannot send LTC. Re-run ltc-rpc-probe.sh FIX."

hr "Q1f. what the runner has actually been saying"
journalctl -u yiimp-loop2 --since '2 hours ago' --no-pager 2>/dev/null | tail -25 | sed 's/^/  /'
echo "  -- errors in last 24h:"
journalctl -u yiimp-loop2 --since '24 hours ago' --no-pager 2>/dev/null \
  | grep -aiE 'error|fail|insufficient|passphrase|not specified|-19|denied' | tail -15 | sed 's/^/  /' || echo "  (none)"

hr "Q1g. is the payout code path even reachable?"
for f in "$WEB/yaamp/core/backend/payment.php" "$WEB/yaamp/core/backend/loop2.php"; do
  [ -f "$f" ] && echo "  $f  mtime=$(date -u -d @"$(stat -c%Y "$f")" '+%F %H:%M')  $(grep -c 'sendmany\|sendtoaddress' "$f") send-calls"
done
MY "SELECT symbol, enable, auto_ready, payout_min, txfee, hasmasternodes, dedicated_notify
    FROM coins WHERE symbol IN ('LTC','DOGE')" 2>/dev/null | sed 's/^/  /'

hr "VERDICT"
[ -z "$VERDICT" ] && echo "  no hard blocker detected -- read Q1d/Q1f for the runner's own words." || printf '%s' "$VERDICT"
echo
echo "read-only: nothing on this box was modified."
