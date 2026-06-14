import { TXC_API_BASE } from "./network";

// ---------- Types (Esplora + mempool.space extensions) ----------
export interface AddressStats {
  funded_txo_count: number;
  funded_txo_sum: number;
  spent_txo_count: number;
  spent_txo_sum: number;
  tx_count: number;
}
export interface AddressInfo {
  address: string;
  chain_stats: AddressStats;
  mempool_stats: AddressStats;
}
export interface Utxo {
  txid: string;
  vout: number;
  value: number;
  status: { confirmed: boolean; block_height?: number; block_time?: number; block_hash?: string };
}
export interface TxVin {
  txid: string;
  vout: number;
  prevout?: {
    scriptpubkey_address?: string;
    scriptpubkey_type?: string;
    value: number;
  };
  scriptsig?: string;
  scriptsig_asm?: string;
  witness?: string[];
  is_coinbase?: boolean;
  sequence?: number;
}
export interface TxVout {
  scriptpubkey: string;
  scriptpubkey_asm?: string;
  scriptpubkey_type?: string;
  scriptpubkey_address?: string;
  value: number;
}
export interface Tx {
  txid: string;
  version: number;
  locktime: number;
  vin: TxVin[];
  vout: TxVout[];
  fee: number;
  size: number;
  weight: number;
  status: {
    confirmed: boolean;
    block_height?: number;
    block_hash?: string;
    block_time?: number;
  };
}
export interface BlockSummary {
  id: string;
  height: number;
  version: number;
  timestamp: number;
  tx_count: number;
  size: number;
  weight: number;
  merkle_root: string;
  previousblockhash?: string;
  mediantime?: number;
  nonce: number;
  bits: number;
  difficulty: number;
  extras?: {
    pool?: { id: number; name: string; slug?: string };
    reward?: number;
    totalFees?: number;
    medianFee?: number;
    feeRange?: number[];
    avgFee?: number;
    avgFeeRate?: number;
  };
}
export interface FeeRecommendations {
  fastestFee: number;
  halfHourFee: number;
  hourFee: number;
  economyFee: number;
  minimumFee: number;
}
export interface MempoolBlock {
  blockSize: number;
  blockVSize: number;
  nTx: number;
  totalFees: number;
  medianFee: number;
  feeRange: number[];
}
export interface MempoolInfo {
  count: number;
  vsize: number;
  total_fee: number;
  fee_histogram: [number, number][];
}
export interface DifficultyAdjustment {
  progressPercent: number;
  difficultyChange: number;
  estimatedRetargetDate: number;
  remainingBlocks: number;
  remainingTime: number;
  previousRetarget?: number;
  nextRetargetHeight?: number;
  timeAvg?: number;
  timeOffset?: number;
}
export interface PoolRanking {
  pools: Array<{
    poolId: number;
    name: string;
    link?: string;
    blockCount: number;
    rank: number;
    emptyBlocks: number;
    slug?: string;
    avgMatchRate?: number;
    avgFeeDelta?: number;
    poolUniqueId?: number;
  }>;
  blockCount: number;
  lastEstimatedHashrate?: number;
}

// ---------- HTTP helpers ----------
// The backend runs mempool with MEMPOOL_BACKEND=none (no electrs), so the
// Esplora-compatible bare /api/* routes don't exist — only mempool's native
// /api/v1/* routes do. Auto-prefix any path that isn't already under /v1.
async function get<T>(path: string): Promise<T> {
  const normalized = path.startsWith("/v1/") ? path : `/v1${path}`;
  const res = await fetch(`${TXC_API_BASE}${normalized}`);
  if (!res.ok) throw new Error(`API ${normalized} → ${res.status}`);
  const ct = res.headers.get("content-type") || "";
  if (ct.includes("application/json")) return res.json() as Promise<T>;
  const text = await res.text();
  // numeric endpoints (tip/height) return plain text
  const n = Number(text);
  if (!Number.isNaN(n) && text.trim() !== "") return n as unknown as T;
  return text as unknown as T;
}

