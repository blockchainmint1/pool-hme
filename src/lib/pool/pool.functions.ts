import { createServerFn } from "@tanstack/react-start";

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

export interface PoolSummary {
  coins: PoolCoin[];
  /** Newest-first. Only pool-found chains (TXC / ISK / ZCU) — LTC/DOGE come in as auxpow. */
  blocks: PoolBlock[];
  blocks24h: number;
  lastFoundBySymbol: Record<string, number>; // symbol -> unix seconds
  fetchedAt: number;
  health: { ok: boolean; db: boolean };
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
      const [health, coinsRes, blocksRes] = await Promise.all([
        fetchJson<{ ok: boolean; db: boolean }>("/api/health"),
        fetchJson<{ coins: PoolCoin[] }>("/api/coins"),
        fetchJson<{ blocks: PoolBlock[] }>("/api/blocks?limit=100"),
      ]);

      const nowSec = Math.floor(now / 1000);
      const dayAgo = nowSec - 86_400;

      // Pool-found only (skip auxpow LTC/DOGE)
      const poolFound = blocksRes.blocks.filter((b) => POOL_FOUND.has(b.symbol));

      const blocks24h = poolFound.filter((b) => b.time >= dayAgo).length;

      const lastFoundBySymbol: Record<string, number> = {};
      for (const b of poolFound) {
        const prev = lastFoundBySymbol[b.symbol];
        if (prev == null || b.time > prev) lastFoundBySymbol[b.symbol] = b.time;
      }

      const data: PoolSummary = {
        coins: coinsRes.coins,
        blocks: poolFound.slice(0, 20),
        blocks24h,
        lastFoundBySymbol,
        fetchedAt: nowSec,
        health: { ok: !!health.ok, db: !!health.db },
      };
      g.__poolSummaryCache = { data, fetchedAt: now };
      return data;
    } catch (e) {
      console.error("getPoolSummary failed", e);
      if (cached) return cached.data;
      // Empty fallback so the UI still renders.
      return {
        coins: [],
        blocks: [],
        blocks24h: 0,
        lastFoundBySymbol: {},
        fetchedAt: Math.floor(now / 1000),
        health: { ok: false, db: false },
      };
    }
  },
);
