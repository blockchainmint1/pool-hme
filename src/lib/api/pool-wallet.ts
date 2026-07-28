import { poolFetch } from "@/lib/api/pool-upstream";

const ADDR_RE = /^[a-zA-Z0-9]{20,120}$/;

export interface MinerSummary {
  address: string;
  balance: number;
  pending: number;
  paid: number;
  algos: Array<{
    algo: string;
    workers_online: number;
    hashrate: number;
    last_share: number | null;
  }>;
}

interface Payouts {
  payouts: Array<{ amount: number; time: number; symbol: string | null; tx: string | null }>;
}

export interface WalletBody {
  unsold: number;
  balance: number;
  unpaid: number;
  paid24h: number;
  total: number;
}

export interface WorkerRow {
  worker?: string;
  algo?: string;
  password?: string;
  version?: string;
  difficulty?: number;
  hashrate?: number;
  shares_10m?: number;
  rejects_10m?: number;
  last_share?: number | null;
}

/** Shared yiimp-compatible wallet payload, used by /api/wallet and /api/walletEx. */
export async function buildWallet(
  address: string,
): Promise<{ wallet: WalletBody; miner: MinerSummary }> {
  const miner = await poolFetch<MinerSummary>(`/api/v1/miner/${encodeURIComponent(address)}`);
  let paid24h = 0;
  try {
    const p = await poolFetch<Payouts>(
      `/api/v1/miner/${encodeURIComponent(address)}/payouts?limit=200`,
    );
    const cutoff = Math.floor(Date.now() / 1000) - 86_400;
    paid24h = p.payouts
      .filter((r) => Number(r.time) >= cutoff)
      .reduce((s, r) => s + Number(r.amount ?? 0), 0);
  } catch {
    paid24h = 0;
  }
  const balance = Number(miner.balance ?? 0);
  const unpaid = Number(miner.pending ?? 0) || balance;
  return {
    wallet: { unsold: 0, balance, unpaid, paid24h, total: balance + unpaid },
    miner,
  };
}

export async function fetchWorkers(address: string): Promise<WorkerRow[]> {
  try {
    const r = await poolFetch<{ workers: WorkerRow[] }>(
      `/api/v1/miner/${encodeURIComponent(address)}/workers`,
    );
    return r.workers ?? [];
  } catch {
    return [];
  }
}

export function readAddress(request: Request): string | null {
  const addr = new URL(request.url).searchParams.get("address")?.trim() ?? "";
  return ADDR_RE.test(addr) ? addr : null;
}
