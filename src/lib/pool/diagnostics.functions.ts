import { createServerFn } from "@tanstack/react-start";

// Raw diagnostics feed — mirrors the shell script the operator used to
// copy-paste. Not cached long: this page exists to answer "is anything on
// fire right now?" and should feel live.
const POOL_API = "https://api.stratum.pool.honest.money";

export interface DiagStratumAlgo {
  algo: string;
  clients: number;
  active: number;
  accepted_ghs: number;
  valid: number;
  invalid: number;
  stales: number;
  updated_at: number;
}

export interface DiagAlgo {
  algo: string;
  db_miners: number;
  db_workers: number;
  live_clients: number;
  hashrate_hs: number;
  hashrate_updated_at: number;
}

export interface DiagLastBlock {
  algo: string;
  symbol: string;
  height: number;
  time: number;
  category: string;
  confirmations: number;
}

export interface DiagEffort {
  symbol: string;
  network_difficulty: number;
  effort_pct: number;
}

export interface DiagLocation {
  country: string;
  region: string;
  miner_count: number;
  hashrate: number;
}

export interface DiagSite {
  site: string;
  sessions: number;
  is_known_site: boolean;
}

export interface DiagPayoutAddress {
  address_short: string;
  active_workers_1h: number;
  share_weight_1h: number;
  last_share: number;
}

export interface PoolDiagnostics {
  fetched_at: number;
  health: { ok: boolean; db: boolean };
  stratum_live: Record<string, DiagStratumAlgo>;
  algos: DiagAlgo[];
  active_miners_10m: number;
  blocks_24h_pool_found: number;
  blocks_24h_by_symbol: Record<string, number>;
  last_blocks: DiagLastBlock[];
  effort: DiagEffort[];
  locations: DiagLocation[];
  sites: DiagSite[];
  total_sessions: number;
  payout_addresses: DiagPayoutAddress[];
}


async function fetchJson<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(`${POOL_API}${path}`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

export const getPoolDiagnostics = createServerFn({ method: "GET" }).handler(
  async (): Promise<PoolDiagnostics> => {
    const [health, summary, locations, sites, payoutAddrs] = await Promise.all([
      fetchJson<{ ok: boolean; db: boolean }>("/api/v1/health"),
      fetchJson<{
        stratum_live: Record<string, DiagStratumAlgo>;
        algos: DiagAlgo[];
        active_miners_10m: number;
        blocks_24h_pool_found: number;
        blocks_24h_by_symbol: Record<string, number>;
        last_blocks: DiagLastBlock[];
        effort: DiagEffort[];
        fetched_at: number;
      }>("/api/v1/pool/summary"),
      fetchJson<{ locations: DiagLocation[] }>("/api/v1/miners/locations"),
      fetchJson<{ sites: DiagSite[]; total_sessions: number }>("/api/v1/miners/sites"),
      fetchJson<{ payout_addresses: DiagPayoutAddress[] }>(
        "/api/v1/pool/payout-addresses?limit=50",
      ),
    ]);

    return {
      fetched_at: summary?.fetched_at ?? Math.floor(Date.now() / 1000),
      health: health ?? { ok: false, db: false },
      stratum_live: summary?.stratum_live ?? {},
      algos: summary?.algos ?? [],
      active_miners_10m: Number(summary?.active_miners_10m ?? 0),
      blocks_24h_pool_found: Number(summary?.blocks_24h_pool_found ?? 0),
      blocks_24h_by_symbol: summary?.blocks_24h_by_symbol ?? {},
      last_blocks: summary?.last_blocks ?? [],
      effort: summary?.effort ?? [],
      locations: locations?.locations ?? [],
      sites: sites?.sites ?? [],
      total_sessions: Number(sites?.total_sessions ?? 0),
      payout_addresses: payoutAddrs?.payout_addresses ?? [],
    };
  },
);

