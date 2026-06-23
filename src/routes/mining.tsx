import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  PieChart, Pie, Cell, ResponsiveContainer, Tooltip,
} from "recharts";
import { esplora, type BlockSummary } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { NetworkDifficultyChart } from "@/components/explorer/NetworkDifficultyChart";
import { formatNumber, satsToTxc, shortHash, timeAgo } from "@/lib/txc/format";

const POOL_COLORS = [
  "var(--color-fee-6)", "var(--color-fee-5)", "var(--color-fee-4)",
  "var(--color-fee-3)", "var(--color-fee-2)", "var(--color-fee-1)",
  "var(--color-accent)", "var(--color-success)",
];

export const Route = createFileRoute("/mining")({
  head: () => ({
    meta: [
      { title: "Mining — TXC Mempool Explorer" },
      { name: "description", content: "TEXITcoin mining: network hashrate, difficulty adjustment, pool distribution, and recent blocks." },
      { property: "og:title", content: "TXC Mining" },
      { property: "og:description", content: "Network hashrate, difficulty, and pool distribution for the TEXITcoin chain." },
    ],
  }),
  component: MiningPage,
});

// Pull a window of recent blocks by walking /v1/blocks pages (15 each).
async function fetchRecentBlocks(pages: number): Promise<BlockSummary[]> {
  const all: BlockSummary[] = [];
  let cursor: number | undefined = undefined;
  for (let i = 0; i < pages; i++) {
    const batch: BlockSummary[] = await esplora.blocksV1(cursor);
    if (!batch.length) break;
    all.push(...batch);
    const last = batch[batch.length - 1];
    cursor = last.height - 1;
    if (cursor < 0) break;
  }
  return all;
}

