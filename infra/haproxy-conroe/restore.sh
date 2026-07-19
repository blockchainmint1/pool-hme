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
FORCE_WAN=""
FORCE_LAN=""
for arg in "$@"; do
  case "$arg" in
    --skip-netplan)   SKIP_NETPLAN=1 ;;
    --container=*)    CONTAINER="${arg#*=}" ;;
    --container)      shift; CONTAINER="${1:-}" ;;
    --wan=*)          FORCE_WAN="${arg#*=}" ;;
    --lan=*)          FORCE_LAN="${arg#*=}" ;;
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
  LAN_POOL_START="10.${CONTAINER}.0.20"
  LAN_POOL_END="10.${CONTAINER}.0.254"
  echo "==> container ${CONTAINER}  →  Beelink ${LAN_CIDR}  miners ${LAN_POOL_START}-${LAN_POOL_END}  (235 leases)"
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> restoring haproxy-conroe from $SRC_DIR"

echo "==> apt install"
export DEBIAN_FRONTEND=noninteractive
# netfilter-persistent lives in `universe`; on minimal Ubuntu Server images
# that component is disabled, which makes iptables-persistent uninstallable
# with "Depends: netfilter-persistent but it is not installable".
if ! apt-cache policy netfilter-persistent 2>/dev/null | grep -q 'Candidate: [0-9]'; then
  echo "    enabling universe repo"
  apt-get install -y software-properties-common
  add-apt-repository -y universe
fi
apt-get update -y
apt-get install -y \
    haproxy ufw chrony htop iftop conntrack net-tools rsyslog \
    iptables kea-dhcp4-server

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
# Connectivity probe — used for both pre-flight (before netplan) and
# post-flight (after netplan + ufw). Uses `nc` when available, falls back to
# bash /dev/tcp. Retries a few times so a single DHCP hiccup isn't fatal.
# ---------------------------------------------------------------------------
UPSTREAM_HOST="stratum.pool.honest.money"
UPSTREAM_PORT="3433"

probe_tcp() {
  # probe_tcp <host> <port>  → 0 if any of 3 attempts connects
  local host="$1" port="$2" i
  for i in 1 2 3; do
    if command -v nc >/dev/null 2>&1; then
      if nc -w 4 -z "$host" "$port" >/dev/null 2>&1; then return 0; fi
    else
      if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then return 0; fi
    fi
    sleep 1
  done
  return 1
}

