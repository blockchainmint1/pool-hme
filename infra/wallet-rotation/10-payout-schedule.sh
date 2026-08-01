#!/usr/bin/env bash
# Move LTC + DOGE payouts from "every ~30 min" to once per day.
#
#   sudo bash 10-payout-schedule.sh            # dry run: show what would change
#   sudo bash 10-payout-schedule.sh CONFIRM    # apply
#
# Why: we find an LTC/DOGE block every couple of hours at best. Running the
# payout cycle every 30 minutes means lots of tiny sendmany batches, one tx fee
# each, and a pile of dust rows that litecoind rejects (-3 invalid amount).
# Batching once a day means bigger per-miner amounts, fewer fees, no dust.
#
# Two independent schedules are involved:
#
#   1. yiimp core (LTC and every standard coin) -- runPayouts is rate-limited by
#      YAAMP_PAYMENTS_FREQ in /var/web/serverconfig.php. loop2 checks the clock
#      every pass and only pays when that many seconds have elapsed.
#   2. DOGE -- not on the yiimp path at all; it runs from the custom
#      /var/web/doge-payout-cycle.sh cron entry (see 03-patch-payout-cron.sh).
#
# Optional: raise the per-coin minimum so a miner is only paid once their
# balance is worth the fee. Set PAYOUT_MIN_LTC / PAYOUT_MIN_DOGE to skip.
set -euo pipefail

CONFIRM="${1:-}"
FREQ_SECONDS="${FREQ_SECONDS:-86400}"        # 24h
DOGE_CRON_HOUR="${DOGE_CRON_HOUR:-6}"        # 06:00 UTC daily
DOGE_CRON_MIN="${DOGE_CRON_MIN:-15}"
PAYOUT_MIN_LTC="${PAYOUT_MIN_LTC:-0.01}"
PAYOUT_MIN_DOGE="${PAYOUT_MIN_DOGE:-50}"
SERVERCONFIG="${SERVERCONFIG:-/var/web/serverconfig.php}"
DOGE_CYCLE="${DOGE_CYCLE:-/var/web/doge-payout-cycle.sh}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$SERVERCONFIG" ] || { echo "FATAL: $SERVERCONFIG not found"; exit 1; }

APPLY=false
[ "$CONFIRM" = "CONFIRM" ] && APPLY=true
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "=== Payout schedule -> once per day ==="
echo "Mode           : $([ "$APPLY" = true ] && echo APPLY || echo 'DRY RUN')"
echo "yiimp freq     : ${FREQ_SECONDS}s ($((FREQ_SECONDS/3600))h)"
echo "DOGE cron      : ${DOGE_CRON_MIN} ${DOGE_CRON_HOUR} * * * (UTC)"
echo "payout_min LTC : ${PAYOUT_MIN_LTC:-<unchanged>}"
echo "payout_min DOGE: ${PAYOUT_MIN_DOGE:-<unchanged>}"
echo

