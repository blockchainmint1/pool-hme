#!/usr/bin/env bash
# Replace each daemon's HD wallet with a fresh, encrypted one.
#
# This is the step that actually revokes the old operator: a new seed produces
# addresses the old seed cannot derive, so all future block rewards are out of
# reach of any previously copied wallet.dat.
#
#   sudo ./02-rotate-seed.sh                  # dry run
#   sudo ./02-rotate-seed.sh CONFIRM_ROTATE   # execute
#
# The old wallet file is MOVED ASIDE, never deleted -- immature coinbases still
# belong to the old seed. Re-run 01-sweep.sh against it once they mature.
set -euo pipefail

CONFIRM="${1:-}"
PASS_ENV="/etc/pool-wallets/passphrase.env"
STAMP="$(date +%Y%m%d-%H%M%S)"

DOGE_DIR="/home/ubuntu/.dogecoin"
LTC_DIR="/home/ubuntu/.litecoin"

DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=$DOGE_DIR/dogecoin.conf"

echo "=== Pool wallet seed rotation ==="
echo "Mode: $([ "$CONFIRM" = "CONFIRM_ROTATE" ] && echo EXECUTE || echo 'DRY RUN')"
echo

# --- refuse to run mid-payout -------------------------------------------------
LOCK="/var/web/runtime/doge-payout/doge-payout-cycle.lock"
if [ -f "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; then
  echo "FATAL: a DOGE payout cycle is running right now. Wait for it to finish."
  exit 1
fi

# --- passphrase ---------------------------------------------------------------
if [ ! -f "$PASS_ENV" ]; then
  echo "No passphrase file at $PASS_ENV."
  echo
  echo "Generate one and SAVE IT IN YOUR PASSWORD MANAGER FIRST:"
  echo "  sudo mkdir -p /etc/pool-wallets"
  echo "  printf 'WALLET_PASSPHRASE=%s\\n' \"\$(openssl rand -base64 32)\" \\"
  echo "    | sudo tee $PASS_ENV >/dev/null"
  echo "  sudo chmod 600 $PASS_ENV"
  echo "  sudo cat $PASS_ENV   # copy to password manager, then continue"
  echo
  echo "If this file is lost with no copy, the hot wallet float is unrecoverable."
  exit 1
fi
# shellcheck disable=SC1090
. "$PASS_ENV"
: "${WALLET_PASSPHRASE:?WALLET_PASSPHRASE not set in $PASS_ENV}"

echo "Passphrase file present ($PASS_ENV)."
echo "Confirm it is saved in your password manager before continuing."
echo

# --- plan ---------------------------------------------------------------------
cat <<PLAN
Plan for DOGE (dogecoind):
  1. stop dogecoind                      (mining unaffected; stratum retries getauxblock)
  2. mv $DOGE_DIR/wallet.dat -> wallet.dat.old-seed-$STAMP
  3. start dogecoind                     (creates a fresh HD wallet + seed)
  4. encryptwallet '<passphrase>'        (daemon auto-restarts, new seed on encrypt)
  5. print new hdmasterkeyid + a sample receive address

LTC uses the same shape but a per-wallet directory ($LTC_DIR/wallets/pool/).
Rotate DOGE first, confirm a block lands in the new wallet, then repeat for LTC.

TXC / ISK / ZCU are NOT rotated here: their coinbase destinations are fixed at
the chain/consensus level, so a new local seed would not change where rewards
land and could break payouts. Leave those wallets as-is.

PLAN

if [ "$CONFIRM" != "CONFIRM_ROTATE" ]; then
  echo "Dry run only. Re-run with: sudo $0 CONFIRM_ROTATE"
  exit 0
fi

# --- execute: DOGE ------------------------------------------------------------
echo ">>> stopping dogecoind"
$DCLI stop || true
for i in $(seq 1 60); do
  pgrep -x dogecoind >/dev/null || break
  sleep 1
done
pgrep -x dogecoind >/dev/null && { echo "FATAL: dogecoind still running"; exit 1; }

echo ">>> moving old wallet aside"
mv "$DOGE_DIR/wallet.dat" "$DOGE_DIR/wallet.dat.old-seed-$STAMP"
chmod 600 "$DOGE_DIR/wallet.dat.old-seed-$STAMP"

echo ">>> starting dogecoind with a fresh wallet"
sudo -u ubuntu /home/ubuntu/dogecoin-1.14.9/bin/dogecoind \
  -conf="$DOGE_DIR/dogecoin.conf" -daemon
for i in $(seq 1 120); do
  $DCLI getwalletinfo >/dev/null 2>&1 && break
  sleep 1
done

echo ">>> encrypting new wallet"
$DCLI encryptwallet "$WALLET_PASSPHRASE" || true
sleep 5
for i in $(seq 1 120); do
  pgrep -x dogecoind >/dev/null || break
  sleep 1
done
pgrep -x dogecoind >/dev/null || \
  sudo -u ubuntu /home/ubuntu/dogecoin-1.14.9/bin/dogecoind \
    -conf="$DOGE_DIR/dogecoin.conf" -daemon
for i in $(seq 1 120); do
  $DCLI getwalletinfo >/dev/null 2>&1 && break
  sleep 1
done

echo
echo ">>> new DOGE wallet state"
$DCLI getwalletinfo
echo "sample new address: $($DCLI getnewaddress 2>/dev/null || echo '(locked, expected)')"
echo
echo "Old seed retained at: $DOGE_DIR/wallet.dat.old-seed-$STAMP"
echo "NEXT: run 03-patch-payout-cron.sh before the next payout cycle, or"
echo "      payoutSend will fail against the now-locked wallet."
