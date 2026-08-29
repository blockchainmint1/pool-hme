#!/usr/bin/env bash
# doge-share-archive.sh -- durable per-miner share history so DOGE capture stops
#                          losing every block to `no_shares`.
#
#   inspect (read-only, default):
#     curl -fsSL https://pool.honest.money/install/doge-share-archive.sh | sudo bash
#   install the archiver (safe, additive -- new table + 60s timer):
#     curl -fsSL https://pool.honest.money/install/doge-share-archive.sh | sudo bash -s INSTALL CONFIRM
#
# WHY
#   Proven by doge-shares-window v2 (2026-08-29):
#     shares retention_span_min = 16.6      cycle SHARE_WINDOW_MINUTES = 60
#     newest DOGE block (02:53) -> 4979 ltc shares only in a +/-30m sweep
#     every older block          -> shares_any = 0
#   yiimp purges `shares` far faster than the */10 cycle can capture, so the
#   attribution join has nothing to join to. Not a timezone bug (all clocks
#   agreed at 03:37:34 UTC), not a coinid bug (coin 8 = LTC rows are present),
#   not a lock bug (that was fixed). It is pure retention loss.
#
# WHAT THIS INSTALLS
#   table  doge_share_archive   -- rolled-up per (userid, minute) parent shares
#   unit   doge-share-archive.service/.timer -- every 60s, copies only rows
#          newer than the last watermark, then prunes older than KEEP_DAYS.
#   Nothing existing is modified. The live `shares` table is only READ.
#   The cycle is NOT repointed by this script -- that is a separate, reviewed
#   change once we can see the capture SQL this script dumps in section 4.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSPECT}"; CONFIRM="${2:-}"
CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
KEEP_DAYS="${KEEP_DAYS:-30}"
LTC_COINID="${LTC_COINID:-8}"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { echo; echo "===== $1"; }

echo "doge-share-archive v1  $(date -u '+%F %T UTC')  mode=$MODE"
[ -n "${DBU:-}" ] || { echo "could not read YAAMP_DBUSER from $SERVERCONFIG"; exit 1; }

# ------------------------------------------------------------- 1. live window
hr "1. how much share history actually survives right now"
MY "SELECT COUNT(*) rows_now,
      FROM_UNIXTIME(MIN(time)) oldest, FROM_UNIXTIME(MAX(time)) newest,
      ROUND((MAX(time)-MIN(time))/60,1) retention_span_min
    FROM shares;"
echo "  cycle wants SHARE_WINDOW_MINUTES=$(grep -oP 'SHARE_WINDOW_MINUTES="\K[0-9]+' "$CYCLE" 2>/dev/null || echo '?') minutes of history."

