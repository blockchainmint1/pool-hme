#!/usr/bin/env bash
# doge-payout-revive.sh -- get DOGE payouts to parity with LTC.
#
#   curl -fsSL https://pool.honest.money/install/doge-payout-revive.sh | sudo bash                  # DIAGNOSE (read-only, default)
#   curl -fsSL https://pool.honest.money/install/doge-payout-revive.sh | sudo bash -s RUNONCE       # run one cycle in the cycle's own dry-run mode
#   curl -fsSL https://pool.honest.money/install/doge-payout-revive.sh | sudo bash -s REVIVE CONFIRM # reinstall cadence + unlock wiring, then run live
#
# WHY DOGE IS DIFFERENT FROM LTC
#   LTC is the PARENT chain. Yiimp pays it natively: shares -> earnings ->
#   accounts.balance -> payouts, driven by yiimp-loop2.service. That path is
#   healthy and settles daily.
#   DOGE is an AUX (merged-mined) chain. Yiimp has no native aux payout path at
#   all, so this pool runs a bespoke one: /var/web/doge-payout-cycle.sh, driven
#   by cron, writing doge_payout_ledger + accounts.doge_balance, sending from the
#   dogecoind hot wallet. Nothing in yiimp-loop2 touches DOGE. If that cron is
#   missing, DOGE payouts are simply not running -- everything else can look fine.
#
# THE KNOWN FAILURE MODE
#   Capture must attribute a DOGE block to miners WHILE the `shares` rows for the
#   parent LTC round still exist. Yiimp deletes those rows the moment the parent
#   round is credited (minutes). So the cycle has to run every ~10 minutes. A
#   daily cadence loses nearly every block to `no_shares`, and the reward piles up
#   as unattributable wallet float.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-DIAGNOSE}"
CONFIRM="${2:-}"
CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/yiimp-doge-payout-cycle}"
EVERY_MIN="${EVERY_MIN:-10}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
PASS_ENV=/etc/pool-wallets/passphrase.env
LOCK_DIR=/var/web/runtime/doge-payout
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }

echo "doge-payout-revive v1  $(date -u '+%F %T UTC')  mode=$MODE"
echo

# ---------------------------------------------------------------- 1. the runner
echo "===== 1. is anything actually driving DOGE payouts?"
if [ -f "$CYCLE" ]; then
  echo "  cycle script: $CYCLE  (mtime $(date -u -r "$CYCLE" '+%F %T UTC'))"
  grep -nE '^(TOKEN_WINDOW_HOURS|BLOCK_LIMIT|SHARE_WINDOW_MINUTES|MIN_PAYOUT_DOGE|MAX_TOTAL_SEND_DOGE|MAX_BATCHES_PER_RUN)=' "$CYCLE" | sed 's/^/    /'
else
  echo "  !! $CYCLE MISSING -- there is no DOGE payout runner on this box at all."
fi
echo "  cron entries mentioning the cycle:"
grep -rh 'doge-payout-cycle' /etc/cron.d/* /etc/crontab 2>/dev/null | grep -v '^#' | sed 's/^/    /' || true
if ! grep -rqh 'doge-payout-cycle' /etc/cron.d/* /etc/crontab 2>/dev/null; then
  echo "    (none) <-- THIS is why DOGE payouts stopped. Nothing invokes the cycle."
fi
echo "  systemd timers:"
systemctl list-timers --all --no-pager 2>/dev/null | grep -i doge | sed 's/^/    /' || echo "    (none)"
echo "  last cycle log activity:"
for f in /var/log/doge-payout-cycle.log "$LOCK_DIR"/*.log; do
  [ -f "$f" ] && echo "    $f  last write $(date -u -r "$f" '+%F %T UTC')  ($(wc -l <"$f") lines)"
done
echo

# ---------------------------------------------------------------- 2. the ledger
echo "===== 2. ledger state (what DOGE owes and when it last moved)"
MY "SELECT status, COUNT(*) rows_, ROUND(SUM(amount),2) doge,
           FROM_UNIXTIME(MIN(created_at)) oldest, FROM_UNIXTIME(MAX(updated_at)) newest
    FROM doge_payout_ledger GROUP BY status ORDER BY doge DESC"
echo "  accounts carrying an unpaid doge_balance:"
MY "SELECT COUNT(*) miners, ROUND(SUM(doge_balance),2) doge_owed,
           SUM(doge_payout_address IS NULL OR doge_payout_address='') missing_addr
    FROM accounts WHERE doge_balance > 0"
echo "  top owed:"
MY "SELECT username, ROUND(doge_balance,2) doge, IFNULL(doge_payout_address,'(NONE SET)') dest
    FROM accounts WHERE doge_balance > 0 ORDER BY doge_balance DESC LIMIT 10"
echo

# ------------------------------------------------------- 3. capture vs. blocks
echo "===== 3. are DOGE blocks being captured, or aging out into float?"
MY "SELECT DATE(FROM_UNIXTIME(time)) day, COUNT(*) doge_blocks, ROUND(SUM(amount),2) doge
    FROM blocks WHERE coin_id=(SELECT id FROM coins WHERE symbol='DOGE')
      AND time > UNIX_TIMESTAMP()-14*86400
    GROUP BY day ORDER BY day DESC"
echo "  captured ledger rows per day (should track the block table above):"
MY "SELECT DATE(FROM_UNIXTIME(created_at)) day, COUNT(*) rows_, ROUND(SUM(amount),2) doge
    FROM doge_payout_ledger WHERE created_at > UNIX_TIMESTAMP()-14*86400
    GROUP BY day ORDER BY day DESC"
echo "  share-row survival (capture must beat this purge):"
MY "SELECT COUNT(*) live_share_rows, FROM_UNIXTIME(MIN(time)) oldest_share FROM shares"
echo

# ---------------------------------------------------------------- 4. the wallet
echo "===== 4. hot wallet + unlock wiring"
$DCLI getwalletinfo 2>&1 | grep -E 'balance|unlocked_until|txcount' | sed 's/^/    /'
if [ -f "$PASS_ENV" ]; then
  echo "    $PASS_ENV present ($(stat -c '%a %U:%G' "$PASS_ENV")) -- cycle can unlock on demand"
  grep -q 'DOGE' "$PASS_ENV" && echo "    DOGE passphrase key present" || echo "    !! no DOGE key in $PASS_ENV"
else
  echo "    !! $PASS_ENV MISSING -- cycle cannot unlock; sends will fail with -13"
fi
UNTIL=$($DCLI getwalletinfo 2>/dev/null | sed -n 's/.*"unlocked_until": *\([0-9]*\).*/\1/p')
NOW=$(date +%s)
if [ -n "${UNTIL:-}" ] && [ "${UNTIL:-0}" -gt "$((NOW+7200))" ] 2>/dev/null; then
  echo "    !! wallet is unlocked until $(date -u -d @"$UNTIL" '+%F %T UTC') -- far too long. Should be seconds, per send."
