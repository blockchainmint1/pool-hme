#!/usr/bin/env bash
# zcu-sync-timer.sh -- keep the homepage/API in step with the ZCU chain.
#
#   install:  curl -fsSL https://pool.honest.money/install/zcu-sync-timer.sh | sudo bash -s INSTALL
#   status:   ... | sudo bash -s STATUS
#   remove:   ... | sudo bash -s UNINSTALL
#
# WHY: zcu-mainnet-yiimp-block-sync is a Type=oneshot unit with no timer, so the
# yiimp DB (what pool.honest.money reads) only advances when a human runs it.
# On 13 Aug 2026 the chain was at 19390 while the site still showed 19386 from
# 13 July. This adds a timer that runs the existing sync unit every 2 minutes.
#
# It NEVER touches stratum, the gate, geth, or scrypt.conf. Worst case the sync
# unit fails and the timer retries in 2 minutes.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="$(printf '%s' "${1:-INSTALL}" | tr '[:lower:]' '[:upper:]')"
VER="v2"
SYNC_UNIT=zcu-mainnet-yiimp-block-sync
echo "zcu-sync-timer $VER  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

case "$MODE" in INSTALL|STATUS|UNINSTALL) ;; *)
  echo "  unknown mode. Use INSTALL, STATUS or UNINSTALL"; exit 1 ;; esac

if [ "$MODE" = "UNINSTALL" ]; then
  systemctl disable --now zcu-sync.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/zcu-sync.timer
  systemctl daemon-reload
  echo "  timer removed (the sync unit itself is untouched)"
  exit 0
fi

if [ "$MODE" = "STATUS" ]; then
  echo "  timer     : $(systemctl is-enabled zcu-sync.timer 2>/dev/null) / $(systemctl is-active zcu-sync.timer 2>/dev/null)"
  echo "  sync unit : $(systemctl is-active $SYNC_UNIT 2>/dev/null)  last: $(systemctl show $SYNC_UNIT -p ExecMainExitTimestamp --value 2>/dev/null)"
  GAUTH=()
  # shellcheck disable=SC1091
  [ -f /etc/zcu-adapter-v6.env ] && . /etc/zcu-adapter-v6.env 2>/dev/null || true
  [ -n "${GETH_USER:-}" ] && GAUTH=(-u "$GETH_USER:${GETH_PASS:-}")
  TIP=$(curl -s --max-time 5 "${GAUTH[@]}" -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    http://127.0.0.1:8747 2>/dev/null | grep -o '0x[0-9a-fA-F]*')
  [ -n "${TIP:-}" ] && echo "  geth tip  : $((TIP))" || echo "  geth tip  : unreachable"
  DBH=$(timeout 8 mysql yiimpfrontend -N -B -e \
    "SELECT COALESCE(MAX(b.height),0) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'" 2>/dev/null)
  echo "  yiimp DB  : ${DBH:-?}"
  echo "  --- next runs"; systemctl list-timers zcu-sync.timer --no-pager 2>/dev/null | head -3
  exit 0
fi

##############################################################################
if ! systemctl cat "$SYNC_UNIT" >/dev/null 2>&1; then
  echo "  FAIL  $SYNC_UNIT does not exist on this box -- nothing to schedule"
  exit 1
fi
# a failed oneshot will not start again until reset
systemctl reset-failed "$SYNC_UNIT" >/dev/null 2>&1 || true

cat > /etc/systemd/system/zcu-sync.timer <<EOF
[Unit]
Description=Run the ZCU -> yiimp block DB sync every 2 minutes
[Timer]
Unit=$SYNC_UNIT.service
OnBootSec=120
OnUnitActiveSec=120
AccuracySec=10s
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable zcu-sync.timer >/dev/null 2>&1
systemctl start --no-block zcu-sync.timer >/dev/null 2>&1
# --no-block: the oneshot can take many minutes on a big backfill; never hold the installer
systemctl start --no-block "$SYNC_UNIT" >/dev/null 2>&1 || true

echo "  installed: $SYNC_UNIT now runs every 120s"
echo "  timer   : $(systemctl is-active zcu-sync.timer)"
echo "  check   : curl -fsSL https://pool.honest.money/install/zcu-sync-timer.sh | sudo bash -s STATUS"
echo "zcu-sync-timer $VER done."
