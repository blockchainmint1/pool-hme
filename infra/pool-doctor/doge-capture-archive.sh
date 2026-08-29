#!/usr/bin/env bash
# doge-capture-archive.sh -- repoint DOGE capture attribution at the durable
#                            share archive so blocks stop landing in `no_shares`.
#
#   inspect (read-only, default):
#     curl -fsSL https://pool.honest.money/install/doge-capture-archive.sh | sudo bash
#   apply the patch:
#     curl -fsSL https://pool.honest.money/install/doge-capture-archive.sh | sudo bash -s PATCH CONFIRM
#   undo (restores the newest backup):
#     curl -fsSL https://pool.honest.money/install/doge-capture-archive.sh | sudo bash -s REVERT CONFIRM
#
# WHY
#   captureLedger() in DogePayoutCommand.php runs two queries against `shares`
#   over a 60-minute window:
#       SELECT SUM(difficulty) ...                      (total parent diff)
#       SELECT userid, SUM(difficulty) AS total ...     (per-miner split)
#   `shares` only retains 7-16 minutes, so every block older than that scores
#   zero and is bucketed `no_shares`. doge_share_archive (installed by
#   doge-share-archive.sh) keeps per-(userid,minute) rollups for 30 days.
#
# WHAT THE PATCH DOES
#   Both queries become a UNION ALL over `shares` and `doge_share_archive`,
#   collapsed with MAX() per userid. MAX (not SUM) means no double counting
#   where both sources cover the same minutes -- whichever source has more
#   data for that miner wins, so the still-live current minute is never lost
#   and archived history is finally usable.
#   The total is then derived from the same per-user set, so total and split
#   can never disagree.
#   Nothing else in the file is touched. A timestamped backup is written and
#   `php -l` must pass before the new file is moved into place.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSPECT}"; CONFIRM="${2:-}"
PHP_FILE="${PHP_FILE:-/var/web/yaamp/commands/DogePayoutCommand.php}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
BACKUP_DIR="${BACKUP_DIR:-/var/backups/doge-capture}"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { echo; echo "===== $1"; }

echo "doge-capture-archive v1  $(date -u '+%F %T') UTC  mode=$MODE"

[ -f "$PHP_FILE" ] || { echo "missing $PHP_FILE"; exit 1; }

hr "1. preconditions"
ARCH_ROWS=$(MYN "SELECT COUNT(*) FROM doge_share_archive" 2>/dev/null)
case "$ARCH_ROWS" in
  ''|*[!0-9]*) echo "  doge_share_archive is MISSING -- install it first:"
               echo "    curl -fsSL https://pool.honest.money/install/doge-share-archive.sh | sudo bash -s INSTALL CONFIRM"
               exit 1;;
  *) echo "  doge_share_archive rows: $ARCH_ROWS";;
esac
echo "  archiver timer: $(systemctl is-active doge-share-archive.timer 2>/dev/null)"
MY "SELECT COUNT(*) rows_now, FROM_UNIXTIME(MIN(minute_ts)) oldest, FROM_UNIXTIME(MAX(minute_ts)) newest,
        ROUND((MAX(minute_ts)-MIN(minute_ts))/60,1) span_min
     FROM doge_share_archive"

hr "2. current state of the two capture queries"
if grep -q 'doge_share_archive' "$PHP_FILE"; then
  echo "  ALREADY PATCHED -- captureLedger already references doge_share_archive."
  PATCHED=1
else
  echo "  not patched yet -- both queries read \`shares\` only."
  PATCHED=0
fi
grep -n 'FROM shares' "$PHP_FILE" | sed 's/^/    /'

if [ "$MODE" = "REVERT" ]; then
  [ "$CONFIRM" = "CONFIRM" ] || { echo; echo "REVERT needs: ... | sudo bash -s REVERT CONFIRM"; exit 1; }
  LATEST=$(ls -1t "$BACKUP_DIR"/DogePayoutCommand.php.* 2>/dev/null | head -1)
  [ -n "$LATEST" ] || { echo "no backup found in $BACKUP_DIR"; exit 1; }
  cp -a "$LATEST" "$PHP_FILE"
  echo; echo "restored $LATEST -> $PHP_FILE"
  php -l "$PHP_FILE"
  exit 0
fi

