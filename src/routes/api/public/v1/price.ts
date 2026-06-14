import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import { getTxcPrice } from "@/lib/txc/price.functions";

export const Route = createFileRoute("/api/public/v1/price")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => {
        try {
          const p = await getTxcPrice();
          if (!p) return errorResponse("Price unavailable (CMC_API_KEY missing or upstream error)", 503);
          return jsonResponse(p, {
            headers: { "Cache-Control": "public, max-age=60, s-maxage=60" },
          });
        } catch (e) {
          return errorResponse((e as Error).message, 502);
        }
      },
    },
  },
});
