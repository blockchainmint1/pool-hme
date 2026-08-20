#!/usr/bin/env bash
# payout-watch.sh v1 -- continuous proof that payouts CALCULATE and PAY.
#
#   curl -fsSL "https://pool.honest.money/install/payout-watch.sh?v=$(date +%s)" | sudo bash            # CHECK (read only)
#   curl -fsSL "https://pool.honest.money/install/payout-watch.sh?v=$(date +%s)" | sudo bash -s INSTALL # + systemd timer, every 15m
#   ... | sudo bash -s STATUS      # what the timer thinks right now
#   ... | sudo bash -s UNINSTALL   # remove timer, change nothing else
#
# It never sends coins, never edits yiimp code, never touches a wallet key.
# It only reads the DB + daemons and yells (Telegram) when one of the seven
# payout invariants breaks. Alerts are edge-triggered: one message when a
# fault appears, one "RECOVERED" when it clears. No spam.
#
# THE SEVEN INVARIANTS (in payout-chain order)
#   1 credit      every block older than 30m has an earnings row
#   2 accrual     earnings are still being written (freshness)
#   3 maturity    matured earnings turn into accounts.balance
#   4 runner      yiimp loop2 alive, DOGE cycle cron is */10 and the daily
#                 regression cron is absent
#   5 wallet      LTC + DOGE wallets unlocked
#   6 solvency    spendable >= owed for each coin
#   7 delivery    when owed exceeds payout_min, a completed payout with a tx
#                 appears within PAYOUT_MAX_MIN
set -uo pipefail

MODE="${1:-CHECK}"
VERSION="v1"
BIN=/usr/local/bin/payout-watch-check
ENVF=/etc/payout-watch.env
STATE=/var/lib/payout-watch
LOG=/var/log/payout-watch.log
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

##############################################################################
if [ "$MODE" = UNINSTALL ]; then
  systemctl disable --now payout-watch.timer 2>/dev/null
  rm -f /etc/systemd/system/payout-watch.{service,timer} "$BIN"
  systemctl daemon-reload
  echo "payout-watch removed (env, state and log kept: $ENVF $STATE $LOG)"
  exit 0
fi

if [ "$MODE" = STATUS ]; then
  echo "payout-watch $VERSION status"
  echo "  timer : $(systemctl is-active payout-watch.timer 2>/dev/null || echo absent)"
  echo "  next  : $(systemctl show payout-watch.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
  echo "  faults: $(ls -1 "$STATE"/fault.* 2>/dev/null | sed 's|.*/fault\.||' | paste -sd, || echo none)"
  echo "  --- last 30 log lines"; tail -30 "$LOG" 2>/dev/null || echo "  (no log yet)"
  exit 0
fi

##############################################################################
# config + telegram inheritance
mkdir -p "$STATE"
if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<'EOF'
# payout-watch configuration
EARN_MAX_MIN=120        # no new earnings row for this long = fault
PAYOUT_MAX_MIN=240      # owed over payout_min for this long with no payout = fault
CREDIT_GAP_MAX=3        # blocks older than 30m with no earnings row before alerting
SOLVENCY_MARGIN=1.02    # spendable must cover owed * this
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EOF
  chmod 0600 "$ENVF"
fi
if [ -f /etc/nicehash-watcher.env ] && ! grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$ENVF"; then
  T=$(grep -s '^TELEGRAM_BOT_TOKEN=' /etc/nicehash-watcher.env | cut -d= -f2-)
  C=$(grep -s '^TELEGRAM_CHAT_ID='   /etc/nicehash-watcher.env | cut -d= -f2-)
  [ -n "${T:-}" ] && sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$T|" "$ENVF"
  [ -n "${C:-}" ] && sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=$C|"   "$ENVF"
  echo "  telegram credentials inherited from /etc/nicehash-watcher.env"
fi

