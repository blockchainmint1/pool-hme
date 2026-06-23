import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

function safe(p: string) { return /^[0-9a-fA-F]{64}$/.test(p); }

export const Route = createFileRoute("/api/public/v1/block/$hash")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!safe(params.hash)) return errorResponse("Invalid hash", 400);
        return proxy(`/v1/block/${params.hash}`, { cacheSeconds: 60 });
      },
    },
  },
});
