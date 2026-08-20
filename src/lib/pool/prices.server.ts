import type { PoolBlock } from "./pool.functions";
import type { CoinValuation } from "./coin.functions";

const COINGECKO_ID: Record<string, string> = {
  LTC: "litecoin",
  DOGE: "dogecoin",
};

/** Daily close prices keyed by UTC day start (unix seconds), plus the spot price. */
export async function fetchPriceHistory(symbol: string) {
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

export function valueBlocks(
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

