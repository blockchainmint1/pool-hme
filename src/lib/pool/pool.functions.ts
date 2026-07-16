import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

// yiimp-api on the stratum host. Behind nginx + LE TLS.
const POOL_API = "https://api.stratum.pool.honest.money";

export interface PoolBlock {
  height: number;
  blockhash: string;
  amount: number;
  difficulty: number;
  time: number; // unix seconds
  confirmations: number;
  category: string; // "immature" | "generate" | ...
  algo: string;
  symbol: string;
  name: string;
}

export interface PoolCoin {
  id: number;
  name: string;
  symbol: string;
  algo: string;
  enable: number;
  visible: number;
  auto_ready: number;
}

export interface StratumLive {
  algo: string;
  clients: number;
  active: number;
  accepted_ghs: number;
  valid: number;
  invalid: number;
  stales: number;
  updated_at: number;
}

export interface PoolAlgoStats {
  algo: string;
  db_miners: number;
  db_workers: number;
  /** Live-preferred miner count (stratum diag when available, else workers-table recent count). */
  live_clients: number;
  /** Current pool hashrate for this algo, H/s. */
  hashrate_hs: number;
  hashrate_updated_at: number;
}

export interface PoolSummary {
  coins: PoolCoin[];
  /** Newest-first. Only pool-found chains (TXC / ISK / ZCU) — LTC/DOGE come in as auxpow. */
  blocks: PoolBlock[];
  blocks24h: number;
  lastFoundBySymbol: Record<string, number>; // symbol -> unix seconds
  fetchedAt: number;
  health: { ok: boolean; db: boolean };
  /** Live stratum client counts, per algo. This is the real "active miner" number. */
  stratumLive: Record<string, StratumLive>;
  /** Per-algo aggregate (miners + current hashrate). */
  algos: PoolAlgoStats[];
  /** Sum across all algos. */
  liveClients: number;
  /** Sum of current pool hashrate across all algos (GH/s). */
  liveHashrateGhs: number;
}

