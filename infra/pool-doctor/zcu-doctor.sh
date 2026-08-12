#!/usr/bin/env bash
# zcu-doctor.sh -- READ ONLY. Full picture of why ZCU stopped being merge-mined.
#
#   curl -fsSL https://pool.honest.money/install/zcu-doctor.sh | sudo bash
#
# ZCU is an EVM (geth) aux child, not a UTXO coin. It cannot answer
# getblocktemplate / getauxblock / validateaddress the way DOGE/TXC/ISK do,
# so the stratum's UTXO-only code paths silently drop it. This script proves
# which RPCs the node *does* answer and where the stratum gives up.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n=== %s ===\n' "$*"; }

STRATUM_CFG_DIR=${STRATUM_CFG_DIR:-/var/stratum/config}
STRATUM_LOG=${STRATUM_LOG:-/var/stratum/scrypt.log}
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}

echo "zcu-doctor  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"

hr "1. ZCU section of the stratum config (creds masked)"
grep -rn -i -A14 'zcu\|zero *chill' "$STRATUM_CFG_DIR" 2>/dev/null \
  | sed -E 's/(password|rpcpassword|user|rpcuser)[[:space:]]*=.*/\1 = ***MASKED***/I' | sed 's/^/   /' \
  || echo "   (no ZCU block found in $STRATUM_CFG_DIR)"

# Pull host/port/user/pass out of the ZCU coin conf for live RPC probing.
ZFILE=$(grep -rl -i 'zcu\|zero *chill' "$STRATUM_CFG_DIR" 2>/dev/null | head -1)
RH=$(grep -i -m1 'rpchost\|host' "${ZFILE:-/dev/null}" 2>/dev/null | sed 's/.*= *//;s/[",;]//g')
RP=$(grep -i -m1 'rpcport\|port' "${ZFILE:-/dev/null}" 2>/dev/null | sed 's/.*= *//;s/[",;]//g')
RU=$(grep -i -m1 'rpcuser\|user' "${ZFILE:-/dev/null}" 2>/dev/null | sed 's/.*= *//;s/[",;]//g')
RW=$(grep -i -m1 'rpcpassword\|password' "${ZFILE:-/dev/null}" 2>/dev/null | sed 's/.*= *//;s/[",;]//g')
RH=${ZCU_HOST:-${RH:-127.0.0.1}}; RP=${ZCU_PORT:-${RP:-8545}}
echo "   probing RPC at $RH:$RP  (config file: ${ZFILE:-none})"

rpc() { # rpc <method> [params-json]
  local m=$1 p=${2:-[]}
  local out
  out=$(curl -s -m 8 --user "${RU:-}:${RW:-}" -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":$p}" \
        "http://$RH:$RP/" 2>&1)
  [ -z "$out" ] && out="(no response / connection refused)"
  printf '   %-22s %s\n' "$m" "$(echo "$out" | head -c 300)"
}

hr "2. Is anything listening, and what is it?"
ss -ltnp 2>/dev/null | grep -E ":$RP\b" | sed 's/^/   /' || echo "   nothing listening on $RP"
ps -ef | grep -iE '[g]eth|[z]cu|[z]erochill' | sed 's/^/   /' || echo "   no geth/zcu process"
systemctl list-units --type=service --no-pager 2>/dev/null | grep -iE 'geth|zcu|chill' | sed 's/^/   /'

hr "3. EVM-side RPC probes (what the node CAN do)"
rpc eth_blockNumber
rpc eth_syncing
rpc net_peerCount
rpc eth_chainId
rpc eth_mining
rpc eth_getWork
rpc eth_coinbase
rpc web3_clientVersion

hr "4. UTXO-style probes (what the stratum WANTS and will not get)"
rpc getblocktemplate '[{"capabilities":["coinbasetxn"]}]'
rpc getauxblock
rpc getinfo
rpc getblockcount
rpc validateaddress '["0x0000000000000000000000000000000000000000"]'

hr "5. Merge-mining specific probes (geth aux forks usually expose these)"
rpc getauxblock '[]'
rpc eth_getAuxBlock
rpc miner_getAuxBlock
rpc eth_submitWork '["0x0","0x0","0x0"]'

hr "6. What the stratum log says about ZCU"
grep -i -E 'zcu|zero chill' "$STRATUM_LOG" 2>/dev/null | tail -n 40 | sed 's/^/   /' || echo "   (no ZCU lines in $STRATUM_LOG)"
echo "-- ZCU line counts by message shape (last 200k lines):"
tail -n 200000 "$STRATUM_LOG" 2>/dev/null | grep -i 'zcu' | sed -E 's/[0-9a-fx]{8,}/<hex>/g;s/[0-9]+/<n>/g' \
  | sort | uniq -c | sort -rn | head -15 | sed 's/^/   /'
echo "-- for contrast, aux submits per coin (last 200k lines):"
tail -n 200000 "$STRATUM_LOG" 2>/dev/null | grep -i 'aux submit' | awk '{print $NF, $0}' \
  | grep -oiE '\b(doge|txc|isk|zcu)\b' | sort | uniq -c | sed 's/^/   /'

hr "7. Pool DB view of ZCU"
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1; }
MYT "SELECT id,symbol,name,enable,visible,auto_ready,rpchost,rpcport FROM coins WHERE symbol='ZCU'" | sed 's/^/   /'
MYT "SELECT height, category, amount, FROM_UNIXTIME(time) t FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU' ORDER BY b.time DESC LIMIT 5" | sed 's/^/   /'

hr "8. Stratum binary in use"
sha256sum /var/stratum/stratum 2>/dev/null | sed 's/^/   /'
ls -l /var/stratum/stratum* 2>/dev/null | sed 's/^/   /'
systemctl status stratum-aws-scrypt --no-pager -n 5 2>&1 | sed 's/^/   /'

echo
echo "zcu-doctor done -- nothing was modified."
