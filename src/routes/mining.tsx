import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  PieChart, Pie, Cell, ResponsiveContainer, Tooltip,
  LineChart, Line, XAxis, YAxis, CartesianGrid,
} from "recharts";
import { esplora } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { formatNumber } from "@/lib/txc/format";

const POOL_COLORS = [
  "var(--color-fee-6)", "var(--color-fee-5)", "var(--color-fee-4)",
  "var(--color-fee-3)", "var(--color-fee-2)", "var(--color-fee-1)",
  "var(--color-accent)", "var(--color-success)",
];

export const Route = createFileRoute("/mining")({
  head: () => ({
    meta: [
      { title: "Mining — TXC Mempool Explorer" },
      { name: "description", content: "TEXITcoin mining pool distribution, hashrate, difficulty adjustment, and rewards." },
      { property: "og:title", content: "TXC Mining" },
      { property: "og:description", content: "Mining pool distribution and hashrate for the TEXITcoin chain." },
    ],
  }),
  component: MiningPage,
});

function MiningPage() {
  const pools = useQuery({ queryKey: ["mempool", "pools-1w"], queryFn: () => esplora.poolRanking1w(), retry: 0 });
  const hashrate = useQuery({ queryKey: ["mempool", "hashrate"], queryFn: () => esplora.hashrate1m(), retry: 0 });
  const diff = useQuery({ queryKey: ["mempool", "difficulty"], queryFn: () => esplora.difficultyAdjustment(), retry: 0 });

  const unavailable = pools.isError && hashrate.isError && diff.isError;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div>
        <h1 className="font-display text-3xl">Mining</h1>
        <p className="text-sm text-muted-foreground mt-1">Who's mining TXC right now, how fast, and what's next.</p>
      </div>

      {unavailable && (
        <div className="rounded-md border border-border surface-2 p-6 text-sm text-muted-foreground">
          The upstream mempool backend doesn't expose <span className="font-mono">/v1/mining/*</span>{" "}
          for this TXC instance yet. Once those endpoints are enabled, this page will populate automatically.
        </div>
      )}

      {diff.data && (
        <div className="grid md:grid-cols-4 gap-3">
          <StatTile
            label="Retarget progress"
            value={`${diff.data.progressPercent.toFixed(1)}%`}
            hint={`${diff.data.remainingBlocks} blocks left`}
          />
          <StatTile
            label="Expected change"
            value={`${diff.data.difficultyChange >= 0 ? "+" : ""}${diff.data.difficultyChange.toFixed(2)}%`}
          />
          <StatTile
            label="Avg block time"
            value={diff.data.timeAvg ? `${(diff.data.timeAvg / 60).toFixed(2)} min` : "—"}
          />
          <StatTile
            label="ETA"
            value={diff.data.remainingTime > 0 ? `~${Math.round(diff.data.remainingTime / 3600)}h` : "—"}
          />
        </div>
      )}

      <div className="grid lg:grid-cols-2 gap-6">
        {pools.data && pools.data.pools && pools.data.pools.length > 0 && (
          <div className="rounded-md surface-2 border border-border p-4">
            <h2 className="font-display text-base uppercase tracking-wide mb-3">Pool distribution · 1 week</h2>
            <div className="h-72">
              <ResponsiveContainer>
                <PieChart>
                  <Pie
                    data={pools.data.pools.slice(0, 8).map((p) => ({ name: p.name, value: p.blockCount }))}
                    dataKey="value"
                    nameKey="name"
                    innerRadius={60}
                    outerRadius={100}
                    paddingAngle={2}
                  >
                    {pools.data.pools.slice(0, 8).map((_, i) => (
                      <Cell key={i} fill={POOL_COLORS[i % POOL_COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6, fontFamily: "var(--font-mono)" }}
                  />
                </PieChart>
              </ResponsiveContainer>
            </div>
            <div className="grid grid-cols-2 gap-1 mt-3 text-xs font-mono">
              {pools.data.pools.slice(0, 8).map((p, i) => (
                <div key={p.poolId} className="flex justify-between gap-2 px-1">
                  <div className="flex items-center gap-1.5 min-w-0">
                    <span className="size-2 flex-shrink-0 rounded-sm" style={{ background: POOL_COLORS[i % POOL_COLORS.length] }} />
                    <span className="truncate">{p.name}</span>
                  </div>
                  <span>{formatNumber(p.blockCount)}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {hashrate.data && hashrate.data.hashrates && hashrate.data.hashrates.length > 0 && (
          <div className="rounded-md surface-2 border border-border p-4">
            <h2 className="font-display text-base uppercase tracking-wide mb-3">Hashrate</h2>
            <div className="h-72">
              <ResponsiveContainer>
                <LineChart data={hashrate.data.hashrates}>
                  <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
                  <XAxis
                    dataKey="timestamp"
                    tickFormatter={(t) => new Date(t * 1000).toLocaleDateString()}
                    stroke="var(--color-muted-foreground)"
                    fontSize={10}
                  />
                  <YAxis
                    stroke="var(--color-muted-foreground)"
                    fontSize={10}
                    tickFormatter={(v) => `${(v / 1e9).toFixed(1)} GH/s`}
                  />
                  <Tooltip
                    contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }}
                    labelFormatter={(l) => new Date((l as number) * 1000).toLocaleString()}
                  />
                  <Line type="monotone" dataKey="avgHashrate" stroke="var(--color-primary)" strokeWidth={2} dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
