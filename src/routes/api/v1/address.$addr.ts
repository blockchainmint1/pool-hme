import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

const isAddr = (a: string) => /^T[1-9A-HJ-NP-Za-km-z]{25,40}$/.test(a);

export const Route = createFileRoute("/api/public/v1/address/$addr")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!isAddr(params.addr)) return errorResponse("Invalid address", 400);
        return proxy(`/v1/address/${params.addr}`, { cacheSeconds: 5 });
      },
    },
  },
});
