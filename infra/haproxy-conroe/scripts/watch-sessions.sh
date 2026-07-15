#!/usr/bin/env bash
# Live view of miner→proxy and proxy→upstream session counts.
set -euo pipefail

while true; do
  clear
  echo "== $(date -u +%FT%TZ) =="
  MINERS=$(ss -Htn state established sport = :3433 | wc -l)
  UPSTREAM=$(ss -Htn state established dport = :3433 | wc -l)
  echo "miner  → proxy   (established, sport=3433): $MINERS"
  echo "proxy  → upstream (established, dport=3433): $UPSTREAM"
  echo
  echo "-- top miner source IPs --"
  ss -Htn state established sport = :3433 \
    | awk '{print $4}' | sed 's/:[0-9]*$//' \
    | sort | uniq -c | sort -rn | head -10
  sleep 2
done
