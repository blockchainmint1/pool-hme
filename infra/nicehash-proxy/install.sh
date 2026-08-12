#!/usr/bin/env bash
#
# nicehash-proxy installer. Run as root on the stratum host.
#
set -euo pipefail

APP_DIR=/opt/nicehash-proxy
ENV_DIR=/etc/nicehash-proxy
SVC_USER=nicehash-proxy

echo "==> checking node"
command -v node >/dev/null || { echo "node not installed" >&2; exit 1; }

echo "==> service user"
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"

echo "==> installing to $APP_DIR"
install -d -o "$SVC_USER" -g "$SVC_USER" "$APP_DIR"
install -m 0644 -o "$SVC_USER" -g "$SVC_USER" src/proxy.cjs "$APP_DIR/proxy.cjs"

echo "==> env at $ENV_DIR/env"
install -d -m 0750 "$ENV_DIR"
if [[ -f "$ENV_DIR/env" ]]; then
  echo "    keeping existing env"
else
  install -m 0640 .env.example "$ENV_DIR/env"
fi
chown -R root:"$SVC_USER" "$ENV_DIR"

echo "==> systemd unit"
install -m 0644 systemd/nicehash-proxy.service /etc/systemd/system/nicehash-proxy.service
systemctl daemon-reload
systemctl enable nicehash-proxy
systemctl restart nicehash-proxy
sleep 2
systemctl --no-pager status nicehash-proxy | head -12

PORT="$(grep -E '^LISTEN_PORT=' "$ENV_DIR/env" | cut -d= -f2)"
echo
echo "==> listening check"
ss -ltnp | grep ":${PORT:-3533}" || echo "    NOT LISTENING — check: journalctl -u nicehash-proxy -n 50"

cat <<EOF

Done. Remaining step (once): open TCP ${PORT:-3533} to the internet
  - AWS security group inbound rule: TCP ${PORT:-3533} from 0.0.0.0/0
  - ufw (if enabled): ufw allow ${PORT:-3533}/tcp

Then point NiceHash / MiningRigRentals at:
  stratum+tcp://stratum.pool.honest.money:${PORT:-3533}
  user: <your LTC address>[.worker]
  pass: x            (proxy injects d=65536 automatically)
EOF
