#!/usr/bin/env bash
# Sweep the OLD (pre-rotation) LTC seed into the CURRENT hot wallet.
#
#   sudo bash 07-sweep-old-ltc.sh                 # dry run  (load + rescan + report only)
#   sudo bash 07-sweep-old-ltc.sh CONFIRM_SWEEP   # rescan, then send everything
#
# Why this is much gentler than the DOGE sweep:
#   Litecoin Core 0.21 is multiwallet. We can `loadwallet` the old seed directory
#   alongside the live `pool` wallet and rescan it IN PLACE -- litecoind never
#   stops, stratum never loses the parent chain, no block templates are missed.
#   The old wallet is unloaded again at the end.
#
# Impact while it runs:
#   None to mining. The rescan is a background scan on the running daemon; RPC
#   stays responsive. Nothing is deleted -- the old wallet dir stays on disk.
set -euo pipefail

CONFIRM="${1:-}"
LTC_DIR="${LTC_DIR:-/home/ubuntu/.litecoin}"
LTC_BIN="${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}"
CONF="$LTC_DIR/litecoin.conf"
LCLI="$LTC_BIN/litecoin-cli -conf=$CONF"
PASS_ENV=/etc/pool-wallets/passphrase.env

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# --- live wallet name (from litecoin.conf `wallet=` line, this box: pool) ------
LIVE_WALLET="$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$CONF" 2>/dev/null | head -1)"
LIVE_WALLET="${LIVE_WALLET:-pool}"
LIVE="$LCLI -rpcwallet=$LIVE_WALLET"

# --- find the old-seed wallet directory ----------------------------------------
OLD_DIR=$(ls -1dt "$LTC_DIR/wallets/"*old-seed-* 2>/dev/null | head -1 || true)
[ -n "$OLD_DIR" ] || { echo "FATAL: no $LTC_DIR/wallets/*old-seed-* directory found"; exit 1; }
OLD_NAME=$(basename "$OLD_DIR")
OLD="$LCLI -rpcwallet=$OLD_NAME"

echo "=== Sweep old LTC seed -> current hot wallet ==="
echo "Mode        : $([ "$CONFIRM" = CONFIRM_SWEEP ] && echo EXECUTE || echo 'DRY RUN')"
echo "Live wallet : $LIVE_WALLET"
echo "Old wallet  : $OLD_NAME"

$LCLI getblockcount >/dev/null 2>&1 || { echo "FATAL: litecoind not responding"; exit 1; }

# --- destination on the CURRENT rotated seed -----------------------------------
DEST="${DEST:-}"
[ -n "$DEST" ] || DEST=$($LIVE getnewaddress "sweep-from-old-seed")
CUR_SEED=$($LIVE getwalletinfo | sed -n 's/.*"hdseedid": *"\([^"]*\)".*/\1/p;s/.*"hdmasterkeyid": *"\([^"]*\)".*/\1/p' | head -1)
echo "Dest addr   : $DEST   (current seed ${CUR_SEED:-unknown})"
echo

# --- load the old wallet (idempotent) ------------------------------------------
# `loadwallet` on an already-loaded wallet returns error -4 ("already loaded"),
# which is harmless: a previous dry run may have failed to unload it. Detect with
# listwallets, and treat a failed load as fatal only if the wallet is still absent.
is_loaded() { $LCLI listwallets 2>/dev/null | grep -q "\"$OLD_NAME\""; }
if is_loaded; then
  log "$OLD_NAME already loaded (left over from an earlier run) -- reusing it"
else
  log "loading $OLD_NAME"
  $LCLI loadwallet "$OLD_NAME" >/dev/null 2>&1 || true
  is_loaded || { echo "FATAL: could not load $OLD_NAME"; $LCLI loadwallet "$OLD_NAME"; exit 1; }
fi
LOADED=1
unload_old() {
  [ "${LOADED:-0}" = 1 ] || return 0
  $OLD walletlock >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    is_loaded || { log "unloaded $OLD_NAME"; return 0; }
    $LCLI unloadwallet "$OLD_NAME" >/dev/null 2>&1 || true
    sleep 2
  done
  echo "WARNING: $OLD_NAME is still loaded (a rescan may still be running)."
  echo "         Unload it manually before re-running:  $LCLI unloadwallet $OLD_NAME"
}
trap 'echo "FAILED -- unloading old wallet"; unload_old' ERR


# --- rescan so matured coinbases show up ---------------------------------------
log "rescanning $OLD_NAME (daemon stays online; this can take several minutes)"
$OLD rescanblockchain >/dev/null 2>&1 || true

echo "--- old seed wallet ---"
$OLD getwalletinfo | grep -E 'walletname|hdseedid|hdmasterkeyid|"balance"|immature|txcount'
BAL=$($OLD getbalance)
IMM=$($OLD getwalletinfo | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')
echo
echo "Spendable on old seed : $BAL LTC"
echo "Still immature        : ${IMM:-0} LTC  (needs 100 confs)"
echo

if [ "$CONFIRM" != "CONFIRM_SWEEP" ]; then
  cat <<EOF
DRY RUN -- nothing sent.

Plan:
  1. loadwallet $OLD_NAME              (done, will be unloaded again now)
  2. rescanblockchain                  (done)
  3. walletpassphrase from $PASS_ENV   (old seed may be encrypted)
  4. sendtoaddress $DEST $BAL  (subtractfeefromamount)
  5. walletlock + unloadwallet $OLD_NAME

Nothing is deleted. The old wallet directory stays at:
  $OLD_DIR

Re-run with: sudo $0 CONFIRM_SWEEP
EOF
  trap - ERR
  unload_old
  exit 0
fi

# --- unlock (the rotated-era wallets are encrypted) -----------------------------
# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"
if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  $OLD walletpassphrase "$WALLET_PASSPHRASE" 600 >/dev/null 2>&1 || true
fi

if awk -v b="$BAL" 'BEGIN{exit !(b <= 0.001)}'; then
  log "nothing spendable on the old seed (balance=$BAL) -- immature coinbases may still be pending"
else
  log "sending $BAL LTC -> $DEST"
  TXID=$($OLD sendtoaddress "$DEST" "$BAL" "old seed sweep" "" true)
  log "SENT txid=$TXID"
fi

trap - ERR
unload_old

echo
echo "--- live wallet after sweep ---"
$LIVE getwalletinfo | grep -E 'walletname|hdseedid|hdmasterkeyid|"balance"|unconfirmed|immature'
echo
echo "Done. Old wallet directory kept at $OLD_DIR"
echo "If immature coinbases remained on the old seed, re-run this after they mature (100 confs)."
