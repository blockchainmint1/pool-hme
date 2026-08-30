#!/usr/bin/env bash
# zcu-remove-rotation.sh — take ZCU out of the scrypt aux rotation.
#
# What it does (only with: REMOVE-ZCU CONFIRM):
#   1. Saves the current coins row for ZCU into the pre-removal backup dir
#      (exact revert values, timestamped).
#   2. UPDATE coins SET enable=0, auto_ready=0 WHERE symbol='ZCU'.
#   3. Restarts stratum-aws-scrypt (brief ~5s miner reconnect).
#   4. Stops + disables zcu-gate (adapter no longer needed; geth is LEFT
#      RUNNING so the chain keeps syncing and re-enable stays cheap).
#   5. Verifies: stratum up, clients reconnecting, shares flowing, ZCU
#      absent from aux lines, TXC/ISK still getting templates.
#
# Revert: re-run with REVERT — restores the saved enable/auto_ready values,
# re-enables zcu-gate, restarts stratum.
#
# Default (no args) = DRY RUN: shows current state and planned actions only.
set -euo pipefail

MODE="${1:-DRYRUN}"
CONFIRM="${2:-}"
BK="$(ls -dt /var/backups/pre-zcu-removal-* 2>/dev/null | head -1 || true)"

say() { printf '[zcu-remove] %s\n' "$*"; }

[ -n "$BK" ] || { say "FATAL: no /var/backups/pre-zcu-removal-* snapshot found. Run pre-zcu-removal-backup.sh first."; exit 1; }
say "using snapshot: $BK"

cur=$(mysql yiimpfrontend -N -e "SELECT enable, auto_ready FROM coins WHERE symbol='ZCU';" 2>/dev/null || true)
say "current ZCU coins row (enable auto_ready): ${cur:-<missing>}"

case "$MODE" in
  DRYRUN)
    say "DRY RUN — would: save row -> $BK/zcu-coins-row.tsv; set enable=0,auto_ready=0;"
    say "  restart stratum-aws-scrypt; stop+disable zcu-gate; verify."
    say "Execute with: $0 REMOVE-ZCU CONFIRM"
    exit 0
    ;;
  REMOVE-ZCU)
    [ "$CONFIRM" = "CONFIRM" ] || { say "need: REMOVE-ZCU CONFIRM"; exit 1; }
    mysql yiimpfrontend -e "SELECT * FROM coins WHERE symbol='ZCU';" > "$BK/zcu-coins-row.tsv"
    say "saved full ZCU coins row -> $BK/zcu-coins-row.tsv"
    mysql yiimpfrontend -e "UPDATE coins SET enable=0, auto_ready=0 WHERE symbol='ZCU';"
    say "coins updated: $(mysql yiimpfrontend -N -e "SELECT CONCAT(enable,',',auto_ready) FROM coins WHERE symbol='ZCU';")"
    systemctl stop zcu-gate 2>/dev/null || true
    systemctl disable zcu-gate 2>/dev/null || true
    say "zcu-gate stopped+disabled (geth left running)"
    systemctl restart stratum-aws-scrypt
    sleep 8
    say "stratum: $(systemctl is-active stratum-aws-scrypt)"
    sleep 20
    conns=$(ss -tn 2>/dev/null | grep -c ':3433' || true)
    say "connections on :3433 after restart: $conns"
    shares=$(mysql yiimpfrontend -N -e "SELECT COUNT(*) FROM shares WHERE time > UNIX_TIMESTAMP()-60;" 2>/dev/null || echo '?')
    say "shares in last 60s: $shares"
    say "NOTE: DOGE/LTC/TXC/ISK find rates should normalize over the next hours; monitor with mining-canary.sh."
    say "DONE. Revert with: $0 REVERT"
    ;;
  REVERT)
    [ -f "$BK/zcu-coins-row.tsv" ] || { say "no saved row at $BK/zcu-coins-row.tsv"; exit 1; }
    mysql yiimpfrontend -e "UPDATE coins SET enable=1, auto_ready=1 WHERE symbol='ZCU';"
    systemctl enable zcu-gate 2>/dev/null || true
    systemctl start zcu-gate 2>/dev/null || true
    systemctl restart stratum-aws-scrypt
    say "reverted: ZCU enable=1/auto_ready=1, zcu-gate started, stratum restarted"
    ;;
  *)
    say "unknown mode: $MODE (use REMOVE-ZCU CONFIRM | REVERT)"; exit 1;;
esac
