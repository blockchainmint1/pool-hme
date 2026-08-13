#!/usr/bin/env bash
# zcu-doctor.sh -- READ ONLY. Why ZCU stopped merge-mining (last block 8 Jul 2026).
#
#   curl -fsSL https://pool.honest.money/install/zcu-doctor.sh | sudo bash
#
# Topology (discovered):
#   stratum --(bitcoind-style JSON-RPC :8749)--> /opt/zcu-adapter/adapter.py
#           adapter --(EVM JSON-RPC :8747)--> /opt/zcu-mainnet/bin/geth
# Stratum logs "Zero Chill Units error getblocktemplate result" every 21s, so the
# adapter is answering but its getblocktemplate reply is missing/!ok. This script
# probes BOTH hops so we can see which one breaks.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n=== %s ===\n' "$*"; }

STRATUM_CFG_DIR=${STRATUM_CFG_DIR:-/var/stratum/config}
STRATUM_LOG=${STRATUM_LOG:-/var/stratum/scrypt.log}
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
ADAPTER=${ADAPTER:-/opt/zcu-adapter/adapter.py}
ADAPTER_PORT=${ADAPTER_PORT:-8749}
GETH_PORT=${GETH_PORT:-8747}

echo "zcu-doctor v2  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"

hr "0. services"
for u in zcu-adapter zcu-mainnet-geth zcu-mainnet-yiimp-block-sync; do
  echo "-- $u"; systemctl status "$u" --no-pager -n 6 2>&1 | sed 's/^/   /'
done
ss -ltnp 2>/dev/null | grep -E ":(8747|8748|8749|8751)\b" | sed 's/^/   /'

hr "1. how the pool DB / stratum address ZCU"
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1; }
MYT "SELECT id,symbol,enable,visible,auto_ready,rpchost,rpcport,rpcuser IS NOT NULL has_user, rpcencoding, hasmasternodes FROM coins WHERE symbol='ZCU'" | sed 's/^/   /'
grep -rn -i -B2 -A16 'zcu\|8749\|zero *chill' "$STRATUM_CFG_DIR" 2>/dev/null \
  | sed -E 's/(password|rpcpassword|user|rpcuser)([[:space:]]*=).*/\1\2 ***MASKED***/I' | sed 's/^/   /' \
  || echo "   (ZCU not in $STRATUM_CFG_DIR -- stratum reads it from the coins table)"

# RPC creds for the adapter, taken from the coins row (yiimp passes these through).
RU=$(mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e "SELECT IFNULL(rpcuser,'') FROM coins WHERE symbol='ZCU'" 2>/dev/null)
RW=$(mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e "SELECT IFNULL(rpcpasswd,'') FROM coins WHERE symbol='ZCU'" 2>/dev/null)

rpc() { # rpc <port> <method> [params-json]
  local port=$1 m=$2 p=${3:-[]} out
  out=$(curl -s -m 10 --user "${RU}:${RW}" -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":$p}" \
        "http://127.0.0.1:$port/" 2>&1)
  [ -z "$out" ] && out="(empty / connection refused)"
  printf '   %-24s %s\n' "$m" "$(echo "$out" | tr -d '\n' | head -c 500)"
}

hr "2. ADAPTER :$ADAPTER_PORT -- the bitcoind face the stratum talks to"
rpc "$ADAPTER_PORT" getinfo
rpc "$ADAPTER_PORT" getblockcount
rpc "$ADAPTER_PORT" getmininginfo
rpc "$ADAPTER_PORT" getblocktemplate '[{"capabilities":["coinbasetxn","workid","coinbase/append"]}]'
rpc "$ADAPTER_PORT" getblocktemplate '[]'
rpc "$ADAPTER_PORT" getauxblock
rpc "$ADAPTER_PORT" validateaddress '["0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe"]'
echo "   -- raw HTTP headers for a getblocktemplate call:"
curl -s -m 10 -D - -o /dev/null --user "${RU}:${RW}" -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getblocktemplate","params":[]}' \
  "http://127.0.0.1:$ADAPTER_PORT/" 2>&1 | sed 's/^/      /'

hr "3. GETH :$GETH_PORT -- the chain behind the adapter"
grpc() { local m=$1 p=${2:-[]} out
  out=$(curl -s -m 10 -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":$p}" \
        "http://127.0.0.1:$GETH_PORT/" 2>&1)
  printf '   %-24s %s\n' "$m" "$(echo "${out:-(empty)}" | tr -d '\n' | head -c 400)"; }
