#!/usr/bin/env bash
# payout-forensics.sh v2 -- READ ONLY.
#
#   Q1  payouts: LTC rows exist daily -- but do they land on YOUR address? why is DOGE dead since Aug 12?
#   Q2  coinbase: are the dedicated wallets actually receiving the block rewards?
#
#   curl -fsSL "https://pool.honest.money/install/payout-forensics.sh?v=$(date +%s)" | sudo bash 2>&1 | tee /tmp/payout-forensics.txt
#
# v2 fixes vs v1: no assumption that a `users` table exists (schema is introspected),
#                 DOGE ownership falls back to validateaddress (Dogecoin Core has no
#                 getaddressinfo), payout txids are decoded to real destination addresses,
#                 and the LTC coinbase-address drift is attributed.
#
# Nothing is modified. No coins move. No config is written.
set -uo pipefail
VERSION=v2
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
hr "S. schema introspection (v1 guessed wrong -- this is what actually exists)"
ACC_COLS=$(MYN "SELECT GROUP_CONCAT(column_name ORDER BY ordinal_position)
                FROM information_schema.columns
                WHERE table_schema='yiimpfrontend' AND table_name='accounts'")
echo "  accounts columns: ${ACC_COLS:-<no accounts table>}"
echo "  candidate tables: $(MYN "SELECT GROUP_CONCAT(table_name) FROM information_schema.tables
       WHERE table_schema='yiimpfrontend' AND (table_name LIKE '%account%' OR table_name LIKE '%user%' OR table_name LIKE '%payout%' OR table_name LIKE '%earning%')")"
# which column on accounts holds the miner's payout address?
ADDRCOL=""
for c in username address wallet payoutaddress; do
  case ",$ACC_COLS," in *",$c,"*) ADDRCOL=$c; break;; esac
done
echo "  -> miner-address column on accounts: ${ADDRCOL:-NOT FOUND}"

##############################################################################
hr "Q1a. who is owed what right now (top 15)"
if [ -n "$ADDRCOL" ]; then
  MY "SELECT c.symbol, LEFT(a.$ADDRCOL,40) miner, ROUND(a.balance,6) owed,
             ROUND(IFNULL(c.payout_min,0),6) payout_min,
             CASE WHEN a.balance >= IFNULL(c.payout_min,0) THEN 'DUE' ELSE 'below-min' END due
      FROM accounts a JOIN coins c ON c.id=a.coinid
      WHERE a.balance>0 ORDER BY a.balance DESC LIMIT 15"
  MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) total_owed,
             SUM(CASE WHEN a.balance>=IFNULL(c.payout_min,0) THEN 1 ELSE 0 END) due_now,
             SUM(CASE WHEN a.$ADDRCOL IS NULL OR a.$ADDRCOL='' THEN 1 ELSE 0 END) no_addr
      FROM accounts a JOIN coins c ON c.id=a.coinid WHERE a.balance>0 GROUP BY 1 ORDER BY 1"
else
  MY "SELECT * FROM accounts ORDER BY balance DESC LIMIT 10"
fi