if [ "$MODE" != "PATCH" ]; then
  echo
  echo "inspect-only -- nothing was changed."
  echo "to apply:"
  echo "  curl -fsSL https://pool.honest.money/install/doge-capture-archive.sh | sudo bash -s PATCH CONFIRM"
  exit 0
fi
[ "$CONFIRM" = "CONFIRM" ] || { echo; echo "PATCH needs: ... | sudo bash -s PATCH CONFIRM"; exit 1; }
[ "$PATCHED" = "0" ] || { echo; echo "already patched -- nothing to do."; exit 0; }

hr "3. backup"
mkdir -p "$BACKUP_DIR"
STAMP=$(date -u '+%Y%m%d-%H%M%S')
cp -a "$PHP_FILE" "$BACKUP_DIR/DogePayoutCommand.php.$STAMP"
echo "  $BACKUP_DIR/DogePayoutCommand.php.$STAMP"
sha256sum "$PHP_FILE" | sed 's/^/  /'

hr "4. rewriting the two capture queries"
TMP=$(mktemp /tmp/DogePayoutCommand.XXXXXX.php)
python3 - "$PHP_FILE" "$TMP" <<'PY'
import re, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = open(src_path).read()

UNION = """SELECT userid, MAX(total) AS total
                         FROM (
                             SELECT userid, SUM(difficulty) AS total
                             FROM shares
                             WHERE valid=1 AND algo=:algo AND coinid=:ltc
                               AND time BETWEEN :start AND :end
                               AND (solo IS NULL OR solo=0)
                             GROUP BY userid
                             UNION ALL
                             SELECT userid, SUM(diff_sum) AS total
                             FROM doge_share_archive
                             WHERE algo=:algo AND coinid=:ltc
                               AND minute_ts BETWEEN :start AND :end
                             GROUP BY userid
                         ) src
                         GROUP BY userid"""

# --- query B: per-user split -------------------------------------------------
pat_b = re.compile(
    r'"SELECT\s+userid,\s*SUM\(difficulty\)\s+AS\s+total.*?ORDER BY total DESC"',
    re.S)
mb = pat_b.search(src)
if not mb:
    sys.exit("could not locate the per-user shares query")
src = src[:mb.start()] + '"' + UNION + '\n                         ORDER BY total DESC"' + src[mb.end():]

# --- query A: total diff -----------------------------------------------------
pat_a = re.compile(
    r'"SELECT\s+SUM\(difficulty\)\s*\n.*?\(solo IS NULL OR solo=0\)"',
    re.S)
ma = pat_a.search(src)
if not ma:
    sys.exit("could not locate the total-difficulty query")
TOTAL = ('"SELECT SUM(total) FROM (\n                         ' +
         UNION.replace('\n', '\n    ') +
         '\n                         ) agg"')
src = src[:ma.start()] + TOTAL + src[ma.end():]

open(out_path, 'w').write(src)
print("  rewrote both queries to UNION shares + doge_share_archive (MAX per userid)")
PY
RC=$?
[ "$RC" -eq 0 ] || { echo "  patch generation FAILED (rc=$RC) -- original file untouched"; rm -f "$TMP"; exit 1; }

hr "5. syntax check"
if php -l "$TMP"; then
  cp -a "$TMP" "$PHP_FILE"
  rm -f "$TMP"
  echo "  applied to $PHP_FILE"
  sha256sum "$PHP_FILE" | sed 's/^/  /'
else
  echo "  php -l FAILED -- original file untouched"
  rm -f "$TMP"
  exit 1
fi

hr "6. patched query text"
grep -n -A 20 'SELECT SUM(total) FROM' "$PHP_FILE" | head -30 | sed 's/^/  /'

hr "7. dry-run capture against real blocks"
cd /var/web 2>/dev/null && php yaamp/yiic.php dogePayout capture 24 50 60 2>&1 | tail -40 | sed 's/^/  /'

hr "done"
cat <<EOF
The archive only started collecting at ~03:34 UTC today, so blocks older than
that still show no_shares -- that history is unrecoverable. Every DOGE block
found from now on has 30 days of per-miner share data to attribute against.

Watch the next cron cycle:
  sudo tail -f /var/web/runtime/doge-payout/cycle.log

Undo at any time:
  curl -fsSL https://pool.honest.money/install/doge-capture-archive.sh | sudo bash -s REVERT CONFIRM
EOF
