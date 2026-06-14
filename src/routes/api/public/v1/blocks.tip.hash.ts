import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/upstream";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/blocks/tip/hash")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/v1/blocks/tip/hash", { cacheSeconds: 5 }),
    },
  },
});
