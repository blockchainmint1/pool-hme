import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/upstream";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/public/v1/address/$addr/txs")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!/^T[1-9A-HJ-NP-Za-km-z]{25,40}$/.test(params.addr)) return errorResponse("Invalid address", 400);
        return proxy(`/v1/address/${params.addr}/txs`, { cacheSeconds: 5 });
      },
    },
  },
});