run_connectivity_check() {
  # $1 = label ("pre-flight" | "post-install")
  local label="$1"
  echo "==> ${label}: DNS + TCP ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
  local ok=1 ips=""
  if ips="$(getent hosts "$UPSTREAM_HOST" 2>/dev/null | awk '{print $1}' | paste -sd, -)" && [[ -n "$ips" ]]; then
    echo "    DNS: $ips"
  else
    echo "    !! DNS lookup for $UPSTREAM_HOST FAILED"
    ok=0
  fi
  if probe_tcp "$UPSTREAM_HOST" "$UPSTREAM_PORT"; then
    echo "    TCP ${UPSTREAM_PORT} (by name): OK"
  else
    echo "    !! TCP ${UPSTREAM_HOST}:${UPSTREAM_PORT} FAILED"
    # try each resolved IP directly to isolate DNS vs. routing
    for ip in ${ips//,/ }; do
      if probe_tcp "$ip" "$UPSTREAM_PORT"; then
        echo "    TCP ${UPSTREAM_PORT} (direct $ip): OK  (DNS/resolver is the problem)"
        ok=0
        return 0
      else
        echo "    TCP ${UPSTREAM_PORT} (direct $ip): FAILED"
      fi
    done
    echo "       WAN egress IP: $(timeout 5 curl -fsS https://api.ipify.org 2>/dev/null || echo '?')"
    echo "       default route: $(ip -o -4 route show default | head -1 || echo none)"
    ok=0
  fi
  if [[ $ok -ne 1 ]]; then
    echo "    !! ${label} check did not fully pass"
    return 1
  fi
  return 0
}

run_connectivity_check "pre-flight" || \
  echo "    (continuing — will re-check after netplan + ufw)"

# ---------------------------------------------------------------------------
# Interface detection.
# WAN = whatever holds the default route (DHCP from landlord).
# LAN = the other physical ethernet.
# Overridable with --wan=IFACE --lan=IFACE if auto-detect picks wrong.
# ---------------------------------------------------------------------------
detect_ifaces() {
  if [[ -n "$FORCE_WAN" ]]; then WAN_IF="$FORCE_WAN"
  else WAN_IF="$(ip -o -4 route show default | awk '{print $5; exit}')"
  fi
  if [[ -n "$FORCE_LAN" ]]; then LAN_IF="$FORCE_LAN"
  else LAN_IF="$(ip -o link show | awk -F': ' '{print $2}' \
             | grep -E '^(en|eth)' | grep -v "^${WAN_IF}$" | head -1 || true)"
  fi
}

if [[ $SKIP_NETPLAN -eq 0 ]]; then
  detect_ifaces
  if [[ -z "${WAN_IF:-}" || -z "${LAN_IF:-}" || "$WAN_IF" == "$LAN_IF" ]]; then
    echo "ERROR: could not detect two distinct ethernet interfaces." >&2
    echo "  WAN_IF=$WAN_IF  LAN_IF=$LAN_IF" >&2
    echo "  ip -o link show:" >&2
    ip -o link show >&2
    echo "  re-run with:  --wan=<iface> --lan=<iface>" >&2
    exit 3
  fi
  echo "==> netplan  WAN=$WAN_IF (dhcp)  LAN=$LAN_IF (static $LAN_CIDR)"
  sed -e "s|__WAN__|$WAN_IF|g" \
      -e "s|__LAN__|$LAN_IF|g" \
      -e "s|__LAN_CIDR__|$LAN_CIDR|g" \
      "$SRC_DIR/config/99-haproxy.yaml" > /etc/netplan/99-haproxy.yaml
  chmod 0600 /etc/netplan/99-haproxy.yaml
  # Neutralise cloud-init's netplan (it sets eno1 dhcp4:true, which fights us).
  if [[ -f /etc/netplan/50-cloud-init.yaml ]]; then
    cat > /etc/netplan/50-cloud-init.yaml <<'YAML'
network:
  version: 2
  ethernets: {}
YAML
    chmod 0600 /etc/netplan/50-cloud-init.yaml
  fi
  mkdir -p /etc/cloud/cloud.cfg.d
  echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  netplan apply
  sleep 3

  # ---- WAN sanity: some landlord DHCP pools hand out host-part .255 (valid
  # in /23 but frequently dropped by stateful upstream gear). If the DHCP
  # lease lands on an address that ends in .255 or .0, switch WAN to a static
  # in the same subnet using the same gateway.
  WAN_ADDR="$(ip -o -4 addr show "$WAN_IF" | awk '{print $4}' | head -1)"
  WAN_HOST_OCT="${WAN_ADDR%%/*}"; WAN_HOST_OCT="${WAN_HOST_OCT##*.}"
  if [[ "$WAN_HOST_OCT" == "255" || "$WAN_HOST_OCT" == "0" ]]; then
    WAN_GW="$(ip -o -4 route show default dev "$WAN_IF" | awk '{print $3; exit}')"
    WAN_PREFIX="${WAN_ADDR#*/}"
    WAN_BASE="$(echo "$WAN_ADDR" | awk -F'[./]' '{print $1"."$2"."$3}')"
    WAN_STATIC="${WAN_BASE}.100/${WAN_PREFIX}"
    echo "==> WAN DHCP handed out ${WAN_ADDR} (broadcast-looking); pinning static ${WAN_STATIC} via ${WAN_GW}"
    cat > /etc/netplan/60-wan-static.yaml <<YAML
network:
  version: 2
  ethernets:
    ${WAN_IF}:
      dhcp4: false
      addresses: [${WAN_STATIC}]
      routes:
        - to: default
          via: ${WAN_GW}
      nameservers:
        addresses: [1.1.1.1, 9.9.9.9]
YAML
    chmod 0600 /etc/netplan/60-wan-static.yaml
    ip addr flush dev "$WAN_IF"
    netplan apply
    sleep 3
  fi



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

  # NAT block is written AFTER `ufw --force reset` below — reset restores the
  # stock before.rules and would wipe any block written here. See ufw section.
  :
else
  echo "==> skipping netplan / DHCP / NAT (--skip-netplan)"
fi

echo "==> ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed          # allow the NAT forward chain
if [[ $SKIP_NETPLAN -eq 0 ]]; then
  echo "==> ufw-native NAT  ($LAN_IF $LAN_NET → $WAN_IF)"
  # Persist NAT via ufw: DEFAULT_FORWARD_POLICY + a *nat block prepended to
  # /etc/ufw/before.rules. Must run AFTER `ufw --force reset` (which restores
  # the stock before.rules and would erase our block).
  sed -i 's|^DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw
  sed -i '/^# BEGIN haproxy-conroe nat$/,/^# END haproxy-conroe nat$/d' /etc/ufw/before.rules
  TMP_NAT="$(mktemp)"
  cat > "$TMP_NAT" <<EOF
# BEGIN haproxy-conroe nat
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${LAN_NET} -o ${WAN_IF} -j MASQUERADE
COMMIT
# END haproxy-conroe nat
EOF
  cat "$TMP_NAT" /etc/ufw/before.rules > "${TMP_NAT}.new"
  mv "${TMP_NAT}.new" /etc/ufw/before.rules
  rm -f "$TMP_NAT"
  # Runtime rule so NAT works immediately (ufw enable below will also load it).
  iptables -t nat -C POSTROUTING -o "$WAN_IF" -s "$LAN_NET" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$LAN_NET" -j MASQUERADE
fi
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

# ---------------------------------------------------------------------------
# Post-install verification — this is the check that matters. The pre-flight
# above ran with initial DHCP state; this one runs against the final config
# (netplan + ufw + NAT applied), so if this passes you can point miners here.
# ---------------------------------------------------------------------------
echo ""
if run_connectivity_check "post-install"; then
  echo "==> READY: upstream reachable, haproxy running. Safe to point L9s here."
else
  echo "==> NOT READY: upstream unreachable from this Beelink after full setup."
  echo "    interface state:"
  ip -brief addr | sed 's/^/      /'
  echo "    default route:"
  ip -o -4 route show default | sed 's/^/      /'
  echo "    troubleshooting:"
  echo "      • confirm WAN cable is in the port shown as '$WAN_IF' above"
  echo "      • try  nc -vz 100.51.160.163 3433   (direct IP bypasses DNS)"
  echo "      • try  nc -vz 100.51.160.163 443    (isolates 3433 vs. all egress)"
  echo "      • if only 3433 fails, landlord/CPE is filtering that port"
  echo "      • override NIC choice:  sudo bash restore.sh --container N --wan=<if> --lan=<if>"
fi