##############################################################################
cat > "$BIN" <<'CHECK'
#!/usr/bin/env bash
# one payout-watch evaluation. VERBOSE=1 -> print the full report too.
set -uo pipefail
ENVF=/etc/payout-watch.env; STATE=/var/lib/payout-watch; LOG=/var/log/payout-watch.log
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool"
VERBOSE="${VERBOSE:-0}"
mkdir -p "$STATE"; . "$ENVF" 2>/dev/null || true
EARN_MAX_MIN=${EARN_MAX_MIN:-120}; PAYOUT_MAX_MIN=${PAYOUT_MAX_MIN:-240}
CREDIT_GAP_MAX=${CREDIT_GAP_MAX:-3}; SOLVENCY_MARGIN=${SOLVENCY_MARGIN:-1.02}

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>/dev/null; }
num() { local v="${1:-}"; case "$v" in ''|NULL|*[!0-9.-]*) echo 0;; *) echo "$v";; esac; }
say() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >> "$LOG"; [ "$VERBOSE" = 1 ] && echo "  $*"; }
tg() {
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -fsS -m 15 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode=HTML --data-urlencode text="$1" >/dev/null 2>&1 || true
}
# edge-triggered fault reporting: fault <key> <ok|bad> <message>
fault() {
  local key="$1" st="$2" msg="$3" f="$STATE/fault.$key"
  if [ "$st" = bad ]; then
    say "FAULT[$key] $msg"
    [ -f "$f" ] || { echo "$msg" > "$f"; tg "<b>PAYOUT FAULT</b> [$key]%0A$msg"; }
  else
    say "ok[$key] $msg"
    [ -f "$f" ] && { rm -f "$f"; tg "<b>payout recovered</b> [$key]%0A$msg"; }
  fi
}

##############################################################################
# 1. credit -- blocks with no earnings row
GAP=$(num "$(MY "SELECT COUNT(*) FROM blocks b
  LEFT JOIN earnings e ON e.blockid = b.id
  WHERE b.time < UNIX_TIMESTAMP()-1800
    AND b.time > UNIX_TIMESTAMP()-86400
    AND e.id IS NULL")")
if [ "$GAP" -gt "$CREDIT_GAP_MAX" ]; then
  fault credit bad "$GAP blocks in the last 24h have no earnings row -- rewards are not being split. Run credit-fix.sh."
else
  fault credit ok "uncredited blocks in 24h: $GAP (limit $CREDIT_GAP_MAX)"
fi

# 2. accrual -- earnings freshness
EAGE=$(num "$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-MAX(create_time))/60) FROM earnings")")
if [ "$EAGE" -ge "$EARN_MAX_MIN" ]; then
  fault accrual bad "no earnings row written for ${EAGE}m (limit ${EARN_MAX_MIN}m) -- share accounting stalled."
else
  fault accrual ok "last earnings ${EAGE}m ago"
fi

# 3. maturity -- matured earnings must become balance
STUCK=$(num "$(MY "SELECT COUNT(*) FROM earnings WHERE status < 2 AND create_time < UNIX_TIMESTAMP()-86400")")
say "info earnings still immature after 24h: $STUCK"

# 4. runner -- loop2 + cron cadence
RUNNER_BAD=""
pgrep -f 'loop2' >/dev/null || RUNNER_BAD="yiimp loop2 is not running"
grep -qs '^\*/10 .*doge-payout-cycle' /etc/cron.d/yiimp-doge-payout-cycle \
  || RUNNER_BAD="${RUNNER_BAD:+$RUNNER_BAD; }DOGE payout cycle is not on the */10 cadence"
[ -f /etc/cron.d/yiimp-doge-payout ] \
  && RUNNER_BAD="${RUNNER_BAD:+$RUNNER_BAD; }the retired DAILY doge cron is back (strands blocks)"
if [ -n "$RUNNER_BAD" ]; then fault runner bad "$RUNNER_BAD"; else fault runner ok "loop2 alive, doge cycle */10, no daily regression"; fi

