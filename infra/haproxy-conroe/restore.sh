#!/usr/bin/env bash
#
# restore.sh — apply the haproxy-conroe config to a fresh Ubuntu 24.04 box.
# Idempotent: safe to re-run after every config change in this repo.
#
# Usage:  sudo bash restore.sh [--skip-netplan]
#
# --skip-netplan   Don't touch networking (use on EC2 or when DHCP is fine).
#
set -euo pipefail

SKIP_NETPLAN=0
for arg in "$@"; do
  case "$arg" in
    --skip-netplan) SKIP_NETPLAN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> restoring haproxy-conroe from $SRC_DIR"

echo "==> apt install"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y haproxy ufw chrony htop iftop conntrack net-tools rsyslog

echo "==> sysctl"
install -m 0644 "$SRC_DIR/config/99-haproxy.conf" /etc/sysctl.d/99-haproxy.conf
sysctl --system >/dev/null

echo "==> systemd override (LimitNOFILE)"
install -d -m 0755 /etc/systemd/system/haproxy.service.d
install -m 0644 "$SRC_DIR/config/haproxy.limits.conf" \
    /etc/systemd/system/haproxy.service.d/limits.conf
systemctl daemon-reload

echo "==> haproxy.cfg"
install -m 0644 "$SRC_DIR/config/haproxy.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg

if [[ $SKIP_NETPLAN -eq 0 ]]; then
  echo "==> netplan (static 10.0.0.10/24)"
  # Detect the primary interface name; substitute into the template if needed.
  IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
  if [[ -n "$IFACE" && "$IFACE" != "enp1s0" ]]; then
    echo "    detected iface $IFACE (template uses enp1s0) — rewriting"
    sed "s/enp1s0/$IFACE/" "$SRC_DIR/config/99-haproxy.yaml" \
        > /etc/netplan/99-haproxy.yaml
  else
    install -m 0600 "$SRC_DIR/config/99-haproxy.yaml" /etc/netplan/99-haproxy.yaml
  fi
  chmod 0600 /etc/netplan/99-haproxy.yaml
  netplan apply
else
  echo "==> skipping netplan (--skip-netplan)"
fi

echo "==> ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.0.0.0/24 to any port 22 proto tcp
ufw allow 3433/tcp
ufw allow from 10.0.0.0/24 to any port 8404 proto tcp
ufw --force enable

echo "==> enable + restart haproxy"
systemctl enable haproxy
systemctl restart haproxy
sleep 1
systemctl --no-pager --full status haproxy | head -20

echo "==> install ops scripts under /opt/haproxy-conroe/"
install -d -m 0755 /opt/haproxy-conroe
install -m 0755 "$SRC_DIR/scripts/smoke-test.sh"     /opt/haproxy-conroe/smoke-test.sh
install -m 0755 "$SRC_DIR/scripts/watch-sessions.sh" /opt/haproxy-conroe/watch-sessions.sh

echo "==> done."
echo "    smoke test:  sudo /opt/haproxy-conroe/smoke-test.sh"
echo "    live view:   sudo /opt/haproxy-conroe/watch-sessions.sh"
