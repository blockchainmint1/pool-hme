#!/usr/bin/env bash
# Dumps the mempool stats DB to /var/backups/txc-stack/mempool-YYYYMMDD.sql.gz
# Keeps the last 14 dumps. Schedule with cron:  0 4 * * * /opt/txc-stack/scripts/backup.sh

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

OUT=/var/backups/txc-stack
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M)
FILE="$OUT/mempool-$STAMP.sql.gz"

docker compose exec -T mempool-db \
  mariadb-dump -u root -p"${MYSQL_ROOT_PASSWORD}" --single-transaction "${MYSQL_DATABASE}" \
  | gzip -9 > "$FILE"

echo "wrote $FILE ($(du -h "$FILE" | cut -f1))"

# prune
ls -1t "$OUT"/mempool-*.sql.gz | tail -n +15 | xargs -r rm -v
