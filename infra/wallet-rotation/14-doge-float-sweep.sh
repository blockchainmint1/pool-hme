#!/usr/bin/env bash
# GOAL 2: move the stranded DOGE float out of the pool hot wallet.
#
#   sudo bash 14-doge-float-sweep.sh                 # dry run
#   sudo bash 14-doge-float-sweep.sh CONFIRM_SWEEP   # send
#
# WHAT THIS IS
# ~246 merged DOGE blocks were credited to the pool wallet but could never be
# attributed to miners: Yiimp deletes the `shares` rows for a round as soon as
# the parent LTC round is credited, so by the time the once-a-day cycle ran the
# allocation data was already gone. Those rewards are unallocatable forever --
# they sit in the hot wallet as float. This sends that float to an address you
# control, keeping a reserve behind so ongoing payouts never bounce.
#
# SAFETY
#  - refuses to run while the payout cycle holds its lock
#  - validates the destination with validateaddress
#  - reads the unpaid/pending DOGE the pool still owes and keeps RESERVE on top
#  - dry run by default; prints every number before it moves anything
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR

CONFIRM="${1:-}"
DEST="${DEST:-DMA7AvFzJWGEnJhUtkSMcGiCnJCCohYKFG}"
RESERVE="${RESERVE:-25000}"           # working float left in the hot wallet, DOGE
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
PASS_ENV=/etc/pool-wallets/passphrase.env
PAYOUT_LOCK=/var/web/runtime/doge-payout/doge-payout-cycle.lock

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "=== DOGE float sweep -> personal wallet ==="
echo "Mode: $([ "$CONFIRM" = CONFIRM_SWEEP ] && echo EXECUTE || echo 'DRY RUN')"
echo "Dest: $DEST"
echo

# ---- never fight the payout cron
if [ -f "$PAYOUT_LOCK" ]; then
  exec 9>"$PAYOUT_LOCK"
  flock -n 9 || { echo "payout cycle running -- try again in a few minutes"; exit 0; }
fi

echo "[1/4] destination check"
VALID=$($DCLI validateaddress "$DEST" | sed -n 's/.*"isvalid": *\([a-z]*\).*/\1/p')
[ "$VALID" = "true" ] || { echo "FATAL: $DEST is not a valid Dogecoin address"; exit 1; }
echo "      isvalid=true"
echo

echo "[2/4] wallet"
BAL=$($DCLI getbalance)
IMM=$($DCLI getwalletinfo | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')
echo "      spendable : $BAL"
echo "      immature  : ${IMM:-0}  (matures at 60 confs; re-run later to sweep)"
echo

echo "[3/4] liabilities still owed to miners"
OWED=0
if command -v mysql >/dev/null 2>&1; then
  OWED=$(mysql -N -B yiimpfrontend -e "
    SELECT ROUND(COALESCE(
      (SELECT SUM(amount) FROM doge_payout_ledger WHERE paid_at IS NULL), 0
    ) + COALESCE(
      (SELECT SUM(doge_balance) FROM accounts WHERE doge_balance > 0), 0
    ), 2);" 2>/dev/null || echo 0)
  [ -n "$OWED" ] || OWED=0
fi
echo "      unpaid ledger + account balances : $OWED"
echo "      extra reserve kept               : $RESERVE"

KEEP=$(awk -v o="$OWED" -v r="$RESERVE" 'BEGIN{printf "%.8f", o+r}')
SEND=$(awk -v b="$BAL" -v k="$KEEP" 'BEGIN{d=b-k; if(d<0)d=0; printf "%.8f", d}')
echo "      total kept behind                : $KEEP"
echo "      sweepable                        : $SEND"
echo

echo "[4/4] send"
if awk -v s="$SEND" 'BEGIN{exit !(s <= 0)}'; then
  echo "      nothing to sweep -- balance is at or below liabilities + reserve."
  exit 0
fi

if [ "$CONFIRM" != "CONFIRM_SWEEP" ]; then
  echo "      would send $SEND DOGE -> $DEST"
  echo
  echo "DRY RUN -- nothing sent. Re-run with: sudo $0 CONFIRM_SWEEP"
  echo "Tune with: RESERVE=50000 sudo -E $0 CONFIRM_SWEEP"
  exit 0
fi

# encrypted wallet needs the passphrase
# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"
if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  $DCLI walletpassphrase "$WALLET_PASSPHRASE" 300 >/dev/null 2>&1 || true
fi

TXID=$($DCLI sendtoaddress "$DEST" "$SEND" "pool float sweep" "" true)
$DCLI walletlock >/dev/null 2>&1 || true
echo "      SENT $SEND DOGE  txid=$TXID"
echo
echo "Verify: https://dogechain.info/tx/$TXID"
echo "Remaining hot-wallet balance:"
$DCLI getbalance
echo
echo "Re-run after the immature ${IMM:-0} DOGE matures to collect the rest."
