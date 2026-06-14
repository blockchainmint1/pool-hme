import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/upstream";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/mempool/")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/v1/mempool", { cacheSeconds: 5 }),
    },
  },
});
