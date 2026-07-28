#!/usr/bin/env bash
# Sweep spendable pool balance to cold storage, leaving a working float.
#
#   sudo ./01-sweep.sh                 # dry run
#   sudo ./01-sweep.sh CONFIRM_SWEEP   # execute
#
# Cold addresses come from /etc/pool-wallets/cold.env (mode 600):
#   COLD_DOGE=D...
#   COLD_LTC=ltc1...
set -euo pipefail

CONFIRM="${1:-}"
COLD_ENV="/etc/pool-wallets/cold.env"

# Float left behind so the payout cron never runs dry.
# Cycle sends ~1400-2000 DOGE per linked miner every ~2.5h.
FLOAT_DOGE="${FLOAT_DOGE:-5000}"
FLOAT_LTC="${FLOAT_LTC:-0}"

DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf"

if [ ! -f "$COLD_ENV" ]; then
  echo "FATAL: $COLD_ENV missing."
  echo
  echo "Create it first, with addresses generated on hardware you control:"
  echo "  sudo mkdir -p /etc/pool-wallets"
  echo "  sudo tee $COLD_ENV >/dev/null <<'EOF'"
  echo "COLD_DOGE=D..."
  echo "COLD_LTC=ltc1..."
  echo "EOF"
  echo "  sudo chmod 600 $COLD_ENV"
  echo
  echo "Send a test transaction FROM each cold address before continuing."
  exit 1
fi
# shellcheck disable=SC1090
. "$COLD_ENV"

: "${COLD_DOGE:?COLD_DOGE not set in $COLD_ENV}"
: "${COLD_LTC:?COLD_LTC not set in $COLD_ENV}"

echo "=== Pool wallet sweep ==="
echo "Mode: $([ "$CONFIRM" = "CONFIRM_SWEEP" ] && echo EXECUTE || echo 'DRY RUN')"
echo

sweep() {
  local name="$1" cli="$2" cold="$3" float="$4"

  local bal imm send
  bal=$($cli getbalance 2>/dev/null || echo 0)
  imm=$($cli getwalletinfo 2>/dev/null | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')

  echo "--- $name ---"
  echo "  spendable : $bal"
  echo "  immature  : ${imm:-0}   (needs ~240 confs; re-run this script later)"
  echo "  float kept: $float"
  echo "  cold dest : $cold"

  send=$(awk -v b="$bal" -v f="$float" 'BEGIN{d=b-f; if(d<0)d=0; printf "%.8f", d}')

  if awk -v s="$send" 'BEGIN{exit !(s <= 0)}'; then
    echo "  -> nothing to sweep (balance at or below float)"
    echo
    return
  fi

  echo "  -> would send $send $name to $cold"

  if [ "$CONFIRM" = "CONFIRM_SWEEP" ]; then
    local txid
    txid=$($cli sendtoaddress "$cold" "$send" "pool cold sweep" "" true)
    echo "  -> SENT  txid=$txid"
  fi
  echo
}

sweep DOGE "$DCLI" "$COLD_DOGE" "$FLOAT_DOGE"
sweep LTC  "$LCLI" "$COLD_LTC"  "$FLOAT_LTC"

if [ "$CONFIRM" != "CONFIRM_SWEEP" ]; then
  echo "Dry run only. Re-run with: sudo $0 CONFIRM_SWEEP"
else
  echo "Sweep complete. Verify on a block explorer before running 02-rotate-seed.sh."
fi
