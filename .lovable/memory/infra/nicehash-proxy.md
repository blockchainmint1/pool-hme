---
name: NiceHash/MRR stratum shim
description: Why rental pool verification failed and the nicehash-proxy on port 3533 that fixes it without touching scrypt.conf
type: feature
---
Rental services (NiceHash, MiningRigRentals) fail pool verification against
`stratum.pool.honest.money:3433` for two reasons:

1. The **mining.subscribe reply** advertises `["mining.set_difficulty","16"]`.
   NiceHash parses that string — not the later `set_difficulty` notification —
   and errors `Pool difficulty too low (provided=16, minimum=50000)`. Passing
   `d=65536` in the password does NOT change the subscribe reply.
2. The first real `mining.notify` arrives 6–11s after connect; verifiers time
   out and log "Unknown message".

Fix: `infra/nicehash-proxy/` — a dependency-free Node TCP shim on **3533**
forwarding to 127.0.0.1:3433. It rewrites the subscribe-reply difficulty,
injects `d=<MIN_DIFF>` into authorize passwords, raises sub-minimum
set_difficulty, and primes each connection with a cached job (from a
persistent sentinel upstream connection) in ~0.3s. Verified: subscribe
advertises 65536, first job at 0.31s.

Deploy: `bash infra/nicehash-proxy/build-bundle.sh` → Publish → on the box
`curl -fsSL https://pool.honest.money/install/nicehash-proxy.sh | sudo bash`.
Requires AWS security-group inbound TCP 3533.

Rental settings: host `stratum.pool.honest.money:3533`, user = LTC address
(+`.nh`/`.mrr` worker suffix), pass `x`.

The live stratum config stays untouched — that rule still holds.
