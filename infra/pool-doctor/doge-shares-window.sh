#!/usr/bin/env bash
# doge-shares-window.sh -- why does EVERY DOGE block capture as `no_shares`?
#
#   curl -fsSL https://pool.honest.money/install/doge-shares-window.sh | sudo bash
#
# Read-only. Nothing is written, nothing is sent.
#
# CONTEXT
#   The DOGE cycle now runs (the wrapper-lock deadlock is fixed), but capture
#   reports no_shares for all 262 blocks, incl. blocks only ~1h old. That is no
#   longer a cadence problem -- a 1h-old block should still have live parent
#   shares if the window/join is right. This script proves which of these is
#   true:
#     A. `shares` really is empty / stale        -> stratum or splitter problem
#     B. shares exist but outside the cycle's window (SHARE_WINDOW_MINUTES)
#     C. shares exist in-window but are filtered out (algo/coinid/error/valid)
#     D. shares exist but the join key the cycle uses is NULL/mismatched
#   And on the payout side, why 251 pending rows / ~650 DOGE never send.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { echo; echo "===== $1"; }

echo "doge-shares-window v2  $(date -u '+%F %T UTC')  READ-ONLY"

# ------------------------------------------------------------------ 1. window
hr "1. what window / filters does the cycle actually use?"
if [ -f "$CYCLE" ]; then
  grep -nE '^[A-Z_]+=' "$CYCLE" | sed 's/^/    /'
  echo "  --- lines mentioning shares (this is the capture join):"
  grep -nE 'shares|no_shares|SHARE_WINDOW' "$CYCLE" | head -40 | sed 's/^/    /'
  echo "  --- helper scripts the cycle calls:"
  grep -noE '(/var/web|/home/ubuntu)[A-Za-z0-9_./-]+\.(py|sh)' "$CYCLE" | sort -u -t: -k2 | sed 's/^/    /'
else
  echo "  !! $CYCLE missing"
fi

# ------------------------------------------------------------------ 2. shares
hr "2. is the shares table alive at all? (A vs B/C/D)"
MY "SELECT COUNT(*) rows_now,
        FROM_UNIXTIME(MIN(time)) oldest,
        FROM_UNIXTIME(MAX(time)) newest,
        ROUND((UNIX_TIMESTAMP()-MAX(time))/60,1) newest_age_min,
        ROUND((MAX(time)-MIN(time))/60,1) retention_span_min
     FROM shares;"
echo "  ^ retention_span_min is the REAL share window available to capture."
echo "    If it is smaller than the cycle's SHARE_WINDOW_MINUTES, every block"
echo "    older than that span is unrecoverable no matter how we join."
MY "SELECT algo, coinid, COUNT(*) n, SUM(valid) valid_n, SUM(error) err_n,
        FROM_UNIXTIME(MIN(time)) oldest, FROM_UNIXTIME(MAX(time)) newest
     FROM shares GROUP BY algo, coinid ORDER BY n DESC LIMIT 10;"
echo "  ^ if coinid here is the LTC coin id, the capture must match on it."
MYN "SELECT id, symbol FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU');" | sed 's/^/    coin /'

# ------------------------------------------------------------------ 3. newest block vs shares
hr "3. newest DOGE blocks vs the shares that existed in their window"
DOGEID=$(MYN "SELECT id FROM coins WHERE symbol='DOGE' LIMIT 1;")
LTCID=$(MYN  "SELECT id FROM coins WHERE symbol='LTC'  LIMIT 1;")
echo "  doge coin_id=$DOGEID  ltc coin_id=$LTCID"
for W in 10 30 60 240; do
  echo "  --- share rows within +/- ${W} min of each of the 5 newest DOGE blocks:"
  MY "SELECT b.height, FROM_UNIXTIME(b.time) block_time,
          (SELECT COUNT(*) FROM shares s
             WHERE s.time BETWEEN b.time-${W}*60 AND b.time+${W}*60) shares_any,
          (SELECT COUNT(*) FROM shares s
             WHERE s.coinid=${LTCID:-0}
               AND s.time BETWEEN b.time-${W}*60 AND b.time+${W}*60) shares_ltc,
          (SELECT COUNT(*) FROM shares s
             WHERE s.valid=1 AND s.error=0
               AND s.time BETWEEN b.time-${W}*60 AND b.time+${W}*60) shares_valid
       FROM blocks b WHERE b.coin_id=${DOGEID:-0}
       ORDER BY b.time DESC LIMIT 5;"
