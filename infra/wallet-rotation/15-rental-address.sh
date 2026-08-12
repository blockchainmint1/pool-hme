#!/usr/bin/env bash
# Create a DEDICATED LTC address for rented hashpower (NiceHash / MiningRigRentals),
# so rental shares/earnings never mix with the McKinney L7 fleet's address.
#
#   sudo bash 15-rental-address.sh            # create (idempotent) + print address
#   sudo bash 15-rental-address.sh show       # just print the existing address
#
# WHAT IT DOES
#   Creates a separate Litecoin Core wallet named `rental` on the running daemon
#   (multiwallet -- litecoind is never stopped, mining is unaffected), derives one
#   bech32 receive address, labels it `rental`, and writes it to
#   /etc/pool-wallets/rental-ltc.txt for reference.
#
#   The wallet is created WITHOUT a passphrase on purpose: it only ever receives
#   pool payouts, holds no pool float, and nothing automated spends from it.
#   Back up /home/ubuntu/.litecoin/rental/wallet.dat after creating it.
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR

MODE="${1:-create}"
LTC_DIR="${LTC_DIR:-/home/ubuntu/.litecoin}"
LTC_BIN="${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}"
CONF="$LTC_DIR/litecoin.conf"
LCLI="$LTC_BIN/litecoin-cli -conf=$CONF"
WALLET="${WALLET:-rental}"
OUT=/etc/pool-wallets/rental-ltc.txt

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

$LCLI getblockchaininfo >/dev/null || { echo "litecoind not reachable"; exit 1; }

loaded() { $LCLI listwallets | grep -q "\"$WALLET\""; }

if [ "$MODE" != "show" ]; then
  if loaded; then
    log "wallet '$WALLET' already loaded"
  elif $LCLI loadwallet "$WALLET" >/dev/null 2>&1; then
    log "loaded existing wallet '$WALLET'"
  else
    log "creating wallet '$WALLET'"
    $LCLI createwallet "$WALLET" >/dev/null
  fi
fi

loaded || { echo "wallet '$WALLET' is not loaded"; exit 1; }

WCLI="$LCLI -rpcwallet=$WALLET"

ADDR="$($WCLI getaddressesbylabel rental 2>/dev/null | grep -oE '"(ltc1|[LM3])[a-zA-Z0-9]+"' | head -1 | tr -d '"' || true)"
if [ -z "$ADDR" ]; then
  ADDR="$($WCLI getnewaddress rental bech32)"
  log "derived new rental address"
fi

mkdir -p /etc/pool-wallets
printf '%s\n' "$ADDR" > "$OUT"
chmod 600 "$OUT"

BAL="$($WCLI getbalance 2>/dev/null || echo 0)"

cat <<EOF

=== rental LTC address ===
  wallet   : $WALLET  ($LTC_DIR/$WALLET/wallet.dat)
  address  : $ADDR
  balance  : $BAL LTC
  saved to : $OUT

Use it for rented hashpower only:

  NiceHash / MRR
    host : stratum.pool.honest.money
    port : 3533
    user : $ADDR.nh          (or .mrr for MiningRigRentals)
    pass : x

Back this up once:
  sudo cp $LTC_DIR/$WALLET/wallet.dat /root/rental-wallet-\$(date -u +%Y%m%d).dat
EOF