##############################################################################
hr "Q1b. where did the LAST LTC payout batch actually SEND coins?"
LASTTX=$(MYN "SELECT p.tx FROM payouts p JOIN coins c ON c.id=p.idcoin
              WHERE c.symbol='LTC' AND p.completed=1 AND p.tx<>'' ORDER BY p.time DESC LIMIT 1")
echo "  newest completed LTC payout tx: ${LASTTX:-<none>}"
if [ -n "$LASTTX" ]; then
  $LCLI gettransaction "$LASTTX" 2>&1 | python3 -c '
import sys,json
try: t=json.load(sys.stdin)
except Exception as e: print("   could not decode:",sys.stdin.read()[:200]); sys.exit(0)
print(f"   time={t.get(\"time\")} fee={t.get(\"fee\")} confirmations={t.get(\"confirmations\")}")
for d in t.get("details",[])[:20]:
    print(f"   {d.get(\"category\"):8s} {str(d.get(\"amount\")):>14s}  {d.get(\"address\")}")
' 2>/dev/null | sed 's/^/ /'
fi
echo "  -- all distinct destinations paid in the last 30 days:"
if [ -n "$ADDRCOL" ]; then
  MY "SELECT c.symbol, LEFT(a.$ADDRCOL,40) dest, COUNT(*) n, ROUND(SUM(p.amount),6) sent,
             FROM_UNIXTIME(MAX(p.time)) newest
      FROM payouts p JOIN coins c ON c.id=p.idcoin
      LEFT JOIN accounts a ON a.id=p.account_id
      WHERE p.completed=1 AND p.time > UNIX_TIMESTAMP()-30*86400
      GROUP BY 1,2 ORDER BY sent DESC LIMIT 15" 2>&1 | grep -v 'Unknown column' || \
  MY "SELECT GROUP_CONCAT(column_name) cols FROM information_schema.columns
      WHERE table_schema='yiimpfrontend' AND table_name='payouts'"
fi
MY "SELECT GROUP_CONCAT(column_name ORDER BY ordinal_position) payouts_columns
    FROM information_schema.columns WHERE table_schema='yiimpfrontend' AND table_name='payouts'"

##############################################################################
hr "Q1c. DOGE: why has nothing been paid since 2026-08-12?"
DID=$(MYN "SELECT id FROM coins WHERE symbol='DOGE'")
echo "  DOGE coinid=$DID  payout_min=$(MYN "SELECT payout_min FROM coins WHERE symbol='DOGE'")"
MY "SELECT 'earnings' src, COUNT(*) rows_14d, ROUND(SUM(amount),4) amt,
           FROM_UNIXTIME(MAX(time)) newest
    FROM earnings WHERE coinid=$DID AND time > UNIX_TIMESTAMP()-14*86400"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),4) amt, FROM_UNIXTIME(MAX(time)) newest
    FROM earnings WHERE coinid=$DID GROUP BY status ORDER BY n DESC LIMIT 8"
if [ -n "$ADDRCOL" ]; then
  MY "SELECT LEFT(a.$ADDRCOL,40) miner, ROUND(a.balance,4) owed
      FROM accounts a WHERE a.coinid=$DID AND a.balance>0 ORDER BY a.balance DESC LIMIT 10"
fi
echo "  DOGE blocks credited recently:"
MY "SELECT FROM_UNIXTIME(b.time) t, b.height, b.category, ROUND(b.amount,4) amt, b.confirmations
    FROM blocks b WHERE b.coin_id=$DID ORDER BY b.time DESC LIMIT 8" 2>&1 | grep -v 'Unknown column' || \
MY "SELECT GROUP_CONCAT(column_name ORDER BY ordinal_position) blocks_columns
    FROM information_schema.columns WHERE table_schema='yiimpfrontend' AND table_name='blocks'"

##############################################################################
hr "Q2a. what yiimp thinks the coinbase addresses are"
MY "SELECT symbol, LEFT(master_wallet,44) master_wallet, payout_min, txfee, enable, auto_ready, installed
    FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU') ORDER BY symbol"

hr "Q2b. does the LOCAL WALLET own those addresses? (validateaddress fallback for DOGE)"
own() { # $1=cli $2=addr -> prints ismine/iswitness
  local out mine wit
  out=$($1 getaddressinfo "$2" 2>&1)
  case "$out" in *"Method not found"*|*"unknown command"*|*error*) out=$($1 validateaddress "$2" 2>&1);; esac
  mine=$(printf '%s' "$out" | grep -oE '"ismine": *(true|false)' | awk '{print $2}')
  wit=$(printf '%s'  "$out" | grep -oE '"iswitness": *(true|false)' | awk '{print $2}')
  echo "${mine:-?} ${wit:-?}"
}
for S in LTC DOGE; do
  MW=$(MYN "SELECT master_wallet FROM coins WHERE symbol='$S'")
  [ -z "$MW" ] && { echo "  $S : (no master_wallet set!)"; note "Q2 FAIL: $S has no master_wallet."; continue; }
  if [ "$S" = LTC ]; then CLI="$LCLI"; else CLI="$DCLI"; fi
  read -r MINE WIT <<<"$(own "$CLI" "$MW")"
  RCV=$($CLI getreceivedbyaddress "$MW" 0 2>&1 | tr -d '\n')
  printf '  %-4s %s\n       ismine=%s iswitness=%s received=%s\n' "$S" "$MW" "$MINE" "$WIT" "$RCV"
  [ "$MINE" = false ] && note "Q2 FAIL: $S master_wallet is NOT ismine -- yiimp cannot spend that reward."
  [ "$MINE" = "?" ]   && note "Q2 UNKNOWN: $S ownership probe inconclusive (see raw below)."
  [ "$S" = LTC ] && [ "$WIT" = true ] && note "Q2 FAIL: LTC coinbase is segwit -- breaks TXC/ISK/DOGE auxpow. Revert to legacy P2PKH."
