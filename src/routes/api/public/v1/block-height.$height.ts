import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/upstream";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/block-height/$height")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        const h = Number(params.height);
        if (!Number.isFinite(h) || h < 0) return errorResponse("Invalid height", 400);
        return proxy(`/v1/block-height/${h}`, { cacheSeconds: 60 });
      },
    },
  },
});
