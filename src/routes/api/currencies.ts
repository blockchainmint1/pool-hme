import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import {
  poolFetch,
  STRATUM_PORTS,
  type UpstreamCoin,
  type UpstreamSummary,
} from "@/lib/api/pool-upstream";

interface CoinDetail {
  coin?: {
    symbol: string;
    difficulty?: number | null;
    network_hash?: number | null;
    reward?: number | null;
    pool_fee?: number | null;
  };
}

/**
 * yiimp-compatible GET /api/currencies — per-coin pool status.
 * Replaces pool.texitcoin.org/api/currencies.
 */
export const Route = createFileRoute("/api/currencies")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => {
        try {
          const [summary, coinsRes] = await Promise.all([
            poolFetch<UpstreamSummary>("/api/v1/pool/summary"),
            poolFetch<{ coins: UpstreamCoin[] }>("/api/v1/coins"),
          ]);

          const details = await Promise.all(
            coinsRes.coins.map((c) =>
              poolFetch<CoinDetail>(`/api/v1/coins/${c.symbol}`).catch(() => ({}) as CoinDetail),
            ),
          );
          const detailBySymbol = new Map(coinsRes.coins.map((c, i) => [c.symbol, details[i]?.coin]));
          // Coin detail can be unavailable on older backends — fall back to the
          // network difficulty carried in the pool summary's effort rows.
          const effortDiff = new Map(
            summary.effort.map((e) => [e.symbol, Number(e.network_difficulty ?? 0)]),
          );


          const now = summary.fetched_at;
          const lastBySymbol = new Map(summary.last_blocks.map((b) => [b.symbol, b]));
          const algoByName = new Map(summary.algos.map((a) => [a.algo, a]));

          const out: Record<string, unknown> = {};
          for (const c of coinsRes.coins) {
            const last = lastBySymbol.get(c.symbol);
            const algo = algoByName.get(c.algo);
            const d = detailBySymbol.get(c.symbol);
            out[c.symbol] = {
              algo: c.algo,
              port: STRATUM_PORTS[c.algo] ?? 3433,
              name: c.name,
              symbol: c.symbol,
              height: last?.height ?? 0,
              workers: algo?.live_clients ?? 0,
              hashrate: Math.round(algo?.hashrate_hs ?? 0),
              difficulty: Number(d?.difficulty ?? 0),
              network_hashrate: Number(d?.network_hash ?? 0),
              reward: Number(d?.reward ?? 0),
              "24h_blocks": summary.blocks_24h_by_symbol[c.symbol] ?? 0,
              lastblock: last?.height ?? 0,
              timesincelast: last ? Math.max(0, now - last.time) : null,
            };
          }
          return jsonResponse(out, {
            headers: { "Cache-Control": "public, max-age=30, s-maxage=30" },
          });
        } catch (e) {
          return errorResponse((e as Error).message, 502);
        }
      },
    },
  },
});
