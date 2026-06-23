import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import { decodeOpReturn } from "@/lib/txc/omni";

interface RawTx {
  vout: Array<{ scriptpubkey: string; scriptpubkey_type?: string }>;
}

export const Route = createFileRoute("/api/public/v1/omni/tx/$txid")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) return errorResponse("Invalid txid", 400);
        try {
          const res = await fetch(`https://api.mempool.texitcoin.org/api/v1/tx/${params.txid}`);
          if (!res.ok) return errorResponse(`Upstream ${res.status}`, res.status);
          const tx = (await res.json()) as RawTx;
          const decoded = tx.vout
            .map((v) => decodeOpReturn(v.scriptpubkey))
            .find((d) => d.kind === "omni");
          if (!decoded) return jsonResponse({ omni: null, message: "No Omni payload detected" });
          return jsonResponse({ omni: decoded });
        } catch (e) {
          return errorResponse((e as Error).message, 502);
        }
      },
    },
  },
});
