#!/usr/bin/env bash
# zcu-deadman.sh -- unattended safety net for the ARMED ZCU gate.
#
#   install:  curl -fsSL https://pool.honest.money/install/zcu-deadman.sh | sudo bash -s INSTALL
#   arm:      ... | sudo bash -s ARM       (install/start the deadman; gate unchanged)
#   status:   ... | sudo bash -s STATUS
#   test:     ... | sudo bash -s TEST      (one evaluation, prints verdict, no action)
#   remove:   ... | sudo bash -s UNINSTALL
#
# WHY: arming the gate is the only step that can touch geth. If geth wedges the
# way it did on 13 Aug, the pool loses LTC/DOGE/TXC/ISK -- and Bobby might be on
# a plane. This runs every 60s and DISARMS the gate automatically the moment
# mining health regresses, then alerts Telegram.
#
# TRIP CONDITIONS (any one, while the gate is ARMED):
#   1. No TXC block AND no ISK block for DRY_MAX_MIN minutes (default 60).
#      We are the only pool on both chains; healthy is ~1 block / 3 min.
#   2. stratum NRestarts increased since the deadman last looked (crash loop).
#   3. new 'dead lock, exiting' lines in /var/stratum/scrypt.log.
#   4. stratum unit not active.
#
# v2 (13 Aug 2026): dry-spell limit raised 15m -> 60m. The 15m trigger was
# written for an unattended flight and false-positives on ordinary variance.
# The hard triggers (2,3,4) are unchanged -- those are never false positives.
# v2 also adds a Telegram NOTIFY (not just a trip alert): every ZCU block that
# geth accepts, and every gated winner geth rejects, is announced once.
#
# ACTION: writes ZCU_DRY_RUN=1 to /etc/zcu-gate.env, restarts zcu-gate only.
# Stratum, scrypt.conf and the binary are NEVER touched -- disarming cannot
# itself cause a mining blip. Trips are latched: it will not re-arm on its own.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="$(printf '%s' "${1:-INSTALL}" | tr '[:lower:]' '[:upper:]')"
# ARM means arm the deadman timer, not the ZCU gate. DISARM removes the timer.
case "$MODE" in ARM|START) MODE=INSTALL ;; DISARM) MODE=STOP ;; esac
VER="v3"
BIN=/usr/local/sbin/zcu-deadman-check
ENVF=/etc/zcu-deadman.env
STATE=/var/lib/zcu-deadman
LOG=/var/log/zcu-deadman.log
GATE_ENV=/etc/zcu-gate.env
echo "zcu-deadman $VER  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

case "$MODE" in INSTALL|STATUS|TEST|UNINSTALL|STOP) ;; *)
  echo "  unknown mode. Use INSTALL (aka ARM), STATUS, TEST, DISARM or UNINSTALL"; exit 1 ;; esac

if [ "$MODE" = "UNINSTALL" ] || [ "$MODE" = "STOP" ]; then
  systemctl disable --now zcu-deadman.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/zcu-deadman.{timer,service}
  systemctl daemon-reload
  echo "  deadman removed (gate left exactly as it is)"
  exit 0
fi

if [ "$MODE" = "STATUS" ]; then
  echo "  timer : $(systemctl is-enabled zcu-deadman.timer 2>/dev/null) / $(systemctl is-active zcu-deadman.timer 2>/dev/null)"
  echo "  gate  : dry_run=$(grep -s '^ZCU_DRY_RUN=' $GATE_ENV | cut -d= -f2)  unit=$(systemctl is-active zcu-gate 2>/dev/null)"
  echo "  tripped: $([ -f $STATE/tripped ] && cat $STATE/tripped || echo no)"
  echo "  --- last 20 log lines"; tail -20 "$LOG" 2>/dev/null || echo "  (no log yet)"
  exit 0
fi

##############################################################################
mkdir -p "$STATE"
if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<'EOF'
# zcu-deadman configuration
DRY_MAX_MIN=60
# Telegram (optional). Blank disables alerts.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EOF
  chmod 0600 "$ENVF"
fi
# v2 migration: bump an existing 15m limit to the new 60m default
if grep -qs '^DRY_MAX_MIN=15$' "$ENVF"; then
  sed -i 's/^DRY_MAX_MIN=15$/DRY_MAX_MIN=60/' "$ENVF"
  echo "  migrated DRY_MAX_MIN 15 -> 60 (v2 default)"
fi
# inherit creds from the nicehash watcher if present and not set here
if [ -f /etc/nicehash-watcher.env ] && ! grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$ENVF"; then
  T=$(grep -s '^TELEGRAM_BOT_TOKEN=' /etc/nicehash-watcher.env | cut -d= -f2-)
  C=$(grep -s '^TELEGRAM_CHAT_ID='   /etc/nicehash-watcher.env | cut -d= -f2-)
  [ -n "${T:-}" ] && sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$T|" "$ENVF"
  [ -n "${C:-}" ] && sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=$C|"   "$ENVF"
  echo "  telegram credentials inherited from /etc/nicehash-watcher.env"
fi

