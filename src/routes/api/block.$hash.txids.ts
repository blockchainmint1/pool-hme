import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/block/$hash/txids")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!/^[0-9a-fA-F]{64}$/.test(params.hash)) return errorResponse("Invalid hash", 400);
        return proxy(`/block/${params.hash}/txids`, { cacheSeconds: 60 });
      },
    },
  },
});
