# Track 1: Expand yiimp-api (this turn)

Building out the yiimp-api service on `stratum.pool.honest.money` so the frontend, third-party dashboards, and the SDK all have real data. Tracks 2–4 (miner reg flow, graph rebuild, workers/locations page) come after this ships.

## The 4 answers that shape this build

1. **Active miner = live stratum clients**, not the `workers` MySQL table. The workers table keeps stale rows for hours after disconnect — that's why the number looks wrong. Truth is the `clients=` field on `SCRYPT summary diag` lines emitted every minute by the stratum daemon.
2. **Locations = country + region from GeoIP**, raw IPs stay admin-only (never in a public response).
3. **API's unique value = pool-native + merged-mining + realtime + SDK.** All four. Explorer/mempool can't see any of this.
4. **Scope order:** finish the endpoints first, then everything else has real data to render.

## New endpoints on `api.stratum.pool.honest.money`

Read-only, versioned under `/api/v1/*`. Existing `/api/*` stays as a legacy alias for one release.

### Pool-native

| Endpoint | Returns |
|---|---|
| `GET /api/v1/pool/summary` | one-shot dashboard payload: hashrate per algo, active clients per algo, blocks 24h, last block per coin, luck, fees, effort |
| `GET /api/v1/pool/hashrate?window=1h\|24h\|7d\|30d` | time-series from `hashstats` (yiimp's own rollup) — pool total + per-algo |
| `GET /api/v1/pool/blocks/luck?window=24h\|7d\|30d` | actual vs expected blocks per coin (uses network difficulty) |
| `GET /api/v1/pool/effort` | current round effort per coin: shares since last block ÷ network difficulty |
| `GET /api/v1/coins/:symbol` | one coin: algo, block reward, network diff, network hashrate, current price (from `coins.price` col), fee, min payout |
| `GET /api/v1/coins/:symbol/blocks?limit=100` | pool-found blocks for that coin |

### Merged-mining truth (the thing nobody else surfaces)

| Endpoint | Returns |
|---|---|
| `GET /api/v1/mergedmining/summary` | for each scrypt block round: primary chain solved (TXC/ISK/ZCU), and which auxpow chains (LTC/DOGE) also credited in the same time window |
| `GET /api/v1/mergedmining/credits?limit=200` | flat feed of every credit event across all 5 coins, source: auxpow vs solo, so consumers can reconstruct "one hash → 5 coins" |

### Miners & workers (with corrected counts)

| Endpoint | Returns |
|---|---|
| `GET /api/v1/miners/top?limit=50` | leaderboard: address (truncated), hashrate 1h, workers online, algo — no IPs |
| `GET /api/v1/miners/count` | live from stratum diag: `{scrypt: {clients, active, accepted_ghs}}` — the real "active miners" number |
| `GET /api/v1/miners/locations` | aggregate `{country, region, miner_count, hashrate}[]` from GeoIP over live IPs; no per-address geo in public response |
| `GET /api/v1/miner/:address/summary` | already exists — extend with 1h/24h hashrate history |
| `GET /api/v1/miner/:address/workers` | already exists — add `country_code`, `region` (from live stratum IP+GeoIP), hashrate history |
| `GET /api/v1/miner/:address/hashrate?window=24h\|7d` | per-miner time-series |

### Realtime

| Endpoint | Returns |
|---|---|
| `GET /api/v1/stream` (SSE) | server-sent events: `block-found`, `share-batch`, `hashrate-tick`, `client-connected`, `client-disconnected`. SSE first (works everywhere, one-way); WS upgrade later if needed |

## Server-side implementation

### Fixing the miner count

Add `scrapeStratumSummaries()` variants for all active algos, parse `clients` / `active` / `accepted_ghs` / `valid` / `invalid` from the last summary line of each `${algo}.log` in `STRATUM_LOG_DIR`. Cache 30s. Expose at `/api/v1/miners/count` and inline into `/api/v1/pool/summary`.

### GeoIP

Add `geoip-lite` (embedded MaxMind Lite DB, ~30 MB, refreshed monthly via cron). Look up `accounts.IP` on demand, drop octets before returning, aggregate before any public response.

### hashstats time-series

yiimp's `hashstats` table has per-algo hashrate samples every ~2 min. Query with time bucketing.

### SSE stream

Fastify `reply.sse()` via `fastify-sse-v2`. Tail stratum log + poll `blocks`/`workers` deltas, fan out. Backpressure: bounded per-connection queue, drop oldest.

## Frontend wiring (this turn)

- Update `src/lib/pool/pool.functions.ts`: swap `/api/*` calls to `/api/v1/*`, add `getPoolLive` server fn that hits `/api/v1/pool/summary` and `/api/v1/miners/count` in parallel.
- Wire `blocks24h`, active miners, and per-coin last-block time on the homepage to live numbers.
- Fix the `17m/18m ago` SSR-vs-client hydration mismatch by rendering relative times only after mount.

## Public docs

- `GET /api/v1/openapi.json` — machine-readable spec (generated from Fastify schemas).
- Add `docs/api.md` in this repo with copy-pasteable curl examples for every endpoint.
- Publish `@honestmoney/pool-sdk` (TypeScript, works in Node + browser, WS auto-reconnect) — repo scaffold in `infra/pool-sdk/`. Publish to npm in a later turn.

## Deploy path

I edit `infra/yiimp-api/src/server.ts` + package.json in this repo. Then you run on the box:

```
cd ~/yiimp-api && git pull && bun install && sudo systemctl restart yiimp-api
```

New `geoip-lite` dep adds ~30 MB — first `bun install` takes an extra minute.

## Files touched

- `infra/yiimp-api/src/server.ts` — new endpoints
- `infra/yiimp-api/src/stratum-live.ts` — SSE fan-out + log tailing
- `infra/yiimp-api/src/geoip.ts` — GeoIP wrapper
- `infra/yiimp-api/src/hashstats.ts` — time-series queries
- `infra/yiimp-api/package.json` — add `fastify-sse-v2`, `geoip-lite`
- `infra/yiimp-api/README.md` — update endpoint list
- `docs/api.md` — public API docs
- `src/lib/pool/pool.functions.ts` — call `/api/v1/*`
- `src/routes/index.tsx` — wire live miner count, fix hydration mismatch
- `infra/pool-sdk/` — SDK scaffold (published later)

## Not in this turn

Tracks 2–4 (new registration flow, graph rebuild, workers/locations UI page) — each is a big enough surface that they deserve their own turn once endpoints are live and returning real data.
