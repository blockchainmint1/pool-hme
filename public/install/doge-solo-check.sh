#!/usr/bin/env bash
# doge-solo-check.sh -- READ ONLY. One question:
#   "Do DOGE wins that come WITHOUT an LTC win get lost?"
# run: curl -fsSL "https://pool.honest.money/install/doge-solo-check.sh?v=$(date +%s)" | sudo bash
# Makes NO changes anywhere.
# v1 2026-10-06 initial
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
DAYS=7
DOGECLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -datadir=/home/ubuntu/.dogecoin"
TXCCLI="/home/ubuntu/Fork-Upgrade/binaries/txc/texitcoin-cli"
DB=yiimpfrontend
MY()  { mysql "$DB" -N -B -e "$1" 2>/dev/null; }
MYT() { mysql "$DB" -t -e "$1" 2>&1; }
hr()  { printf '\n===== %s\n' "$*"; }
echo "doge-solo-check v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  window=${DAYS}d"

hr "1. pool records: every DOGE block, paired with an LTC block (+/-10s) or ALONE"
MYT "SELECT FROM_UNIXTIME(d.time) doge_time, d.height doge_height, d.category,
     IF(EXISTS(SELECT 1 FROM blocks l JOIN coins lc ON lc.id=l.coin_id
        WHERE lc.symbol='LTC' AND ABS(l.time-d.time)<=10),'with LTC','ALONE') kind
     FROM blocks d JOIN coins c ON c.id=d.coin_id
     WHERE c.symbol='DOGE' AND d.time > UNIX_TIMESTAMP()-${DAYS}*86400
     ORDER BY d.time" | sed 's/^/  /'
MYT "SELECT c.symbol, COUNT(*) finds_${DAYS}d FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE','TXC','ISK') AND b.time > UNIX_TIMESTAMP()-${DAYS}*86400
     GROUP BY 1" | sed 's/^/  /'

hr "2. expected DOGE finds (from TXC finds x difficulty ratio, current difficulties)"
TXCN=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='TXC' AND b.time > UNIX_TIMESTAMP()-${DAYS}*86400")
TXD=$(sudo -u ubuntu $TXCCLI getdifficulty 2>/dev/null)
DD=$($DOGECLI getdifficulty 2>/dev/null)
python3 - "$TXCN" "$TXD" "$DD" "$DAYS" <<'PY'
import sys
try:
    n,t,d,days=int(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]),int(sys.argv[4])
    e=n*t/d
    print(f"  TXC finds={n}  TXC diff={t:,.0f}  DOGE diff={d:,.0f}")
    print(f"  expected DOGE finds in {days}d ~ {e:.1f}  (~{e/days:.1f}/day)")
except Exception as x: print("  could not compute:",x)
PY

hr "3. dogecoind's own wallet: mined rewards it knows about (catches blocks the pool DB missed)"
$DOGECLI listtransactions "*" 5000 2>/dev/null | python3 -c '
import sys,json,time
try: tx=json.load(sys.stdin)
except Exception as e: print("  wallet read failed:",e); sys.exit()
cut=time.time()-'"$DAYS"'*86400
g=[t for t in tx if t.get("category") in ("generate","immature","orphan") and t.get("time",0)>cut]
from collections import Counter
print("  mined-reward entries in window:",len(g),dict(Counter(t["category"] for t in g)))
for t in sorted(g,key=lambda t:t["time"])[-20:]:
    print("   ",time.strftime("%m-%d %H:%M:%S",time.gmtime(t["time"])),t["category"],round(t.get("amount",0),2),"conf",t.get("confirmations"))
'

hr "4. what DOGE submit lines actually look like in the logs (numbers stripped)"
LOGS=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum-2*.log 2>/dev/null | head -60)
for SYM in DOGE TXC; do
  echo "  --- $SYM (TXC is the control) ---"
  for F in $LOGS; do grep -a "$SYM" "$F" 2>/dev/null | grep -av 'skip target'; done \
    | sed -E 's/^[0-9: -]+//; s/[0-9a-f]{16,}/<hex>/g; s/[0-9]+(\.[0-9]+)?/N/g' \
    | sort | uniq -c | sort -rn | head -12 | cut -c1-200 | sed 's/^/    /'
done
echo "  --- last 10 raw DOGE lines that are NOT 'skip target' ---"
for F in $LOGS; do grep -a 'DOGE' "$F" 2>/dev/null | grep -av 'skip target'; done | tail -10 | cut -c1-220 | sed 's/^/    /'

hr "done -- paste everything to the assistant"