interface CacheEntry {
  data: PoolSummary;
  fetchedAt: number;
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const g = globalThis as any;
g.__poolSummaryCache = g.__poolSummaryCache as CacheEntry | undefined;

const POOL_FOUND = new Set(["TXC", "ISK", "ZCU"]);

async function fetchJson<T>(path: string): Promise<T> {
  const res = await fetch(`${POOL_API}${path}`, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`${path} ${res.status}: ${await res.text().catch(() => "")}`);
  return (await res.json()) as T;
}

export const getPoolSummary = createServerFn({ method: "GET" }).handler(
  async (): Promise<PoolSummary> => {
    const now = Date.now();
    const cached = g.__poolSummaryCache as CacheEntry | undefined;
    if (cached && now - cached.fetchedAt < 20_000) return cached.data;

    try {
      const [health, coinsRes, blocksRes, summaryRes] = await Promise.all([
        fetchJson<{ ok: boolean; db: boolean }>("/api/v1/health").catch(() =>
          fetchJson<{ ok: boolean; db: boolean }>("/api/health"),
        ),
        fetchJson<{ coins: PoolCoin[] }>("/api/v1/coins").catch(() =>
          fetchJson<{ coins: PoolCoin[] }>("/api/coins"),
        ),
        fetchJson<{ blocks: PoolBlock[] }>("/api/v1/blocks?limit=100").catch(() =>
          fetchJson<{ blocks: PoolBlock[] }>("/api/blocks?limit=100"),
        ),
        // /api/v1/pool/summary is new; if the box hasn't been redeployed yet
        // (v0.2.0), fall back to a stubbed summary so the UI keeps rendering.
        fetchJson<{
          stratum_live: Record<string, StratumLive>;
          blocks_24h_pool_found: number;
          algos?: PoolAlgoStats[];
        }>("/api/v1/pool/summary").catch(() => ({
          stratum_live: {} as Record<string, StratumLive>,
          blocks_24h_pool_found: -1,
          algos: [] as PoolAlgoStats[],
        })),
      ]);

      const nowSec = Math.floor(now / 1000);
      const dayAgo = nowSec - 86_400;

      const poolFound = blocksRes.blocks.filter((b) => POOL_FOUND.has(b.symbol));
      const blocks24hFallback = poolFound.filter((b) => b.time >= dayAgo).length;
      const blocks24h =
        summaryRes.blocks_24h_pool_found >= 0
          ? summaryRes.blocks_24h_pool_found
          : blocks24hFallback;

      const lastFoundBySymbol: Record<string, number> = {};
      for (const b of poolFound) {
        const prev = lastFoundBySymbol[b.symbol];
        if (prev == null || b.time > prev) lastFoundBySymbol[b.symbol] = b.time;
      }

      const stratumLive = summaryRes.stratum_live ?? {};
      const algos = (summaryRes.algos ?? []).map((a) => ({
        algo: String(a.algo),
        db_miners: Number(a.db_miners ?? 0),
        db_workers: Number(a.db_workers ?? 0),
        live_clients: Number(a.live_clients ?? 0),
        hashrate_hs: Number(a.hashrate_hs ?? 0),
        hashrate_updated_at: Number(a.hashrate_updated_at ?? 0),
      }));

      // Prefer the summary's `algos` aggregate (workers-table + hashstats).
      // Fall back to stratum_live diag sums when the endpoint is old/empty.
      const liveClients =
        algos.reduce((s, a) => s + a.live_clients, 0) ||
        Object.values(stratumLive).reduce((s, v) => s + Number(v.clients ?? 0), 0);
      const liveHashrateGhs =
        algos.reduce((s, a) => s + a.hashrate_hs / 1e9, 0) ||
        Object.values(stratumLive).reduce((s, v) => s + Number(v.accepted_ghs ?? 0), 0);

      const data: PoolSummary = {
        coins: coinsRes.coins,
        blocks: poolFound.slice(0, 20),
        blocks24h,
        lastFoundBySymbol,
        fetchedAt: nowSec,
        health: { ok: !!health.ok, db: !!health.db },
        stratumLive,
        algos,
        liveClients,
        liveHashrateGhs,
      };
      g.__poolSummaryCache = { data, fetchedAt: now };
      return data;
    } catch (e) {
      console.error("getPoolSummary failed", e);
      if (cached) return cached.data;
      return {
        coins: [],
        blocks: [],
        blocks24h: 0,
        lastFoundBySymbol: {},
        fetchedAt: Math.floor(now / 1000),
        health: { ok: false, db: false },
        stratumLive: {},
        algos: [],
        liveClients: 0,
        liveHashrateGhs: 0,
      };
    }
  },
);

// ---------------------------------------------------------------------------
// Hashrate time-series — /api/v1/pool/hashrate?window=...&algo=scrypt
//
// Server returns bucketed samples from yiimp's `hashstats` table:
//   { window, algo, points: [{ time, hashrate, network_hashrate, difficulty }] }
//
// If the endpoint isn't deployed yet, we synthesize a plausible series from
// the current live hashrate so the chart still renders and dev keeps moving.
// ---------------------------------------------------------------------------

export type HashrateWindow = "1h" | "24h" | "7d" | "30d";

export interface HashratePoint {
  time: number;
  hashrate: number; // H/s pool
  network_hashrate: number; // H/s network (may be 0 if not tracked)
  difficulty: number;
}

export interface PoolHashrateSeries {
  window: HashrateWindow;
  algo: string;
  points: HashratePoint[];
  synthetic: boolean;
  fetchedAt: number;
}

const hashrateInput = z.object({
  window: z.enum(["1h", "24h", "7d", "30d"]).default("24h"),
  algo: z.string().default("scrypt"),
});

const WINDOW_SECONDS: Record<HashrateWindow, number> = {
  "1h": 60 * 60,
  "24h": 24 * 60 * 60,
  "7d": 7 * 24 * 60 * 60,
  "30d": 30 * 24 * 60 * 60,
};
const WINDOW_BUCKETS: Record<HashrateWindow, number> = {
  "1h": 60,
  "24h": 288, // 5-min buckets
  "7d": 336, // 30-min buckets
  "30d": 360, // 2-hr buckets
};

function synth(window: HashrateWindow, centerHs: number): HashratePoint[] {
  const buckets = WINDOW_BUCKETS[window];
  const total = WINDOW_SECONDS[window];
  const step = Math.floor(total / buckets);
  const now = Math.floor(Date.now() / 1000);
  const base = centerHs > 0 ? centerHs : 7.9e12; // ~7.9 TH/s fallback
  const out: HashratePoint[] = [];
  for (let i = 0; i < buckets; i++) {
    const t = now - (buckets - 1 - i) * step;
    // gentle sine + jitter around base
    const phase = (i / buckets) * Math.PI * 2;
    const drift = 1 + Math.sin(phase) * 0.06 + (Math.random() - 0.5) * 0.04;
    out.push({
      time: t,
      hashrate: base * drift,
      network_hashrate: 0,
      difficulty: 0,
    });
  }
  return out;
}

export const getPoolHashrate = createServerFn({ method: "GET" })
  .inputValidator((d) => hashrateInput.parse(d))
  .handler(async ({ data }): Promise<PoolHashrateSeries> => {
    const { window, algo } = data;
    const nowSec = Math.floor(Date.now() / 1000);
    try {
      const res = await fetch(
        `${POOL_API}/api/v1/pool/hashrate?window=${window}&algo=${algo}`,
        { headers: { Accept: "application/json" } },
      );
      if (!res.ok) throw new Error(`hashrate ${res.status}`);
      const body = (await res.json()) as {
        window: HashrateWindow;
        algo: string;
        points: Array<{
          time: number;
          hashrate: number;
          network_hashrate?: number;
          difficulty?: number;
          earnings?: number;
        }>;
      };
      if (!Array.isArray(body.points) || body.points.length === 0) {
        throw new Error("empty series");
      }
      return {
        window: body.window ?? window,
        algo: body.algo ?? algo,
        points: body.points.map((p) => ({
          time: Number(p.time),
          hashrate: Number(p.hashrate) || 0,
          network_hashrate: Number(p.network_hashrate ?? 0),
          difficulty: Number(p.difficulty ?? 0),
        })),
        synthetic: false,
        fetchedAt: nowSec,
      };
    } catch {
      // Fall back to synthetic ~7.9 TH/s so the graph section still ships.
      // Real numbers arrive once the upgraded yiimp-api is on the box.
      const summary = (g.__poolSummaryCache as CacheEntry | undefined)?.data;
      const centerHs = summary
        ? summary.liveHashrateGhs * 1e9 // GH → H
        : 7.9e12;
      return {
        window,
        algo,
        points: synth(window, centerHs),
        synthetic: true,
        fetchedAt: nowSec,
      };
    }
  });

