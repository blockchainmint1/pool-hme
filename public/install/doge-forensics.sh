#!/usr/bin/env bash
# doge-forensics.sh -- READ ONLY. Answers the two questions the triage did not:
#
#   1. Why was there a WEEK of silence, then a payment the moment we started poking?
#   2. Why is there 400k+ DOGE sitting in the hot wallet that nobody has been paid?
#
#   curl -fsSL https://pool.honest.money/install/doge-forensics.sh | sudo bash 2>&1 | tee /tmp/doge-forensics.txt
#   ADDR=D... curl -fsSL .../doge-forensics.sh | sudo bash    # also trace one payout address
#
# Hypotheses it discriminates between:
#   H1  stale flock  -- a crashed run left the lock held, so every */10 cycle
#                       exited instantly for a week until something cleared it
#   H2  cron never fired -- entry present but cron not reading it (bad user field,
#                       missing newline, file perms, cron not restarted)
#   H3  capture works, SEND does not -- ledger grows, sends never leave (threshold,
#                       MAX_TOTAL_SEND_DOGE cap, MAX_BATCHES_PER_RUN throttle)
#   H4  blocks never entered the ledger -- rewards landed in the wallet as float
#                       (no_shares), which is what 400k unallocated looks like
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
CYCLE=${CYCLE:-/var/web/doge-payout-cycle.sh}
RUNDIR=${RUNDIR:-/var/web/runtime/doge-payout}
LOG=${LOG:-/var/log/doge-payout-cycle.log}
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }

echo "doge-forensics $(date -u '+%F %T UTC')"

# ---------------------------------------------------------------- H1 / H2
hr "1. did the cycle actually RUN, every 10 minutes, for the last week?"
echo "-- cron entries seen by cron:"
for f in /etc/cron.d/*; do
  grep -Hn 'doge-payout' "$f" 2>/dev/null | grep -v '^\s*#' | sed 's/^/   /'
done
for f in /etc/cron.d/*doge*; do
  [ -f "$f" ] || continue
  printf '   perms %s owner %s  %s' "$(stat -c%a "$f")" "$(stat -c%U:%G "$f")" "$f"
  tail -c1 "$f" | od -c | head -1 | grep -q '\\n' && echo "  (ends with newline: ok)" || echo "  ** NO TRAILING NEWLINE -- cron IGNORES this file **"
done
echo
echo "-- syslog evidence of the job firing (last 7d, hourly counts):"
journalctl -u cron --since "7 days ago" --no-pager 2>/dev/null \
  | grep -i 'doge-payout-cycle' \
  | awk '{print substr($0,1,13)}' | uniq -c | tail -25 | sed 's/^/   /'
journalctl -u cron --since "7 days ago" --no-pager 2>/dev/null | grep -ci 'doge-payout-cycle' \
  | awk '{print "   total CRON lines mentioning the cycle in 7d: "$1"   (expect ~1000 at */10)"}'
