#!/usr/bin/env bash
# Usage: ./vardiff-report.sh user@host [algo]
# Reads DB creds from ansible/group_vars/vault.yml on the box.
set -euo pipefail
TARGET="${1:?usage: $0 user@host [algo]}"
ALGO="${2:-scrypt}"

ssh "$TARGET" "sudo bash -s" <<EOF
set -e
CONF=/var/stratum/config/${ALGO}.conf
USER=\$(awk -F'= *' '/^username/{print \$2}' "\$CONF")
PASS=\$(awk -F'= *' '/^password/{print \$2}' "\$CONF" | tail -1)
DB=\$(awk -F'= *' '/^database/{print \$2}' "\$CONF")

echo "=== reported hashrate (last 8 samples) ==="
mysql -u "\$USER" -p"\$PASS" "\$DB" -e \
  "SELECT hashrate/1e12 AS TH_s, hashrate_bad/1e12 AS TH_bad, FROM_UNIXTIME(time) t
   FROM hashrate WHERE algo='${ALGO}' ORDER BY time DESC LIMIT 8;"

echo
echo "=== vardiff distribution ==="
mysql -u "\$USER" -p"\$PASS" "\$DB" -e \
  "SELECT
     SUM(CASE WHEN difficulty >= 16777216 THEN 1 ELSE 0 END) AS at_16M,
     SUM(CASE WHEN difficulty >= 8388608  THEN 1 ELSE 0 END) AS above_8M,
     SUM(CASE WHEN difficulty >= 4194304  THEN 1 ELSE 0 END) AS above_4M,
     SUM(CASE WHEN difficulty >= 1000000  THEN 1 ELSE 0 END) AS above_1M,
     SUM(CASE WHEN difficulty <= 100000   THEN 1 ELSE 0 END) AS below_100k,
     ROUND(AVG(difficulty)) AS avg_d,
     COUNT(*) AS n
   FROM workers WHERE algo='${ALGO}';"
EOF
