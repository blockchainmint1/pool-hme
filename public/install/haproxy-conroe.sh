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
