import { createFileRoute } from "@tanstack/react-router";

/**
 * /api/public/nicehash-env — hands the nicehash-watcher its credentials.
 *
 *   GET ?token=…   → text/plain env lines for /etc/nicehash-watcher.env
 *
 * The NiceHash keys live in the Lovable secret store (backend env), but the
 * watcher runs on the pool box. This endpoint bridges the two, gated by the
 * same MONITOR_TOKEN as /api/public/monitor. RENTAL_LTC_ADDR is the pool's
 * legacy P2PKH LTC coinbase wallet — it is NOT a secret, but is served here
 * so the box gets the full config in one fetch.
 */

// Legacy P2PKH merged-mining parent wallet (mem: LTC coinbase legacy-only).
const RENTAL_LTC_ADDR = "LdSHVgxVWbP5kGKzmZMm8aEXe2wprwwr32";

const KEY_MAP: Array<[string, string]> = [
  ["NICEHASH_API", "NICEHASH_API"],
  ["NICEHASH_SECRET", "NICEHASH_SECRET"],
  ["NICEHASH_ORGANIZATION", "NICEHASH_ORGANIZATION"],
  ["TELEGRAM_BOT_TOKEN", "TELEGRAM_BOT_TOKEN"],
  ["TELEGRAM_CHAT_ID", "TELEGRAM_CHAT_ID"],
];

function readToken(request: Request): string {
  const url = new URL(request.url);
  return url.searchParams.get("token") ?? request.headers.get("x-monitor-token") ?? "";
}

export const Route = createFileRoute("/api/public/nicehash-env")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const { tokenOk } = await import("@/lib/monitor/monitor.server");
        if (!tokenOk(readToken(request))) {
          return new Response("Forbidden\n", { status: 403 });
        }
        const missing: string[] = [];
        const lines: string[] = [];
        for (const [envName, outName] of KEY_MAP) {
          const v = process.env[envName] ?? "";
          if (!v) missing.push(envName);
          else lines.push(`${outName}=${v}`);
        }
        lines.push(`RENTAL_LTC_ADDR=${RENTAL_LTC_ADDR}`);
        if (missing.length > 0) {
          return new Response(
            JSON.stringify({ error: "secrets_not_configured", missing }),
            { status: 503, headers: { "content-type": "application/json", "cache-control": "no-store" } },
          );
        }
        return new Response(lines.join("\n") + "\n", {
          status: 200,
          headers: { "content-type": "text/plain", "cache-control": "no-store" },
        });
      },
    },
  },
});
