import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/v1/mempool/txids")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/v1/mempool/txids", { cacheSeconds: 5 }),
    },
  },
});