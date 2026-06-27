import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

export const Route = createFileRoute("/api/address/$addr/balance-history")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params, request }) => {
        if (!/^[A-Za-z0-9]{14,120}$/.test(params.addr)) return errorResponse("Invalid address", 400);
        const url = new URL(request.url);
        const bucket = url.searchParams.get("bucket") === "hour" ? "hour" : "day";
        const limit = url.searchParams.get("limit") ?? "400";
        return proxy(
          `/address/${params.addr}/balance-history?bucket=${bucket}&limit=${encodeURIComponent(limit)}`,
          { cacheSeconds: 30 },
        );
      },
    },
  },
});