import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/tx/$txid")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) return errorResponse("Invalid txid", 400);
        return proxy(`/tx/${params.txid}`, { cacheSeconds: 10 });
      },
    },
  },
});