#!/usr/bin/env bash
# Keep the hot DOGE wallet at a working float, pushing the excess to cold.
# Caps the loss from any future host compromise at roughly one payout cycle.
#
# Install:
#   sudo cp 04-auto-sweep.sh /usr/local/sbin/pool-auto-sweep.sh
#   sudo chmod 700 /usr/local/sbin/pool-auto-sweep.sh
#   sudo tee /etc/cron.d/pool-auto-sweep >/dev/null <<'EOF'
#   SHELL=/bin/bash
#   PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#   17 */6 * * * root /usr/local/sbin/pool-auto-sweep.sh >> /var/log/pool-auto-sweep.log 2>&1
#   EOF
#
# Runs every 6h at :17 so it never collides with the */5 payout cron.
set -euo pipefail

COLD_ENV="/etc/pool-wallets/cold.env"
PASS_ENV="/etc/pool-wallets/passphrase.env"
PAYOUT_LOCK="/var/web/runtime/doge-payout/doge-payout-cycle.lock"

# Keep enough for ~2 payout cycles.
FLOAT_DOGE="${FLOAT_DOGE:-5000}"
# Don't bother with dust-sized sweeps.
MIN_SWEEP_DOGE="${MIN_SWEEP_DOGE:-1000}"

DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# shellcheck disable=SC1090
[ -r "$COLD_ENV" ] && . "$COLD_ENV"
# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"

if [ -z "${COLD_DOGE:-}" ]; then
  log "COLD_DOGE not configured in $COLD_ENV -- skipping"
  exit 0
fi

# Never run while a payout cycle holds the lock.
if [ -f "$PAYOUT_LOCK" ]; then
  exec 9>"$PAYOUT_LOCK"
  if ! flock -n 9; then
    log "payout cycle in progress -- skipping this sweep"
    exit 0
  fi
fi

BAL=$($DCLI getbalance 2>/dev/null || echo 0)
SEND=$(awk -v b="$BAL" -v f="$FLOAT_DOGE" 'BEGIN{d=b-f; if(d<0)d=0; printf "%.8f", d}')

log "balance=$BAL float=$FLOAT_DOGE excess=$SEND"

if awk -v s="$SEND" -v m="$MIN_SWEEP_DOGE" 'BEGIN{exit !(s < m)}'; then
  log "excess below MIN_SWEEP_DOGE=$MIN_SWEEP_DOGE -- nothing to do"
  exit 0
fi

lock_wallet() { $DCLI walletlock >/dev/null 2>&1 || true; }

if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  trap lock_wallet EXIT
  $DCLI walletpassphrase "$WALLET_PASSPHRASE" 120 >/dev/null 2>&1 || {
    log "FATAL: wallet unlock failed"
    exit 1
  }
fi

TXID=$($DCLI sendtoaddress "$COLD_DOGE" "$SEND" "auto cold sweep" "" true)
log "swept $SEND DOGE to $COLD_DOGE txid=$TXID"
