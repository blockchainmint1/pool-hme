#!/usr/bin/env bash
# One-shot host setup for the TXC mempool stack.
# Run as root on a fresh Ubuntu 22.04/24.04 box AFTER node-spinner has
# installed and started texitcoind.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "!! Copy .env.example to .env and edit it first."
  exit 1
fi
# shellcheck disable=SC1091
source .env

# ---------- 1. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker-compose-plugin
fi

# ---------- 2. Firewall ----------
if command -v ufw >/dev/null 2>&1; then
  echo "==> Configuring ufw..."
  ufw allow OpenSSH      || true
  ufw allow 80/tcp       || true
  ufw allow 443/tcp      || true
  ufw allow "${P2P_PORT}/tcp" || true
  yes | ufw enable       || true
fi

# ---------- 3. Verify the host node is reachable ----------
echo "==> Checking host texitcoind RPC on 127.0.0.1:${RPC_PORT}..."
if ! curl -fsS --user "${RPC_USER}:${RPC_PASSWORD}" \
      --data-binary '{"jsonrpc":"1.0","id":"boot","method":"getblockchaininfo","params":[]}' \
      -H 'content-type: text/plain;' "http://127.0.0.1:${RPC_PORT}/" >/dev/null; then
  echo "!! Could not reach texitcoind RPC. Make sure node-spinner installed it,"
  echo "   that systemctl status texitcoind is active, and that texitcoin.conf has:"
  echo "     rpcbind=0.0.0.0"
  echo "     rpcallowip=172.17.0.0/16"
  echo "   (containers use the docker0 bridge to reach the host RPC.)"
  exit 1
fi
echo "    RPC OK"

# ---------- 4. Issue TLS cert standalone (port 80 must be free) ----------
mkdir -p data/certbot/conf data/certbot/www
if [[ ! -d "data/certbot/conf/live/${DOMAIN}" ]]; then
  echo "==> Issuing Let's Encrypt cert for ${DOMAIN} (standalone)..."
  docker run --rm -p 80:80 \
    -v "$PWD/data/certbot/conf:/etc/letsencrypt" \
    -v "$PWD/data/certbot/www:/var/www/certbot" \
    certbot/certbot:latest certonly --standalone --non-interactive --agree-tos \
      -m "${LETSENCRYPT_EMAIL}" -d "${DOMAIN}"
else
  echo "==> Cert already exists for ${DOMAIN}, skipping."
fi

# ---------- 5. Up ----------
echo "==> docker compose up -d"
docker compose --env-file .env up -d

echo
echo "All set. Watch logs with:"
echo "  docker compose logs -f indexer mempool-api nginx"
echo "Test once the node is synced (~30-60 min on a fresh box):"
echo "  curl https://${DOMAIN}/api/blocks/tip/height"
echo "  curl https://${DOMAIN}/api/address/_status"
