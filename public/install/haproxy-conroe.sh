#!/usr/bin/env bash
#
# haproxy-conroe bootstrap — one-paste installer.
#
# On a fresh Ubuntu 24.04 Beelink connected to the internet, run:
#
#   curl -fsSL https://pool.honest.money/install/haproxy-conroe.sh | sudo bash
#
# You'll be prompted for the container number (1-6). Or pass it inline:
#
#   curl -fsSL https://pool.honest.money/install/haproxy-conroe.sh \
#     | sudo bash -s -- --container 1
#
# For EC2 burn-in (single NIC, no NAT):
#
#   curl -fsSL https://pool.honest.money/install/haproxy-conroe.sh \
#     | sudo bash -s -- --skip-netplan
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root — pipe through sudo bash" >&2
  exit 1
fi

# ---- parse args ------------------------------------------------------------
CONTAINER=""
SKIP_NETPLAN=0
for arg in "$@"; do
  case "$arg" in
    --skip-netplan) SKIP_NETPLAN=1 ;;
    --container=*)  CONTAINER="${arg#*=}" ;;
    --container)    shift; CONTAINER="${1:-}" ;;
    [1-6])          CONTAINER="$arg" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- prompt for container number if not given and not EC2 ------------------
if [[ $SKIP_NETPLAN -eq 0 && -z "$CONTAINER" ]]; then
  if [[ ! -t 0 ]]; then
    # stdin is the piped tarball payload — reopen the terminal for the prompt
    exec < /dev/tty
  fi
  echo ""
  echo "=================================================================="
  echo "  haproxy-conroe installer"
  echo "=================================================================="
  echo ""
  echo "  Which container is this Beelink in? (1-6)"
  echo ""
  echo "    Container 1 → LAN 10.1.0.10/24, miners 10.1.0.100-.254"
  echo "    Container 2 → LAN 10.2.0.10/24, miners 10.2.0.100-.254"
  echo "    Container 3 → LAN 10.3.0.10/24, miners 10.3.0.100-.254"
  echo "    Container 4 → LAN 10.4.0.10/24, miners 10.4.0.100-.254"
  echo "    Container 5 → LAN 10.5.0.10/24, miners 10.5.0.100-.254"
  echo "    Container 6 → LAN 10.6.0.10/24, miners 10.6.0.100-.254"
  echo ""
  while [[ ! "$CONTAINER" =~ ^[1-6]$ ]]; do
    read -rp "  Container number [1-6]: " CONTAINER
  done
  echo ""
  echo "  → installing as container $CONTAINER"
  echo ""
fi

# ---- unpack the embedded tarball ------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking installer bundle"
base64 -d <<'PAYLOAD' | tar xzf - -C "$WORK"
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
bJ7Ns3k2z+bZPJtn82yezbN53PN/Q8/xLQCgAAA=
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