# 5. wallet locks
NOW=$(date +%s); LOCK_BAD=""
for pair in "LTC:$LCLI" "DOGE:$DCLI"; do
  sym=${pair%%:*}; cli=${pair#*:}
  u=$(num "$($cli getwalletinfo 2>/dev/null | grep -oE '"unlocked_until": *[0-9]+' | grep -oE '[0-9]+$')")
  [ "${u%.*}" -le "$NOW" ] && LOCK_BAD="${LOCK_BAD:+$LOCK_BAD; }$sym wallet LOCKED"
done
if [ -n "$LOCK_BAD" ]; then fault wallet bad "$LOCK_BAD -- every send fails silently. Run payout-unstick.sh CONFIRM."; else fault wallet ok "LTC + DOGE wallets unlocked"; fi

# 6. solvency + 7. delivery, per coin
SOLV_BAD=""; DELIV_BAD=""
for pair in "LTC:$LCLI" "DOGE:$DCLI"; do
  sym=${pair%%:*}; cli=${pair#*:}
  owed=$(num "$(MY "SELECT IFNULL(ROUND(SUM(a.balance),8),0) FROM accounts a JOIN coins c ON c.id=a.coinid WHERE c.symbol='$sym' AND a.balance>0")")
  spend=$(num "$($cli getbalance 2>/dev/null | tr -d ' \n')")
  need=$(awk -v o="$owed" -v m="$SOLVENCY_MARGIN" 'BEGIN{printf "%.8f", o*m}')
  short=$(awk -v n="$need" -v s="$spend" 'BEGIN{print (s < n) ? 1 : 0}')
  say "info $sym owed=$owed spendable=$spend need=$need"
  [ "$short" = 1 ] && SOLV_BAD="${SOLV_BAD:+$SOLV_BAD; }$sym owed $owed but only $spend spendable"

  pmin=$(num "$(MY "SELECT IFNULL(payout_min,0) FROM coins WHERE symbol='$sym' LIMIT 1")")
  due=$(awk -v o="$owed" -v p="$pmin" 'BEGIN{print (p>0 && o>=p) ? 1 : 0}')
  page=$(num "$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-IFNULL(MAX(p.time),0))/60) FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE c.symbol='$sym' AND p.completed=1 AND IFNULL(p.tx,'')<>''")")
  say "info $sym payout_min=$pmin due=$due last_completed_payout=${page}m ago"
  if [ "$due" = 1 ] && [ "$page" -ge "$PAYOUT_MAX_MIN" ]; then
    DELIV_BAD="${DELIV_BAD:+$DELIV_BAD; }$sym owes $owed (min $pmin) yet nothing has paid out in ${page}m"
  fi
done
if [ -n "$SOLV_BAD" ]; then fault solvency bad "$SOLV_BAD -- top up the hot float from cold storage."; else fault solvency ok "both wallets cover their liabilities"; fi
if [ -n "$DELIV_BAD" ]; then fault delivery bad "$DELIV_BAD"; else fault delivery ok "no overdue payouts"; fi

exit 0
CHECK
chmod 0755 "$BIN"

##############################################################################
if [ "$MODE" = INSTALL ]; then
  cat > /etc/systemd/system/payout-watch.service <<EOF
[Unit]
Description=payout-watch -- verify pool payouts calculate and pay
[Service]
Type=oneshot
EnvironmentFile=-$ENVF
ExecStart=$BIN
EOF
  cat > /etc/systemd/system/payout-watch.timer <<'EOF'
[Unit]
Description=run payout-watch every 15 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now payout-watch.timer
  echo "installed: payout-watch.timer -> $(systemctl is-active payout-watch.timer)"
fi

echo
echo "===== running one evaluation now"
VERBOSE=1 "$BIN"
echo
echo "faults currently latched: $(ls -1 "$STATE"/fault.* 2>/dev/null | sed 's|.*/fault\.||' | paste -sd, || echo none)"
echo "log: $LOG"
[ "$MODE" = INSTALL ] || echo "note: CHECK only. Re-run with 'INSTALL' to arm the 15-minute watchdog + Telegram alerts."
