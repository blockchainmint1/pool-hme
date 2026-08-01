#!/usr/bin/env bash
# Keep the rotated (encrypted) LTC wallet unlocked so yiimp's payout loop can
# call sendmany, and re-queue the payouts that already failed with error -13.
#
#   sudo bash 08-ltc-unlock.sh              # dry run: show what would happen
#   sudo bash 08-ltc-unlock.sh CONFIRM      # install unlock timer + requeue rows
#
# Why a timer instead of patching yiimp:
#   yiimp's payout path (loop2.sh -> yaamp runtime) calls sendmany directly with
#   no passphrase hook. Rather than patch PHP we keep the wallet unlocked in a
#   rolling window: every 2 minutes walletpassphrase for 300s. If the timer dies
#   the wallet re-locks within 5 minutes on its own -- fail-safe, not fail-open.
#
# Security note: the passphrase is read from /etc/pool-wallets/passphrase.env
# (root-only, 600). It is never written into this script or into /var/web.
set -euo pipefail

CONFIRM="${1:-}"
LTC_DIR="${LTC_DIR:-/home/ubuntu/.litecoin}"
LTC_BIN="${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}"
CONF="$LTC_DIR/litecoin.conf"
PASS_ENV=/etc/pool-wallets/passphrase.env
UNLOCK_BIN=/usr/local/sbin/ltc-keep-unlocked.sh

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -r "$PASS_ENV" ] || { echo "FATAL: $PASS_ENV missing/unreadable"; exit 1; }

WALLET_NAME="$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$CONF" 2>/dev/null | head -1)"
WALLET_NAME="${WALLET_NAME:-pool}"
LCLI="$LTC_BIN/litecoin-cli -conf=$CONF -rpcwallet=$WALLET_NAME"

echo "=== LTC payout unlock shim ==="
echo "Mode        : $([ "$CONFIRM" = CONFIRM ] && echo EXECUTE || echo 'DRY RUN')"
echo "Wallet      : $WALLET_NAME"
$LCLI getwalletinfo | grep -E '"balance"|unlocked_until|walletname' || true
echo

# --- yiimp DB creds (read-only lookup of the stuck rows) -----------------------
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" /var/web/serverconfig.php)"
MY() { mysql -u"$DBU" -p"$DBP" yiimpfrontend -N -B -e "$1"; }

PENDING=$(MY "SELECT COUNT(*) FROM payouts WHERE idcoin=8 AND completed=0")
PENDAMT=$(MY "SELECT IFNULL(SUM(amount),0) FROM payouts WHERE idcoin=8 AND completed=0")
echo "Pending LTC payouts: $PENDING rows, $PENDAMT LTC"

if [ "$CONFIRM" != "CONFIRM" ]; then
  cat <<EOF

DRY RUN -- nothing changed.

Would do:
  1. install $UNLOCK_BIN + systemd timer (every 2 min, unlock for 300s)
  2. start it and verify unlocked_until is in the future
  3. clear errmsg on the $PENDING stuck LTC rows so the payout loop retries them

Re-run with: sudo $0 CONFIRM
EOF
  exit 0
fi

log "installing $UNLOCK_BIN"
cat > "$UNLOCK_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. $PASS_ENV
exec $LTC_BIN/litecoin-cli -conf=$CONF -rpcwallet=$WALLET_NAME \\
  walletpassphrase "\$WALLET_PASSPHRASE" 300
EOF
chmod 700 "$UNLOCK_BIN"

cat > /etc/systemd/system/ltc-unlock.service <<EOF
[Unit]
Description=Keep the LTC pool wallet unlocked for yiimp payouts
After=network.target

[Service]
Type=oneshot
ExecStart=$UNLOCK_BIN
EOF

cat > /etc/systemd/system/ltc-unlock.timer <<'EOF'
[Unit]
Description=Refresh LTC wallet unlock every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=2min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ltc-unlock.timer
systemctl start ltc-unlock.service

sleep 2
UNTIL=$($LCLI getwalletinfo | sed -n 's/.*"unlocked_until": *\([0-9]*\).*/\1/p')
NOW=$(date +%s)
if [ -n "$UNTIL" ] && [ "$UNTIL" -gt "$NOW" ]; then
  log "wallet unlocked until $(date -u -d "@$UNTIL" '+%H:%M:%S')Z -- OK"
else
  echo "FATAL: wallet still locked. Check: journalctl -u ltc-unlock -n 20"
  exit 1
fi

log "re-queueing $PENDING stuck LTC payouts (clearing errmsg)"
MY "UPDATE payouts SET errmsg='' WHERE idcoin=8 AND completed=0 AND errmsg LIKE '%passphrase%'"

echo
echo "=== verification ==="
systemctl --no-pager status ltc-unlock.timer | head -6
MY "SELECT completed, COUNT(*), IFNULL(SUM(amount),0) FROM payouts WHERE idcoin=8 GROUP BY completed"
echo
cat <<'NEXT'
NEXT
  * Watch the next payout cycle land:
      watch -n30 "mysql ... -e \"select count(*) from payouts where idcoin=8 and completed=0\""
  * Confirm sends appear on-chain:
      litecoin-cli -rpcwallet=pool listtransactions '*' 10 0 | grep -E 'category|amount|txid'
  * The wallet auto-relocks 5 minutes after the timer stops, so disabling the
    timer (systemctl disable --now ltc-unlock.timer) is enough to re-secure it.
NEXT
