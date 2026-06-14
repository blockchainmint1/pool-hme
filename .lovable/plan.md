# Three-part build: Public API, Live Price, Fun Address Page

## 1) Public API + `/docs` page

Stand up a **TXC-flavored** version of the mempool.space REST/WebSocket API, hosted on our explorer at `/api/v1/*`. Routes proxy through to the self-hosted backend at `api.mempool.texitcoin.org` and add TXC-only extras.

**New server routes** (under `src/routes/api/public/v1/`, so they're CORS-free for outside callers):
- `blocks/tip/height`, `blocks/tip/hash`
- `block/$hash`, `block/$hash/txids`, `block-height/$height`
- `blocks` (paginated), `blocks/$startHeight`
- `tx/$txid`, `tx/$txid/status`, `tx/$txid/hex`, `tx/$txid/outspends`
- `address/$addr`, `address/$addr/utxo`, `address/$addr/txs`
- `mempool`, `mempool/recent`, `fees/recommended`, `fees/mempool-blocks`
- `mining/pools/24h|1w|1m`, `difficulty-adjustment`
- **TXC extras**: `omni/tx/$txid` (decoded Omni payload), `price` (live TXC price + 24h change), `supply` (circulating supply from emission curve)
- `ws` — thin WebSocket pass-through to the upstream mempool WS, so external apps can subscribe to new blocks/txs/address updates

All routes: GET-only, CORS `*`, OPTIONS handlers, JSON, 30-60s edge cache where appropriate.

**New `/docs` route**: a clean, searchable reference page (left sidebar of categories, right pane with endpoint + example curl + example JSON response) styled in the explorer's dark theme. Tabs for **REST** and **WebSocket**.

## 2) Live TXC price (CoinMarketCap)

- Add `CMC_API_KEY` secret.
- New server fn `getTxcPrice` → calls CMC `/v2/cryptocurrency/quotes/latest?symbol=TXC`, caches result for 60s in memory.
- New `/api/v1/price` public endpoint exposes `{ usd, btc, change24h, marketCap, volume24h, updatedAt }`.
- New `<PriceTicker>` component pinned in the top nav: TXC/USD with green/red 24h delta.
- USD values appear next to TXC amounts on the **address** and **tx** pages (toggleable).

## 3) Supercharged address page

Rebuild `/address/$addr` into a multi-section dashboard:

1. **Header card** (existing) + new pills: first-seen, last-seen, age, Type badge (P2PKH / P2SH / Multisig / Omni-issuer if detected).
2. **Balance History chart** — line/area chart (Recharts), computed client-side by walking the address's tx history and summing deltas. Toggle: All vs Last 30 days. USD overlay if price is available.
3. **UTXO bubble chart** — packed circles sized by sat value, color-graded by age (fresh → aged). Hover = value + height + age. Click = jump to funding tx.
4. **Activity heatmap** — GitHub-style 12-month grid, one cell per day, intensity = tx count.
5. **Flow & counterparties** — totals received vs sent, top 5 sending addresses, top 5 receiving addresses (with TXC totals), Omni token holdings if present.
6. **Tx history list** (existing) moved to the bottom, with sticky filter chips: All / Received / Sent / Omni / Coinbase.

## Technical details

- Server routes use `createFileRoute(... )({ server: { handlers: { GET, OPTIONS } } })` with shared `CORS_HEADERS` helper at `src/lib/api/cors.ts`.
- A thin `proxy(path)` helper in `src/lib/api/upstream.ts` fetches from `https://api.mempool.texitcoin.org/api/v1/...` and returns `Response.json(...)` with CORS + cache headers.
- Charts use the existing `recharts` (already in deps); bubble packing uses `d3-hierarchy` (small, edge-safe).
- Heatmap is a custom CSS-grid component (no extra dep).
- Price fetcher is a server fn (keeps CMC key server-side), called from a React Query hook polling every 60s.
- Docs page content is a single data file (`src/lib/docs/api-spec.ts`) so endpoints stay easy to edit.

## Files (new)
- `src/lib/api/cors.ts`, `src/lib/api/upstream.ts`
- `src/routes/api/public/v1/*.ts` (one per endpoint group)
- `src/routes/docs.tsx`
- `src/lib/docs/api-spec.ts`
- `src/lib/txc/price.functions.ts`, `src/components/explorer/PriceTicker.tsx`
- `src/components/address/BalanceHistoryChart.tsx`
- `src/components/address/UtxoBubbleChart.tsx`
- `src/components/address/ActivityHeatmap.tsx`
- `src/components/address/CounterpartiesPanel.tsx`

## Out of scope (for this round)
- Persisting historical price snapshots (we'll just cache live).
- Authenticated/rate-limited API keys (open public API for now).
- Mobile-specific layouts beyond what Tailwind responsive utilities already give us.

Ready to build — shall I go?