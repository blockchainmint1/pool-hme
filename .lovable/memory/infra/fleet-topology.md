---
name: Fleet topology (Conroe TX)
description: 6 Foghashing BC40 containers, 200 Antminer L9s each, 1200 total. Each container fronted by a Beelink for NAT/conntrack offload.
type: feature
---
Single site: Conroe, TX.
Hardware: 6× Foghashing BC40 containers, 200 Antminer L9s per container = 1200 L9s total.
Each container has a Beelink mini-PC doing SNAT/DHCP (`10.N.0.0/24`, `10.N.0.10` = HAProxy) so conntrack lives on the Beelink, not the landlord CPE.
All containers share a single WAN IP (209.34.50.105) at the landlord — expect ~200 established sessions per container from that IP on stratum.pool.honest.money:3433.
Healthy full-fleet target: ~1200 established TCP sessions on port 3433 from 209.34.50.105.
Per-container smoke: ~200 sessions. Significantly fewer = container's L9s not fully repointed or Beelink NAT broken.
