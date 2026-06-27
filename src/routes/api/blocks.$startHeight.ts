import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/blocks/$startHeight")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        const height = Number(params.startHeight);
        if (!Number.isFinite(height) || height < 0) return errorResponse("Invalid height", 400);
        return proxy(`/blocks/${height}`, { cacheSeconds: 30 });
      },
    },
  },
});