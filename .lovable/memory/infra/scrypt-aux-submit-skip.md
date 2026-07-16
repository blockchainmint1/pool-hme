---
name: scrypt aux submit skip is normal
description: "aux submit skip" in scrypt.log is per-share filtering, NOT an error; and how to correctly diagnose "not mining LTC/DOGE"
type: feature
---
`XXX aux submit skip target parent_diff=X child_diff=Y hash=...` in
`/var/stratum/scrypt.log` is NORMAL. Every share is checked against every
aux chain's target; if the share's computed difficulty doesn't meet an aux
chain's child_diff, it logs a skip. Most shares skip every aux. This is not
a bug, not an RPC failure, not a config error.

Correct signals that LTC parent-chain templating is healthy:
- `LTC <height> - diff <N> job <id> to X/X/X clients, hash ...` lines every few seconds
- `LTC template mweb length=...` lines (MWeb rules active)
- DB: `shares` table has thousands of `valid=1` rows with `coin_id` = LTC id in the last hour

Correct signals that merged aux submission is working:
- `child_diff` values are being logged per aux per share (means the aux is
  wired in and being evaluated)
- TXC/ISK aux find blocks regularly at `child_diff` ~200k-240k
- DOGE aux `child_diff` is ~40M (varies with DOGE network diff) — roughly
  ~200x harder than TXC/ISK, so DOGE blocks are ~200x rarer at the same
  effective hashrate. Long gaps without a DOGE block are variance, not bugs.

LTC block variance: LTC network diff ~91M and network hashrate ~2.5+ EH/s
means a small pool (5-20 TH/s) statistically waits many hours between LTC
blocks. "No LTC block in 36h" is unlucky, not broken.

Real diagnosis when the user says "LTC/DOGE not mining":
1. Check the log for `LTC ... job ... to X clients` — if present, parent
   chain is fine, stop investigating that.
2. Check `shares` table for valid LTC shares in the last hour — if > 0,
   merged mining is running.
3. Compute expected block rate = pool_hashrate / network_hashrate * blocks_per_day.
   Confirm the observed gap is within a few multiples of that expectation
   before calling it broken.
4. If effective hashrate is well below fleet capacity, the real bug is in
   the miner-side path (proxy, network, ASIC health), not in the pool.
