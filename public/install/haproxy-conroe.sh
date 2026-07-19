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
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
