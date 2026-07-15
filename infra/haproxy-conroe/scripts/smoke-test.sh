#!/usr/bin/env bash
# Quick sanity check that HAProxy is up and can reach upstream stratum.
set -euo pipefail

echo "-- haproxy status --"
systemctl is-active haproxy && echo "  active" || { echo "  DOWN"; exit 1; }

echo "-- listener on :3433 --"
ss -ltn '( sport = :3433 )' | grep -q ':3433' && echo "  bound" || { echo "  NOT bound"; exit 1; }

echo "-- upstream reachable --"
if timeout 5 bash - > /dev/null; then
  echo "  stratum.pool.honest.money:3433 open"
else
  echo "  stratum.pool.honest.money:3433 UNREACHABLE"
  exit 1
fi

echo "-- local accept test --"
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3433' 2>/dev/null; then
  echo "  127.0.0.1:3433 accepts"
else
  echo "  127.0.0.1:3433 does NOT accept"
  exit 1
fi

echo "OK"
