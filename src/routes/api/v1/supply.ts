import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";

// TEXITcoin emission: 50 TXC initial subsidy, halving every 210,000 blocks (Bitcoin-style).
// Max supply ~ 50_000_000 TXC after all halvings.
function circulatingAtHeight(height: number): number {
  const HALVING = 210_000;
  let subsidy = 50; // TXC
  let total = 0;
  let remaining = height;
  while (remaining > 0 && subsidy > 1e-8) {
    const take = Math.min(remaining, HALVING);
    total += take * subsidy;
    remaining -= take;
    subsidy /= 2;
  }
  return total;
}

export const Route = createFileRoute("/api/public/v1/supply")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => {
        try {
          const res = await fetch("https://api.mempool.texitcoin.org/api/v1/blocks/tip/height");
          const height = Number(await res.text());
          if (!Number.isFinite(height)) return errorResponse("Tip height unavailable", 502);
          const circulating = circulatingAtHeight(height);
          return jsonResponse({
            height,
            circulating: Number(circulating.toFixed(8)),
            max: 21_000_000,
            note: "Approximation from Bitcoin-style halving schedule (50 TXC start, 210000-block halvings).",
          });
        } catch (e) {
          return errorResponse((e as Error).message, 502);
        }
      },
    },
  },
});
