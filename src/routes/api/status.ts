import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import {
  poolFetch,
  STRATUM_PORTS,
  type UpstreamCoin,
  type UpstreamSummary,
} from "@/lib/api/pool-upstream";

/**
 * yiimp-compatible GET /api/status — per-algo pool status.
 * Replaces pool.texitcoin.org/api/status for existing miner tooling.
 */
export const Route = createFileRoute("/api/status")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => {
        try {
          const [summary, coins] = await Promise.all([
            poolFetch<UpstreamSummary>("/api/v1/pool/summary"),
            poolFetch<{ coins: UpstreamCoin[] }>("/api/v1/coins"),
          ]);

          const out: Record<string, unknown> = {};
          for (const a of summary.algos) {
            const coinCount = coins.coins.filter((c) => c.algo === a.algo && c.enable).length;
            out[a.algo] = {
              name: a.algo,
              port: STRATUM_PORTS[a.algo] ?? 3433,
              coins: coinCount,
              fees: 0,
              hashrate: Math.round(a.hashrate_hs),
              workers: a.live_clients,
              miners: a.db_miners,
              hashrate_last24h: Math.round(a.hashrate_hs),
              blocks24h: summary.blocks_24h_pool_found,
              timestamp: summary.fetched_at,
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
