#!/usr/bin/env bash
# 17-payout-restore.sh -- put LTC + DOGE payouts back on the cadence that used
# to work, and fix the three things that silently break them.
#
#   sudo bash 17-payout-restore.sh            # CHECK: read-only diagnosis
#   sudo bash 17-payout-restore.sh CONFIRM    # apply the fixes
#
# WHAT WENT WRONG (the three failure modes, in the order they bite)
#   1. CADENCE. 10-payout-schedule.sh moved everything to once a day. For DOGE
#      that is fatal, not slow: yiimp DELETEs the `shares` rows for a round the
#      moment the parent LTC round is credited, so a daily cycle finds no share
#      data and credits nobody. Back to */10 for DOGE, 30 min for yiimp.
#   2. WALLET LOCK. After the seed rotation both wallets are encrypted. Every
#      sendmany/sendtoaddress fails with "please enter the wallet passphrase"
#      unless the payout path unlocks first (03-patch-payout-cron.sh for DOGE,
#      08-ltc-unlock.sh for LTC).
#   3. LOOP2 IS A DAEMON. It reads serverconfig.php once at boot. Changing the
#      frequency without restarting it changes nothing at all.
set -uo pipefail

CONFIRM="${1:-}"
VERSION="v1"
APPLY=false; [ "$CONFIRM" = CONFIRM ] && APPLY=true

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
DOGE_CYCLE=${DOGE_CYCLE:-/var/web/doge-payout-cycle.sh}
DOGE_LOG=${DOGE_LOG:-/var/web/runtime/doge-payout/cron-wrapper.log}
CRON_D=${CRON_D:-/etc/cron.d/yiimp-doge-payout-cycle}
DOGE_CRON_USER=${DOGE_CRON_USER:-ubuntu}
FREQ_SECONDS=${FREQ_SECONDS:-1800}
PAYOUT_MIN_LTC=${PAYOUT_MIN_LTC:-0.01}
PAYOUT_MIN_DOGE=${PAYOUT_MIN_DOGE:-50}
STAMP="$(date +%Y%m%d-%H%M%S)"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "payout-restore $VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$([ $APPLY = true ] && echo APPLY || echo CHECK)"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e "$1" 2>&1; }
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t    -e "$1" 2>&1; }