cat > "$BIN" <<'CHECK'
#!/usr/bin/env bash
# one deadman evaluation. TEST=1 -> report only, never disarm.
set -uo pipefail
ENVF=/etc/zcu-deadman.env; STATE=/var/lib/zcu-deadman; LOG=/var/log/zcu-deadman.log
GATE_ENV=/etc/zcu-gate.env; UNIT=stratum-aws-scrypt; SLOG=/var/stratum/scrypt.log
TEST="${TEST:-0}"
mkdir -p "$STATE"; . "$ENVF" 2>/dev/null || true
DRY_MAX_MIN=${DRY_MAX_MIN:-60}
say() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >> "$LOG"; [ "$TEST" = 1 ] && echo "  $*"; }
tg() {
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -fsS -m 15 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode=HTML --data-urlencode text="$1" >/dev/null 2>&1 || true
}
MY() { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }

ARMED=$(grep -s '^ZCU_DRY_RUN=' "$GATE_ENV" | cut -d= -f2)
if [ "${ARMED:-1}" != "0" ]; then say "gate not armed (dry_run=${ARMED:-?}) -- nothing to guard"; exit 0; fi

##############################################################################
# NOTIFY -- announce ZCU results once each, independent of the trip logic.
# Runs even when nothing is wrong; this is the "did we win?" ping.
##############################################################################
GLOG=/var/log/zcu-gate.log
notify_new() {  # $1 = grep pattern, $2 = state file, $3 = telegram prefix
  local n prev new
  n=$(grep -c "$1" "$GLOG" 2>/dev/null | tr -dc '0-9'); n=${n:-0}
  prev=$(cat "$STATE/$2" 2>/dev/null | tr -dc '0-9'); prev=${prev:-$n}
  echo "$n" > "$STATE/$2"
  if [ "$n" -gt "$prev" ]; then
    new=$((n - prev))
    say "$3 x$new"
    tg "$3 (x$new)%0AZCU total so far: $n"
  fi
}
notify_new 'ZCU BLOCK ACCEPTED' accepted   '<b>ZCU BLOCK FOUND</b> -- geth accepted it'
notify_new 'geth REJECTED a gated winner' rejected '<b>ZCU winner rejected by geth</b> -- gate ACKed stratum, no mining impact'

REASON=""
# 1. TXC/ISK dry
AGE=$(MY "SELECT FLOOR((UNIX_TIMESTAMP()-MAX(b.time))/60) FROM blocks b
          JOIN coins c ON c.id=b.coin_id WHERE c.symbol IN ('TXC','ISK')")
case "$AGE" in ''|*[!0-9]*) AGE=-1 ;; esac
[ "$AGE" -ge "$DRY_MAX_MIN" ] && REASON="no TXC/ISK block for ${AGE}m (limit ${DRY_MAX_MIN}m)"

# 2. stratum restarts
R=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null); R=${R:-0}
P=$(cat "$STATE/restarts" 2>/dev/null || echo "$R"); echo "$R" > "$STATE/restarts"
[ "$R" -gt "$P" ] && REASON="${REASON:+$REASON; }stratum restarted ($P -> $R)"

# 3. new deadlock lines
D=$(grep -c 'dead lock, exiting' "$SLOG" 2>/dev/null || echo 0)
PD=$(cat "$STATE/deadlocks" 2>/dev/null || echo "$D"); echo "$D" > "$STATE/deadlocks"
[ "$D" -gt "$PD" ] && REASON="${REASON:+$REASON; }new 'dead lock, exiting' lines ($PD -> $D)"

# 4. stratum down
A=$(systemctl is-active "$UNIT" 2>/dev/null)
[ "$A" != "active" ] && REASON="${REASON:+$REASON; }stratum is $A"

if [ -z "$REASON" ]; then
  say "ok  armed, TXC/ISK block ${AGE}m old, restarts=$R, deadlocks=$D"
  exit 0
fi

if [ "$TEST" = 1 ]; then say "WOULD DISARM: $REASON"; exit 0; fi

sed -i 's/^ZCU_DRY_RUN=.*/ZCU_DRY_RUN=1/' "$GATE_ENV"
systemctl restart zcu-gate >/dev/null 2>&1
date -u '+%F %T UTC' > "$STATE/tripped"
say "DISARMED: $REASON"
tg "<b>ZCU deadman tripped</b>%0A$REASON%0AGate auto-disarmed (dry_run=1). Stratum untouched: $(systemctl is-active $UNIT), restarts=$R."
CHECK
chmod 0755 "$BIN"

cat > /etc/systemd/system/zcu-deadman.service <<EOF
[Unit]
Description=ZCU gate deadman -- auto-DISARM on mining regression
[Service]
Type=oneshot
EnvironmentFile=-$ENVF
ExecStart=$BIN
EOF
cat > /etc/systemd/system/zcu-deadman.timer <<'EOF'
[Unit]
Description=Run ZCU gate deadman every minute
[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

if [ "$MODE" = "TEST" ]; then
  echo "===== single evaluation (no action)"
  TEST=1 "$BIN"
  exit 0
fi

systemctl enable --now zcu-deadman.timer >/dev/null 2>&1
echo "  installed: checks every 60s, disarms after ${DRY_MAX_MIN:-60}m of TXC/ISK silence"
echo "  timer   : $(systemctl is-active zcu-deadman.timer)"
echo "  log     : $LOG      config: $ENVF"
echo "  dry run one-off:  sudo TEST=1 $BIN"
echo "zcu-deadman $VER done."