done
echo "  READ THIS: shares_any=0 for a 1h-old block => the shares table is being"
echo "  purged faster than the cycle can run (cadence/retention), not a join bug."
echo "  shares_any>0 but shares_ltc=0 => the capture's coinid filter is wrong."
echo "  shares_ltc>0 but capture still says no_shares => join key / valid filter."

# ------------------------------------------------------------------ 4. timezone
hr "4. TIMEZONE SKEW CHECK (suspected second bug)"
echo "  real UTC now      : $(date -u '+%F %T')"
echo "  box local now     : $(date '+%F %T %Z')"
echo "  mysql now()       : $(MYN 'SELECT NOW();')"
echo "  mysql UTC_TIMESTAMP: $(MYN 'SELECT UTC_TIMESTAMP();')"
echo "  mysql time_zone   : $(MYN "SELECT @@session.time_zone, @@global.time_zone;")"
echo "  python naive now  : $(python3 -c 'import datetime;print(datetime.datetime.now())' 2>/dev/null)"
echo "  python utc now    : $(python3 -c 'import datetime;print(datetime.datetime.utcnow())' 2>/dev/null)"
DOGEID=$(MYN "SELECT id FROM coins WHERE symbol='DOGE' LIMIT 1;")
echo "  --- newest DOGE block, raw epoch vs every rendering:"
MY "SELECT height, time AS raw_epoch,
        FROM_UNIXTIME(time) mysql_render,
        UNIX_TIMESTAMP()-time age_seconds
     FROM blocks WHERE coin_id=${DOGEID:-0} ORDER BY time DESC LIMIT 3;"
echo "  ^ COMPARE age_seconds to how old that block really is. If the cycle"
echo "    printed a time ~2h LATER than mysql_render for the same height, the"
echo "    cycle is adding a tz offset and its 60-min window lands in the future."

# ------------------------------------------------------------------ 5. real schemas
hr "5. actual column names (previous run guessed wrong)"
for T in earnings doge_payout_ledger hashstats accounts; do
  echo "  --- $T"
  MYN "SHOW COLUMNS FROM $T;" | awk '{printf "      %s %s\n",$1,$2}'
done

# ------------------------------------------------------------------ 6. durable history
hr "6. durable per-miner history that survives the shares purge"
echo "  --- hashstats coverage (candidate attribution source):"
MY "SELECT COUNT(*) rows_n, MIN(time) min_t, MAX(time) max_t FROM hashstats;" 2>&1 | head -8
echo "  --- earnings coverage:"
MY "SELECT COUNT(*) rows_n FROM earnings;" 2>&1 | head -8

# ------------------------------------------------------------------ 7. payout side
hr "7. pending ledger groups vs MIN_PAYOUT_DOGE=200"
MY "SELECT status, COUNT(*) rows_n, ROUND(SUM(amount),4) doge
     FROM doge_payout_ledger GROUP BY status ORDER BY doge DESC;"
echo "  --- pending grouped by whatever address column exists:"
ADDRCOL=$(MYN "SHOW COLUMNS FROM doge_payout_ledger;" | awk '{print $1}' | grep -iE 'address|addr' | head -1)
echo "      using ledger column: ${ADDRCOL:-<none found>}"
if [ -n "${ADDRCOL:-}" ]; then
  MY "SELECT $ADDRCOL addr, COUNT(*) rows_n, ROUND(SUM(amount),4) doge
       FROM doge_payout_ledger WHERE status='pending'
       GROUP BY $ADDRCOL ORDER BY doge DESC LIMIT 15;"
fi
echo "  --- what a HEALTHY captured block looked like (the 1609 paid rows):"
MY "SELECT * FROM doge_payout_ledger WHERE status='paid' ORDER BY id DESC LIMIT 3\G" 2>&1 | head -40

hr "verdict inputs collected -- nothing was changed."
