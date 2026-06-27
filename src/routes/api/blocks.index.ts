import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/blocks/")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/blocks", { cacheSeconds: 10 }),
    },
  },
});