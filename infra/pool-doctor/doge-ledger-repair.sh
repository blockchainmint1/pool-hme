#!/usr/bin/env bash
# doge-ledger-repair.sh -- clean up the two leftovers the 12 Aug triage found.
#
#   curl -fsSL https://pool.honest.money/install/doge-ledger-repair.sh | sudo bash                # dry run
#   curl -fsSL https://pool.honest.money/install/doge-ledger-repair.sh | sudo bash -s CONFIRM     # apply
#
# 1. Duplicate cron: 10-payout-schedule.sh left a daily 06:15 entry behind while
#    13-doge-capture-cadence.sh installed the */10 one. Two cycles racing on the
#    same flock is harmless but noisy -- the daily one is the stale wrapper whose
#    log has not moved since 5 Aug. Remove it.
# 2. Seven `failed` ledger rows from 29 Jul (~9903 DOGE). Show them, and on
#    CONFIRM flip them back to `pending` so the next cycle re-attempts the send.
#
# Nothing else is touched. `pending` rows below MIN_PAYOUT_DOGE are NORMAL --
# that is the batching threshold, not a stuck payout.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
CONFIRM="${1:-}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
DAILY_CRON=/etc/cron.d/yiimp-payout-schedule

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }

echo "=== doge-ledger-repair $(date -u '+%F %T UTC') ==="
echo "Mode: $([ "$CONFIRM" = CONFIRM ] && echo APPLY || echo 'DRY RUN')"

echo
echo "--- 1. duplicate DOGE payout cron"
grep -rl 'doge-payout-cycle' /etc/cron.d/* 2>/dev/null | sed 's/^/  file: /'
grep -rh 'doge-payout-cycle' /etc/cron.d/* 2>/dev/null | grep -v '^#' | sed 's/^/  /'
STALE=$(grep -rl '15 6 \* \* \*.*doge-payout-cycle' /etc/cron.d/* 2>/dev/null | head -1)
if [ -n "$STALE" ]; then
  echo "  stale daily entry lives in: $STALE"
  if [ "$CONFIRM" = CONFIRM ]; then
    cp -a "$STALE" "$STALE.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i '/15 6 \* \* \*.*doge-payout-cycle/d' "$STALE"
    # drop the file entirely if only comments remain
    grep -qE '^[^#[:space:]]' "$STALE" || rm -f "$STALE"
    echo "  removed daily 06:15 entry (backup kept)"
  else
    echo "  would remove the 06:15 line; */10 cadence stays"
  fi
else
  echo "  no stale daily entry -- nothing to do"
fi

echo
echo "--- 2. failed ledger rows"
MY "SELECT id, address, ROUND(amount,2) amount, LEFT(IFNULL(txid,'(none)'),20) txid,
           FROM_UNIXTIME(created_at) created, FROM_UNIXTIME(updated_at) touched
    FROM doge_payout_ledger WHERE status='failed' ORDER BY updated_at DESC LIMIT 20"
N=$(MYN "SELECT COUNT(*) FROM doge_payout_ledger WHERE status='failed'")
S=$(MYN "SELECT ROUND(IFNULL(SUM(amount),0),2) FROM doge_payout_ledger WHERE status='failed'")
echo "  $N rows, $S DOGE"
BAL=$(/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf getbalance 2>/dev/null)
echo "  hot wallet spendable: ${BAL:-unknown} DOGE"
if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$CONFIRM" = CONFIRM ]; then
    if awk -v b="${BAL:-0}" -v s="${S:-0}" 'BEGIN{exit !(b > s)}'; then
      MY "UPDATE doge_payout_ledger SET status='pending', updated_at=UNIX_TIMESTAMP()
          WHERE status='failed'"
      echo "  requeued $N rows as pending -- next */10 cycle will re-send"
    else
      echo "  REFUSING: wallet balance does not cover $S DOGE"
    fi
  else
    echo "  would requeue these as 'pending' (balance covers it)"
  fi
fi

echo
echo "--- 3. sanity: what remains"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) amount, FROM_UNIXTIME(MAX(updated_at)) last_touch
    FROM doge_payout_ledger GROUP BY status ORDER BY n DESC"
echo
echo "done. Re-run with CONFIRM to apply, or watch: tail -f /var/log/doge-payout-cycle.log"
