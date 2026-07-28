#!/usr/bin/env bash
#
# haproxy-conroe bootstrap — one-paste installer.
#
# On a fresh Ubuntu 24.04 Beelink connected to the internet, run:
#
#   curl -fsSL https://pool.honest.money/install/haproxy-conroe.sh | sudo bash
#
# You'll be prompted for the container number (1-8). Or pass it inline:
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
    [1-8])          CONTAINER="$arg" ;;
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
  echo "  Which container is this Beelink in? (1-8)"
  echo ""
  echo "    Container 1 → LAN 10.1.0.10/24, miners 10.1.0.100-.254"
  echo "    Container 2 → LAN 10.2.0.10/24, miners 10.2.0.100-.254"
  echo "    Container 3 → LAN 10.3.0.10/24, miners 10.3.0.100-.254"
  echo "    Container 4 → LAN 10.4.0.10/24, miners 10.4.0.100-.254"
  echo "    Container 5 → LAN 10.5.0.10/24, miners 10.5.0.100-.254"
  echo "    Container 6 → LAN 10.6.0.10/24, miners 10.6.0.100-.254  (Conroe)"
  echo "    Container 7 → LAN 10.7.0.10/24, miners 10.7.0.100-.254  (McKinney)"
  echo "    Container 8 → LAN 10.8.0.10/24, miners 10.8.0.100-.254  (Mansfield)"
  echo ""
  while [[ ! "$CONTAINER" =~ ^[1-8]$ ]]; do
    read -rp "  Container number [1-8]: " CONTAINER
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
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
