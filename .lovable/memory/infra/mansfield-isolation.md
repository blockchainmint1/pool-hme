---
name: Mansfield-only stratum isolation
description: iptables pattern to isolate Mansfield (+ Conroe haproxy test) on scrypt stratum port 3433 with auto-revert timer, for debugging hashpower shortages without permanent risk. Includes apply/extend/lift snippets.
type: reference
---

# Purpose

Temporarily restrict `stratum.pool.honest.money:3433` to Mansfield only
(48 L9s, cellular, historically reliable) while debugging fleet-wide
hashrate issues. Always armed with a `sleep && iptables-restore` timer so
the box self-heals if we forget or get cut off.

# Apply (fresh block)

```bash
sudo bash -c '
set -e
STAMP=$(date +%Y%m%d-%H%M%S)
iptables-save > /root/iptables.pre-mansfield.$STAMP.rules
echo "snapshot: /root/iptables.pre-mansfield.$STAMP.rules"

# auto-revert in 30 min (adjust seconds as needed)
( sleep 1800 && iptables-restore < /root/iptables.pre-mansfield.$STAMP.rules \
  && logger "iptables-auto-revert fired" ) &
disown
echo "auto-revert armed, pid $!"

iptables -I INPUT 1 -p tcp --dport 3433 -s 97.154.36.156  -m comment --comment mansfield         -j ACCEPT
iptables -I INPUT 2 -p tcp --dport 3433 -s 13.217.211.175 -m comment --comment conroe-proxy-test -j ACCEPT
iptables -I INPUT 3 -p tcp --dport 3433 -j DROP

# kick everyone else off (returns count killed)
conntrack -D -p tcp --dport 3433 2>/dev/null | wc -l
'
```

# Extend (add another window)

```bash
sudo pkill -f "iptables-restore < /root/iptables.pre-mansfield" 2>/dev/null
LATEST=$(ls -t /root/iptables.pre-mansfield.*.rules | head -1)
sudo bash -c "( sleep 1800 && iptables-restore < $LATEST ) & disown"
```

# Lift early

```bash
sudo pkill -f "iptables-restore < /root/iptables.pre-mansfield" 2>/dev/null
sudo iptables-restore < $(ls -t /root/iptables.pre-mansfield.*.rules | head -1)
```

# Verify

```bash
sudo ss -Htn state established '( sport = :3433 )' \
  | awk '{print $4}' | cut -d: -f1 | sort | uniq -c | sort -rn
# expect: ~48 from 97.154.36.156, 0-1 from 13.217.211.175, nothing else
```

# Notes

- Only affects TCP 3433. SSL stratum on 3434 is left open by design.
- `INPUT` policy is already `DROP`, so the `-j DROP` at rule 3 is defense-in-depth against a future policy flip.
- Do NOT use my earlier `STRATUM_ALLOW` custom-chain variant — it clashed
  with the existing per-IP DROP rules and left dead references in
  snapshots. This pattern is the canonical one.
- Site IPs: Mansfield `97.154.36.156`, Conroe `209.34.50.105`, McKinney
  `99.107.246.68`, Conroe haproxy `13.217.211.175`. See
  `mem://infra/site-wan-ips`.
