import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse, CORS_HEADERS } from "@/lib/api/cors";
import { POOL_API } from "@/lib/api/pool-upstream";

const ALLOWED = /^[a-zA-Z0-9/_.:$-]{1,120}$/;

/**
 * Read-only passthrough to the pool backend's v1 API:
 *   /api/pool/<path>  ->  https://api.stratum.pool.honest.money/api/v1/<path>
 * Keeps the stratum host off the public surface and adds CORS + caching.
 */
export const Route = createFileRoute("/api/pool/$")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params, request }) => {
        const splat = (params as { _splat?: string })._splat ?? "";
        if (!splat || !ALLOWED.test(splat)) return errorResponse("bad path", 400);
        if (splat.includes("..")) return errorResponse("bad path", 400);
        const qs = new URL(request.url).search;
        try {
          const res = await fetch(`${POOL_API}/api/v1/${splat}${qs}`, {
            headers: { Accept: "application/json" },
          });
          const body = await res.text();
          return new Response(body, {
            status: res.status,
            headers: {
              "Content-Type": "application/json",
              "Cache-Control": "public, max-age=15, s-maxage=15",
              ...CORS_HEADERS,
            },
          });
        } catch (e) {
          return jsonResponse({ error: (e as Error).message }, { status: 502 });
        }
      },
    },
  },
});
