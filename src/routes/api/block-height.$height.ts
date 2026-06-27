import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/block-height/$height")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        const height = Number(params.height);
        if (!Number.isFinite(height) || height < 0) return errorResponse("Invalid height", 400);
        return proxy(`/block-height/${height}`, { cacheSeconds: 60 });
      },
    },
  },
});