#!/usr/bin/env bash
#
# build-bundle.sh — regenerate public/install/yiimp-api.sh
#
# Produces a single self-contained bash script (with an embedded base64
# tarball of the whole yiimp-api tree) served from
# https://pool.honest.money/install/yiimp-api.sh
#
# Re-run this whenever anything under infra/yiimp-api/ changes.
#
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../.." && pwd)"
OUT="$REPO/public/install/yiimp-api.sh"

echo "==> packing $SRC → $OUT"

TAR_B64="$(cd "$SRC" && tar czf - \
    install.sh .env.example package.json tsconfig.json \
    src/ nginx/ systemd/ README.md \
    | base64 -w 0 2>/dev/null || tar czf - \
    install.sh .env.example package.json tsconfig.json \
    src/ nginx/ systemd/ README.md | base64)"

mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<'HEADER'
#!/usr/bin/env bash
#
# yiimp-api bootstrap — one-paste installer.
#
# On the yiimp/stratum box (Ubuntu, DNS for api.stratum.pool.honest.money
# already pointing here), run:
#
#   curl -fsSL https://pool.honest.money/install/yiimp-api.sh | sudo bash
#
# After it finishes:
#   1. sudo nano /etc/yiimp-api/env    # set MYSQL_PASSWORD
#   2. sudo systemctl restart yiimp-api
#   3. curl -s https://api.stratum.pool.honest.money/api/health
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

SIZE="$(wc -c < "$OUT")"
LINES="$(wc -l < "$OUT")"
echo "==> wrote $OUT"
echo "    size: $SIZE bytes, $LINES lines"
