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
5tk8m2fzbJ7Ns3k2T+nzf+yyuD4AoAAA
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