fi
echo

# ------------------------------------------------------------------- 5. verdict
echo "===== VERDICT"
HAVE_CRON=no; grep -rqh 'doge-payout-cycle' /etc/cron.d/* /etc/crontab 2>/dev/null && HAVE_CRON=yes
OWED=$(MYN "SELECT ROUND(IFNULL(SUM(amount),0),2) FROM doge_payout_ledger WHERE status IN ('pending','failed')")
if [ ! -f "$CYCLE" ]; then
  echo "  BLOCKER: the cycle script itself is gone. Restore it from /var/web/*.bak-* before anything else."
elif [ "$HAVE_CRON" = no ]; then
  echo "  BLOCKER: no cron drives the DOGE cycle. ~${OWED} DOGE is captured-but-unsent and"
  echo "           every new block is aging out into unattributable float."
  echo "  FIX:     re-run this script as: ... | sudo bash -s REVIVE CONFIRM"
else
  echo "  cadence is installed. If payouts still are not landing, read section 2 (status="
  echo "  failed rows) and section 4 (wallet lock). ${OWED} DOGE currently unpaid."
fi

# ---------------------------------------------------------------- 6. RUNONCE
if [ "$MODE" = RUNONCE ]; then
  echo
  echo "===== 6. one cycle, cycle's own dry-run mode"
  [ -f "$CYCLE" ] || { echo "  no cycle script"; exit 1; }
  DRY_RUN=1 bash "$CYCLE" 2>&1 | tail -60
  exit 0
fi

# ---------------------------------------------------------------- 7. REVIVE
if [ "$MODE" = REVIVE ]; then
  if [ "$CONFIRM" != CONFIRM ]; then
    echo
    echo "REVIVE needs the word CONFIRM as the second argument. Nothing changed."
    exit 0
  fi
  echo
  echo "===== 7. REVIVE"
  [ -f "$CYCLE" ] || { echo "  FATAL: $CYCLE missing"; exit 1; }
  [ -f "$PASS_ENV" ] || { echo "  FATAL: $PASS_ENV missing -- sends would fail. Restore it first."; exit 1; }

  STAMP=$(date +%Y%m%d-%H%M%S)
  cp -a "$CYCLE" "$CYCLE.bak-$STAMP"
  # cadence does the batching work; keep the capture window sane
  sed -i -e 's/^TOKEN_WINDOW_HOURS=.*/TOKEN_WINDOW_HOURS="24"/' "$CYCLE"
  bash -n "$CYCLE" || { echo "  FATAL: syntax error after patch, restoring"; cp -a "$CYCLE.bak-$STAMP" "$CYCLE"; exit 1; }
  echo "  cycle settings normalised (backup $CYCLE.bak-$STAMP)"

  mkdir -p "$LOCK_DIR"
  cat > "$CRON_FILE" <<EOF
# DOGE merged-mining payout cycle.
# MUST stay on a short interval: capture has to attribute a block before yiimp
# deletes the parent LTC round's \`shares\` rows. A daily cadence loses blocks.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/$EVERY_MIN * * * * root flock -n $LOCK_DIR/doge-payout-cycle.lock $CYCLE >> /var/log/doge-payout-cycle.log 2>&1
EOF
  chmod 644 "$CRON_FILE"
  echo "  installed $CRON_FILE (*/$EVERY_MIN)"
  sed 's/^/    /' "$CRON_FILE"

  # drop any competing daily entry left over from the old scheduler
  for f in /etc/cron.d/yiimp-payout-schedule; do
    if [ -f "$f" ] && grep -q 'doge-payout-cycle' "$f"; then
      cp -a "$f" "$f.bak-$STAMP"; sed -i '/doge-payout-cycle/d' "$f"
      grep -qE '^[^#[:space:]]' "$f" || rm -f "$f"
      echo "  removed competing daily entry from $f"
    fi
  done

  systemctl restart cron 2>/dev/null || service cron reload 2>/dev/null || true
  echo "  cron reloaded"
  echo
  echo "  running one live cycle now:"
  flock -n "$LOCK_DIR/doge-payout-cycle.lock" bash "$CYCLE" 2>&1 | tail -40
  echo
  echo "  ledger after:"
  MY "SELECT status, COUNT(*) rows_, ROUND(SUM(amount),2) doge FROM doge_payout_ledger GROUP BY status"
  echo
  echo "  Watch it: sudo tail -f /var/log/doge-payout-cycle.log"
  exit 0
fi

echo
echo "read-only: nothing on this box was modified."
