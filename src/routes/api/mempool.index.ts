import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/mempool/")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/mempool", { cacheSeconds: 5 }),
    },
  },
});