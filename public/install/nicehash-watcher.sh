#!/usr/bin/env bash
# install.sh — installs the NiceHash auto-purchase watcher as a systemd service.
#
# Usage:
#   curl -fsSL https://pool.honest.money/install/nicehash-watcher.sh | sudo bash
#
# Required env (provide before piping, or edit the env file after install):
#   NICEHASH_API_KEY, NICEHASH_API_SECRET, NICEHASH_ORG_ID, RENTAL_LTC_ADDR
#
# Optional env (defaults shown):
#   POOL_API_BASE, POOL_HOST, MIN_TARGET_THS, TRIGGER_FRACTION, RENT_CAP_THS,
#   ORDER_AMOUNT_BTC, REFILL_AMOUNT_BTC, DAILY_BTC_CAP, MAX_CONCURRENT_ORDERS,
#   BID_MARGIN, BID_FLOOR_PRICE, BID_MAX_PRICE, POLL_INTERVAL_SEC, DRY_RUN
set -euo pipefail

SRC_DIR="/opt/nicehash-watcher"
ENV_FILE="/etc/nicehash-watcher.env"
STATE_DIR="/var/lib/nicehash-watcher"
UNIT="/etc/systemd/system/nicehash-watcher.service"

# Locate the bundle shipped beside this script, or download it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo .)" && pwd)"
BUNDLE="$SRC_DIR/bundle.cjs"

echo "==> Installing nicehash-watcher to $SRC_DIR"
mkdir -p "$SRC_DIR" "$STATE_DIR"
chmod 0755 "$SRC_DIR" "$STATE_DIR"

if [ -f "$SCRIPT_DIR/bundle.cjs" ]; then
  cp -f "$SCRIPT_DIR/bundle.cjs" "$BUNDLE"
elif [ -f "$SRC_DIR/src/watcher.cjs" ]; then
  : # dev install — source files already present
else
  echo "==> Downloading bundle from pool.honest.money"
  curl -fsSL https://pool.honest.money/install/nicehash-watcher-bundle.cjs -o "$BUNDLE"
fi
chmod 0644 "$BUNDLE"

# ---- env file ---------------------------------------------------------------
echo "==> Writing env file $ENV_FILE"
ENV_TEMPLATE="$(mktemp)"
trap 'rm -f "$ENV_TEMPLATE"' EXIT
cat > "$ENV_TEMPLATE" <<'EOF'
# NiceHash auto-purchase watcher configuration.
# Fill in the four REQUIRED values, then `systemctl restart nicehash-watcher`.

# REQUIRED — NiceHash API v2 credentials (https://www.nicehash.com/my/api/v2)
# Either name set works: NICEHASH_API_KEY/SECRET/ORG_ID or the short aliases.
NICEHASH_API=
NICEHASH_SECRET=
NICEHASH_ORGANIZATION=
# REQUIRED — payout address for the rental NiceHash pool (LTC mainnet)
RENTAL_LTC_ADDR=

# Pool stats API (yiimp-api). Leave default unless overridden.
POOL_API_BASE=https://api.stratum.pool.honest.money
POOL_HOST=stratum.pool.honest.money:3433

# Strategy
MIN_TARGET_THS=19
TRIGGER_FRACTION=0.75
RENT_CAP_THS=19
MAX_CONCURRENT_ORDERS=2

# Budget
ORDER_AMOUNT_BTC=0.02
REFILL_AMOUNT_BTC=0.02
REFILL_THRESHOLD_BTC=0.005
# DAILY_BTC_CAP=0 disables the hard daily guard (honours "at any cost").
# Set a number (e.g. 2.0) to enforce an emergency spend ceiling.
DAILY_BTC_CAP=0

# Bidding — depth-aware: bid the clearing price needed to win our few TH/s out
# of the market's available speed, plus one tick. Start cheap, then step up by
# BID_TICK every BID_BUMP_EVERY_MIN if the order fills below BID_FILL_FRACTION.
BID_MARGIN=0
BID_TICK=0.0001
BID_FLOOR_PRICE=0
BID_MAX_PRICE=0.05
BID_BUMP_EVERY_MIN=10
BID_FILL_FRACTION=0.85


