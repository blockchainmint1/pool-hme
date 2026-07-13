import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";

// Real TEXITcoin circulating supply — sum of every unspent output currently
// tracked by our indexer (the `balances` table). The previous version of
// this endpoint returned a Bitcoin-style halving approximation (50 TXC start,
// 210k-block halvings, 21M cap) which is NOT the TEXITcoin emission and
// produced badly wrong numbers.
//
// Upstream: our indexer exposes GET /address/_supply through nginx at
// /api/v1/address/_supply. It reads the materialized UTXO balance table
// so the query is sub-millisecond and cached edge-side for 30s.
export const Route = createFileRoute("/api/v1/supply")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async () => {
        try {
          const res = await fetch(
            "https://api.mempool.texitcoin.org/api/v1/address/_supply",
            { headers: { accept: "application/json" } },
          );
          if (!res.ok) return errorResponse("Upstream supply unavailable", 502);
          const data = (await res.json()) as {
            computed_at: number;
            indexed_tip: number;
            circulating_sats: number;
            circulating: number;
            address_count: number;
            utxo_count: number;
          };
          return jsonResponse(
            {
              height: data.indexed_tip,
              circulating: data.circulating,
              circulating_sats: data.circulating_sats,
              address_count: data.address_count,
              utxo_count: data.utxo_count,
              computed_at: data.computed_at,
              source: "indexer:utxo-set",
              note: "Sum of every unspent output currently tracked by the TEXITcoin indexer.",
            },
            { headers: { "Cache-Control": "public, max-age=30, s-maxage=30" } },
          );
        } catch (e) {
          console.error("supply lookup failed", e);
          return errorResponse("Upstream unavailable", 502);
        }
      },
    },
  },
});
