
# TXC Mempool Explorer — Plan

## TL;DR

You already have all the hard backend infra: a synced TXC node behind a mempool/Esplora-compatible HTTP API at `https://mempool.texitcoin.org/api` (the same API surface mempool.space's frontend talks to). That means this becomes a **frontend project**, not an infra project — fully buildable inside Lovable's normal TanStack Start stack, no node-running, no indexer.

The build is the full mempool.space feature set, re-skinned in TEXITcoin branding (consistent with TEXITcoin.org, the wallet, etc.), with extra OP_RETURN / Omni-Layer parsing so token activity is first-class.

## What it will include

**Live dashboard (home `/`)**
- Mempool blocks visualization: colored projected blocks by fee bucket, from `/api/v1/fees/mempool-blocks`
- Confirmed blocks strip: latest ~8 blocks with height, age, tx count, size, miner pool, fee range
- Fee gauge: next-block / 30m / 1h recommended sat/vB from `/api/v1/fees/recommended`
- Stats tiles: tip height, hashrate, difficulty, avg block time, mempool size (count + vsize)
- Live updates over WebSocket (`wss://mempool.texitcoin.org/api/v1/ws` — falls back to 10s polling if not exposed)

**Blocks `/blocks` + `/block/$hash`**
- Paginated block list
- Block detail: header, miner pool, reward, fee total, fee histogram, full tx list with pagination

**Transactions `/tx/$txid`**
- Inputs/outputs with addresses, values, prev-tx links
- Status (confirmed in block X / N confirmations / in mempool with projected block position)
- Fee, fee rate (sat/vB), vsize, weight
- RBF status, ancestor/descendant info where API provides it
- **OP_RETURN decoder panel**: detects the `omni` magic bytes and renders parsed Omni-Layer payloads (Simple Send, Issuance, etc.) with property ID, amount, sender/receiver — based on the format documented at cryptopop.asia/api and imaginenation.com/api. Raw hex fallback for unknown payloads.

**Addresses `/address/$addr`**
- Balance (confirmed / unconfirmed), tx count, totals
- UTXO list and tx history with infinite scroll
- "Tokens held" summary aggregated from OP_RETURN history (best-effort, client-side decode)
- QR code, copy buttons

**Mining `/mining`**
- Pool distribution donut (last 24h / 1w / 1m) from `/api/v1/mining/pools/*`
- Hashrate chart, difficulty adjustment progress and ETA
- Reward and block-time stats

**Charts `/graphs`**
- Mempool size over time, fee rate over time, block size, tx count per block — from `/api/v1/mining/*` and `/api/v1/statistics/*`

**Search**
- Global search bar: detects whether input is a block height, block hash, txid, or TXC address (T-prefix) and routes accordingly

**Static**
- `/about` (what this is, links to wallet, texitcoin.org, the L2 docs)
- `/api` (proxy of the upstream API reference, plus the OP_RETURN/Omni decoder schema we use)

## How it's built

**Stack** (default Lovable TanStack Start template — no infra changes)
- TanStack Start v1 + React 19, Vite 7
- Tailwind v4 with semantic tokens in `src/styles.css`, TEXITcoin palette pulled from the existing TXC projects
- TanStack Query for data fetching/caching (matches the project template's loader + `useSuspenseQuery` pattern)
- D3 (`d3-scale`, `d3-shape`) + Recharts for charts; custom SVG for the signature mempool-blocks viz
- Framer Motion for the block-arrival animation
- `qrcode.react` for address QR codes

**Data layer** (`src/lib/txc/`)
- `network.ts` — base URLs, network constants (ported from your wallet project)
- `esplora.ts` — typed wrapper around `mempool.texitcoin.org/api` (extended beyond your wallet's version: blocks list, block detail, mining endpoints, mempool stats, recent txs, search-by-height/hash)
- `omni.ts` — OP_RETURN parser. Detects `omni` magic, decodes Simple Send (type 0), Managed Issuance (type 54), Send-All (type 4) etc. per cryptopop.asia spec; returns `{ kind, propertyId, amount, ... }`
- `ws.ts` — WebSocket client with auto-reconnect + polling fallback; React hook `useMempoolFeed()` that publishes new blocks, mempool deltas, fee updates
- `format.ts` — sats↔TXC, vsize, time-ago, hash truncation

**Routes** (file-based under `src/routes/`)
- `index.tsx`, `blocks.tsx`, `block.$hash.tsx`, `tx.$txid.tsx`, `address.$addr.tsx`, `mining.tsx`, `graphs.tsx`, `about.tsx`, `api.tsx`, `$.tsx` (catch-all → search)
- Each route ships its own `head()` meta (title/description/og) for SEO and share previews

**Component shape**
- `<MempoolBlocksViz>` (the colored projected-blocks graphic)
- `<ConfirmedBlocksStrip>`, `<BlockCard>`, `<FeeGauge>`, `<StatsTile>`
- `<TxFlow>` (input → output visualization), `<OpReturnPanel>`, `<AddressHeader>`
- `<PoolDonut>`, `<HashrateChart>`, `<DifficultyAdjustment>`
- `<SearchBar>` (in root header), `<NetworkBadge>` (mainnet only for v1)

**Theming**
- Pulled from existing TXC projects so this feels native to the Honest Money ecosystem: deep navy + red/orange TEXITcoin accents, monospace for hashes/heights, sharp corners, dense data-dashboard density (not soft consumer-y)

## Risks / open items

1. **WebSocket availability**: I'll detect at runtime. If `wss://mempool.texitcoin.org/api/v1/ws` isn't exposed, polling fallback kicks in transparently. I'll note this in `/about`.
2. **Mining endpoints**: mempool-backend's `/api/v1/mining/*` may or may not be enabled on the TXC instance. I'll feature-detect and hide the `/mining` page if the endpoints 404. (Easy follow-up: ask the upstream operator to enable them.)
3. **Omni decoder coverage**: I'll cover the message types documented at cryptopop.asia/api (Simple Send, Issuance variants, Send-All). Anything outside that shows as "Unknown Omni payload type N" + raw hex — easy to extend later as new types appear.
4. **CORS**: if browser-direct fetches to `mempool.texitcoin.org` get blocked, I'll add a thin TanStack Start server route at `/api/proxy/$` that forwards to the upstream. (Negligible cost; cached at the edge.)

## Out of scope for v1

- Lightning Network (TXC doesn't run LN)
- Testnet/signet switcher (mainnet only — easy to add later)
- Accelerator / paid prioritization (mempool.space premium feature, doesn't apply here)
- Running our own indexer (not needed — upstream API is sufficient)

## Effort

Realistically 1 polished pass to get the dashboard, blocks, tx, address, search, and OP_RETURN decoder shipped and looking sharp. Mining + charts pages are a natural second pass once we confirm which `/api/v1/mining/*` endpoints the upstream exposes.
