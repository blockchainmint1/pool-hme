#!/usr/bin/env bash
# Fix DOGE under-payment caused by moving the payout cycle to once per day.
#
#   sudo bash 12-doge-payout-window.sh            # dry run: show the diff
#   sudo bash 12-doge-payout-window.sh CONFIRM    # apply
#
# THE BUG
# /var/web/doge-payout-cycle.sh captures eligible ledger rows with a
# TOKEN_WINDOW_HOURS=24 lookback. When the cycle ran every 30 minutes that
# window overlapped ~48x, so every block was captured by some run. After
# 10-payout-schedule.sh moved it to a single 06:15 UTC run per day, the window
# only just covers the gap -- any block that ages past it before the next run is
# never captured and never paid. Blocks kept being found (112 / 1.12M DOGE in
# 14 days) while payouts dropped to ~10-20k/day, so the difference piled up as
# an unspent float in the pool wallet.
#
# THE FIX
# Widen the capture lookback well beyond the cron interval and raise the batch
# ceiling so one daily run can drain a full day of blocks. Nothing about
# eligibility or per-miner amounts changes -- we are only letting the capture
# step see blocks it was already entitled to pay.
#
# SAFETY
# capture is idempotent (already-captured ledger rows are not re-created), and
# payoutSend is gated by its own dry-run/preflight steps, so widening the window
# replays missed blocks rather than double-paying settled ones. Run the cycle by
# hand once after applying and read the dry-run output before trusting cron.
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR

CONFIRM="${1:-}"
CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
TOKEN_WINDOW_HOURS="${TOKEN_WINDOW_HOURS:-168}"   # 7 days of slack vs a 24h cron
BLOCK_LIMIT="${BLOCK_LIMIT:-2000}"                # 14d of blocks is ~112; 500 was tight
MAX_BATCHES_PER_RUN="${MAX_BATCHES_PER_RUN:-12}"  # 12 x 100k = 1.2M DOGE headroom

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$CYCLE" ] || { echo "FATAL: $CYCLE not found"; exit 1; }

APPLY=false
[ "$CONFIRM" = "CONFIRM" ] && APPLY=true
STAMP="$(date +%Y%m%d-%H%M%S)"

show() { grep -nE '^(TOKEN_WINDOW_HOURS|BLOCK_LIMIT|SHARE_WINDOW_MINUTES|MIN_PAYOUT_DOGE|MAX_TOTAL_SEND_DOGE|MAX_BATCHES_PER_RUN)=' "$CYCLE" | sed 's/^/      /'; }

echo "=== DOGE payout capture window ==="
echo "Mode: $([ "$APPLY" = true ] && echo APPLY || echo 'DRY RUN')"
echo
echo "[1/3] current settings in $CYCLE"
show
echo
echo "[2/3] target settings"
echo "      TOKEN_WINDOW_HOURS=$TOKEN_WINDOW_HOURS   (was the 24h that starved the daily run)"
echo "      BLOCK_LIMIT=$BLOCK_LIMIT"
echo "      MAX_BATCHES_PER_RUN=$MAX_BATCHES_PER_RUN"
echo "      (MIN_PAYOUT_DOGE and MAX_TOTAL_SEND_DOGE unchanged)"
echo

echo "[3/3] apply"
if [ "$APPLY" != true ]; then
  echo "      would rewrite the three variables above."
  echo
  echo "DRY RUN -- nothing changed. Re-run with CONFIRM."
  exit 0
fi

cp -a "$CYCLE" "$CYCLE.bak-$STAMP"
sed -i \
  -e "s/^TOKEN_WINDOW_HOURS=.*/TOKEN_WINDOW_HOURS=\"$TOKEN_WINDOW_HOURS\"/" \
  -e "s/^BLOCK_LIMIT=.*/BLOCK_LIMIT=\"$BLOCK_LIMIT\"/" \
  -e "s/^MAX_BATCHES_PER_RUN=.*/MAX_BATCHES_PER_RUN=\"$MAX_BATCHES_PER_RUN\"/" \
  "$CYCLE"
bash -n "$CYCLE" || { echo "FATAL: patched script has a syntax error, restoring"; cp -a "$CYCLE.bak-$STAMP" "$CYCLE"; exit 1; }
echo "      after:"
show
echo "      backup: $CYCLE.bak-$STAMP"
echo

cat <<EOF
Done.

NEXT -- do this now, do not wait for cron:
  sudo -u ubuntu bash $CYCLE 2>&1 | tee /tmp/doge-catchup.log

  Read the "payout dry-run" and "preflight" sections before the send lines.
  They list the grouped per-address amounts. If the totals look sane, the run
  continues on its own and drains the backlog in up to $MAX_BATCHES_PER_RUN batches.

THEN VERIFY the float actually drops:
  /home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli \\
    -conf=/home/ubuntu/.dogecoin/dogecoin.conf getwalletinfo | grep balance

ROLLBACK
  cp $CYCLE.bak-$STAMP $CYCLE
EOF