# ---------------------------------------------------------------- 1. yiimp ---
CUR_FREQ="$(sed -n "s/.*define( *'YAAMP_PAYMENTS_FREQ' *, *\([0-9*]*\).*/\1/p" "$SERVERCONFIG" | head -1)"
echo "[1/3] yiimp YAAMP_PAYMENTS_FREQ"
echo "      current: ${CUR_FREQ:-<undefined, yiimp default>}  ->  new: $FREQ_SECONDS"
if [ "$APPLY" = true ]; then
  cp -a "$SERVERCONFIG" "$SERVERCONFIG.bak-$STAMP"
  if [ -n "$CUR_FREQ" ]; then
    sed -i "s/define( *'YAAMP_PAYMENTS_FREQ' *,[^)]*)/define('YAAMP_PAYMENTS_FREQ', $FREQ_SECONDS)/" "$SERVERCONFIG"
  else
    printf "\n// once-a-day payouts (infra/wallet-rotation/10-payout-schedule.sh)\ndefine('YAAMP_PAYMENTS_FREQ', %s);\n" \
      "$FREQ_SECONDS" >> "$SERVERCONFIG"
  fi
  grep -n "YAAMP_PAYMENTS_FREQ" "$SERVERCONFIG"
  echo "      backup: $SERVERCONFIG.bak-$STAMP"
fi
echo

# ----------------------------------------------------------------- 2. DOGE ---
# The real schedule lives in /etc/cron.d/yiimp-doge-payout-cycle (system crontab
# with a user field), NOT root's crontab. Treat the cron.d file as canonical and
# strip any duplicate doge lines out of root's crontab.
CRON_D="${CRON_D:-/etc/cron.d/yiimp-doge-payout-cycle}"
DOGE_CRON_USER="${DOGE_CRON_USER:-ubuntu}"
DOGE_LOG="${DOGE_LOG:-/var/web/runtime/doge-payout/cron-wrapper.log}"
echo "[2/3] DOGE cron entry ($DOGE_CYCLE)"
if [ ! -f "$DOGE_CYCLE" ]; then
  echo "      WARNING: $DOGE_CYCLE missing -- skipping DOGE schedule."
else
  echo "      existing schedules found:"
  grep -rn "doge-payout-cycle" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null \
    | sed 's/^/        /' || echo "        (none)"
  NEW_LINE="$DOGE_CRON_MIN $DOGE_CRON_HOUR * * * $DOGE_CRON_USER cd /var/web && $DOGE_CYCLE >> $DOGE_LOG 2>&1"
  echo "      new ($CRON_D):  $NEW_LINE"
  if [ "$APPLY" = true ]; then
    [ -f "$CRON_D" ] && cp -a "$CRON_D" "/var/backups/$(basename "$CRON_D").bak-$STAMP"
    printf '# Managed by infra/wallet-rotation/10-payout-schedule.sh (%s)\n# DOGE payouts run once per day; see also YAAMP_PAYMENTS_FREQ.\nSHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s\n' \
      "$STAMP" "$NEW_LINE" > "$CRON_D"
    chmod 0644 "$CRON_D"; chown root:root "$CRON_D"
    echo "      wrote $CRON_D"
    # Drop duplicate entries from root's crontab (an earlier run of this script
    # may have added one there).
    CRONTAB_NOW="$(crontab -l 2>/dev/null || true)"
    if echo "$CRONTAB_NOW" | grep -q "doge-payout-cycle"; then
      echo "$CRONTAB_NOW" > "/var/backups/root-crontab-$STAMP.txt"
      echo "$CRONTAB_NOW" | grep -v "doge-payout-cycle" | sed '/^$/d' | crontab -
      echo "      removed duplicate doge line from root crontab (backup: /var/backups/root-crontab-$STAMP.txt)"
    fi
    echo "      active schedules now:"
    grep -rn "doge-payout-cycle" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | sed 's/^/        /'
  fi
fi
echo


# ----------------------------------------------------------- 3. payout_min ---
echo "[3/3] coins.payout_min"
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG")"
MYSQL=(mysql "-u${DBU}" "-p${DBP}" yiimpfrontend -N -B -e)
"${MYSQL[@]}" "SELECT id, symbol, payout_min FROM coins WHERE symbol IN ('LTC','DOGE');" \
  | awk '{printf "      id=%s %s payout_min=%s\n", $1, $2, $3}'
if [ "$APPLY" = true ]; then
  [ -n "$PAYOUT_MIN_LTC" ]  && "${MYSQL[@]}" "UPDATE coins SET payout_min=$PAYOUT_MIN_LTC  WHERE symbol='LTC';"
  [ -n "$PAYOUT_MIN_DOGE" ] && "${MYSQL[@]}" "UPDATE coins SET payout_min=$PAYOUT_MIN_DOGE WHERE symbol='DOGE';"
  echo "      after:"
  "${MYSQL[@]}" "SELECT id, symbol, payout_min FROM coins WHERE symbol IN ('LTC','DOGE');" \
    | awk '{printf "      id=%s %s payout_min=%s\n", $1, $2, $3}'
fi
echo

if [ "$APPLY" != true ]; then
  echo "DRY RUN -- nothing changed. Re-run with CONFIRM."
  exit 0
fi

# yiimp reads serverconfig.php per process; bounce the loops so the new value
# takes effect immediately instead of at the next natural restart.
for unit in yiimp-loop2 yiimp-loop2.service loop2; do
  if systemctl list-units --all --type=service --no-legend | grep -q "^${unit}"; then
    systemctl restart "$unit" && echo "restarted $unit"
    break
  fi
done

cat <<'EOF'

Done.

WHAT CHANGES
  * LTC (and all standard yiimp coins) now pay at most once per 24h.
  * DOGE runs once a day from cron instead of every 30 minutes.
  * Miners below payout_min simply accumulate -- nothing is lost, and the dust
    rows that litecoind rejected as "invalid amount" stop being created.

VERIFY
  grep YAAMP_PAYMENTS_FREQ /var/web/serverconfig.php
  crontab -l | grep doge-payout-cycle
  mysql -u<user> -p<pass> yiimpfrontend -e \
    "SELECT symbol,payout_min FROM coins WHERE symbol IN ('LTC','DOGE');"

  Then, after the first daily run:
  mysql ... -e "SELECT idcoin, completed, COUNT(*), SUM(amount)
                FROM payouts GROUP BY idcoin, completed;"

ROLLBACK
  cp /var/web/serverconfig.php.bak-<stamp> /var/web/serverconfig.php
  crontab /var/backups/root-crontab-<stamp>.txt
EOF
