#!/usr/bin/env bash
# One-shot host bootstrap for a fresh Ubuntu 22.04/24.04 VPS.
# - installs docker + compose plugin
# - opens 80/443/8333 in ufw
# - issues the initial Let's Encrypt cert (standalone, then hands off to nginx)
#
# Run as root. Idempotent — safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo -i)." >&2; exit 1
fi

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Create .env first (cp .env.example .env && edit)" >&2; exit 1; }
# shellcheck disable=SC1091
source .env
: "${DOMAIN:?set DOMAIN in .env}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL in .env}"

echo "==> Installing docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

echo "==> Firewall"
if command -v ufw >/dev/null; then
  ufw allow 22/tcp  || true
  ufw allow 80/tcp  || true
  ufw allow 443/tcp || true
  ufw allow 8333/tcp || true   # TXC P2P inbound
  yes | ufw enable || true
fi

mkdir -p data/certbot/conf data/certbot/www

echo "==> Issuing initial cert for ${DOMAIN}"
if [[ ! -d "data/certbot/conf/live/${DOMAIN}" ]]; then
  docker run --rm \
    -p 80:80 \
    -v "$PWD/data/certbot/conf:/etc/letsencrypt" \
    -v "$PWD/data/certbot/www:/var/www/certbot" \
    certbot/certbot:latest certonly --standalone \
      --non-interactive --agree-tos \
      -m "${LETSENCRYPT_EMAIL}" \
      -d "${DOMAIN}"
else
  echo "    cert already exists, skipping"
fi

echo "==> Done. Next:  docker compose up -d --build"
