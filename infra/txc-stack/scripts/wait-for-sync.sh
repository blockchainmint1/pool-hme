#!/usr/bin/env bash
# Polls texitcoind until verificationprogress >= 0.9999, then reports
# indexer + mempool-api health. Run after `docker compose up -d`.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

cli() {
  docker compose exec -T texitcoind \
    texitcoin-cli -rpcuser="${RPC_USER}" -rpcpassword="${RPC_PASSWORD}" "$@"
}

echo "==> Waiting for texitcoind to accept RPC..."
until cli getblockchaininfo >/dev/null 2>&1; do sleep 5; done

echo "==> Syncing chain..."
while :; do
  info=$(cli getblockchaininfo 2>/dev/null || cli getblockchaininfo)
  prog=$(echo "$info" | grep -oE '"verificationprogress": *[0-9.]+' | grep -oE '[0-9.]+$')
  height=$(echo "$info" | grep -oE '"blocks": *[0-9]+' | grep -oE '[0-9]+$')
  printf "    height=%s  progress=%s\r" "$height" "$prog"
  awk "BEGIN{exit !($prog >= 0.9999)}" && { echo; break; }
  sleep 10
done
echo "==> Node synced at block $height"

echo "==> Waiting for address indexer..."
until docker compose exec -T indexer node -e "fetch('http://127.0.0.1:3001/address/_status').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))" >/dev/null 2>&1; do
  sleep 10
done
echo "==> indexer ready"

echo "==> Waiting for mempool backend..."
until docker compose exec -T mempool-api wget -qO- http://localhost:8999/api/blocks/tip/height >/dev/null 2>&1; do
  sleep 10
done
echo "==> mempool backend ready"

echo
echo "All green. Test from your laptop:"
echo "  curl https://${DOMAIN}/api/blocks/tip/height"
echo "  curl https://${DOMAIN}/api/address/_status"
