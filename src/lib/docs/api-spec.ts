export interface Endpoint {
  method: "GET" | "WS";
  path: string;
  summary: string;
  example?: string; // example JSON response (string, may be truncated)
}

export interface EndpointGroup {
  id: string;
  title: string;
  description: string;
  endpoints: Endpoint[];
}

export const REST_GROUPS: EndpointGroup[] = [
  {
    id: "chain",
    title: "Chain tip & blocks",
    description: "Current chain tip and block summaries.",
    endpoints: [
      { method: "GET", path: "/api/v1/blocks/tip/height", summary: "Latest block height (plain text).", example: `312188` },
      { method: "GET", path: "/api/v1/blocks/tip/hash", summary: "Hash of the latest block." },
      { method: "GET", path: "/api/v1/blocks", summary: "Last 10 blocks (most recent first)." },
      { method: "GET", path: "/api/v1/blocks/:startHeight", summary: "10 blocks starting at the given height (descending)." },
      { method: "GET", path: "/api/v1/block/:hash", summary: "Block details by hash." },
      { method: "GET", path: "/api/v1/block-height/:height", summary: "Block hash for the given height." },
      { method: "GET", path: "/api/v1/block/:hash/txids", summary: "All txids in a block." },
    ],
  },
  {
    id: "tx",
    title: "Transactions",
    description: "Transaction lookup, outspends, raw hex.",
    endpoints: [
      { method: "GET", path: "/api/v1/tx/:txid", summary: "Full transaction object (inputs, outputs, fee, status)." },
      { method: "GET", path: "/api/v1/tx/:txid/status", summary: "Confirmation status." },
      { method: "GET", path: "/api/v1/tx/:txid/hex", summary: "Raw transaction hex." },
      { method: "GET", path: "/api/v1/tx/:txid/outspends", summary: "Array of {spent, txid?, vin?} per output." },
    ],
  },
  {
    id: "address",
    title: "Addresses",
    description: "Balance, UTXOs, transaction history.",
    endpoints: [
      { method: "GET", path: "/api/v1/address/:addr", summary: "Address summary: chain_stats + mempool_stats." },
      { method: "GET", path: "/api/v1/address/:addr/utxo", summary: "Unspent outputs at this address." },
      { method: "GET", path: "/api/v1/address/:addr/txs", summary: "Most recent transactions involving this address." },
    ],
  },
  {
    id: "mempool",
    title: "Mempool & fees",
    description: "Live mempool snapshot and fee estimates.",
    endpoints: [
      { method: "GET", path: "/api/v1/mempool", summary: "Mempool size, vsize, fee histogram.",
        example: `{\n  "count": 24,\n  "vsize": 5821,\n  "total_fee": 5821,\n  "fee_histogram": [[1,5821]]\n}` },
      { method: "GET", path: "/api/v1/mempool/recent", summary: "Most recent unconfirmed transactions." },
      { method: "GET", path: "/api/v1/fees/recommended", summary: "Fastest / 30-min / 1-hour / economy / minimum fee rates.",
        example: `{\n  "fastestFee": 1,\n  "halfHourFee": 1,\n  "hourFee": 1,\n  "economyFee": 1,\n  "minimumFee": 1\n}` },
      { method: "GET", path: "/api/v1/fees/mempool-blocks", summary: "Projected next blocks by fee bucket." },
    ],
  },
  {
    id: "mining",
    title: "Mining",
    description: "Pool rankings, difficulty adjustment.",
    endpoints: [
      { method: "GET", path: "/api/v1/mining/pools/24h", summary: "Pool block share over the last 24 hours." },
      { method: "GET", path: "/api/v1/mining/pools/1w", summary: "Pool block share over the last 7 days." },
      { method: "GET", path: "/api/v1/mining/pools/1m", summary: "Pool block share over the last 30 days." },
      { method: "GET", path: "/api/v1/difficulty-adjustment", summary: "Progress and ETA to the next retarget." },
    ],
  },
  {
    id: "txc-extras",
    title: "TXC extras",
    description: "TEXITcoin-specific additions on top of the mempool API.",
    endpoints: [
      { method: "GET", path: "/api/v1/price", summary: "Live TXC price from CoinMarketCap (cached 60s).",
        example: `{\n  "usd": 0.0961,\n  "change24h": 2.34,\n  "marketCap": 1200000,\n  "volume24h": 9421,\n  "updatedAt": "2026-06-14T10:30:00Z",\n  "source": "coinmarketcap"\n}` },
      { method: "GET", path: "/api/v1/supply", summary: "Approximate circulating supply derived from the emission schedule.",
        example: `{ "height": 312188, "circulating": 21300000, "max": 50000000 }` },
      { method: "GET", path: "/api/v1/omni/tx/:txid", summary: "Decoded Omni-Layer payload (if the tx contains an Omni OP_RETURN)." },
    ],
  },
];

export const WS_GROUPS: EndpointGroup[] = [
  {
    id: "ws-connect",
    title: "Connecting",
    description: "Connect to the mempool-style WebSocket. Same subprotocol as mempool.space.",
    endpoints: [
      { method: "WS", path: "wss://mempool2.texitcoin.org/api/v1/ws", summary: "Open a WebSocket connection." },
    ],
  },
  {
    id: "ws-subscribe",
    title: "Subscriptions",
    description: "Send a JSON message to subscribe to live updates.",
    endpoints: [
      { method: "WS", path: `{"action":"want","data":["blocks","mempool-blocks","stats"]}`, summary: "Subscribe to new blocks, projected mempool blocks, and global stats." },
      { method: "WS", path: `{"track-address":"TjfL5Kq58h8VaJMWRkHi2T5wxA5eV6HVwB"}`, summary: "Subscribe to all transactions involving an address." },
      { method: "WS", path: `{"track-tx":"<txid>"}`, summary: "Subscribe to confirmation status updates for a single tx." },
    ],
  },
];
