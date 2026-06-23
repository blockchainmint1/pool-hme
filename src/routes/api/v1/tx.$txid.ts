import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

const isTxid = (s: string) => /^[0-9a-fA-F]{64}$/.test(s);

export const Route = createFileRoute("/api/public/v1/tx/$txid")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!isTxid(params.txid)) return errorResponse("Invalid txid", 400);
        return proxy(`/v1/tx/${params.txid}`, { cacheSeconds: 10 });
      },
    },
  },
});