# ------------------------------------------------------------- 1. cadence ---
echo
echo "===== 1. yiimp payment frequency (LTC and all standard coins)"
CUR_FREQ="$(sed -n "s/.*define( *'YAAMP_PAYMENTS_FREQ' *, *\([0-9]*\).*/\1/p" "$SERVERCONFIG" | head -1)"
echo "  current: ${CUR_FREQ:-<undefined>}s   target: ${FREQ_SECONDS}s"
if [ "$APPLY" = true ]; then
  cp -a "$SERVERCONFIG" "$SERVERCONFIG.bak-$STAMP"
  if [ -n "$CUR_FREQ" ]; then
    sed -i "s/define( *'YAAMP_PAYMENTS_FREQ' *,[^)]*)/define('YAAMP_PAYMENTS_FREQ', $FREQ_SECONDS)/" "$SERVERCONFIG"
  else
    printf "\ndefine('YAAMP_PAYMENTS_FREQ', %s);\n" "$FREQ_SECONDS" >> "$SERVERCONFIG"
  fi
  grep -n YAAMP_PAYMENTS_FREQ "$SERVERCONFIG" | sed 's/^/  /'
  echo "  backup: $SERVERCONFIG.bak-$STAMP"
fi

echo
echo "===== 2. DOGE cycle cadence  (MUST stay every ~10 min -- shares are deleted fast)"
grep -rn "doge-payout-cycle" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
NEW_LINE="*/10 * * * * $DOGE_CRON_USER cd /var/web && $DOGE_CYCLE >> $DOGE_LOG 2>&1"
echo "  target : $NEW_LINE"
if [ "$APPLY" = true ]; then
  if [ ! -x "$DOGE_CYCLE" ]; then
    echo "  WARNING: $DOGE_CYCLE missing or not executable -- skipping DOGE cron"
  else
    [ -f "$CRON_D" ] && cp -a "$CRON_D" "/var/backups/$(basename "$CRON_D").bak-$STAMP"
    printf '# Managed by infra/wallet-rotation/17-payout-restore.sh (%s)\n# NEVER move this to hourly/daily: yiimp deletes the share rows a merged DOGE\n# block needs for attribution within minutes of the parent LTC round.\nSHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n%s\n' \
      "$STAMP" "$NEW_LINE" > "$CRON_D"
    chmod 644 "$CRON_D"; chown root:root "$CRON_D"
    echo "  wrote $CRON_D"
  fi
fi

# -------------------------------------------------------- 3. wallet unlock ---
echo
echo "===== 3. encrypted-wallet unlock on the payout paths"
if [ -f "$DOGE_CYCLE" ]; then
  if grep -q walletpassphrase "$DOGE_CYCLE"; then
    echo "  DOGE cycle : unlock block PRESENT"
  else
    echo "  DOGE cycle : MISSING -- every payoutSend will fail"
    echo "               fix: curl -fsSL https://pool.honest.money/install/patch-payout-cron.sh | sudo bash -s CONFIRM_PATCH"
  fi
else
  echo "  DOGE cycle : $DOGE_CYCLE not found"
fi
if [ -r /etc/pool-wallets/passphrase.env ]; then
  # shellcheck disable=SC1091
  . /etc/pool-wallets/passphrase.env
  DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
  LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf"
  if $DCLI walletpassphrase "${WALLET_PASSPHRASE:-}" 5 >/dev/null 2>&1; then
    echo "  DOGE wallet: unlock OK"; $DCLI walletlock >/dev/null 2>&1 || true
  else
    echo "  DOGE wallet: UNLOCK FAILED (or wallet not encrypted)"
  fi
  if $LCLI walletpassphrase "${WALLET_PASSPHRASE:-}" 5 >/dev/null 2>&1; then
    echo "  LTC wallet : unlock OK"; $LCLI walletlock >/dev/null 2>&1 || true
  else
    echo "  LTC wallet : UNLOCK FAILED (or wallet not encrypted)"
  fi
else
  echo "  /etc/pool-wallets/passphrase.env missing -- payouts cannot unlock anything"
fi
echo "  LTC path   : yiimp loop2 calls sendmany directly; it needs the wallet"
echo "               kept unlocked -- see 08-ltc-unlock.sh (ltc-unlock.sh installer)."

# ------------------------------------------------------------- 4. backlog ---
echo
echo "===== 4. current payout backlog"
MYT "SELECT c.symbol, p.completed, COUNT(*) rows_, ROUND(SUM(p.amount),8) amount, MAX(FROM_UNIXTIME(p.time)) latest
     FROM payouts p JOIN coins c ON c.id=p.idcoin
     WHERE c.symbol IN ('LTC','DOGE') GROUP BY 1,2"
MYT "SELECT c.symbol, ROUND(SUM(a.balance),8) owed_now, COUNT(*) accounts
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND a.balance>0 GROUP BY 1"
MYT "SELECT symbol, payout_min, txfee, enable, auto_ready FROM coins WHERE symbol IN ('LTC','DOGE')"

if [ "$APPLY" = true ]; then
  MY "UPDATE coins SET payout_min=$PAYOUT_MIN_LTC  WHERE symbol='LTC'"  >/dev/null
  MY "UPDATE coins SET payout_min=$PAYOUT_MIN_DOGE WHERE symbol='DOGE'" >/dev/null
  echo "  payout_min set: LTC=$PAYOUT_MIN_LTC DOGE=$PAYOUT_MIN_DOGE"
fi

# --------------------------------------------------------------- 5. loop2 ---
echo
echo "===== 5. yiimp loop2 (the process that actually pays)"
ps -ef | grep -E '[l]oop2' | sed 's/^/  /' || echo "  loop2 NOT RUNNING -- nothing will ever pay"
if [ "$APPLY" = true ]; then
  for u in yiimp-loop2.service loop2.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      systemctl restart "$u" && echo "  restarted $u"; break
    fi
  done
  systemctl restart cron >/dev/null 2>&1 && echo "  reloaded cron"
fi

echo
if [ "$APPLY" != true ]; then
  cat <<'EOF'
CHECK ONLY -- nothing changed. Apply with:
  sudo bash 17-payout-restore.sh CONFIRM

Then verify over the next 30 minutes:
  tail -f /var/web/runtime/doge-payout/cron-wrapper.log
  mysql ... -e "SELECT c.symbol,p.completed,COUNT(*),SUM(p.amount) FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY 1,2"
EOF
else
  cat <<'EOF'
APPLIED.

  * yiimp pays at most every 30 min again (loop2 restarted so it re-read it)
  * DOGE cycle back to */10 -- the only cadence that survives yiimp's share purge
  * payout_min reset to sane values so dust rows stop being rejected

WATCH
  tail -f /var/web/runtime/doge-payout/cron-wrapper.log     # next run within 10 min
  sudo bash /usr/local/sbin/payout-doctor.sh                # full chain re-read

ROLLBACK
  cp /var/web/serverconfig.php.bak-<stamp> /var/web/serverconfig.php
  cp /var/backups/yiimp-doge-payout-cycle.bak-<stamp> /etc/cron.d/yiimp-doge-payout-cycle
EOF
fi
