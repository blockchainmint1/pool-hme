#!/usr/bin/env bash
# Usage: ./share-audit.sh user@host [algo]
set -euo pipefail
TARGET="${1:?usage: $0 user@host [algo]}"
ALGO="${2:-scrypt}"

ssh "$TARGET" "sudo bash -s" <<EOF
set -e
LOG=/var/stratum/${ALGO}.log
echo "=== log-event distribution (last 50k lines) ==="
tail -n 50000 "\$LOG" | awk '{print \$2, \$3, \$4}' | sort | uniq -c | sort -rn | head -15

echo
echo "=== share results ==="
echo "accepted: \$(tail -n 50000 "\$LOG" | grep -cE 'share.*accepted|found share' || true)"
echo "rejected: \$(tail -n 50000 "\$LOG" | grep -cE 'share.*reject' || true)"
echo "stale:    \$(tail -n 50000 "\$LOG" | grep -cE 'stale' || true)"
echo "lowdiff:  \$(tail -n 50000 "\$LOG" | grep -cE 'low.?difficulty' || true)"
EOF
