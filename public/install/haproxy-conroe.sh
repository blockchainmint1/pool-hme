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
pjSlKU1pSlOa0pSmNOXJ5b8jTM9nAKAAAA==
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