grpc eth_blockNumber
grpc eth_syncing
grpc net_peerCount
grpc eth_chainId
grpc eth_mining
grpc eth_hashrate
grpc eth_coinbase
grpc eth_getWork
grpc web3_clientVersion
grpc scrypt_getAuxBlock
grpc scrypt_getWork
grpc admin_peers

hr "4. adapter logs + its getblocktemplate implementation"
journalctl -u zcu-adapter -n 60 --no-pager 2>&1 | sed 's/^/   /'
echo "-- adapter source: getblocktemplate / getauxblock handlers"
grep -n -A25 -iE 'def .*(getblocktemplate|get_block_template|getauxblock|get_aux_block)' "$ADAPTER" 2>/dev/null | head -80 | sed 's/^/   /'
echo "-- adapter method dispatch table:"
grep -nE '"[a-z_]+"[[:space:]]*:' "$ADAPTER" 2>/dev/null | head -40 | sed 's/^/   /'
echo "-- adapter listen port / upstream config:"
grep -nE '8747|8748|8749|listen|PORT|GETH|http://' "$ADAPTER" 2>/dev/null | head -30 | sed 's/^/   /'

hr "5. the FAILED yiimp block-sync service"
systemctl cat zcu-mainnet-yiimp-block-sync --no-pager 2>&1 | sed 's/^/   /'
journalctl -u zcu-mainnet-yiimp-block-sync -n 60 --no-pager 2>&1 | sed 's/^/   /'

hr "6. did the chain keep moving after 8 Jul? (geth height vs yiimp height)"
echo "   yiimp last recorded ZCU block:"
MYT "SELECT height, category, amount, FROM_UNIXTIME(time) t FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU' ORDER BY b.time DESC LIMIT 3" | sed 's/^/   /'
echo "   geth head (hex + decimal):"
H=$(curl -s -m 10 -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "http://127.0.0.1:$GETH_PORT/" | grep -oE '0x[0-9a-f]+')
[ -n "$H" ] && printf '   %s = %d\n' "$H" "$H" || echo "   (no answer)"

hr "7. stratum side"
grep -i -E 'zcu|zero chill' "$STRATUM_LOG" 2>/dev/null | tail -n 20 | sed 's/^/   /'
echo "-- aux submits per coin (last 200k log lines):"
tail -n 200000 "$STRATUM_LOG" 2>/dev/null | grep -i 'aux submit' | grep -oiE '\b(doge|txc|isk|zcu)\b' | sort | uniq -c | sed 's/^/   /'
systemctl status stratum-aws-scrypt --no-pager -n 3 2>&1 | sed 's/^/   /'

hr "8. WHY the block-sync crash-loops (ZCU_ROW_NOT_EXACTLY_ONE_OR_NOT_ENABLED)"
echo "-- every ZCU-ish row in coins (the sync expects exactly ONE enabled row):"
MYT "SELECT id,symbol,name,enable,visible,auto_ready,installed,rpchost,rpcport FROM coins WHERE symbol LIKE '%ZCU%' OR name LIKE '%Chill%' OR name LIKE '%Zero%'" | sed 's/^/   /'
echo "-- the sync script + the exact SQL it runs:"
SY=$(systemctl cat zcu-mainnet-yiimp-block-sync --no-pager 2>/dev/null | grep -oE '/[^ ]+\.(sh|py|php)' | head -1)
echo "   script=$SY"
[ -n "$SY" ] && grep -nE "ZCU_ROW_NOT_EXACTLY_ONE|SELECT|enable|symbol" "$SY" 2>/dev/null | head -30 | sed 's/^/   /'

hr "9. adapter: full source of the RPC surface (what it can and cannot answer)"
[ -f "$ADAPTER" ] && { wc -l "$ADAPTER" | sed 's/^/   /'; sed -n '1,200p' "$ADAPTER" | sed 's/^/   /'; }

hr "10. what stratum expects from an aux chain"
grep -rn -iE 'getauxblock|aux_rpc_mode|auxpow_rpc_mode|getblocktemplate' /var/stratum/config/*.conf 2>/dev/null | sed 's/^/   /'
grep -i -E 'zero chill|zcu' /var/log/stratum/debug.log 2>/dev/null | tail -20 | sed 's/^/   /'

echo
echo "zcu-doctor done -- nothing was modified."