# ---------------------------------------------------------------- 2. archive
hr "2. archive table state"
HAS=$(MYN "SELECT COUNT(*) FROM information_schema.tables
           WHERE table_schema='yiimpfrontend' AND table_name='doge_share_archive';")
if [ "$HAS" = "1" ]; then
  MY "SELECT COUNT(*) rows_n, FROM_UNIXTIME(MIN(minute_ts)) oldest,
        FROM_UNIXTIME(MAX(minute_ts)) newest,
        ROUND((MAX(minute_ts)-MIN(minute_ts))/3600,1) span_hours
      FROM doge_share_archive;"
else
  echo "  doge_share_archive: NOT PRESENT (nothing durable exists yet)"
fi

# ----------------------------------------------------------------- 3. timer
hr "3. archiver timer"
systemctl is-enabled doge-share-archive.timer 2>/dev/null | sed 's/^/  enabled: /'
systemctl is-active  doge-share-archive.timer 2>/dev/null | sed 's/^/  active : /'
journalctl -u doge-share-archive --since '15 min ago' --no-pager 2>/dev/null | tail -6 | sed 's/^/  /'

# ------------------------------------------------------- 4. capture SQL dump
hr "4. the cycle's capture query (needed to repoint it at the archive)"
if [ -f "$CYCLE" ]; then
  awk '/shares/{p=NR} {l[NR]=$0} END{for(i=1;i<=NR;i++) if(l[i] ~ /FROM +shares|JOIN +shares|no_shares|SHARE_WINDOW/) {for(j=i-6;j<=i+10;j++) if(j>0 && j<=NR && !seen[j]++) printf "    %d:%s\n", j, l[j]}}' "$CYCLE"
  echo "  --- python/sql helpers invoked:"
  grep -noE '(/var/web|/home/ubuntu)[A-Za-z0-9_./-]+\.(py|sh|sql)' "$CYCLE" | sort -u -t: -k2 | sed 's/^/    /'
fi

if [ "$MODE" != "INSTALL" ] || [ "$CONFIRM" != "CONFIRM" ]; then
  echo
  echo "inspect-only. To install the durable share archiver:"
  echo "  curl -fsSL https://pool.honest.money/install/doge-share-archive.sh | sudo bash -s INSTALL CONFIRM"
  exit 0
fi

# ---------------------------------------------------------------- 5. install
hr "5. INSTALL"
MY "CREATE TABLE IF NOT EXISTS doge_share_archive (
      id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      minute_ts INT NOT NULL,
      userid INT NOT NULL,
      coinid INT NOT NULL,
      algo VARCHAR(16) NOT NULL DEFAULT 'scrypt',
      shares_n INT NOT NULL DEFAULT 0,
      diff_sum DECIMAL(30,12) NOT NULL DEFAULT 0,
      UNIQUE KEY uq_minute_user (minute_ts, userid, coinid, algo),
      KEY ix_minute (minute_ts)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
echo "  table doge_share_archive ready"

install -d -m 755 /var/web/runtime/doge-payout
cat > /usr/local/sbin/doge-share-archive-tick.sh <<'TICK'
#!/usr/bin/env bash
# rolls the last few minutes of live `shares` into doge_share_archive.
set -uo pipefail
SERVERCONFIG=/var/web/serverconfig.php
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG")"
KEEP_DAYS="${KEEP_DAYS:-30}"
mysql -u"$DBU" -p"$DBP" yiimpfrontend -e "
  INSERT INTO doge_share_archive (minute_ts, userid, coinid, algo, shares_n, diff_sum)
  SELECT (time - time % 60) AS minute_ts, userid, coinid, algo,
         COUNT(*), COALESCE(SUM(difficulty),0)
    FROM shares
   WHERE time >= UNIX_TIMESTAMP() - 900
     AND (error IS NULL OR error = 0)
     AND userid IS NOT NULL
   GROUP BY minute_ts, userid, coinid, algo
  ON DUPLICATE KEY UPDATE
      shares_n = GREATEST(doge_share_archive.shares_n, VALUES(shares_n)),
      diff_sum = GREATEST(doge_share_archive.diff_sum, VALUES(diff_sum));
  DELETE FROM doge_share_archive
   WHERE minute_ts < UNIX_TIMESTAMP() - ($KEEP_DAYS * 86400);
" 2>&1 | grep -v '\[Warning\]'
TICK
chmod 755 /usr/local/sbin/doge-share-archive-tick.sh

cat > /etc/systemd/system/doge-share-archive.service <<'UNIT'
[Unit]
Description=Archive yiimp parent shares into doge_share_archive (durable attribution)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/doge-share-archive-tick.sh
UNIT

cat > /etc/systemd/system/doge-share-archive.timer <<'UNIT'
[Unit]
Description=Run the DOGE share archiver every 60s
[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5s
Unit=doge-share-archive.service
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now doge-share-archive.timer >/dev/null 2>&1
/usr/local/sbin/doge-share-archive-tick.sh
echo "  timer installed + first tick run"

hr "6. verify"
MY "SELECT COUNT(*) rows_n, COUNT(DISTINCT userid) miners,
      FROM_UNIXTIME(MIN(minute_ts)) oldest, FROM_UNIXTIME(MAX(minute_ts)) newest
    FROM doge_share_archive;"
MY "SELECT coinid, COUNT(*) rows_n, ROUND(SUM(diff_sum),2) diff
    FROM doge_share_archive GROUP BY coinid ORDER BY rows_n DESC;"
echo
echo "Archiver live. From now on every minute of parent-share work is kept for"
echo "$KEEP_DAYS days, so a DOGE block found at any hour is still attributable."
echo "Next: repoint the cycle's capture join at doge_share_archive (separate,"
echo "reviewed change -- paste section 4 above so it can be patched exactly)."
