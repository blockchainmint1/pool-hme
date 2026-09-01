#!/usr/bin/env bash
# zcu-tip-sync.sh -- make the site show ZCU blocks in near real time.
#
#   install:  curl -fsSL https://pool.honest.money/install/zcu-tip-sync.sh | sudo bash -s INSTALL 60
#             (second arg = seconds between tip syncs, default 60, minimum 20)
#   status:   ... | sudo bash -s STATUS
#   runonce:  ... | sudo bash -s RUNONCE
#   remove:   ... | sudo bash -s UNINSTALL
#
# WHY (proved by zcu-sync-lag v2 on 1 Sep 2026):
#   /opt/zcu-pool-tools/zcu-mainnet-sync-blocks-to-yiimp.py walks heights
#   FORWARD from an old start (range(start, end+1), MAX_BATCH_DEFAULT=5000).
#   The long-running backfill invocation was inserting height 23,0xx while the
#   chain tip was 27,112 -- so the newest blocks land LAST, hours late, and the
#   oneshot never finishes so zcu-sync.timer can never re-fire it.
#
#   The worker already accepts a START HEIGHT as argv[1] (line 83:
#   start = max(1, int(sys.argv[1]))). So we do not need to rewrite it: we run
#   the SAME proven worker with start = tip - LOOKBACK on a short timer. History
#   backfill keeps running separately and slowly; the tip is always current.
#
# It NEVER touches stratum, scrypt.conf, geth, the gate, payouts or wallets.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

VER="v1"
MODE="$(printf '%s' "${1:-INSTALL}" | tr '[:lower:]' '[:upper:]')"
INTERVAL="$(printf '%s' "${2:-60}" | tr -cd '0-9')"; [ -n "$INTERVAL" ] || INTERVAL=60
[ "$INTERVAL" -ge 20 ] 2>/dev/null || INTERVAL=20
LOOKBACK="${ZCU_TIP_LOOKBACK:-200}"
WORKER=/opt/zcu-pool-tools/zcu-mainnet-sync-blocks-to-yiimp.py
RUNNER=/usr/local/bin/zcu-tip-sync-run.sh
echo "zcu-tip-sync $VER  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

case "$MODE" in INSTALL|STATUS|RUNONCE|UNINSTALL) ;; *)
  echo "  unknown mode. Use INSTALL, STATUS, RUNONCE or UNINSTALL"; exit 1 ;; esac

if [ "$MODE" = "UNINSTALL" ]; then
  systemctl disable --now zcu-tip-sync.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/zcu-tip-sync.timer /etc/systemd/system/zcu-tip-sync.service "$RUNNER"
  systemctl daemon-reload
  echo "  removed (backfill unit and geth untouched)"
  exit 0
fi

