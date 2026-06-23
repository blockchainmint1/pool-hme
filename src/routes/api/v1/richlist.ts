import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

// Top N addresses by confirmed unspent balance.
// Served by the self-hosted address indexer; cached at the edge for 60s.
export const Route = createFileRoute("/api/public/v1/richlist")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ request }) => {
        const url = new URL(request.url);
        const raw = Number(url.searchParams.get("limit") ?? 100);
        const limit = Math.max(1, Math.min(500, Number.isFinite(raw) ? raw : 100));
        return proxy(`/address/_richlist?limit=${limit}`, { cacheSeconds: 60 });
      },
    },
  },
});
