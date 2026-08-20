#!/usr/bin/env bash
# ltc-rpc-probe v3  (v3: payment runner is `yiimp-loop2` on this box, not `loop2` -- autodetect the unit name)
#
# The trace told us three hard facts:
#   * litecoind's `pool` wallet HAS the coinbases ("category":"generate", 6.26 LTC each)
#   * yiimp's blocks table says those same blocks are category=orphan, amount=0, confirmations=NULL
#   * two wallets are loaded: pool + rental
#
# When >1 wallet is loaded, the bare RPC root endpoint ("/") REJECTS every wallet
# method (gettransaction / getbalance / sendtoaddress) with:
#     "Wallet file not specified (must request wallet RPC through /wallet/<id> uri-path)"
# yiimp calls the root endpoint. That single fact explains ALL of:
#     - LTC blocks stuck orphan/amount 0  (confirm pass can't gettransaction)
#     - zero LTC earnings rows            (no amount -> nothing to split)
#     - 9.6 days with no payouts          (loop2 can't sendtoaddress)
#
# MODES
#   PROBE  (default) read-only: replays yiimp's exact HTTP call on / and /wallet/pool
#   FIX               unloads the `rental` wallet (reversible: loadwallet rental)
#                     then restarts loop2 so the payment pass runs with a clean root
#
#   curl -fsSL "https://pool.honest.money/install/ltc-rpc-probe.sh?v=$(date +%s)" | sudo bash
#   curl -fsSL "https://pool.honest.money/install/ltc-rpc-probe.sh?v=$(date +%s)" | sudo bash -s FIX
set -uo pipefail

MODE=${1:-PROBE}
LCLI_BIN=${LCLI_BIN:-/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli}
LCONF=${LCONF:-/home/ubuntu/.litecoin/litecoin.conf}
LCLI="$LCLI_BIN -conf=$LCONF"
WEB=/var/web

MYN() { mysql yiimpfrontend -N -B -e "$1" 2>&1; }
MY()  { mysql yiimpfrontend -t  -e "$1" 2>&1; }

echo "ltc-rpc-probe v3  mode=$MODE  $(date -u '+%F %T') UTC"
echo

# ---------------------------------------------------------------- 1. creds
RUSER=$(grep -E '^rpcuser=' "$LCONF" | head -1 | cut -d= -f2-)
RPASS=$(grep -E '^rpcpassword=' "$LCONF" | head -1 | cut -d= -f2-)
RPORT=$(grep -E '^rpcport=' "$LCONF" | head -1 | cut -d= -f2-); RPORT=${RPORT:-9332}
echo "===== 1. litecoind RPC endpoint  127.0.0.1:$RPORT   (creds from $LCONF)"
echo "  wallets loaded: $($LCLI listwallets 2>&1 | tr -d '\n ')"
echo

call() { # $1 = url path, $2 = json
  curl -s --max-time 12 -u "$RUSER:$RPASS" -H 'content-type: text/plain;' \
       --data-binary "$2" "http://127.0.0.1:$RPORT$1"
}

# a real coinbase txid the pool wallet owns
TXID=$($LCLI -rpcwallet=pool listtransactions "*" 40 0 2>/dev/null \
        | grep -B4 '"generate"' | grep '"txid"' | tail -1 | cut -d'"' -f4)
echo "===== 2. replay yiimp's wallet RPC (txid=${TXID:-none})"
if [ -n "$TXID" ]; then
  echo "  -- POST /            (what yiimp does today) --"
  call "/"            "{\"method\":\"gettransaction\",\"params\":[\"$TXID\"],\"id\":1}" | head -c 400; echo
  echo "  -- POST /wallet/pool (what it should do) --"
  call "/wallet/pool"  "{\"method\":\"gettransaction\",\"params\":[\"$TXID\"],\"id\":1}" | head -c 400; echo
fi
echo "  -- POST / getbalance --"
call "/" '{"method":"getbalance","params":[],"id":1}' | head -c 300; echo
echo