# Cadence
POLL_INTERVAL_SEC=30
RECOVER_CONFIRMATIONS=3
LOW_CONFIRMATIONS=3

# Telegram alerts — fires when hashrate drops below TRIGGER_FRACTION of target,
# on recovery, and on order placed/cancelled/failed. Leave blank to disable.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ALERTS_ENABLED=true
ALERT_COOLDOWN_MIN=30

# Remote watchdog on pool.honest.money — the watcher POSTs a heartbeat each
# cycle and asks the site to run outside-in health checks every MONITOR_EVERY_SEC
# (site-side Telegram alerts). Blank MONITOR_TOKEN disables it.
MONITOR_URL=https://pool.honest.money/api/public/monitor
MONITOR_TOKEN=
MONITOR_EVERY_SEC=300

# Set DRY_RUN=true to log actions without spending.
DRY_RUN=false
EOF
if [ -f "$ENV_FILE" ]; then
  echo "    preserving existing values; appending missing settings only"
  while IFS= read -r line; do
    case "$line" in
      [A-Za-z_]*=*)
        key="${line%%=*}"
        grep -q "^${key}=" "$ENV_FILE" || printf '%s\n' "$line" >> "$ENV_FILE"
        ;;
    esac
  done < "$ENV_TEMPLATE"
else
  mv "$ENV_TEMPLATE" "$ENV_FILE"
fi
chmod 0600 "$ENV_FILE"
chown root:root "$ENV_FILE"

# Preserve any values the admin already filled in (re-install keeps config).
set_env() {
  local key="$1" val="$2"
  [ -n "$val" ] || return 0
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
  else
    echo "$key=$val" >> "$ENV_FILE"
  fi
}

echo "==> Applying any env values provided in the pipe environment"
set_env NICEHASH_API "${NICEHASH_API:-${NICEHASH_API_KEY:-}}"
set_env NICEHASH_SECRET "${NICEHASH_SECRET:-${NICEHASH_API_SECRET:-}}"
set_env NICEHASH_ORGANIZATION "${NICEHASH_ORGANIZATION:-${NICEHASH_ORG_ID:-}}"
set_env RENTAL_LTC_ADDR "${RENTAL_LTC_ADDR:-}"
set_env TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN:-}"
set_env TELEGRAM_CHAT_ID "${TELEGRAM_CHAT_ID:-}"
set_env MONITOR_TOKEN "${MONITOR_TOKEN:-}"
set_env MONITOR_URL "${MONITOR_URL:-}"

# ---- systemd unit -----------------------------------------------------------
echo "==> Installing systemd unit $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=NiceHash auto-purchase hashrate watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
WorkingDirectory=$SRC_DIR
ExecStart=/usr/bin/node $BUNDLE
Restart=always
RestartSec=10
# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$STATE_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Detect node path (fallback to /usr/bin/node)
NODE_BIN="$(command -v node || true)"
if [ -n "$NODE_BIN" ] && [ "$NODE_BIN" != "/usr/bin/node" ]; then
  sed -i "s|^ExecStart=.*|ExecStart=$NODE_BIN $BUNDLE|" "$UNIT"
fi

systemctl daemon-reload
systemctl enable nicehash-watcher.service 2>/dev/null || true
systemctl restart nicehash-watcher.service

echo
echo "==> Installed. Status:"
systemctl --no-pager --full status nicehash-watcher.service 2>/dev/null | head -20 || true
echo
echo "NEXT STEPS:"
echo "  1. Edit credentials:  sudo nano $ENV_FILE"
echo "  2. Restart:           sudo systemctl restart nicehash-watcher"
echo "  3. Tail logs:          sudo journalctl -u nicehash-watcher -f"
echo
echo "The watcher stays in standby (logs 'no API credentials') until you fill"
echo "the four REQUIRED values and restart. No money is spent until the pool"
echo "hashrate drops below ${TRIGGER_FRACTION:-0.75} of the target."