function MiningPage() {
  const diff = useQuery({
    queryKey: ["mempool", "difficulty"],
    queryFn: () => esplora.difficultyAdjustment(),
    refetchInterval: 60_000,
    retry: 0,
  });

  // ~10 pages × 15 = ~150 recent blocks (~7.5h on TXC). Enough for a
  // meaningful pool breakdown without hammering the backend.
  const recent = useQuery({
    queryKey: ["mining", "recent-blocks", 10],
    queryFn: () => fetchRecentBlocks(10),
    refetchInterval: 120_000,
    staleTime: 60_000,
  });

  const blocks = recent.data ?? [];

  // ----- pool distribution (computed locally) -----
  const poolStats = (() => {
    const byPool = new Map<string, { name: string; blocks: number; reward: number }>();
    let unknown = 0;
    for (const b of blocks) {
      const name = b.extras?.pool?.name;
      const reward = b.extras?.reward ?? 0;
      if (!name) {
        unknown++;
        continue;
      }
      const cur = byPool.get(name) ?? { name, blocks: 0, reward: 0 };
      cur.blocks += 1;
      cur.reward += reward;
      byPool.set(name, cur);
    }
    if (unknown > 0) byPool.set("Unknown", { name: "Unknown", blocks: unknown, reward: 0 });
    return Array.from(byPool.values()).sort((a, b) => b.blocks - a.blocks);
  })();
  const totalBlocks = blocks.length;
  const windowSpanHrs = (() => {
    if (blocks.length < 2) return 0;
    const ts = blocks.map((b) => b.timestamp);
    return (Math.max(...ts) - Math.min(...ts)) / 3600;
  })();

  // ----- reward stats -----
  const rewardStats = (() => {
    if (!blocks.length) return null;
    const rewards = blocks.map((b) => b.extras?.reward ?? 0).filter((r) => r > 0);
    const fees = blocks.map((b) => b.extras?.totalFees ?? 0).filter((f) => f > 0);
    const avg = (arr: number[]) => (arr.length ? arr.reduce((s, x) => s + x, 0) / arr.length : 0);
    return {
      avgReward: avg(rewards),
      avgFees: avg(fees),
      sampleSize: blocks.length,
    };
  })();

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div>
        <h1 className="font-display text-3xl">Mining</h1>
        <p className="text-sm text-muted-foreground mt-1">
          Who's mining TXC right now, how fast, and what's next.
          {totalBlocks > 0 && (
            <> Pool distribution from last <span className="font-mono text-foreground">{totalBlocks}</span> blocks (~{windowSpanHrs.toFixed(1)}h).</>
          )}
        </p>
      </div>

      {/* Difficulty / next retarget */}
      <div className="grid md:grid-cols-2 lg:grid-cols-4 gap-3">
        <StatTile
          label="Retarget progress"
          value={diff.data ? `${diff.data.progressPercent.toFixed(1)}%` : "—"}
          hint={diff.data ? `${diff.data.remainingBlocks} blocks left` : ""}
        />
        <StatTile
          label="Expected change"
          value={
            diff.data
              ? `${diff.data.difficultyChange >= 0 ? "+" : ""}${diff.data.difficultyChange.toFixed(2)}%`
              : "—"
          }
          hint="next adjustment"
        />
        <StatTile
          label="Avg block time"
          value={
            diff.data?.timeAvg
              ? `${(diff.data.timeAvg / 60).toFixed(2)} min`
              : "—"
          }
          hint="target 3 min"
        />
        <StatTile
          label="ETA"
          value={diff.data && diff.data.remainingTime > 0 ? `~${Math.round(diff.data.remainingTime / 3600)}h` : "—"}
          hint="to next retarget"
        />
      </div>

      {/* Hashrate chart with selector */}
      <NetworkDifficultyChart />

      <div className="grid lg:grid-cols-3 gap-6">
        {/* Pool distribution donut */}
        <div className="lg:col-span-2 rounded-md surface-2 border border-border p-4">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground mb-3">
            Pool distribution
          </h2>
          {recent.isLoading ? (
            <div className="h-72 flex items-center justify-center text-xs text-muted-foreground">
              Loading recent blocks…
            </div>
          ) : poolStats.length === 0 ? (
            <div className="h-72 flex items-center justify-center text-xs text-muted-foreground">
              No recent blocks available.
            </div>
          ) : (
            <div className="grid md:grid-cols-2 gap-4 items-center">
              <div className="h-64">
                <ResponsiveContainer>
                  <PieChart>
                    <Pie
                      data={poolStats.slice(0, 8).map((p) => ({ name: p.name, value: p.blocks }))}
                      dataKey="value"
                      nameKey="name"
                      innerRadius={55}
                      outerRadius={95}
                      paddingAngle={2}
                    >
                      {poolStats.slice(0, 8).map((_, i) => (
                        <Cell key={i} fill={POOL_COLORS[i % POOL_COLORS.length]} />
                      ))}
                    </Pie>
                    <Tooltip
                      contentStyle={{
                        background: "var(--color-popover)",
                        border: "1px solid var(--color-border)",
                        borderRadius: 6,
                        fontFamily: "var(--font-mono)",
                        fontSize: 11,
                      }}
                      formatter={(v: number, n: string) => [`${v} blocks`, n]}
                    />
                  </PieChart>
                </ResponsiveContainer>
              </div>
              <div className="space-y-1 font-mono text-xs">
                {poolStats.slice(0, 8).map((p, i) => {
                  const pct = totalBlocks > 0 ? (p.blocks / totalBlocks) * 100 : 0;
                  return (
                    <div key={p.name} className="flex items-center justify-between gap-2 px-1 py-0.5">
                      <div className="flex items-center gap-2 min-w-0">
                        <span
                          className="size-2 flex-shrink-0 rounded-sm"
                          style={{ background: POOL_COLORS[i % POOL_COLORS.length] }}
                        />
                        <span className="truncate">{p.name}</span>
                      </div>
                      <div className="flex items-center gap-2 flex-shrink-0">
                        <span className="text-muted-foreground">{p.blocks}</span>
                        <span className="text-foreground w-12 text-right">{pct.toFixed(1)}%</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>

        {/* Reward summary */}
        <div className="rounded-md surface-2 border border-border p-4">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground mb-3">
            Block rewards
          </h2>
          {rewardStats ? (
            <div className="space-y-3">
              <div>
                <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Avg reward</div>
                <div className="font-mono text-2xl text-foreground">
                  {satsToTxc(Math.round(rewardStats.avgReward))} <span className="text-sm text-muted-foreground">TXC</span>
                </div>
              </div>
              <div>
                <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Avg fees / block</div>
                <div className="font-mono text-lg text-foreground">
                  {satsToTxc(Math.round(rewardStats.avgFees))} <span className="text-xs text-muted-foreground">TXC</span>
                </div>
              </div>
              <div className="pt-2 border-t border-border text-[11px] text-muted-foreground">
                Sampled over last <span className="font-mono text-foreground">{rewardStats.sampleSize}</span> blocks.
              </div>
            </div>
          ) : (
            <div className="text-xs text-muted-foreground">Loading…</div>
          )}
        </div>
      </div>

      {/* Recent blocks table */}
      <div>
        <div className="flex items-center justify-between mb-3">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Recent blocks
          </h2>
          <Link to="/blocks" className="text-[11px] text-muted-foreground hover:text-primary">
            view all blocks →
          </Link>
        </div>
        <div className="rounded-md surface-2 border border-border overflow-hidden">
          <table className="w-full text-xs">
            <thead className="text-[10px] uppercase tracking-widest text-muted-foreground">
              <tr className="border-b border-border">
                <th className="text-left px-3 py-2">Height</th>
                <th className="text-left px-3 py-2">Age</th>
                <th className="text-left px-3 py-2">Pool</th>
                <th className="text-left px-3 py-2">Txs</th>
                <th className="text-left px-3 py-2">Reward</th>
                <th className="text-left px-3 py-2">Hash</th>
              </tr>
            </thead>
            <tbody className="font-mono">
              {blocks.slice(0, 15).map((b) => (
                <tr key={b.id} className="border-b border-border last:border-b-0 hover:bg-muted/30">
                  <td className="px-3 py-2">
                    <Link to="/block/$hash" params={{ hash: b.id }} className="text-primary hover:underline">
                      {formatNumber(b.height)}
                    </Link>
                  </td>
                  <td className="px-3 py-2 text-muted-foreground">{timeAgo(b.timestamp)}</td>
                  <td className="px-3 py-2">{b.extras?.pool?.name ?? "—"}</td>
                  <td className="px-3 py-2">{b.tx_count}</td>
                  <td className="px-3 py-2">{b.extras?.reward != null ? satsToTxc(b.extras.reward) : "—"}</td>
                  <td className="px-3 py-2">
                    <Link to="/block/$hash" params={{ hash: b.id }} className="text-muted-foreground hover:text-primary">
                      {shortHash(b.id)}
                    </Link>
                  </td>
                </tr>
              ))}
              {!blocks.length && !recent.isLoading && (
                <tr><td colSpan={6} className="px-3 py-6 text-center text-muted-foreground">No blocks loaded.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
