import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import { buildWallet, readAddress } from "@/lib/api/pool-wallet";

/** yiimp-compatible GET /api/wallet?address=ADDR */
export const Route = createFileRoute("/api/wallet")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ request }) => {
        const address = readAddress(request);
        if (!address) return errorResponse("missing or invalid address", 400);
        try {
          const { wallet } = await buildWallet(address);
          return jsonResponse(wallet, {
            headers: { "Cache-Control": "public, max-age=15, s-maxage=15" },
          });
        } catch (e) {
          const msg = (e as Error).message;
          return errorResponse(msg, /404/.test(msg) ? 404 : 502);
        }
      },
    },
  },
});
