#!/usr/bin/env bash
#
# restore.sh — apply the haproxy-conroe config to a fresh Ubuntu 24.04 box.
# Idempotent: safe to re-run after every config change in this repo.
#
# Usage:
#   sudo bash restore.sh --container N      # on-site install, N = 1..6
#   sudo bash restore.sh --skip-netplan     # EC2 burn-in (no LAN, no NAT, no DHCP)
#
# On-site topology (one Beelink per container, 6 total):
#
#   Landlord CPE ── SG2218 ──[WAN NIC] Beelink [LAN NIC] ── container switch ── ~200 L9s
#
# The Beelink is: NAT firewall + DHCP server (kea-dhcp4) + HAProxy.
#
# Addressing plan — each container gets a UNIQUE LAN subnet so `ssh 10.X.0.10`
# from your laptop (when on-site or via a CPE port forward) is unambiguous:
#
#   Container 1  →  Beelink 10.1.0.10/24  →  miners 10.1.0.100-.254
#   Container 2  →  Beelink 10.2.0.10/24  →  miners 10.2.0.100-.254
#   ...
#   Container 6  →  Beelink 10.6.0.10/24  →  miners 10.6.0.100-.254
#
set -euo pipefail

SKIP_NETPLAN=0
CONTAINER=""
for arg in "$@"; do
  case "$arg" in
    --skip-netplan)   SKIP_NETPLAN=1 ;;
    --container=*)    CONTAINER="${arg#*=}" ;;
    --container)      shift; CONTAINER="${1:-}" ;;
    [1-6])            CONTAINER="$arg" ;;  # tolerate `--container 3` split by shell
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

if [[ $SKIP_NETPLAN -eq 0 ]]; then
  if [[ -z "$CONTAINER" || ! "$CONTAINER" =~ ^[1-6]$ ]]; then
    echo "ERROR: --container N required (N = 1..6)" >&2
    echo "  example:  sudo bash restore.sh --container 1" >&2
    exit 2
  fi
  LAN_ADDR="10.${CONTAINER}.0.10"
  LAN_CIDR="10.${CONTAINER}.0.10/24"
  LAN_NET="10.${CONTAINER}.0.0/24"
  LAN_POOL_START="10.${CONTAINER}.0.100"
  LAN_POOL_END="10.${CONTAINER}.0.254"
  echo "==> container ${CONTAINER}  →  Beelink ${LAN_CIDR}  miners ${LAN_POOL_START}-${LAN_POOL_END}"
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> restoring haproxy-conroe from $SRC_DIR"

echo "==> apt install"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    haproxy ufw chrony htop iftop conntrack net-tools rsyslog \
    iptables iptables-persistent kea-dhcp4-server

echo "==> sysctl (haproxy + ip_forward)"
install -m 0644 "$SRC_DIR/config/99-haproxy.conf" /etc/sysctl.d/99-haproxy.conf
install -m 0644 "$SRC_DIR/config/99-forward.conf" /etc/sysctl.d/99-forward.conf
sysctl --system >/dev/null

echo "==> systemd override (LimitNOFILE)"
install -d -m 0755 /etc/systemd/system/haproxy.service.d
install -m 0644 "$SRC_DIR/config/haproxy.limits.conf" \
    /etc/systemd/system/haproxy.service.d/limits.conf
systemctl daemon-reload

echo "==> haproxy.cfg"
install -m 0644 "$SRC_DIR/config/haproxy.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg

# ---------------------------------------------------------------------------
# Interface detection.
# WAN = whatever holds the default route (DHCP from landlord).
# LAN = the other physical ethernet.
# ---------------------------------------------------------------------------
detect_ifaces() {
  WAN_IF="$(ip -o -4 route show default | awk '{print $5; exit}')"
  LAN_IF="$(ip -o link show | awk -F': ' '{print $2}' \
             | grep -E '^(en|eth)' | grep -v "^${WAN_IF}$" | head -1 || true)"
}

if [[ $SKIP_NETPLAN -eq 0 ]]; then
  detect_ifaces
  if [[ -z "${WAN_IF:-}" || -z "${LAN_IF:-}" ]]; then
    echo "ERROR: could not detect two ethernet interfaces." >&2
    echo "  WAN_IF=$WAN_IF  LAN_IF=$LAN_IF" >&2
    echo "  ip -o link show:" >&2
    ip -o link show >&2
    exit 3
  fi
  echo "==> netplan  WAN=$WAN_IF (dhcp)  LAN=$LAN_IF (static $LAN_CIDR)"
  sed -e "s|__WAN__|$WAN_IF|g" \
      -e "s|__LAN__|$LAN_IF|g" \
      -e "s|__LAN_CIDR__|$LAN_CIDR|g" \
      "$SRC_DIR/config/99-haproxy.yaml" > /etc/netplan/99-haproxy.yaml
  chmod 0600 /etc/netplan/99-haproxy.yaml
  netplan apply

  echo "==> kea-dhcp4  (serving $LAN_POOL_START-$LAN_POOL_END on $LAN_IF)"
  install -d -m 0755 /etc/kea
  sed -e "s|__LAN__|$LAN_IF|g" \
      -e "s|__LAN_NET__|$LAN_NET|g" \
      -e "s|__LAN_GATEWAY__|$LAN_ADDR|g" \
      -e "s|__LAN_POOL_START__|$LAN_POOL_START|g" \
      -e "s|__LAN_POOL_END__|$LAN_POOL_END|g" \
      -e "s|__CONTAINER__|$CONTAINER|g" \
      "$SRC_DIR/config/kea-dhcp4.conf" \
      > /etc/kea/kea-dhcp4.conf
  chmod 0644 /etc/kea/kea-dhcp4.conf
  systemctl enable kea-dhcp4-server
  systemctl restart kea-dhcp4-server

  echo "==> iptables MASQUERADE  ($LAN_IF $LAN_NET → $WAN_IF)"
  iptables -t nat -C POSTROUTING -o "$WAN_IF" -s "$LAN_NET" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$LAN_NET" -j MASQUERADE
  iptables -C FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
  iptables -C FORWARD -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
  netfilter-persistent save
else
  echo "==> skipping netplan / DHCP / NAT (--skip-netplan)"
fi

echo "==> ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed          # allow the NAT forward chain we just built
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  # EC2 burn-in: no LAN yet, allow SSH + stratum + stats from anywhere.
  ufw allow 22/tcp
  ufw allow 3433/tcp
  ufw allow 8404/tcp
else
  # On-site: SSH + stratum + stats + DHCP reachable only from the miner LAN.
  # WAN side stays default-deny (only outbound + NAT return traffic).
  ufw allow in on "$LAN_IF" to any port 22   proto tcp
  ufw allow in on "$LAN_IF" to any port 3433 proto tcp
  ufw allow in on "$LAN_IF" to any port 8404 proto tcp
  ufw allow in on "$LAN_IF" to any port 67   proto udp   # DHCP
fi
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
if [[ $SKIP_NETPLAN -eq 0 ]]; then
  echo "$CONTAINER" > /opt/haproxy-conroe/CONTAINER
fi

echo "==> done."
if [[ $SKIP_NETPLAN -eq 0 ]]; then
  echo "    this Beelink:  container ${CONTAINER}  @  ${LAN_ADDR}"
  echo "    miners get:    ${LAN_POOL_START} - ${LAN_POOL_END}"
  echo "    point L9s at:  stratum+tcp://${LAN_ADDR}:3433"
fi
echo "    smoke test:    sudo /opt/haproxy-conroe/smoke-test.sh"
echo "    live view:     sudo /opt/haproxy-conroe/watch-sessions.sh"
