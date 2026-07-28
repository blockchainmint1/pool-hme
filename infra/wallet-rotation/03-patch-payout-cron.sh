#!/usr/bin/env bash
# Teach /var/web/doge-payout-cycle.sh to unlock the encrypted wallet before
# payoutSend and re-lock afterwards.
#
#   sudo ./03-patch-payout-cron.sh                 # show the diff
#   sudo ./03-patch-payout-cron.sh CONFIRM_PATCH   # apply
#
# Without this, every payoutSend fails with "Error: Please enter the wallet
# passphrase with walletpassphrase first" once 02-rotate-seed.sh has run.
set -euo pipefail

CONFIRM="${1:-}"
TARGET="/var/web/doge-payout-cycle.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"

[ -f "$TARGET" ] || { echo "FATAL: $TARGET not found"; exit 1; }

if grep -q "walletpassphrase" "$TARGET"; then
  echo "Already patched -- $TARGET references walletpassphrase. Nothing to do."
  exit 0
fi

read -r -d '' UNLOCK_BLOCK <<'BLOCK' || true

# --- wallet unlock (added by infra/wallet-rotation/03-patch-payout-cron.sh) ---
# The pool wallet is encrypted. sendtoaddress needs an unlocked wallet, so we
# unlock for the duration of the cycle and always re-lock on exit.
DOGE_CLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
PASS_ENV="/etc/pool-wallets/passphrase.env"

if [ -r "$PASS_ENV" ]; then
  # shellcheck disable=SC1090
  . "$PASS_ENV"
fi

lock_wallet() { $DOGE_CLI walletlock >/dev/null 2>&1 || true; }

if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  trap lock_wallet EXIT
  # 3600s is longer than a full 5-batch cycle; the trap re-locks early anyway.
  if ! $DOGE_CLI walletpassphrase "$WALLET_PASSPHRASE" 3600 >/dev/null 2>&1; then
    echo "FATAL: could not unlock DOGE wallet -- wrong passphrase?"
    exit 1
  fi
  echo "DOGE wallet unlocked for this cycle."
else
  echo "WARNING: no WALLET_PASSPHRASE available; payoutSend will fail if the wallet is encrypted."
fi
# --- end wallet unlock -------------------------------------------------------
BLOCK

echo "=== Patch $TARGET ==="
echo "Mode: $([ "$CONFIRM" = "CONFIRM_PATCH" ] && echo APPLY || echo 'PREVIEW')"
echo
echo "Insert after the flock guard, before 'Step 1: scan permanent DOGE tokens':"
echo "$UNLOCK_BLOCK"
echo

if [ "$CONFIRM" != "CONFIRM_PATCH" ]; then
  echo "Preview only. Re-run with: sudo $0 CONFIRM_PATCH"
  exit 0
fi

cp -a "$TARGET" "$TARGET.bak-$STAMP"
echo "backup: $TARGET.bak-$STAMP"

python3 - "$TARGET" <<PY
import sys
path = sys.argv[1]
block = """$UNLOCK_BLOCK"""
src = open(path).read()
anchor = 'echo "=== Step 1: scan permanent DOGE tokens ==="'
if anchor not in src:
    sys.exit("anchor line not found; patch manually")
src = src.replace(anchor, block.strip() + "\n\n" + anchor, 1)
open(path, "w").write(src)
print("patched")
PY

bash -n "$TARGET" && echo "syntax OK"

echo
echo "Verifying the wallet can actually be unlocked with the stored passphrase:"
# shellcheck disable=SC1091
. /etc/pool-wallets/passphrase.env 2>/dev/null || true
if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  if $DCLI walletpassphrase "$WALLET_PASSPHRASE" 5 >/dev/null 2>&1; then
    echo "  unlock OK"
    $DCLI walletlock >/dev/null 2>&1 || true
  else
    echo "  UNLOCK FAILED -- fix before the next cron run (every 5 min)"
    exit 1
  fi
fi
