import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/v1/address/$addr/utxo")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!/^[A-Za-z0-9]{14,120}$/.test(params.addr)) return errorResponse("Invalid address", 400);
        return proxy(`/v1/address/${params.addr}/utxo`, { cacheSeconds: 5 });
      },
    },
  },
});
