import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/upstream";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/mining/pools/$window")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!["24h", "1w", "1m"].includes(params.window))
          return errorResponse("Invalid window. Use 24h, 1w, or 1m.", 400);
        return proxy(`/v1/mining/pools/${params.window}`, { cacheSeconds: 120 });
      },
    },
  },
});
