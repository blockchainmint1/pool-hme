# honest.money Pool API

Base URL: `https://api.stratum.pool.honest.money`

Public, read-only, no auth. Every response is JSON. CORS is open. Cached edge-side for 20–30 s where sensible.

The `/api/v1/*` namespace is the stable surface. The unversioned `/api/*` paths are kept as legacy aliases for one release.

## What this API knows that mempool/explorer don't

`api.mempool.texitcoin.org` and the block explorers answer chain questions — headers, tx, mempool, addresses. This API answers **pool** questions:

- Which of the 5 merged-mined chains (LTC / DOGE / ISK / TXC / ZCU) got credited for the same accepted share, and when?
- What is the pool's current effort on each chain? Are we due for a block?
- Who is actually connected to stratum right now (real number, not the stale `workers` DB rollup)?
- Where in the world are the miners connected?
- What is my address's per-worker hashrate, payout history, and per-block credit?
- Realtime: subscribe once, get every block-found + hashrate-tick without polling.

## Endpoints

### Health
```
GET /api/v1/health
→ { ok, db, uptime, version }
```

### Coins
```
GET /api/v1/coins
GET /api/v1/coins/:symbol           → algo, price, difficulty, network_hash, reward, fees
GET /api/v1/coins/:symbol/blocks    → recent pool-found blocks for one coin
```

### Pool
```
GET /api/v1/pool/summary                       → one-shot dashboard payload
GET /api/v1/pool/hashrate?window=1h|24h|7d|30d → per-algo time-series from hashstats
GET /api/v1/pool/effort                        → shares_since_last_block ÷ network_difficulty
GET /api/v1/pool/blocks/luck?window=…          → actual blocks over window
```

### Merged mining (unique to this API)
```
GET /api/v1/mergedmining/summary?window=…  → per-round: primary chain + auxpow chains credited
GET /api/v1/mergedmining/credits?limit=200 → flat credit feed, tagged solo|auxpow
```

### Miners
```
GET /api/v1/miners/count                     → live stratum clients per algo (the real number)
GET /api/v1/miners/top?limit=50              → leaderboard (addresses truncated)
GET /api/v1/miners/locations                 → country/region rollup from GeoIP, no IPs
GET /api/v1/miner/:address                   → summary: balance, pending, paid, per-algo online
GET /api/v1/miner/:address/workers           → per-worker rows with country/region (never IP)
GET /api/v1/miner/:address/hashrate?window=… → per-miner time-series
GET /api/v1/miner/:address/payouts?limit=50  → payout history
GET /api/v1/miner/:address/earnings?limit=…  → per-block credits with block hash + algo
```

### Realtime
```
GET /api/v1/stream                           → Server-Sent Events
  event: hello           { time, version }
  event: block-found     { algo, symbol, height, hash, time }
  event: hashrate-tick   { algo, clients, accepted_ghs, time }
  event: ping            (keepalive)
```

Example (curl):
```bash
curl -N https://api.stratum.pool.honest.money/api/v1/stream
```

## Privacy

- Raw IPs are **never** returned in any public response.
- `/api/v1/miners/locations` returns only aggregate country/region rollups.
- `/api/v1/miner/:address/workers` includes `country` + `region` but not the IP itself.
- Wallet addresses are public data on-chain and are used as the account key, exactly like every other yiimp-based pool.

## Rate limits

nginx: 20 req/s per IP, burst 50. SSE connections do not count toward request-rate limits.

## OpenAPI

```
GET /api/v1/openapi.json
```

Machine-readable schema for client generation. Enough to point Swagger UI or `openapi-typescript` at.

## Client SDK

```ts
import { PoolClient } from "@honestmoney/pool-sdk";
const pool = new PoolClient(); // defaults to https://api.stratum.pool.honest.money

const summary = await pool.getSummary();
const workers = await pool.getMinerWorkers("YOUR_ADDRESS");

pool.stream({
  onBlockFound: (b) => console.log("block!", b),
  onHashrateTick: (t) => console.log("tick", t),
});
```

See `infra/pool-sdk/` in the honest.money-pool repo.
