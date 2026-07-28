import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, textResponse } from "@/lib/api/cors";

/** yiimp-compatible GET /api/time — server unix time. */
export const Route = createFileRoute("/api/time")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () =>
        textResponse(String(Math.floor(Date.now() / 1000)), {
          headers: { "Cache-Control": "no-store" },
        }),
    },
  },
});
