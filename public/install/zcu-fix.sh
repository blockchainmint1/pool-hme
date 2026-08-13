#!/usr/bin/env bash
# zcu-fix.sh v1 -- READ ONLY inspection of the two ZCU blockers.
#
#   curl -fsSL https://pool.honest.money/install/zcu-fix.sh | sudo bash
#
# Blocker A: stratum asks the ZCU adapter for getblocktemplate (auxpow_rpc_mode=1)
#            but the adapter only implements getauxblock/createauxblock (mode 0).
#            Same class of bug we fixed for DOGE in db.cpp.
# Blocker B: zcu-mainnet-sync-blocks-to-yiimp.py exits ZCU_ROW_NOT_EXACTLY_ONE_OR_NOT_ENABLED
#            rows=0 even though coins.symbol='ZCU' exists with enable=1 -- so its
#            SELECT is looking somewhere/something else.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-fix v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  READ ONLY"

SRC_DIRS="/home/ubuntu/aws/LIVE/live-aux-issue-doge/stratum /home/ubuntu/yiimp-install-only-do-not-run-commands-from-this-folder/stratum /var/stratum/src"
SYNC=/opt/zcu-pool-tools/zcu-mainnet-sync-blocks-to-yiimp.py
ADAPTER=/opt/zcu-adapter/adapter.py
SERVERCONFIG=/var/web/serverconfig.php

hr "A1. where is the live stratum source tree?"
for d in $SRC_DIRS; do [ -d "$d" ] && { echo "   FOUND $d"; ls -la "$d"/*.cpp 2>/dev/null | head -20 | sed 's/^/      /'; }; done
SRC=""
for d in $SRC_DIRS; do [ -f "$d/db.cpp" ] && { SRC="$d"; break; }; done
echo "   using SRC=${SRC:-NONE}"

hr "A2. auxpow_rpc_mode / getauxblock / getblocktemplate decision sites"
if [ -n "$SRC" ]; then
  grep -rn -B4 -A10 'auxpow_rpc_mode' "$SRC" 2>/dev/null | head -120 | sed 's/^/   /'
  echo "-- getblocktemplate call sites in the aux path:"
  grep -rn 'getblocktemplate\|createauxblock\|getauxblock' "$SRC"/*.cpp "$SRC"/*.h 2>/dev/null | head -40 | sed 's/^/   /'
  echo "-- how coins rows are loaded (symbol -> flags):"
  grep -rn -A6 "symbol" "$SRC/db.cpp" 2>/dev/null | grep -n -i 'auxpow\|rpc_mode\|evm\|zcu' | head -30 | sed 's/^/   /'
else
  echo "   (no stratum source found -- tell me the path and I'll re-target)"
fi

hr "A3. does the coins table itself carry the mode? (all aux children side by side)"
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1; }
MYT "SELECT id,symbol,name,enable,auto_ready,rpcport,rpcencoding,txmessage,hasmasternodes,installed FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU')" | sed 's/^/   /'

hr "B1. the block-sync script -- its ZCU lookup"
if [ -f "$SYNC" ]; then
  wc -l "$SYNC" | sed 's/^/   /'
  grep -n -B6 -A10 'ZCU_ROW_NOT_EXACTLY_ONE_OR_NOT_ENABLED' "$SYNC" | sed 's/^/   /'
  echo "-- every SELECT / db connect in the script:"
  grep -nE "SELECT|connect\(|database=|db=|user=|host=" "$SYNC" | sed -E "s/(pass(wd|word)?[[:space:]]*=[[:space:]]*)[^,)]*/\1***MASKED***/I" | sed 's/^/   /'
else
  echo "   $SYNC missing"
fi

hr "B2. run that exact lookup by hand against both plausible DBs"
for db in yiimpfrontend yiimp; do
  echo "-- db=$db"
  mysql -u"${DBU:-}" -p"${DBP:-}" "$db" -t -e \
    "SELECT id,symbol,enable,auto_ready,installed FROM coins WHERE symbol='ZCU'" 2>&1 | sed 's/^/   /'
done

hr "C. adapter: the aux methods it already serves correctly"
[ -f "$ADAPTER" ] && sed -n '60,100p' "$ADAPTER" | sed 's/^/   /'

echo
echo "zcu-fix v1 done -- nothing was modified."