# ---------------------------------------------------------------- 3. yiimp coin rpc row
echo "===== 3. how yiimp is configured to reach litecoind"
MY "SELECT id,symbol,rpchost,rpcport,rpcencoding,enable FROM coins WHERE symbol IN ('LTC','DOGE');"
echo "  -- does the yiimp rpc client support a URL path at all? --"
grep -rn "curl_setopt.*CURLOPT_URL\|http://\".\$this->host\|\$this->host" "$WEB/yaamp/core/backend/rpc"*.php "$WEB/yaamp/modules/thread/"*.php 2>/dev/null | head -8 | sed 's/^/  /'
grep -rn "class .*jsonRPCClient\|function __construct" "$WEB"/yaamp/core/*/*rpc*.php 2>/dev/null | head -5 | sed 's/^/  /'
echo

# ---------------------------------------------------------------- 4. loop2
echo "===== 4. loop2 (the payment runner)"
systemctl show -p ActiveEnterTimestamp -p SubState loop2 2>/dev/null | sed 's/^/  /'
UP=$(systemctl show -p ActiveEnterTimestampMonotonic --value loop2 2>/dev/null)
echo "  now: $(date -u '+%F %T') UTC   freq: $(grep YAAMP_PAYMENTS_FREQ $WEB/serverconfig.php | tr -d '\t')"
journalctl -u loop2 --since '24 hours ago' 2>/dev/null | grep -iE 'payment|payout|sendtoaddress|wallet' | tail -15 | sed 's/^/  /'
echo

# ---------------------------------------------------------------- 5. who is owed (correct columns)
echo "===== 5. balances owed (accounts schema-safe)"
MY "SELECT a.id, c.symbol, LEFT(a.username,26) addr, a.balance,
           FROM_UNIXTIME(a.last_earning) last_earning
      FROM accounts a LEFT JOIN coins c ON c.id=a.coinid
     WHERE a.balance > 0 ORDER BY a.balance DESC LIMIT 15;"
echo

if [ "$MODE" != "FIX" ]; then
  echo "PROBE only -- nothing was modified."
  echo "If section 2 shows '/' erroring with 'Wallet file not specified' while"
  echo "/wallet/pool returns the tx, re-run with:  ... | sudo bash -s FIX"
  exit 0
fi

# ---------------------------------------------------------------- FIX
echo "===== FIX"
RBAL=$($LCLI -rpcwallet=rental getbalance 2>/dev/null)
echo "  rental wallet balance before unload: ${RBAL:-?}"
if [ -n "$RBAL" ] && awk "BEGIN{exit !($RBAL > 0.001)}"; then
  echo "  !! rental wallet holds funds -- unloading is still safe (funds stay on disk),"
  echo "     but nothing can spend from it until 'litecoin-cli loadwallet rental'."
fi
echo "  unloading rental so the RPC root resolves to 'pool' alone..."
$LCLI unloadwallet rental 2>&1 | sed 's/^/    /'
echo "  wallets now: $($LCLI listwallets 2>&1 | tr -d '\n ')"
echo "  -- re-test POST / getbalance (must NOT say 'Wallet file not specified') --"
call "/" '{"method":"getbalance","params":[],"id":1}' | head -c 300; echo
if [ -n "$TXID" ]; then
  echo "  -- re-test POST / gettransaction --"
  call "/" "{\"method\":\"gettransaction\",\"params\":[\"$TXID\"],\"id\":1}" | head -c 300; echo
fi

# loop2 was DEAD (not merely stale) on 20 Aug -- restart alone is not enough if
# the unit is disabled or has latched a failed state.
echo
echo "  -- payment runner --"
# The unit is called `loop2` on stock yiimp but `yiimp-loop2` on this box.
L2=""
for u in loop2 yiimp-loop2 yiimp-loop2.service loop2.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then L2="${u%.service}"; break; fi
done
if [ -z "$L2" ]; then
  echo "    !! no payment-runner unit found. candidates on this box:"
  systemctl list-unit-files 2>/dev/null | grep -iE 'loop|yiimp|payment' | sed 's/^/       /'
  crontab -l 2>/dev/null | grep -i loop | sed 's/^/       cron: /'
else
  echo "    unit      : $L2"
  echo "    enabled   : $(systemctl is-enabled "$L2" 2>&1)"
  echo "    was       : $(systemctl is-active "$L2" 2>&1)"
  systemctl reset-failed "$L2" >/dev/null 2>&1 || true
  systemctl enable "$L2" >/dev/null 2>&1 || true
  systemctl restart "$L2" 2>&1 | sed 's/^/    /'
  sleep 8
  echo "    active    : $(systemctl is-active "$L2" 2>&1)"
  echo "    recent log:"
  journalctl -u "$L2" --since '3 minutes ago' --no-pager 2>/dev/null | tail -25 | sed 's/^/      /'
fi
echo
echo "done. Watch the confirm pass pick the orphans back up:"
echo "  watch -n60 \"mysql yiimpfrontend -t -e \\\"SELECT height,category,amount,confirmations FROM blocks WHERE coin_id=8 ORDER BY id DESC LIMIT 8\\\"\""
echo "To revert:  $LCLI loadwallet rental"

