#!/usr/bin/env bash
# Usage: ./health-check.sh user@host [algo]
# Defaults to scrypt. Reproduces the diagnostic commands used during the
# 2026-07-15 lock-contention incident.
set -euo pipefail
TARGET="${1:?usage: $0 user@host [algo]}"
ALGO="${2:-scrypt}"

ssh "$TARGET" "sudo bash -s" <<EOF
set -e
echo "=== service status ==="
systemctl status stratum-aws-${ALGO}.service --no-pager | head -12

echo
echo "=== connection count ==="
PORT=\$(grep -oE '^port *= *[0-9]+' /var/stratum/config/${ALGO}.conf | head -1 | awk '{print \$3}')
ss -tn "( sport = :\$PORT )" | wc -l

echo
echo "=== top client IPs ==="
ss -tn "( sport = :\$PORT )" | awk 'NR>1{split(\$5,a,":");print a[1]}' | sort | uniq -c | sort -rn | head -5

echo
echo "=== 5s syscall profile ==="
PID=\$(pgrep -n -x stratum || true)
if [ -n "\$PID" ]; then
  timeout 5 strace -c -f -p "\$PID" 2>&1 | tail -12
fi

echo
echo "=== log tail ==="
tail -n 5 /var/stratum/${ALGO}.log
EOF
