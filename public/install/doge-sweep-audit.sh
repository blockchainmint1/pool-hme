#!/usr/bin/env bash
# doge-sweep-audit.sh v1
#
#   AUDIT  (default, READ ONLY) -- where is every DOGE in the box wallet sitting,
#                                  address by address, and how much is actually free?
#   SWEEP CONFIRM                -- send everything above miner liabilities + reserve
#                                  to your personal wallet.
#
#   curl -fsSL "https://pool.honest.money/install/doge-sweep-audit.sh?v=$(date +%s)" | sudo bash
#   curl -fsSL "https://pool.honest.money/install/doge-sweep-audit.sh?v=$(date +%s)" | sudo bash -s SWEEP CONFIRM
#
# Safety:
#   - AUDIT never touches the wallet.
#   - SWEEP validates the destination, refuses if the payout cycle holds a lock,
#     keeps every DOGE the pool still owes miners plus RESERVE behind,
#     and re-locks the wallet immediately after the send.
set -uo pipefail
VERSION=v1
MODE="${1:-AUDIT}"; CONFIRM="${2:-}"
DEST="${DEST:-DNW32nET5ZVmzTj9BR8yHB5ovHNSG4wLSj}"
RESERVE="${RESERVE:-25000}"          # working float left behind, DOGE
PASS_ENV=/etc/pool-wallets/passphrase.env
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
PAYOUT_LOCK=/var/web/runtime/doge-payout/doge-payout-cycle.lock
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>/dev/null | grep -v '\[Warning\]'; }
hr() { printf '\n===== %s\n' "$*"; }

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.dogecoin}/dogecoin.conf"; }
detect dogecoind; DCLI="$D_BIN/dogecoin-cli -conf=$D_CONF"

echo "doge-sweep-audit $VERSION  $(date -u '+%F %T UTC')  mode=$MODE"
echo "cli: $DCLI"

