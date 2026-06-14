// TEXITcoin network constants + mempool/Esplora API endpoints.
export const TXC_NETWORK = {
  ticker: "TXC",
  name: "TEXITcoin",
  pubKeyHash: 0x42,
  scriptHash: 0x32,
  wif: 0xc2,
  decimals: 8,
  satsPerCoin: 100_000_000,
  blockTimeSec: 180,
  addressPrefix: "T",
} as const;

// Self-hosted backend on EC2 (api.mempool.texitcoin.org).
export const TXC_API_BASE = "https://api.mempool.texitcoin.org/api";
export const TXC_WS_URL = "wss://api.mempool.texitcoin.org/api/v1/ws";
// Public-facing explorer hostname (currently the old explorer; will swap to Lovable later).
export const TXC_EXPLORER_BASE = "https://mempool.texitcoin.org";

export const upstreamTxUrl = (txid: string) => `${TXC_EXPLORER_BASE}/tx/${txid}`;
export const upstreamAddrUrl = (addr: string) => `${TXC_EXPLORER_BASE}/address/${addr}`;
export const upstreamBlockUrl = (hash: string) => `${TXC_EXPLORER_BASE}/block/${hash}`;
