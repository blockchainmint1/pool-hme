import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

/**
 * /api/public/monitor — external cron target + watcher heartbeat sink.
 *
 *   GET  ?token=…            run all health checks, send Telegram alerts
 *   GET  ?token=…&silent=1   run checks, report only (no Telegram)
 *   POST ?token=…            nicehash-watcher heartbeat (JSON body)
 *
 * Token-gated: this route can send messages and accepts state, so it must
 * never be callable anonymously.
 */

const heartbeatSchema = z.object({
  actual_ths: z.number().min(0).max(1e6),
  target_ths: z.number().min(0).max(1e6),
  active_orders: z.number().int().min(0).max(1000).default(0),
  spend_today_btc: z.number().min(0).max(1000).default(0),
  dry_run: z.boolean().default(false),
});

function readToken(request: Request): string {
  const url = new URL(request.url);
  return (
    url.searchParams.get("token") ??
    request.headers.get("x-monitor-token") ??
    ""
  );
}

const noStore = { "content-type": "application/json", "cache-control": "no-store" };

export const Route = createFileRoute("/api/public/monitor")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const { tokenOk, runWatchdog } = await import("@/lib/monitor/monitor.server");
        if (!tokenOk(readToken(request))) {
          return new Response("Forbidden\n", { status: 403 });
        }
        const silent = new URL(request.url).searchParams.get("silent") === "1";
        const report = await runWatchdog({ silent });
        return new Response(JSON.stringify(report), { status: 200, headers: noStore });
      },

      POST: async ({ request }) => {
        const { tokenOk, recordHeartbeat } = await import("@/lib/monitor/monitor.server");
        if (!tokenOk(readToken(request))) {
          return new Response("Forbidden\n", { status: 403 });
        }
        let body: unknown;
        try {
          body = await request.json();
        } catch {
          return new Response(JSON.stringify({ error: "invalid JSON" }), {
            status: 400,
            headers: noStore,
          });
        }
        const parsed = heartbeatSchema.safeParse(body);
        if (!parsed.success) {
          return new Response(
            JSON.stringify({ error: "invalid heartbeat", issues: parsed.error.issues }),
            { status: 400, headers: noStore },
          );
        }
        recordHeartbeat({ ...parsed.data, received_at: Math.floor(Date.now() / 1000) });
        return new Response(JSON.stringify({ ok: true }), { status: 200, headers: noStore });
      },
    },
  },
});
