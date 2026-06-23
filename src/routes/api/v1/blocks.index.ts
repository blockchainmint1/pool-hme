import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/blocks/")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => proxy("/v1/blocks", { cacheSeconds: 10 }),
    },
  },
});
