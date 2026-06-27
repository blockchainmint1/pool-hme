import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/v1/fee-estimates")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/v1/fee-estimates", { cacheSeconds: 15 }),
    },
  },
});