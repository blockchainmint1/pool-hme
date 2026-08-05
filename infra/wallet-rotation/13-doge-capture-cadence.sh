#!/usr/bin/env bash
# GOAL 1: make DOGE payouts correct going FORWARD.
#
#   sudo bash 13-doge-capture-cadence.sh            # dry run
#   sudo bash 13-doge-capture-cadence.sh CONFIRM    # apply
#
# WHY THE DAILY CRON KEEPS LOSING BLOCKS
# Yiimp treats `shares` as a consumable round ledger:
#   yaamp/core/backend/blocks.php  -> DELETE FROM shares WHERE coinid=<algo coin>
#   yaamp/core/backend/system.php  -> age-based purge
# Every time a PARENT (LTC) round is credited, the share rows that a merged DOGE
# block would have been allocated against are wiped. The DOGE cycle's capture
# step can only attribute a block while those shares still exist -- typically
# minutes, not hours. Widening TOKEN_WINDOW_HOURS to 168 (script 12) let capture
# SEE old blocks, but by then their shares were gone, so they land as `no_shares`
# and pay nothing. That is why 246 blocks (~2.46M DOGE) piled up as wallet float.
#
# THE FIX
# Decouple cadence from payout size: run the CYCLE often (default every 10 min)
# so capture always beats the share purge, and let MIN_PAYOUT_DOGE do the
# batching. Miners still receive one consolidated transfer once their pending
# balance crosses the threshold -- they do not get 144 dust sends a day.
#
# This replaces the single 06:15 daily entry in /etc/cron.d/yiimp-doge-payout-cycle.
# The cycle already takes a flock, so overlapping runs are impossible.
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR

CONFIRM="${1:-}"
CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/yiimp-doge-payout-cycle}"
EVERY_MIN="${EVERY_MIN:-10}"                    # capture cadence, minutes
TOKEN_WINDOW_HOURS="${TOKEN_WINDOW_HOURS:-24}"  # back to a sane value; cadence does the work now
MIN_PAYOUT_DOGE="${MIN_PAYOUT_DOGE:-200}"       # batching happens here, not in the cron interval

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$CYCLE" ] || { echo "FATAL: $CYCLE not found"; exit 1; }

APPLY=false
[ "$CONFIRM" = "CONFIRM" ] && APPLY=true
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "=== DOGE capture cadence ==="
echo "Mode: $([ "$APPLY" = true ] && echo APPLY || echo 'DRY RUN')"
echo

echo "[1/4] current cycle settings"
grep -nE '^(TOKEN_WINDOW_HOURS|BLOCK_LIMIT|SHARE_WINDOW_MINUTES|MIN_PAYOUT_DOGE|MAX_TOTAL_SEND_DOGE|MAX_BATCHES_PER_RUN)=' "$CYCLE" | sed 's/^/      /'
echo
echo "[2/4] current cron"
if [ -f "$CRON_FILE" ]; then sed 's/^/      /' "$CRON_FILE"; else echo "      (no $CRON_FILE)"; fi
echo

echo "[3/4] target"
echo "      cron            : */$EVERY_MIN * * * *   (was 15 6 * * *)"
echo "      TOKEN_WINDOW_HOURS=$TOKEN_WINDOW_HOURS"
echo "      MIN_PAYOUT_DOGE=$MIN_PAYOUT_DOGE   (miners still get batched transfers)"
echo

echo "[4/4] apply"
if [ "$APPLY" != true ]; then
  echo "      would rewrite the cron entry and the two variables above."
  echo
  echo "DRY RUN -- nothing changed. Re-run with CONFIRM."
  exit 0
fi

cp -a "$CYCLE" "$CYCLE.bak-$STAMP"
sed -i \
  -e "s/^TOKEN_WINDOW_HOURS=.*/TOKEN_WINDOW_HOURS=\"$TOKEN_WINDOW_HOURS\"/" \
  -e "s/^MIN_PAYOUT_DOGE=.*/MIN_PAYOUT_DOGE=\"$MIN_PAYOUT_DOGE\"/" \
  "$CYCLE"
bash -n "$CYCLE" || { echo "FATAL: syntax error, restoring"; cp -a "$CYCLE.bak-$STAMP" "$CYCLE"; exit 1; }

[ -f "$CRON_FILE" ] && cp -a "$CRON_FILE" "$CRON_FILE.bak-$STAMP"
cat > "$CRON_FILE" <<EOF
# Managed by 13-doge-capture-cadence.sh -- do not hand-edit.
# Runs often so block capture beats Yiimp's share purge; MIN_PAYOUT_DOGE batches sends.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/$EVERY_MIN * * * * ubuntu /bin/bash $CYCLE >> /var/log/doge-payout-cycle.log 2>&1
EOF
chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || service cron restart || true

echo "      cron now:"
sed 's/^/      /' "$CRON_FILE"
echo "      backups: $CYCLE.bak-$STAMP  $CRON_FILE.bak-$STAMP"
echo

cat <<EOF
Done.

VERIFY over the next hour:
  sudo tail -n 200 /var/log/doge-payout-cycle.log
  # expect: each run captures 0-1 blocks and reports few/no "no_shares"

  mysql yiimpfrontend -e "
    SELECT DATE(FROM_UNIXTIME(time)) d, COUNT(*) blocks
      FROM blocks WHERE coin_id=(SELECT id FROM coins WHERE symbol='DOGE')
       AND time > UNIX_TIMESTAMP()-7*86400 GROUP BY d;"

  # and payouts should now track block finds day over day:
  mysql yiimpfrontend -e "
    SELECT DATE(FROM_UNIXTIME(time)) d, ROUND(SUM(amount)) doge
      FROM payouts WHERE time > UNIX_TIMESTAMP()-7*86400 GROUP BY d;"

NOTE: this only fixes blocks found from now on. The ~246 already-orphaned
blocks can never be attributed -- their share rows are gone. Use
14-doge-float-sweep.sh to move that stranded float out of the hot wallet.

ROLLBACK
  cp $CYCLE.bak-$STAMP $CYCLE
  cp $CRON_FILE.bak-$STAMP $CRON_FILE && systemctl restart cron
EOF
