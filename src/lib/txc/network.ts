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

// Legacy block explorer — kept around for cross-referencing while the
// community migrates. Not authoritative; this app is the authoritative UI.
export const LEGACY_EXPLORER_BASE = "https://mempool.texitcoin.org";

export const legacyExplorerTxUrl = (txid: string) => `${LEGACY_EXPLORER_BASE}/tx/${txid}`;
export const legacyExplorerAddrUrl = (addr: string) => `${LEGACY_EXPLORER_BASE}/address/${addr}`;
export const legacyExplorerBlockUrl = (hash: string) => `${LEGACY_EXPLORER_BASE}/block/${hash}`;
