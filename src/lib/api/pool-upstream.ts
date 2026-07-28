/**
 * Thin fetch helper for the yiimp-api service running on the stratum host.
 * Used by the public, yiimp-compatible pool endpoints under /api/*.
 */
export const POOL_API = "https://api.stratum.pool.honest.money";

/** Stratum endpoint miners point at (scrypt merged mining). */
export const STRATUM_HOST = "stratum.pool.honest.money";
export const STRATUM_PORTS: Record<string, number> = { scrypt: 3433 };

export async function poolFetch<T>(path: string, timeoutMs = 8000): Promise<T> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${POOL_API}${path}`, {
      signal: ctl.signal,
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`upstream ${res.status} for ${path}`);
    return (await res.json()) as T;
  } finally {
    clearTimeout(t);
  }
}

export interface UpstreamSummary {
  algos: Array<{
    algo: string;
    db_miners: number;
    db_workers: number;
    live_clients: number;
    hashrate_hs: number;
    hashrate_updated_at: number;
  }>;
  last_blocks: Array<{
    algo: string;
    height: number;
    time: number;
    category: string;
    confirmations: number;
    symbol: string;
  }>;
  blocks_24h_by_symbol: Record<string, number>;
  blocks_24h_pool_found: number;
  active_miners_10m: number;
  effort: Array<{ symbol: string; network_difficulty: number; effort_pct: number }>;
  fetched_at: number;
}

export interface UpstreamCoin {
  id: number;
  name: string;
  symbol: string;
  algo: string;
  enable: number;
  visible: number;
}
