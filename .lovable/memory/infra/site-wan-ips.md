---
name: Site WAN egress IPs
description: Known WAN egress IPs per mining site (Conroe, Mansfield, McKinney). Use to isolate/filter stratum traffic per site.
type: reference
---
Mining site WAN egress IPs, as seen by yiimp stratum on `stratum.pool.honest.money:3433`.

- **Conroe, TX** — `209.34.50.105` — largest site, ~325+ L9s. This is Conroe's NAT egress, ALL L9s at Conroe appear as this IP (whether direct or via haproxy).
- **Mansfield, TX** — `97.154.36.156` — 48 L9s. Historically very reliable — good baseline for isolation tests.
- **McKinney, TX** — `99.107.246.68` — 21 L9s.

Conroe also has a proxy at `13.217.211.175` (haproxy L4 passthrough → stratum). L9s pointed at the proxy egress as haproxy's WAN, not `209.34.50.105`. Only used for a single test L9 currently.

To list live sessions per site:
```
sudo ss -Htn state established '( sport = :3433 )' \
  | awk '{print $4}' | cut -d: -f1 | sort | uniq -c | sort -rn | head
```
