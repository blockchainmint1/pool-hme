#!/usr/bin/env bash
#
# build-bundle.sh — regenerate public/install/haproxy-conroe.sh
#
# Produces a single self-contained bash script (with an embedded base64
# tarball of the whole haproxy-conroe/ tree) and drops it under
# public/install/ so it's served from https://pool.honest.money/install/.
#
# Re-run this whenever anything under infra/haproxy-conroe/ changes.
#
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../.." && pwd)"
OUT="$REPO/public/install/haproxy-conroe.sh"

echo "==> packing $SRC → $OUT"

TAR_B64="$(cd "$SRC" && tar czf - \
    restore.sh config/ scripts/ README.md \
    | base64 -w 0 2>/dev/null || tar czf - restore.sh config/ scripts/ README.md | base64)"

mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<'HEADER'
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
HEADER

echo "$TAR_B64" | fold -w 76 >> "$OUT"

cat >> "$OUT" <<'FOOTER'
PAYLOAD

# ---- hand off to restore.sh -----------------------------------------------
cd "$WORK"
chmod +x restore.sh scripts/*.sh
if [[ $SKIP_NETPLAN -eq 1 ]]; then
  exec bash "$WORK/restore.sh" --skip-netplan
else
  exec bash "$WORK/restore.sh" --container "$CONTAINER"
fi
FOOTER

chmod +x "$OUT"

SIZE="$(wc -c < "$OUT")"
LINES="$(wc -l < "$OUT")"
echo "==> wrote $OUT"
echo "    size: $SIZE bytes, $LINES lines"
echo ""
echo "Next: commit public/install/haproxy-conroe.sh so it's served from"
echo "      https://pool.honest.money/install/haproxy-conroe.sh"
