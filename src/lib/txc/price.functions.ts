import { createServerFn } from "@tanstack/react-start";

export interface TxcPrice {
  usd: number;
  btc: number;
  change24h: number;
  marketCap: number;
  volume24h: number;
  updatedAt: string;
  source: string;
}

interface CacheEntry {
  data: TxcPrice;
  fetchedAt: number;
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const g = globalThis as any;
g.__txcPriceCache = g.__txcPriceCache as CacheEntry | undefined;

async function fetchFromCmc(apiKey: string): Promise<TxcPrice> {
  const url =
    "https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest?symbol=TXC&convert=USD";
  const res = await fetch(url, {
    headers: { "X-CMC_PRO_API_KEY": apiKey, Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`CMC ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as {
    data: Record<string, Array<{
      name: string;
      symbol: string;
      slug?: string;
      quote: { USD: { price: number; percent_change_24h: number; market_cap: number; volume_24h: number; last_updated: string } };
    }>>;
  };
  const arr = json.data?.TXC;
  // Find TEXITcoin specifically (CMC may return multiple TXC tickers).
  const entry =
    arr?.find((e) => /texit/i.test(e.name) || e.slug === "texitcoin") ?? arr?.[0];
  if (!entry) throw new Error("TXC not found in CMC response");
  const q = entry.quote.USD;
  return {
    usd: q.price,
    btc: 0,
    change24h: q.percent_change_24h,
    marketCap: q.market_cap,
    volume24h: q.volume_24h,
    updatedAt: q.last_updated,
    source: "coinmarketcap",
  };
}

export const getTxcPrice = createServerFn({ method: "GET" }).handler(
  async (): Promise<TxcPrice | null> => {
    const apiKey = process.env.CMC_API_KEY;
    if (!apiKey) return null;

    const now = Date.now();
    const cached = g.__txcPriceCache as CacheEntry | undefined;
    if (cached && now - cached.fetchedAt < 60_000) return cached.data;

    try {
      const data = await fetchFromCmc(apiKey);
      g.__txcPriceCache = { data, fetchedAt: now };
      return data;
    } catch (e) {
      console.error("getTxcPrice failed", e);
      // Serve stale cache if we have it
      return cached?.data ?? null;
    }
  },
);
