import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import { buildWallet, fetchWorkers, readAddress } from "@/lib/api/pool-wallet";

/** yiimp-compatible GET /api/walletEx?address=ADDR — wallet plus per-worker rows. */
export const Route = createFileRoute("/api/walletEx")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ request }) => {
        const address = readAddress(request);
        if (!address) return errorResponse("missing or invalid address", 400);
        try {
          const [{ wallet }, workers] = await Promise.all([
            buildWallet(address),
            fetchWorkers(address),
          ]);
          return jsonResponse(
            {
              ...wallet,
              miners: workers.map((w) => ({
                version: w.version ?? "",
                password: w.password ?? "",
                ID: w.worker ?? "",
                algo: w.algo ?? "scrypt",
                difficulty: Number(w.difficulty ?? 0),
                subscribe: 1,
                accepted: Number(w.shares_10m ?? 0),
                rejected: Number(w.rejects_10m ?? 0),
                hashrate: Number(w.hashrate ?? 0),
                last_share: w.last_share ?? null,
              })),
            },
            { headers: { "Cache-Control": "public, max-age=15, s-maxage=15" } },
          );
        } catch (e) {
          const msg = (e as Error).message;
          return errorResponse(msg, /404/.test(msg) ? 404 : 502);
        }
      },
    },
  },
});
