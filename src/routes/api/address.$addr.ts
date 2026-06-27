import { createFileRoute } from "@tanstack/react-router";
import { proxy } from "@/lib/api/backend";
import { optionsHandler, errorResponse } from "@/lib/api/cors";

const isAddr = (addr: string) => /^[A-Za-z0-9]{14,120}$/.test(addr);

export const Route = createFileRoute("/api/address/$addr")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ params }) => {
        if (!isAddr(params.addr)) return errorResponse("Invalid address", 400);
        return proxy(`/address/${params.addr}`, { cacheSeconds: 5 });
      },
    },
  },
});