export const esplora = {
  // ---- chain tip / blocks ----
  tipHeight: () => get<number>("/blocks/tip/height"),
  tipHash: () => get<string>("/blocks/tip/hash"),
  /** Last 10 blocks (or last 10 starting at height) */
  recentBlocks: (startHeight?: number) =>
    get<BlockSummary[]>(`/blocks${startHeight != null ? `/${startHeight}` : ""}`),
  /** v1 paginated by date — used by /blocks page */
  blocksV1: (startHeight?: number) =>
    get<BlockSummary[]>(`/v1/blocks${startHeight != null ? `/${startHeight}` : ""}`),
  blockByHash: (hash: string) => get<BlockSummary>(`/block/${hash}`),
  blockByHeight: (height: number) => get<string>(`/block-height/${height}`),
  blockTxids: (hash: string) => get<string[]>(`/block/${hash}/txids`),
  blockTxs: (hash: string, startIndex = 0) =>
    get<Tx[]>(`/block/${hash}/txs/${startIndex}`),

  // ---- transactions ----
  tx: (txid: string) => get<Tx>(`/tx/${txid}`),
  txHex: (txid: string) => get<string>(`/tx/${txid}/hex`),
  txStatus: (txid: string) => get<Tx["status"]>(`/tx/${txid}/status`),
  txOutspends: (txid: string) =>
    get<Array<{ spent: boolean; txid?: string; vin?: number; status?: Tx["status"] }>>(
      `/tx/${txid}/outspends`,
    ),

  // ---- addresses ----
  address: (a: string) => get<AddressInfo>(`/address/${a}`),
  addressUtxos: (a: string) => get<Utxo[]>(`/address/${a}/utxo`),
  addressTxs: (a: string, lastSeenTxid?: string) =>
    get<Tx[]>(`/address/${a}/txs${lastSeenTxid ? `/chain/${lastSeenTxid}` : ""}`),
  addressMempool: (a: string) => get<Tx[]>(`/address/${a}/txs/mempool`),

  // ---- mempool / fees ----
  mempool: () => get<MempoolInfo>("/mempool"),
  mempoolRecentTxids: () => get<string[]>("/mempool/txids"),
  mempoolRecent: () =>
    get<Array<{ txid: string; fee: number; vsize: number; value: number }>>(
      "/mempool/recent",
    ),
  mempoolBlocks: () => get<MempoolBlock[]>("/v1/fees/mempool-blocks"),
  feesRecommended: () => get<FeeRecommendations>("/v1/fees/recommended"),

  // ---- mining (mempool.space extensions; may 404 — caller handles) ----
  hashrate1m: () =>
    get<{ currentHashrate: number; currentDifficulty: number; hashrates: Array<{ timestamp: number; avgHashrate: number }>; difficulty: Array<{ timestamp: number; difficulty: number; height: number }> }>(
      "/v1/mining/hashrate/3d",
    ),
  difficultyAdjustment: () => get<DifficultyAdjustment>("/v1/difficulty-adjustment"),
  poolRanking24h: () => get<PoolRanking>("/v1/mining/pools/24h"),
  poolRanking1w: () => get<PoolRanking>("/v1/mining/pools/1w"),
  poolRanking1m: () => get<PoolRanking>("/v1/mining/pools/1m"),
  blockReward: () => get<{ reward: number }>("/v1/mining/reward-stats/100"),
};

export function addressBalanceSats(info: AddressInfo) {
  const confirmed =
    info.chain_stats.funded_txo_sum - info.chain_stats.spent_txo_sum;
  const unconfirmed =
    info.mempool_stats.funded_txo_sum - info.mempool_stats.spent_txo_sum;
  return { confirmed, unconfirmed, total: confirmed + unconfirmed };
}

export function txFeeRate(tx: Tx): number {
  const vsize = tx.weight ? tx.weight / 4 : tx.size;
  if (!vsize) return 0;
  return tx.fee / vsize;
}
