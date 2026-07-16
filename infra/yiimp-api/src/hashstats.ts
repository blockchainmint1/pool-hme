/**
 * hashstats time-series queries.
 *
 * yiimpfrontend `hashstats` schema (this fork):
 *   id       INT PK
 *   time     INT   (unix seconds)
 *   hashrate BIGINT (H/s across the pool for this algo)
 *   earnings DOUBLE
 *   algo     VARCHAR(16)
 *
 * No network-hashrate or difficulty columns — those come from `coins` /
 * `stats` if we ever need them.
 *
 * Per-miner series uses the `shares` table.
 */
import type { Pool, RowDataPacket } from "mysql2/promise";

export type Window = "1h" | "24h" | "7d" | "30d";

const CFG: Record<Window, { seconds: number; bucketSec: number }> = {
  "1h": { seconds: 60 * 60, bucketSec: 60 },
  "24h": { seconds: 24 * 60 * 60, bucketSec: 5 * 60 },
  "7d": { seconds: 7 * 24 * 60 * 60, bucketSec: 30 * 60 },
  "30d": { seconds: 30 * 24 * 60 * 60, bucketSec: 2 * 60 * 60 },
};

export function windowConfig(w: Window) {
  return CFG[w];
}

export interface HashratePoint {
  time: number;
  hashrate: number;
  earnings: number;
}

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
            AVG(earnings) AS earnings
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
    earnings: Number(r.earnings ?? 0),
  }));
}

/**
 * Per-miner hashrate series from `shares`. Standard pool-side estimate:
 *   hashrate ≈ Σ(share_difficulty * 2^32) / bucket_seconds
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
