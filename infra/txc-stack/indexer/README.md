# TXC address indexer

Small Node/TypeScript service that walks the TexitCoin chain via JSON-RPC and
serves Esplora-compatible `/address/*` endpoints. SQLite for storage.

## Why this exists

Stock `electrs` / `mempool-electrs` only support Bitcoin's network params
(magic bytes, genesis hash, address prefixes). TexitCoin is a fork, so they
won't index it. Rather than maintain a patched Rust fork, this service uses
nothing but texitcoind's stable JSON-RPC surface.

## What it provides

Esplora REST endpoints used by the explorer frontend:

- `GET /address/:addr` → `{ address, chain_stats, mempool_stats }`
- `GET /address/:addr/utxo` → unspent outputs
- `GET /address/:addr/txs` → 25 most-recent confirmed + mempool txs
- `GET /address/:addr/txs/chain/:lastSeenTxid` → next 25 confirmed
- `GET /address/:addr/txs/mempool` → pending txs
- `GET /health` → `{ ok, tip }`

## How it works

1. Poll `getblockcount` every 5s.
2. For each new block: `getblock <hash> 2` (full tx data), then in one
   SQLite transaction insert every output's `(address, txid, value, height)`
   row and mark every spent prevout.
3. On reorg (parent hash mismatch), roll back blocks one at a time until we
   re-converge with the node, then move forward.
4. Mempool snapshot refreshes every 15s via `getrawmempool` +
   `getrawtransaction` per tx; address-level deltas are stored so address
   pages can report pending balance changes.
5. HTTP responses are assembled on demand by calling `getrawtransaction` for
   the tx ids we need to return; we cache per-request to avoid duplicate RPC
   fan-out within a single page.

## Storage

A single SQLite file at `$DB_PATH` (default `/data/indexer.sqlite`). Mount a
volume at `/data`. Initial sync time depends on chain length — expect a few
hours for a chain with millions of txs. Subsequent restarts resume in
seconds.

## Environment

| Var | Default | Notes |
|-----|---------|-------|
| `RPC_URL` | `http://host.docker.internal:15739` | texitcoind RPC endpoint |
| `RPC_USER` | — | from texitcoin.conf |
| `RPC_PASSWORD` | — | from texitcoin.conf |
| `DB_PATH` | `/data/indexer.sqlite` | SQLite file path |
| `HTTP_PORT` | `3001` | Listen port |
| `POLL_MS` | `5000` | Block poll interval |
| `MEMPOOL_REFRESH_MS` | `15000` | Mempool snapshot interval |

## Running locally (dev)

```sh
npm install
RPC_URL=http://127.0.0.1:15739 RPC_USER=... RPC_PASSWORD=... npm run dev
```

## In the stack

Wired into `docker-compose.yml` as service `indexer`; nginx routes
`/api/address/...` and `/api/v1/address/...` to it. The mempool-api stays
on `MEMPOOL_BACKEND=none`.
