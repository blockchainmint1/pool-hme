#!/usr/bin/env bash
# pre-zcu-removal-backup.sh — snapshot EVERYTHING relevant before taking ZCU
# out of the aux rotation, so we can return to exactly this state.
#
# READ-ONLY with respect to the running system: it only copies files and
# dumps state into /var/backups/pre-zcu-removal-<ts>/. Nothing is stopped,
# restarted, edited, or deleted.
#
# Usage:
#   curl -fsSL "https://pool.honest.money/install/pre-zcu-removal-backup.sh?v=$(date +%s)" | sudo bash
set -euo pipefail

TS="$(date -u +%Y%m%d-%H%M%S)"
DEST="/var/backups/pre-zcu-removal-$TS"
mkdir -p "$DEST"/{stratum,zcu,systemd,web,db,logs,state}

say() { printf '[backup] %s\n' "$*"; }

say "destination: $DEST"

# --- 1. Stratum binary + live config -------------------------------------
say "stratum binary + config"
cp -a /var/stratum/stratum "$DEST/stratum/" 2>/dev/null || true
cp -a /var/stratum/scrypt.conf "$DEST/stratum/" 2>/dev/null || true
cp -a /var/stratum/config "$DEST/stratum/config-dir" 2>/dev/null || true
sha256sum /var/stratum/stratum 2>/dev/null > "$DEST/stratum/stratum.sha256" || true

# --- 2. ZCU gate / adapter sources ----------------------------------------
say "zcu gate + adapter"
for d in /opt/zcu-gate /opt/zcu-adapter /var/zcu /etc/zcu-gate /usr/local/bin; do
  [ -e "$d" ] || continue
  case "$d" in
    /usr/local/bin) cp -a /usr/local/bin/zcu* "$DEST/zcu/" 2>/dev/null || true ;;
    *) tar czf "$DEST/zcu/$(echo "$d" | tr '/_' '__').tar.gz" "$d" 2>/dev/null || true ;;
  esac
done
# any zcu scripts referenced by units
grep -rsl -i zcu /etc/systemd/system/ 2>/dev/null | while read -r u; do
  grep -oE 'ExecStart=[^ ]+' "$u" 2>/dev/null | cut -d= -f2- | while read -r p; do
    [ -f "$p" ] && cp -a "$p" "$DEST/zcu/" 2>/dev/null || true
  done
done || true

# --- 3. systemd units ------------------------------------------------------
say "systemd units"
for u in stratum-aws-scrypt zcu-gate zcu-mainnet-geth zcu-mainnet-yiimp-block-sync \
         yiimp-loop2 yiimp-api nicehash-watcher doge-share-archive.timer \
         doge-share-archive.service; do
  systemctl cat "$u" > "$DEST/systemd/$u.unit" 2>/dev/null || true
done
systemctl list-units --all --no-pager > "$DEST/state/systemctl-units.txt" 2>/dev/null || true
crontab -l > "$DEST/state/root-crontab.txt" 2>/dev/null || true
cp -a /etc/cron.d "$DEST/state/cron.d" 2>/dev/null || true

# --- 4. Web / payout / API code -------------------------------------------
say "web payout code + yiimp-api"
cp -a /var/web/doge-payout-cycle.sh "$DEST/web/" 2>/dev/null || true
cp -a /var/web/serverconfig.php "$DEST/web/serverconfig.php.REDACTED-CHECK" 2>/dev/null || true
# redact DB creds from the serverconfig copy
sed -i -E "s/(YAAMP_DBUSER|YAAMP_DBPASSWORD|WALLET_PASSPHRASE)[^;]*/\1 = '<redacted>'/g" \
  "$DEST/web/serverconfig.php.REDACTED-CHECK" 2>/dev/null || true
find /var/web -name 'DogePayoutCommand.php' -exec cp -a {} "$DEST/web/" \; 2>/dev/null || true
tar czf "$DEST/web/yiimp-api.tar.gz" /opt/yiimp-api 2>/dev/null || true

# --- 5. DB schema + key config rows (no balances, no secrets) --------------
say "db schema + coin config rows"
if sudo -n true 2>/dev/null || [ "$(id -u)" = "0" ]; then
  mysqldump --no-data yiimpfrontend > "$DEST/db/yiimpfrontend-schema.sql" 2>/dev/null || true
  mysql yiimpfrontend -e "SELECT * FROM coins;" > "$DEST/db/coins.tsv" 2>/dev/null || true
fi

# --- 6. Logs around the incident window (2026-08-29 14:00 -> now) ---------
say "incident-window logs"
journalctl -u stratum-aws-scrypt --since '2026-08-29 14:00' --no-pager \
  > "$DEST/logs/stratum-aws-scrypt.journal" 2>/dev/null || true
journalctl -u zcu-gate --since '2026-08-29 14:00' --no-pager \
  > "$DEST/logs/zcu-gate.journal" 2>/dev/null || true
journalctl -u zcu-mainnet-geth --since '2026-08-29 14:00' --no-pager \
  > "$DEST/logs/zcu-mainnet-geth.journal" 2>/dev/null || true
cp -a /var/stratum/logs/stratum-20260829-150000-pid2443993.log "$DEST/logs/" 2>/dev/null || true
cp -a /var/stratum/logs/*pid2766200*.log "$DEST/logs/" 2>/dev/null || true
ls -la /var/stratum/logs/ > "$DEST/logs/log-listing.txt" 2>/dev/null || true

# --- 7. Live state snapshot ------------------------------------------------
say "live state"
ss -tnp 2>/dev/null | grep -c ':3433' > "$DEST/state/connections-3433.count" || true
curl -s -X POST -H 'content-type: application/json' --user zcu:zcu \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  http://127.0.0.1:8747 > "$DEST/state/zcu-eth-blockNumber.json" 2>/dev/null || true
mysql yiimpfrontend -e \
  "SELECT symbol,MAX(time) AS last_block FROM blocks GROUP BY symbol;" \
  > "$DEST/state/last-blocks.tsv" 2>/dev/null || true
date -u > "$DEST/state/backup-finished-utc.txt"

# --- 8. Manifest ------------------------------------------------------------
say "manifest"
( cd "$DEST" && find . -type f -exec sha256sum {} \; ) > "$DEST/MANIFEST.sha256" 2>/dev/null || true

echo
say "DONE. Snapshot at: $DEST"
say "Verify with: cd $DEST && sha256sum -c MANIFEST.sha256 | grep -v ': OK' || echo ALL-OK"
du -sh "$DEST" 2>/dev/null || true
