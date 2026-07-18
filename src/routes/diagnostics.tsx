import { createFileRoute, Link } from "@tanstack/react-router";
import { queryOptions, useSuspenseQuery } from "@tanstack/react-query";
import { getPoolDiagnostics } from "@/lib/pool/diagnostics.functions";
import { ChevronLeft, Activity, AlertTriangle, CheckCircle2 } from "lucide-react";

const diagnosticsQuery = queryOptions({
  queryKey: ["pool", "diagnostics"],
  queryFn: () => getPoolDiagnostics(),
  staleTime: 15_000,
  refetchInterval: 20_000,
});

export const Route = createFileRoute("/diagnostics")({
  head: () => ({
    meta: [
      { title: "Pool diagnostics · honest.money" },
      {
        name: "description",
        content:
          "Live stratum health, per-algo miner counts, block find rate, and effort — the same numbers we'd otherwise pull over SSH.",
      },
      { name: "robots", content: "noindex" },
    ],
  }),
  loader: ({ context }) => context.queryClient.ensureQueryData(diagnosticsQuery),
  errorComponent: ({ error }) => (
    <div className="max-w-3xl mx-auto p-8 text-pool-steel-hi">
      <h1 className="text-xl font-mono mb-2">Diagnostics unavailable</h1>
      <p className="text-sm text-pool-steel">{String(error)}</p>
    </div>
  ),
  component: DiagnosticsPage,
});

