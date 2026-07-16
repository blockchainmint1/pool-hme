#!/usr/bin/env bash
# Idempotent installer for yiimp-api on the yiimp box.
# Run: sudo bash install.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/yiimp-api"
ENV_DIR="/etc/yiimp-api"
SERVICE_USER="yiimp-api"
DOMAIN="${YIIMP_API_DOMAIN:-api.stratum.pool.honest.money}"


if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi

echo "==> [1/7] apt packages"
apt-get update -y
apt-get install -y curl ca-certificates gnupg nginx

echo "==> [2/7] Node 20"
if ! command -v node >/dev/null || ! node -v | grep -q "^v20"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "==> [3/7] service user"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

echo "==> [4/7] copy source + build"
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
  --exclude node_modules --exclude dist \
  "$SRC_DIR"/ "$INSTALL_DIR"/
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
sudo -u "$SERVICE_USER" bash -c "cd $INSTALL_DIR && (npm ci --omit=optional 2>/dev/null || npm install --omit=optional) && npm run build"

echo "==> [5/7] env file"
mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_DIR/env" ]]; then
  cp "$SRC_DIR/.env.example" "$ENV_DIR/env"
  echo "!! Wrote $ENV_DIR/env from template — edit MYSQL_PASSWORD before starting."
fi
chown root:"$SERVICE_USER" "$ENV_DIR/env"
chmod 640 "$ENV_DIR/env"

echo "==> [6/7] systemd"
cp "$SRC_DIR/systemd/yiimp-api.service" /etc/systemd/system/yiimp-api.service
systemctl daemon-reload
systemctl enable yiimp-api.service
systemctl restart yiimp-api.service

echo "==> [7/8] nginx"
# rate limit zone
cat >/etc/nginx/conf.d/yiimp-api-limits.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=yiimp_api:10m rate=20r/s;
EOF
cp "$SRC_DIR/nginx/yiimp-api.conf" /etc/nginx/sites-available/yiimp-api.conf
ln -sf /etc/nginx/sites-available/yiimp-api.conf /etc/nginx/sites-enabled/yiimp-api.conf
nginx -t
systemctl reload nginx

echo "==> [8/8] TLS via certbot"
if ! command -v certbot >/dev/null; then
  apt-get install -y certbot python3-certbot-nginx
fi
if ! certbot certificates 2>/dev/null | grep -q "Domains:.*$DOMAIN"; then
  echo "    requesting cert for $DOMAIN (DNS must already resolve to this box)"
  certbot --nginx --non-interactive --agree-tos --redirect \
    -m "admin@honest.money" -d "$DOMAIN" || {
      echo "!! certbot failed — DNS may not be propagated. Re-run:"
      echo "   sudo certbot --nginx -d $DOMAIN"
    }
else
  echo "    cert for $DOMAIN already present"
fi

echo
echo "==> done."
echo "   next steps:"
echo "     1. edit $ENV_DIR/env and set MYSQL_PASSWORD (see README for GRANT)"
echo "     2. systemctl restart yiimp-api"
echo "     3. curl -s https://$DOMAIN/api/health"
