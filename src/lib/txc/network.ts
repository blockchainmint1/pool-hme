// TEXITcoin network constants + self-hosted API endpoints.
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

// Our own backend (mempool-api + custom indexer behind nginx on EC2).
export const TXC_API_BASE = "https://api.mempool.texitcoin.org/api";
export const TXC_WS_URL = "wss://api.mempool.texitcoin.org/api/v1/ws";

