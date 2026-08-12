#!/usr/bin/env bash
#
# build-bundle.sh — regenerate public/install/nicehash-proxy.sh
#
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../.." && pwd)"
OUT="$REPO/public/install/nicehash-proxy.sh"

echo "==> packing $SRC → $OUT"
TAR_B64="$(cd "$SRC" && tar czf - install.sh .env.example src/ systemd/ README.md | base64 -w 0 2>/dev/null || (cd "$SRC" && tar czf - install.sh .env.example src/ systemd/ README.md | base64))"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<'HEADER'
#!/usr/bin/env bash
#
# nicehash-proxy bootstrap — one-paste installer.
#
#   curl -fsSL https://pool.honest.money/install/nicehash-proxy.sh | sudo bash
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root — pipe through sudo bash" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> unpacking installer bundle"
base64 -d <<'PAYLOAD' | tar xzf - -C "$WORK"
HEADER

echo "$TAR_B64" | fold -w 76 >> "$OUT"

cat >> "$OUT" <<'FOOTER'
PAYLOAD

cd "$WORK"
chmod +x install.sh
exec bash "$WORK/install.sh"
FOOTER

chmod +x "$OUT"
echo "==> wrote $OUT ($(wc -c < "$OUT") bytes)"
