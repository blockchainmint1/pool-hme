import type { PoolBlock } from "./pool.functions";
import type { CoinValuation } from "./coin.functions";

const COINGECKO_ID: Record<string, string> = {
  LTC: "litecoin",
  DOGE: "dogecoin",
};

const CMC_HOST = "https://pro-api.coinmarketcap.com";

async function getJson<T>(url: string, headers: Record<string, string> = {}, ms = 9000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: { accept: "application/json", ...headers },
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/** CoinMarketCap spot price, USD. */
async function cmcSpot(symbol: string, key: string) {
  type Q = {
    data?: Record<string, { quote?: { USD?: { price?: number } } }[]>;
  };
  const json = await getJson<Q>(
    `${CMC_HOST}/v2/cryptocurrency/quotes/latest?symbol=${symbol}&convert=USD`,
    { "X-CMC_PRO_API_KEY": key },
  );
  return json?.data?.[symbol]?.[0]?.quote?.USD?.price ?? null;
}

/** CoinMarketCap daily historical closes, keyed by UTC day start. */
async function cmcHistory(symbol: string, key: string, fromSec: number) {
  type H = {
    data?: Record<
      string,
      { quotes?: { timestamp: string; quote?: { USD?: { price?: number } } }[] }[]
    >;
  };
  const start = new Date(fromSec * 1000).toISOString().slice(0, 10);
  const json = await getJson<H>(
    `${CMC_HOST}/v2/cryptocurrency/quotes/historical?symbol=${symbol}` +
      `&time_start=${start}&interval=daily&count=1000&convert=USD`,
    { "X-CMC_PRO_API_KEY": key },
  );
  const quotes = json?.data?.[symbol]?.[0]?.quotes;
  if (!quotes?.length) return null;
  const byDay = new Map<number, number>();
  for (const q of quotes) {
    const price = q.quote?.USD?.price;
    if (price == null) continue;
    byDay.set(Math.floor(Date.parse(q.timestamp) / 1000 / 86400) * 86400, price);
  }
  return byDay.size ? byDay : null;
}

/** CoinGecko fallback: 365 daily closes plus the latest point as spot. */
async function geckoHistory(symbol: string) {
  const id = COINGECKO_ID[symbol];
  if (!id) return null;
  const json = await getJson<{ prices?: [number, number][] }>(
    `https://api.coingecko.com/api/v3/coins/${id}/market_chart?vs_currency=usd&days=365&interval=daily`,
  );
  if (!json?.prices?.length) return null;
  const byDay = new Map<number, number>();
  for (const [ms, price] of json.prices) {
    byDay.set(Math.floor(ms / 1000 / 86400) * 86400, price);
  }
  return { byDay, priceNow: json.prices[json.prices.length - 1][1] };
}

/**
 * Daily close prices keyed by UTC day start, plus the spot price.
 * CoinMarketCap first (we hold a key), CoinGecko as an unauthenticated fallback.
 */
export async function fetchPriceHistory(symbol: string, earliestSec?: number) {
  const key = process.env["CMC_API_KEY"];
  const from = earliestSec ?? Math.floor(Date.now() / 1000) - 365 * 86400;

  if (key) {
    const [spot, byDay] = await Promise.all([
      cmcSpot(symbol, key),
      cmcHistory(symbol, key, from),
    ]);
    if (spot != null) return { byDay: byDay ?? new Map<number, number>(), priceNow: spot };
  }

  return geckoHistory(symbol);
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

