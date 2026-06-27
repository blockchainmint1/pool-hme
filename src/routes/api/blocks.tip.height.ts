import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/blocks/tip/height")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/blocks/tip/height", { cacheSeconds: 5 }),
    },
  },
});