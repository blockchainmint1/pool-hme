// Network hashrate / difficulty calculation, derived from block headers.
// Pure functions — no IO — so they can be reused on server and client.
//
// hashrate = difficulty * 2^32 / avg_block_time_sec
//
// This is the same formula mempool's `/mining/hashrate/*` route uses
// internally; we compute it ourselves from `/api/v1/blocks` so we don't
// depend on heavy block-by-block indexing.

export interface BlockHeaderLite {
  height: number;
  timestamp: number;
  difficulty: number;
}

export interface HashrateSample {
  timestamp: number;
  avgHashrate: number;
}

export interface DifficultySample {
  timestamp: number;
  difficulty: number;
  height: number;
}

// 2^32 expressed as a number — exact, fits in a double.
const TWO_32 = 4294967296;

/** Hashrate (H/s) implied by one block's difficulty + the time it took. */
export function hashrateFromBlocks(blocks: BlockHeaderLite[]): number {
  if (blocks.length < 2) return 0;
  // Blocks may arrive newest-first or oldest-first; sort oldest-first.
  const sorted = [...blocks].sort((a, b) => a.timestamp - b.timestamp);
  const span = sorted[sorted.length - 1].timestamp - sorted[0].timestamp;
  if (span <= 0) return 0;
  const avgBlockTime = span / (sorted.length - 1);
  const avgDifficulty =
    sorted.reduce((s, b) => s + b.difficulty, 0) / sorted.length;
  return (avgDifficulty * TWO_32) / avgBlockTime;
}

/** Build a sparse hashrate time series from sampled block chunks. */
export function seriesFromChunks(chunks: BlockHeaderLite[][]): HashrateSample[] {
  return chunks
    .map((chunk) => {
      if (chunk.length === 0) return null;
      const ts = chunk.reduce((s, b) => s + b.timestamp, 0) / chunk.length;
      return { timestamp: Math.round(ts), avgHashrate: hashrateFromBlocks(chunk) };
    })
    .filter((x): x is HashrateSample => x != null && x.avgHashrate > 0)
    .sort((a, b) => a.timestamp - b.timestamp);
}

/** One difficulty point per chunk (newest block per chunk). */
export function difficultyFromChunks(chunks: BlockHeaderLite[][]): DifficultySample[] {
  return chunks
    .map((chunk) => {
      if (chunk.length === 0) return null;
      const newest = chunk.reduce((a, b) => (a.height > b.height ? a : b));
      return { timestamp: newest.timestamp, difficulty: newest.difficulty, height: newest.height };
    })
    .filter((x): x is DifficultySample => x != null)
    .sort((a, b) => a.timestamp - b.timestamp);
}

export type Window = "1d" | "1w" | "1m" | "3m" | "1y";

/** TXC targets 3-min blocks. */
export const TXC_BLOCKS_PER_DAY = 480;

/**
 * For a given time window, return the heights we should sample.
 * Each sample fetches `/api/v1/blocks/{height}` which returns 15 blocks,
 * giving us a clean local average for the hashrate at that point in time.
 *
 * Capped at ~60 samples so a fully-cold request finishes in a few seconds
 * even when we have to walk a year of history.
 */
export function sampleHeights(tip: number, window: Window): number[] {
  const days: Record<Window, number> = { "1d": 1, "1w": 7, "1m": 30, "3m": 90, "1y": 365 };
  const totalBlocks = days[window] * TXC_BLOCKS_PER_DAY;
  const maxSamples = 60;
  const step = Math.max(15, Math.floor(totalBlocks / maxSamples));
  const heights: number[] = [];
  // Newest first; `/blocks/{h}` returns 15 blocks ending at h.
  for (let h = tip; h > tip - totalBlocks && h > 15; h -= step) {
    heights.push(h);
  }
  return heights;
}