function fmtAge(sec: number, now: number): string {
  if (!sec) return "—";
  const d = Math.max(0, now - sec);
  if (d < 60) return `${d}s ago`;
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86400)}d ago`;
}

function fmtHashrate(hs: number): string {
  if (!hs || !Number.isFinite(hs)) return "—";
  if (hs >= 1e12) return `${(hs / 1e12).toFixed(2)} TH/s`;
  if (hs >= 1e9) return `${(hs / 1e9).toFixed(2)} GH/s`;
  if (hs >= 1e6) return `${(hs / 1e6).toFixed(2)} MH/s`;
  return `${hs.toFixed(0)} H/s`;
}

function DiagnosticsPage() {
  const { data } = useSuspenseQuery(diagnosticsQuery);
  const now = Math.floor(Date.now() / 1000);
  const healthy = data.health.ok && data.health.db;

  return (
    <div className="min-h-screen bg-pool-ink text-pool-steel-hi">
      <div className="max-w-6xl mx-auto px-4 py-8 space-y-8">
        <header className="flex items-center justify-between">
          <div>
            <Link
              to="/"
              className="inline-flex items-center gap-1 text-xs text-pool-steel hover:text-pool-steel-hi mb-2 font-mono"
            >
              <ChevronLeft className="size-3" /> Back to pool
            </Link>
            <h1 className="text-2xl font-mono">Pool diagnostics</h1>
            <p className="text-xs text-pool-steel font-mono mt-1">
              Live from yiimp-api · fetched {fmtAge(data.fetched_at, now)} · refresh 20s
            </p>
          </div>
          <div
            className={`flex items-center gap-2 px-3 py-2 rounded-md border font-mono text-sm ${
              healthy
                ? "border-pool-mint/30 text-pool-mint"
                : "border-red-500/40 text-red-400"
            }`}
          >
            {healthy ? (
              <CheckCircle2 className="size-4" />
            ) : (
              <AlertTriangle className="size-4" />
            )}
            {healthy ? "healthy" : "degraded"}
            <span className="text-pool-steel">
              · api {String(data.health.ok)} · db {String(data.health.db)}
            </span>
          </div>
        </header>

        {/* Per-algo */}
        <Section title="1 · Stratum health · per algo">
          <Table
            head={["Algo", "Connected", "Hashing 10m", "Pool hashrate", "Diag valid", "Diag stales", "Updated"]}
            rows={data.algos.map((a) => {
              const s = data.stratum_live[a.algo];
              return [
                a.algo,
                <b key="c">{a.live_clients.toLocaleString()}</b>,
                a.db_workers.toLocaleString(),
                fmtHashrate(a.hashrate_hs),
                s ? s.valid.toLocaleString() : "—",
                s ? s.stales.toLocaleString() : "—",
                fmtAge(a.hashrate_updated_at, now),
              ];
            })}
          />
          <p className="text-[11px] text-pool-steel font-mono mt-2 px-1">
            Connected = live stratum TCP sessions (matches old dashboard's "Miners"). Hashing = distinct
            workers that submitted a valid share in the last 10 minutes. A wide gap between the two is a
            share-counting or vardiff signal.
          </p>
        </Section>

        {/* Blocks */}
        <Section title="2 · Block find rate · last 24h">
          <Table
            head={["Symbol", "Blocks 24h", "Last find", "Effort %"]}
            rows={Object.entries(data.blocks_24h_by_symbol)
              .sort((a, b) => Number(b[1]) - Number(a[1]))
              .map(([sym, n]) => {
                const last = data.last_blocks.find(
                  (b) => b.symbol.toUpperCase() === sym.toUpperCase(),
                );
                const eff = data.effort.find(
                  (e) => e.symbol.toUpperCase() === sym.toUpperCase(),
                );
                return [
                  sym,
                  Number(n).toLocaleString(),
                  last ? fmtAge(last.time, now) : "—",
                  eff ? `${eff.effort_pct.toFixed(1)}%` : "—",
                ];
              })}
          />
          <p className="text-[11px] text-pool-steel font-mono mt-2 px-1">
            Target find rate for TXC / ISK is roughly 1 block every 3 minutes when healthy. LTC and DOGE
            blocks are rare on a fleet this size — they surface here as auxpow credits, not solo finds.
          </p>
        </Section>

        {/* Latest blocks */}
        <Section title="3 · Latest block per chain">
          <Table
            head={["Symbol", "Height", "Age", "Category", "Confs"]}
            rows={[...data.last_blocks]
              .sort((a, b) => b.time - a.time)
              .map((b) => [
                b.symbol,
                b.height.toLocaleString(),
                fmtAge(b.time, now),
                b.category,
                String(b.confirmations),
              ])}
          />
        </Section>

        {/* Geo rollup */}
        <Section title="4 · Miners by region">
          {data.locations.length === 0 ? (
            <p className="text-xs text-pool-steel font-mono px-3 py-4">
              No GeoIP data. Ensure geoip-lite DB is fresh on the yiimp-api box.
            </p>
          ) : (
            <Table
              head={["Country", "Region", "Miners", "Hashrate"]}
              rows={data.locations.map((l) => [
                l.country,
                l.region,
                l.miner_count.toLocaleString(),
                fmtHashrate(l.hashrate),
              ])}
            />
          )}
          <p className="text-[11px] text-pool-steel font-mono mt-2 px-1">
            Per-site (Conroe / Mansfield / McKinney) session counts by WAN IP aren't exposed yet — that's a
            small yiimp-api addition. Ask and we'll add it.
          </p>
        </Section>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="pool-kpi-panel rounded-lg p-4">
      <div className="flex items-center gap-2 mb-3">
        <Activity className="size-4 text-pool-steel" />
        <h2 className="text-xs uppercase tracking-widest font-mono text-pool-steel">
          {title}
        </h2>
      </div>
      {children}
    </section>
  );
}

function Table({ head, rows }: { head: string[]; rows: React.ReactNode[][] }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm font-mono">
        <thead>
          <tr className="text-[10px] uppercase tracking-widest text-pool-steel border-b border-pool-hairline">
            {head.map((h) => (
              <th key={h} className="text-left px-3 py-2 font-normal">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td
                className="px-3 py-4 text-pool-steel text-xs"
                colSpan={head.length}
              >
                no data
              </td>
            </tr>
          ) : (
            rows.map((r, i) => (
              <tr key={i} className="border-b border-pool-hairline/40 last:border-0">
                {r.map((c, j) => (
                  <td key={j} className="px-3 py-2 text-pool-steel-hi">
                    {c}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