done
echo "  -- raw DOGE probe:"
$DCLI validateaddress "$(MYN "SELECT master_wallet FROM coins WHERE symbol='DOGE'")" 2>&1 | head -14 | sed 's/^/    /'

hr "Q2c. LTC coinbase drift: which address is the CURRENT tip paying?"
$LCLI listtransactions "*" 500 0 2>/dev/null | python3 -c '
import sys,json
from collections import Counter
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
g=[x for x in t if x.get("category") in ("generate","immature")]
g.sort(key=lambda x:x.get("confirmations",0))
print("   newest 5 coinbases (lowest confirmations first):")
for x in g[:5]:
    print(f"     conf={x.get(\"confirmations\"):>6}  {str(x.get(\"amount\")):>12}  {x.get(\"address\")}")
print("   all coinbase destinations in window:")
for a,n in Counter(x.get("address","(none)") for x in g).most_common(8):
    newest=min((x.get("confirmations",10**9) for x in g if x.get("address")==a), default=-1)
    print(f"     {n:5d}  {a}   newest_conf={newest}")
' 2>/dev/null
echo "  -- is the OLD coinbase address still ismine (i.e. are those coins safe)?"
for A in $($LCLI listtransactions "*" 500 0 2>/dev/null | python3 -c '
import sys,json
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
print(" ".join({x["address"] for x in t if x.get("category") in ("generate","immature") and x.get("address")}))' 2>/dev/null); do
  read -r M W <<<"$(own "$LCLI" "$A")"
  printf '     %s  ismine=%s iswitness=%s balance_received=%s\n' "$A" "$M" "$W" "$($LCLI getreceivedbyaddress "$A" 0 2>&1 | tr -d '\n')"
done

hr "Q2d. DOGE coinbase destinations"
$DCLI listtransactions "*" 500 0 2>/dev/null | python3 -c '
import sys,json
from collections import Counter
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
g=[x for x in t if x.get("category") in ("generate","immature")]
g.sort(key=lambda x:x.get("confirmations",0))
for x in g[:5]:
    print(f"     conf={x.get(\"confirmations\"):>6}  {str(x.get(\"amount\")):>14}  {x.get(\"address\")}")
print("   counts:")
for a,n in Counter(x.get("address","(none)") for x in g).most_common(8): print(f"     {n:5d}  {a}")
' 2>/dev/null

##############################################################################
hr "Q1d. payout runner + config"
grep -aoE "define\( *'YAAMP_(PAYMENTS_FREQ|PAYMENT[A-Z_]*|ALLOW_[A-Z_]*)' *, *[^)]*\)" "$SERVERCONFIG" 2>/dev/null | sed 's/^/  /'
echo "  runner yiimp-loop2 = $(systemctl is-active yiimp-loop2 2>/dev/null || echo absent) since $(systemctl show yiimp-loop2 -p ActiveEnterTimestamp --value 2>/dev/null)"
MY "SELECT c.symbol, p.completed, COUNT(*) n, ROUND(SUM(p.amount),6) amount, FROM_UNIXTIME(MAX(p.time)) newest
    FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY 1,2 ORDER BY 1,2"

hr "Q1e. wallets able to sign?"
echo "  LTC : $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "  DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"

hr "VERDICT"
[ -z "$VERDICT" ] && echo "  no hard blocker detected -- read Q1a/Q1b/Q1c." || printf '%s' "$VERDICT"
echo
echo "read-only: nothing on this box was modified."