##############################################################################
hr "1. wallet totals"
$DCLI getwalletinfo 2>&1 | grep -E 'balance|unconfirmed|immature|txcount|unlocked_until' | sed 's/^/  /'
BAL=$($DCLI getbalance 2>/dev/null | tr -d '\r')
IMM=$($DCLI getwalletinfo 2>/dev/null | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')
BAL=${BAL:-0}; IMM=${IMM:-0}

hr "2. every address holding DOGE (spendable UTXOs, by address)"
$DCLI listunspent 0 9999999 2>/dev/null | python3 -c '
import sys,json
from collections import defaultdict
try: u=json.load(sys.stdin)
except Exception: print("   (could not read listunspent)"); sys.exit(0)
tot=defaultdict(float); n=defaultdict(int); minconf={}
for x in u:
    a=x.get("address","(none)"); tot[a]+=float(x.get("amount",0)); n[a]+=1
    minconf[a]=min(minconf.get(a,10**9), x.get("confirmations",0))
print(f"   {\"address\":36s} {\"DOGE\":>16s} {\"utxos\":>7s} {\"minconf\":>9s}")
for a,v in sorted(tot.items(), key=lambda kv:-kv[1]):
    print(f"   {a:36s} {v:16.4f} {n[a]:7d} {minconf[a]:9d}")
print(f"   {\"TOTAL SPENDABLE\":36s} {sum(tot.values()):16.4f} {sum(n.values()):7d}")
'

hr "3. immature coinbase still locked (matures at 60 confs)"
$DCLI listtransactions "*" 600 0 2>/dev/null | python3 -c '
import sys,json
from collections import defaultdict
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
imm=defaultdict(float); n=defaultdict(int)
for x in t:
    if x.get("category")=="immature":
        imm[x.get("address","(none)")]+=float(x.get("amount",0)); n[x.get("address","(none)")]+=1
if not imm: print("   (none)")
for a,v in sorted(imm.items(), key=lambda kv:-kv[1]):
    print(f"   {a:36s} {v:14.4f}  ({n[a]} blocks)")
print(f"   {\"TOTAL IMMATURE\":36s} {sum(imm.values()):14.4f}")
'

hr "4. what the pool still OWES miners in DOGE"
# This box credits DOGE through a CUSTOM ledger, not accounts.balance/coinid:
#   doge_payout_ledger (unpaid rows) + accounts.doge_balance + pending payouts rows.
# Every source is summed and the largest interpretation is kept behind.
DID=$(MYN "SELECT id FROM coins WHERE symbol='DOGE'"); DID=${DID:-9}
OWED_LEDGER=$(MYN "SELECT ROUND(IFNULL(SUM(amount),0),4) FROM doge_payout_ledger WHERE paid_at IS NULL")
OWED_DBAL=$(MYN  "SELECT ROUND(IFNULL(SUM(doge_balance),0),4) FROM accounts WHERE doge_balance>0")
OWED_ACC=$(MYN   "SELECT ROUND(IFNULL(SUM(balance),0),4) FROM accounts WHERE coinid=$DID AND balance>0")
OWED_PEND=$(MYN  "SELECT ROUND(IFNULL(SUM(amount),0),4) FROM payouts WHERE idcoin=$DID AND completed=0")
OWED_LEDGER=${OWED_LEDGER:-0}; OWED_DBAL=${OWED_DBAL:-0}; OWED_ACC=${OWED_ACC:-0}; OWED_PEND=${OWED_PEND:-0}
echo "  doge_payout_ledger unpaid   : $OWED_LEDGER"
echo "  accounts.doge_balance       : $OWED_DBAL"
echo "  accounts.balance (coinid=$DID) : $OWED_ACC"
echo "  payouts rows not completed  : $OWED_PEND"
OWED=$(awk -v l="$OWED_LEDGER" -v d="$OWED_DBAL" -v a="$OWED_ACC" -v p="$OWED_PEND" \
  'BEGIN{printf "%.4f", l+d+a+p}')
echo "  total liabilities (sum, deliberately conservative) : $OWED"
echo "  -- top owed miners (custom ledger view):"
mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "
  SELECT LEFT(username,26) miner, LEFT(IFNULL(doge_payout_address,'(none)'),36) doge_dest,
         ROUND(doge_balance,4) owed
  FROM accounts WHERE doge_balance>0 ORDER BY doge_balance DESC LIMIT 12" 2>&1 \
  | grep -v '\[Warning\]' | sed 's/^/  /'


hr "5. sweep math"
KEEP=$(awk -v o="$OWED" -v r="$RESERVE" 'BEGIN{printf "%.8f", o+r}')
SEND=$(awk -v b="$BAL" -v k="$KEEP" 'BEGIN{d=b-k; if(d<0)d=0; printf "%.8f", d}')
printf '  spendable        : %s\n  immature (later) : %s\n  liabilities      : %s\n  reserve          : %s\n  KEEP behind      : %s\n  SWEEPABLE NOW    : %s -> %s\n' \
  "$BAL" "$IMM" "$OWED" "$RESERVE" "$KEEP" "$SEND" "$DEST"

if [ "$MODE" != "SWEEP" ]; then
  hr "AUDIT ONLY -- nothing moved"
  echo "  to send:  curl -fsSL \"https://pool.honest.money/install/doge-sweep-audit.sh?v=\$(date +%s)\" | sudo bash -s SWEEP CONFIRM"
  exit 0
fi

##############################################################################
hr "6. SWEEP"
[ "$CONFIRM" = "CONFIRM" ] || { echo "  refusing: pass CONFIRM as the second argument."; exit 1; }
VALID=$($DCLI validateaddress "$DEST" 2>/dev/null | sed -n 's/.*"isvalid": *\([a-z]*\).*/\1/p')
[ "$VALID" = "true" ] || { echo "  FATAL: $DEST is not a valid Dogecoin address (isvalid=$VALID)"; exit 1; }
MINE=$($DCLI validateaddress "$DEST" 2>/dev/null | sed -n 's/.*"ismine": *\([a-z]*\).*/\1/p')
echo "  dest valid=true ismine=${MINE:-false} (ismine=false is expected for a personal cold wallet)"

if [ -f "$PAYOUT_LOCK" ]; then
  exec 9>"$PAYOUT_LOCK"
  flock -n 9 || { echo "  payout cycle is running -- try again in a few minutes"; exit 0; }
fi

if awk -v s="$SEND" 'BEGIN{exit !(s <= 0)}'; then
  echo "  nothing to sweep -- balance is at or below liabilities + reserve."
  exit 0
fi

# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"
if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  $DCLI walletpassphrase "$WALLET_PASSPHRASE" 300 >/dev/null 2>&1 || true
else
  echo "  WARNING: no passphrase at $PASS_ENV -- send will fail if the wallet is encrypted."
fi

TXID=$($DCLI sendtoaddress "$DEST" "$SEND" "pool float sweep" "" true 2>&1)
$DCLI walletlock >/dev/null 2>&1 || true
case "$TXID" in
  *error*|*Error*|"") echo "  SEND FAILED: $TXID"; exit 1;;
esac
echo "  SENT $SEND DOGE  txid=$TXID"
echo "  verify: https://dogechain.info/tx/$TXID"
echo "  remaining spendable: $($DCLI getbalance 2>/dev/null)"
echo "  re-run after the immature $IMM DOGE matures to collect the rest."
