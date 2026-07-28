import { createServerFn } from "@tanstack/react-start";

/**
 * "How's my account doing?" — read-only per-address rollup.
 *
 * Thin proxy over yiimp-api's per-miner endpoints so the browser never
 * talks to the pool box directly. Everything here is public read data
 * keyed by the miner's own LTC payout address.
 */
const POOL_API = "https://api.stratum.pool.honest.money";

export interface AccountWorker {
  worker?: string;
  algo?: string;
  difficulty?: number;
  hashrate?: number;
  shares?: number;
  rejects?: number;
  stales?: number;
  /** Live counts over the last 10 minutes, from the shares table. */
  shares_10m?: number;
  rejects_10m?: number;
  connected_since?: number | null;
  /** Last accepted share; null when the rig has not submitted recently. */
  last_share?: number | null;
  /** Last share if any, else the stratum connection timestamp. */
  last_seen?: number | null;
  country?: string;
  region?: string;
}


export interface AccountAlgo {
  algo: string;
  /** yiimp-api aggregates online workers under this key. */
  workers_online?: number;
  workers?: number;
  hashrate: number;
  last_share: number;
}

export interface AccountPayout {
  id: number;
  amount: number;
  fee: number;
  tx: string | null;
  time: number;
  symbol: string | null;
  name: string | null;
}

export interface AccountEarning {
  id: number;
  amount: number;
  time: number;
  status: number;
  height: number | null;
  blockhash: string | null;
  algo: string | null;
  symbol: string | null;
}

export interface AccountHashPoint {
  time: number;
  hashrate: number;
}

export interface AccountDogeLink {
  linked: boolean;
  doge_address_masked?: string;
  active?: boolean;
  token_last_seen?: number | null;
  created_at?: number;
}

export interface AccountOverview {
  found: boolean;
  address: string;
  fetched_at: number;
  balance: number;
  pending: number;
  paid: number;
  algos: AccountAlgo[];
  payouts_summary: { total_paid: number; payout_count: number; last_payout: number | null };
  workers: AccountWorker[];
  payouts: AccountPayout[];
  earnings: AccountEarning[];
  hashrate_24h: AccountHashPoint[];
  doge: AccountDogeLink;
}

const ADDR_RE = /^[A-Za-z0-9]{20,80}$/;

async function fetchJson<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(`${POOL_API}${path}`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(12_000),
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

export const getAccountOverview = createServerFn({ method: "GET" })
  .inputValidator((data: { address: string }) => {
    const address = String(data?.address ?? "").trim();
    if (!ADDR_RE.test(address)) {
      throw new Error("Enter the mining address you point your workers at.");
    }
    return { address };
  })
  .handler(async ({ data }): Promise<AccountOverview> => {
    const a = encodeURIComponent(data.address);

    const [summary, workers, payouts, earnings, hash, doge] = await Promise.all([
      fetchJson<{
        address: string;
        balance: number;
        pending: number;
        paid: number;
        algos: AccountAlgo[];
        payouts_summary: AccountOverview["payouts_summary"];
      }>(`/api/v1/miner/${a}`),
      fetchJson<{ workers: AccountWorker[] }>(`/api/v1/miner/${a}/workers`),
      fetchJson<{ payouts: AccountPayout[] }>(`/api/v1/miner/${a}/payouts?limit=25`),
      fetchJson<{ earnings: AccountEarning[] }>(`/api/v1/miner/${a}/earnings?limit=25`),
      fetchJson<{ points: AccountHashPoint[] }>(`/api/v1/miner/${a}/hashrate?window=24h`),
      fetchJson<AccountDogeLink>(`/api/v1/doge/registration/lookup?ltc=${a}`),
    ]);

    return {
      found: !!summary,
      address: data.address,
      fetched_at: Math.floor(Date.now() / 1000),
      balance: Number(summary?.balance ?? 0),
      pending: Number(summary?.pending ?? 0),
      paid: Number(summary?.paid ?? 0),
      algos: summary?.algos ?? [],
      payouts_summary:
        summary?.payouts_summary ?? { total_paid: 0, payout_count: 0, last_payout: null },
      workers: workers?.workers ?? [],
      payouts: payouts?.payouts ?? [],
      earnings: earnings?.earnings ?? [],
      hashrate_24h: hash?.points ?? [],
      doge: doge ?? { linked: false },
    };
  });