geth_tip() {
  local GAUTH=() HEX
  # shellcheck disable=SC1091
  [ -f /etc/zcu-adapter-v6.env ] && . /etc/zcu-adapter-v6.env 2>/dev/null || true
  [ -n "${GETH_USER:-}" ] && GAUTH=(-u "$GETH_USER:${GETH_PASS:-}")
  HEX=$(curl -s --max-time 5 "${GAUTH[@]}" -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    http://127.0.0.1:8747 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | head -1)
  [ -n "${HEX:-}" ] && echo $((HEX)) || echo ""
}

if [ "$MODE" = "STATUS" ]; then
  echo "  runner    : $([ -x "$RUNNER" ] && echo present || echo MISSING)"
  echo "  timer     : $(systemctl is-enabled zcu-tip-sync.timer 2>/dev/null) / $(systemctl is-active zcu-tip-sync.timer 2>/dev/null)"
  echo "  last run  : $(systemctl show zcu-tip-sync.service -p ExecMainExitTimestamp --value 2>/dev/null)"
  echo "  last rc   : $(systemctl show zcu-tip-sync.service -p ExecMainStatus --value 2>/dev/null)"
  TIP=$(geth_tip)
  DBH=$(timeout 8 mysql yiimpfrontend -N -B -e \
    "SELECT COALESCE(MAX(b.height),0) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU'" 2>/dev/null)
  echo "  geth tip  : ${TIP:-unreachable}"
  echo "  yiimp DB  : ${DBH:-?}"
  [ -n "${TIP:-}" ] && [ -n "${DBH:-}" ] && echo "  gap       : $((TIP - DBH)) blocks"
  echo "  --- last 20 tip-sync log lines"
  journalctl -u zcu-tip-sync.service --no-pager -o short-iso 2>/dev/null | tail -20 | sed 's/^/    /'
  echo "  --- next runs"; systemctl list-timers zcu-tip-sync.timer --no-pager 2>/dev/null | head -3 | sed 's/^/    /'
  exit 0
fi

if [ ! -r "$WORKER" ]; then
  echo "  FAIL  worker not found at $WORKER -- nothing to drive"
  exit 1
fi

##############################################################################
cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# installed by zcu-tip-sync $VER -- sync ONLY the newest ZCU blocks, then exit.
set -uo pipefail
LOOKBACK=\${ZCU_TIP_LOOKBACK:-$LOOKBACK}
WORKER=$WORKER
GAUTH=()
[ -f /etc/zcu-adapter-v6.env ] && . /etc/zcu-adapter-v6.env 2>/dev/null || true
[ -n "\${GETH_USER:-}" ] && GAUTH=(-u "\$GETH_USER:\${GETH_PASS:-}")
HEX=\$(curl -s --max-time 5 "\${GAUTH[@]}" -X POST -H 'content-type: application/json' \\
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \\
  http://127.0.0.1:8747 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | head -1)
[ -n "\${HEX:-}" ] || { echo "TIP_SYNC_SKIP reason=geth_unreachable"; exit 0; }
TIP=\$((HEX))
START=\$(( TIP - LOOKBACK )); [ "\$START" -lt 1 ] && START=1
echo "TIP_SYNC_START tip=\$TIP start=\$START lookback=\$LOOKBACK"
# own lock: never collide with another tip run; the long backfill uses its own unit
exec flock -n /var/lock/zcu-tip-sync.lock python3 "\$WORKER" "\$START"
EOF
chmod 0755 "$RUNNER"

cat > /etc/systemd/system/zcu-tip-sync.service <<EOF
[Unit]
Description=ZCU tip-first block sync into yiimp (newest blocks only)
After=network-online.target
[Service]
Type=oneshot
ExecStart=$RUNNER
TimeoutStartSec=$(( INTERVAL * 3 ))
Nice=5
EOF

cat > /etc/systemd/system/zcu-tip-sync.timer <<EOF
[Unit]
Description=Run the ZCU tip-first sync every ${INTERVAL}s
[Timer]
Unit=zcu-tip-sync.service
OnBootSec=30
OnUnitInactiveSec=$INTERVAL
AccuracySec=5s
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl reset-failed zcu-tip-sync.service >/dev/null 2>&1 || true

if [ "$MODE" = "RUNONCE" ]; then
  echo "  running one tip sync in the foreground..."
  "$RUNNER" 2>&1 | tail -40 | sed 's/^/    /'
  exit 0
fi

systemctl enable zcu-tip-sync.timer >/dev/null 2>&1
systemctl start zcu-tip-sync.timer >/dev/null 2>&1
systemctl start --no-block zcu-tip-sync.service >/dev/null 2>&1 || true

echo "  installed: tip sync (last $LOOKBACK heights) runs every ${INTERVAL}s"
echo "  timer    : $(systemctl is-active zcu-tip-sync.timer)"
echo
echo "  NOTE  the old long-running backfill (zcu-mainnet-yiimp-block-sync) is left alone."
echo "        It can keep walking history; the tip is now current regardless."
echo "        If you want history to stop hogging the DB:  systemctl stop zcu-mainnet-yiimp-block-sync"
echo "  check    : curl -fsSL https://pool.honest.money/install/zcu-tip-sync.sh | sudo bash -s STATUS"
echo "zcu-tip-sync $VER done."
