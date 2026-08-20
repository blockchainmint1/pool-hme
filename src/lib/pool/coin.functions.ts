import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import type { PoolBlock } from "./pool.functions";

const POOL_API = "https://api.stratum.pool.honest.money";

export interface CoinReport {
  coin: {
    symbol: string;
    name: string;
    algo: string;
    /** Coinbase address the chain pays block rewards to. Public, on-chain. */
    master_wallet: string | null;
    reward: number;
    difficulty: number;
    network_hash: number;
  };
  totals: {
    blocks: number;
    total_amount: number;
    confirmed: number;
    immature: number;
    orphan: number;
    first_time: number;
    last_time: number;
  };
  daily: { day: number; blocks: number; amount: number }[];
  payouts: {
    total_paid: number;
    count: number;
    last_payout: number;
    top: { address: string; amount: number; payouts: number }[];
  };
}

export interface CoinValuation {
  currency: "USD";
  /** Spot price now, null when the price feed is unavailable. */
  priceNow: number | null;
  /** Sum of block rewards valued at the price on the day each block was found. */
  valueAtMining: number;
  /** Same rewards valued at today's price. */
  valueNow: number;
  /** How many blocks had a historical price to value against. */
  pricedBlocks: number;
}

export interface CoinPageData {
  symbol: string;
  blocks: PoolBlock[];
  /** null when the price feed is unavailable. */
  valuation: CoinValuation | null;
  /** null when the pool API predates /coins/:symbol/report (v0.6.0). */
  report: CoinReport | null;
  fetchedAt: number;
}

const symbolSchema = z.object({
  symbol: z.enum(["LTC", "DOGE", "TXC", "ISK", "ZCU"]),
  limit: z.number().int().min(1).max(500).optional(),
});

async function fetchJson<T>(path: string, timeoutMs = 8000): Promise<T> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${POOL_API}${path}`, {
      signal: ctrl.signal,
      headers: { accept: "application/json" },
    });
    if (!res.ok) throw new Error(`${path} -> ${res.status}`);
    return (await res.json()) as T;
  } finally {
    clearTimeout(t);
  }
}

const COINGECKO_ID: Record<string, string> = {
  LTC: "litecoin",
  DOGE: "dogecoin",
};

/** Daily close prices keyed by UTC day start (unix seconds), plus the spot price. */
async function fetchPriceHistory(symbol: string) {
  const id = COINGECKO_ID[symbol];
  if (!id) return null;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const res = await fetch(
      `https://api.coingecko.com/api/v3/coins/${id}/market_chart?vs_currency=usd&days=365&interval=daily`,
      { signal: ctrl.signal, headers: { accept: "application/json" } },
    );
    if (!res.ok) return null;
    const json = (await res.json()) as { prices?: [number, number][] };
    if (!json.prices?.length) return null;
    const byDay = new Map<number, number>();
    for (const [ms, price] of json.prices) {
      byDay.set(Math.floor(ms / 1000 / 86400) * 86400, price);
    }
    const priceNow = json.prices[json.prices.length - 1][1];
    return { byDay, priceNow };
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

function valueBlocks(
  blocks: PoolBlock[],
  history: { byDay: Map<number, number>; priceNow: number },
): CoinValuation {
  let valueAtMining = 0;
  let valueNow = 0;
  let pricedBlocks = 0;
  for (const b of blocks) {
    const amount = b.amount ?? 0;
    if (!amount) continue;
    const day = Math.floor(b.time / 86400) * 86400;
    const price = history.byDay.get(day);
    valueNow += amount * history.priceNow;
    if (price != null) {
      valueAtMining += amount * price;
      pricedBlocks += 1;
    } else {
      // Older than the price window: fall back to spot so totals stay comparable.
      valueAtMining += amount * history.priceNow;
    }
  }
  return {
    currency: "USD",
    priceNow: history.priceNow,
    valueAtMining,
    valueNow,
    pricedBlocks,
  };
}

/**
 * Everything one coin page needs. The report endpoint is newer than the blocks
 * endpoint, so a 404 there degrades to blocks-only rather than failing the page.
 */
export const getCoinPageData = createServerFn({ method: "GET" })
  .inputValidator((data: unknown) => symbolSchema.parse(data))
  .handler(async ({ data }): Promise<CoinPageData> => {
    const { symbol } = data;
    const limit = data.limit ?? 200;

    const [blocksRes, report, history] = await Promise.all([
      fetchJson<{ blocks: PoolBlock[] }>(
        `/api/v1/blocks?coin=${symbol}&limit=${limit}`,
      ).catch(() => ({ blocks: [] as PoolBlock[] })),
      fetchJson<CoinReport>(`/api/v1/coins/${symbol}/report`).catch(() => null),
      fetchPriceHistory(symbol),
    ]);

    const blocks = blocksRes.blocks ?? [];

    return {
      symbol,
      blocks,
      valuation: history ? valueBlocks(blocks, history) : null,
      report,
      fetchedAt: Math.floor(Date.now() / 1000),
    };
  });