echo
echo "-- lock file (H1: a stale flock silently no-ops every run):"
ls -la "$RUNDIR" 2>/dev/null | sed 's/^/   /'
for L in "$RUNDIR"/*.lock; do
  [ -f "$L" ] || continue
  echo "   $L  mtime=$(date -u -d @"$(stat -c%Y "$L")" '+%F %H:%M UTC')"
  if command -v fuser >/dev/null; then
    H=$(fuser "$L" 2>/dev/null); [ -n "$H" ] && echo "   ** currently held by pid(s):$H **" || echo "   not held right now"
  fi
done
echo
echo "-- run history from the log (one line per run start):"
if [ -f "$LOG" ]; then
  echo "   $LOG mtime=$(date -u -d @"$(stat -c%Y "$LOG")" '+%F %H:%M UTC') size=$(stat -c%s "$LOG")"
  grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$LOG" 2>/dev/null | uniq -c | tail -15 | sed 's/^/   /'
  echo "   -- last 40 lines:"; tail -n 40 "$LOG" | sed 's/^/   /'
else
  echo "   ** $LOG missing -- the cycle has never written here **"
fi
echo
echo "-- other log destinations the cycle may be using:"
grep -nE 'LOG|exec .*>>|tee ' "$CYCLE" 2>/dev/null | head -10 | sed 's/^/   /'
ls -la /var/log/doge* /var/web/runtime/doge-payout/*.log 2>/dev/null | sed 's/^/   /'

# ---------------------------------------------------------------- H3
hr "2. cycle tuning -- can a send even happen?"
grep -nE '^(TOKEN_WINDOW_HOURS|BLOCK_LIMIT|SHARE_WINDOW_MINUTES|MIN_PAYOUT_DOGE|MAX_TOTAL_SEND_DOGE|MAX_BATCHES_PER_RUN|DRY_RUN|CONFIRM)=' "$CYCLE" 2>/dev/null | sed 's/^/   /'
echo "   (MAX_TOTAL_SEND_DOGE / MAX_BATCHES_PER_RUN are the throttles that can"
echo "    make a backlog drain slower than it accumulates -- compare to owed below)"

hr "3. ledger state, by status AND by week"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) doge,
        FROM_UNIXTIME(MIN(created_at)) oldest, FROM_UNIXTIME(MAX(updated_at)) last_touch
     FROM doge_payout_ledger GROUP BY status ORDER BY doge DESC"
MY "SELECT DATE(FROM_UNIXTIME(created_at)) d, status, COUNT(*) n, ROUND(SUM(amount),2) doge
     FROM doge_payout_ledger WHERE created_at > UNIX_TIMESTAMP()-14*86400
     GROUP BY d, status ORDER BY d DESC, doge DESC"
echo "-- rows actually SENT per day (txid present):"
MY "SELECT DATE(FROM_UNIXTIME(IFNULL(paid_at,updated_at))) d, COUNT(*) n, ROUND(SUM(amount),2) doge
     FROM doge_payout_ledger WHERE txid IS NOT NULL AND txid <> ''
       AND IFNULL(paid_at,updated_at) > UNIX_TIMESTAMP()-21*86400
     GROUP BY d ORDER BY d DESC"

# ---------------------------------------------------------------- H4
hr "4. the 400k: blocks found vs DOGE ever allocated to miners"
MY "SELECT DATE(FROM_UNIXTIME(b.time)) d, COUNT(*) blocks, ROUND(SUM(b.amount),2) doge_mined
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-14*86400
     GROUP BY d ORDER BY d DESC"
echo "-- 14d totals: mined vs entered-the-ledger vs actually-sent"
MYN "SELECT CONCAT('   mined  : ', ROUND(IFNULL(SUM(b.amount),0),2))
      FROM blocks b JOIN coins c ON c.id=b.coin_id
      WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-14*86400"
MYN "SELECT CONCAT('   ledgered: ', ROUND(IFNULL(SUM(amount),0),2))
      FROM doge_payout_ledger WHERE created_at > UNIX_TIMESTAMP()-14*86400"
MYN "SELECT CONCAT('   sent    : ', ROUND(IFNULL(SUM(amount),0),2))
      FROM doge_payout_ledger WHERE txid IS NOT NULL AND txid<>''
        AND IFNULL(paid_at,updated_at) > UNIX_TIMESTAMP()-14*86400"
echo "   (mined >> ledgered means capture is losing blocks to no_shares = float)"
echo
echo "-- capture outcomes recorded in the log:"
grep -ohE 'no_shares|captured|skipped|already|insufficient|error' "$LOG" 2>/dev/null | sort | uniq -c | sort -rn | head | sed 's/^/   /'

hr "5. wallet vs obligations"
echo "   spendable : $($DCLI getbalance 2>&1 | head -1)"
$DCLI getwalletinfo 2>/dev/null | grep -E '"balance"|immature|unlocked_until|txcount' | sed 's/^/   /'
MYN "SELECT CONCAT('   owed (ledger unpaid): ', ROUND(IFNULL(SUM(amount),0),2))
      FROM doge_payout_ledger WHERE status<>'paid' AND (txid IS NULL OR txid='')"
echo "   -- last 10 outgoing wallet sends:"
$DCLI listtransactions "*" 40 0 2>/dev/null \
  | grep -E '"category"|"amount"|"time"|"txid"' | paste - - - - | grep send | tail -10 | sed 's/^/   /'

hr "6. top unpaid addresses (who is waiting, and how long)"
MY "SELECT address, COUNT(*) rows_, ROUND(SUM(amount),2) doge,
        FROM_UNIXTIME(MIN(created_at)) waiting_since
     FROM doge_payout_ledger WHERE status<>'paid' AND (txid IS NULL OR txid='')
     GROUP BY address ORDER BY doge DESC LIMIT 15"

if [ -n "${ADDR:-}" ]; then
  hr "7. trace for $ADDR"
  MY "SELECT id, status, ROUND(amount,4) amount, LEFT(IFNULL(txid,'(none)'),24) txid,
          FROM_UNIXTIME(created_at) created, FROM_UNIXTIME(updated_at) touched
       FROM doge_payout_ledger WHERE address='$ADDR' ORDER BY created_at DESC LIMIT 30"
  MY "SELECT ROUND(doge_balance,4) doge_balance FROM accounts WHERE username='$ADDR' OR coinsymbol='DOGE' AND username='$ADDR' LIMIT 5"
fi

echo
echo "read-only -- nothing was modified."
