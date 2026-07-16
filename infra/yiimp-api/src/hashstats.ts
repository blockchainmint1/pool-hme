/**
 * hashstats time-series queries.
 *
 * yiimp's `hashstats` table stores per-algo hashrate + earning samples every
 * ~2 minutes. Schema (relevant columns):
 *
 *   time       INT UNSIGNED  (unix seconds)
 *   hashrate   DOUBLE        (H/s across the pool for this algo)
 *   NHR        DOUBLE        (network hashrate)
 *   difficulty DOUBLE
 *   algo       VARCHAR
 *   coin_id    INT (nullable — pool-wide row uses NULL/0)
 *
 * We expose bucketed series for 1h / 24h / 7d / 30d windows so charts stay
 * cheap and paginated.
 */
import type { Pool, RowDataPacket } from "mysql2/promise";

export type Window = "1h" | "24h" | "7d" | "30d";

const CFG: Record<Window, { seconds: number; bucketSec: number }> = {
  "1h": { seconds: 60 * 60, bucketSec: 60 }, // 1-min buckets
  "24h": { seconds: 24 * 60 * 60, bucketSec: 5 * 60 }, // 5-min buckets
  "7d": { seconds: 7 * 24 * 60 * 60, bucketSec: 30 * 60 }, // 30-min buckets
  "30d": { seconds: 30 * 24 * 60 * 60, bucketSec: 2 * 60 * 60 }, // 2-hour buckets
};

export function windowConfig(w: Window) {
  return CFG[w];
}

export interface HashratePoint {
  time: number; // bucket start, unix seconds
  hashrate: number; // pool hashrate at this bucket
  network_hashrate: number;
  difficulty: number;
}

/**
 * Aggregate hashstats into fixed-width time buckets. Query is fully
 * indexed via (time, algo).
 */
export async function poolHashrateSeries(
  pool: Pool,
  algo: string,
  window: Window,
): Promise<HashratePoint[]> {
  const { seconds, bucketSec } = CFG[window];
  const since = Math.floor(Date.now() / 1000) - seconds;
  const [rows] = await pool.query<RowDataPacket[]>(
    `SELECT FLOOR(time / ?) * ? AS bucket,
            AVG(hashrate) AS hashrate,
            AVG(NHR) AS network_hashrate,
            AVG(difficulty) AS difficulty
       FROM hashstats
      WHERE algo = ? AND time >= ?
      GROUP BY bucket
      ORDER BY bucket ASC
      LIMIT 5000`,
    [bucketSec, bucketSec, algo, since],
  );
  return rows.map((r) => ({
    time: Number(r.bucket),
    hashrate: Number(r.hashrate ?? 0),
    network_hashrate: Number(r.network_hashrate ?? 0),
    difficulty: Number(r.difficulty ?? 0),
  }));
}

/**
 * Per-miner hashrate series, computed from the `shares` table since
 * `hashstats` does not break down by user. We approximate with:
 *
 *   hashrate ≈ Σ(share_difficulty * 2^32) / bucket_seconds
 *
 * This is the standard "pool-side" estimate and matches what the miner
 * dashboard shows.
 */
export async function minerHashrateSeries(
  pool: Pool,
  userid: number,
  window: Window,
): Promise<{ time: number; hashrate: number }[]> {
  const { seconds, bucketSec } = CFG[window];
  const since = Math.floor(Date.now() / 1000) - seconds;
  const [rows] = await pool.query<RowDataPacket[]>(
    `SELECT FLOOR(time / ?) * ? AS bucket,
            SUM(difficulty) * POW(2, 32) / ? AS hashrate
       FROM shares
      WHERE userid = ? AND time >= ? AND valid = 1
      GROUP BY bucket
      ORDER BY bucket ASC
      LIMIT 5000`,
    [bucketSec, bucketSec, bucketSec, userid, since],
  );
  return rows.map((r) => ({
    time: Number(r.bucket),
    hashrate: Number(r.hashrate ?? 0),
  }));
}
