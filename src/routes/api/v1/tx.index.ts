import { createFileRoute } from "@tanstack/react-router";
import { proxyPost } from "@/lib/api/backend";
import { optionsHandler } from "@/lib/api/cors";

export const Route = createFileRoute("/api/v1/tx/")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      POST: async ({ request }) => proxyPost("/v1/tx", request),
    },
  },
});