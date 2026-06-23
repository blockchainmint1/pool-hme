import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import {
  AreaChart, Area, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";
import { esplora, type BlockSummary } from "@/lib/txc/esplora";
import { formatBytes, satsToTxc } from "@/lib/txc/format";

type Window = "1d" | "1w" | "1m" | "3m";

// TXC targets 3-min blocks → 480/day. Cap chunks so cold-window loads
// stay snappy: we sample at most ~60 buckets per window.
const WINDOW_BLOCKS: Record<Window, number> = {
  "1d": 480,
  "1w": 480 * 7,
  "1m": 480 * 30,
  "3m": 480 * 90,
};
const WINDOW_LABEL: Record<Window, string> = { "1d": "Day", "1w": "Week", "1m": "Month", "3m": "3 months" };

export const Route = createFileRoute("/graphs")({
  head: () => ({
    meta: [
      { title: "Graphs — TXC Mempool Explorer" },
      { name: "description", content: "TEXITcoin chain charts: block sizes, fees, rewards, and tx counts over day, week, month, or 3 months." },
      { property: "og:title", content: "TXC Graphs" },
      { property: "og:description", content: "Charts of recent TEXITcoin chain activity." },
    ],
  }),
  component: GraphsPage,
});

async function fetchWindow(target: number): Promise<BlockSummary[]> {
  const out: BlockSummary[] = [];
  let from: number | undefined = undefined;
  // /v1/blocks returns 15 per page.
  const pages = Math.ceil(target / 15);
  for (let i = 0; i < pages; i++) {
    const batch: BlockSummary[] = await esplora.blocksV1(from);
    if (!batch.length) break;
    out.push(...batch);
    from = batch[batch.length - 1].height - 1;
    if (from < 0) break;
  }
  return out.sort((a, b) => a.height - b.height);
}

/** Aggregate blocks into ~60 buckets for plotting. */
function bucketize(blocks: BlockSummary[], buckets = 60) {
  if (!blocks.length) return [];
  const size = Math.max(1, Math.ceil(blocks.length / buckets));
  const out: Array<{
    height: number;
    size: number;
    tx_count: number;
    medianFee: number;
    avgFeeRate: number;
    reward: number;
    fees: number;
  }> = [];
  for (let i = 0; i < blocks.length; i += size) {
    const chunk = blocks.slice(i, i + size);
    const n = chunk.length;
    const sum = (f: (b: BlockSummary) => number) => chunk.reduce((s, b) => s + f(b), 0);
    out.push({
      height: chunk[chunk.length - 1].height,
      size: sum((b) => b.size) / n,
      tx_count: sum((b) => b.tx_count) / n,
      medianFee: sum((b) => b.extras?.medianFee ?? 0) / n,
      avgFeeRate: sum((b) => b.extras?.avgFeeRate ?? 0) / n,
      reward: sum((b) => b.extras?.reward ?? 0) / n,
      fees: sum((b) => b.extras?.totalFees ?? 0) / n,
    });
  }
  return out;
}

function GraphsPage() {
  const [window, setWindow] = useState<Window>("1w");

  const blocks = useQuery({
    queryKey: ["graphs", "blocks", window],
    queryFn: () => fetchWindow(WINDOW_BLOCKS[window]),
    refetchInterval: window === "1d" ? 60_000 : 5 * 60_000,
    staleTime: 60_000,
  });

  const data = bucketize(blocks.data ?? []);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="font-display text-3xl">Graphs</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Recent on-chain activity over the last {WINDOW_LABEL[window].toLowerCase()}.
            {blocks.data && (
              <> Aggregated from <span className="font-mono text-foreground">{blocks.data.length}</span> blocks into {data.length} buckets.</>
            )}
          </p>
        </div>
        <div className="inline-flex rounded-md border border-border surface-2 text-xs overflow-hidden">
          {(Object.keys(WINDOW_LABEL) as Window[]).map((w) => (
            <button
              key={w}
              onClick={() => setWindow(w)}
              className={`px-3 py-1.5 font-mono uppercase tracking-wide ${
                window === w ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {WINDOW_LABEL[w]}
            </button>
          ))}
        </div>
      </div>

      {blocks.isLoading && (
        <div className="text-sm text-muted-foreground">Loading {WINDOW_LABEL[window].toLowerCase()} of blocks…</div>
      )}

      {data.length > 0 && (
        <div className="grid lg:grid-cols-2 gap-6">
          <ChartCard title="Block size">
            <AreaChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} tickFormatter={(v) => formatBytes(v)} />
              <Tooltip
                contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }}
                formatter={(v: number) => formatBytes(v)}
              />
              <Area type="monotone" dataKey="size" stroke="var(--color-accent)" fill="var(--color-accent)" fillOpacity={0.2} />
            </AreaChart>
          </ChartCard>

          <ChartCard title="Transactions per block">
            <BarChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} />
              <Tooltip contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }} />
              <Bar dataKey="tx_count" fill="var(--color-primary)" />
            </BarChart>
          </ChartCard>

          <ChartCard title="Median fee rate (sat/vB)">
            <AreaChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} />
              <Tooltip contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }} />
              <Area type="monotone" dataKey="medianFee" stroke="var(--color-fee-5)" fill="var(--color-fee-5)" fillOpacity={0.2} />
            </AreaChart>
          </ChartCard>

          <ChartCard title="Average fee rate (sat/vB)">
            <AreaChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} />
              <Tooltip contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }} />
              <Area type="monotone" dataKey="avgFeeRate" stroke="var(--color-fee-3)" fill="var(--color-fee-3)" fillOpacity={0.2} />
            </AreaChart>
          </ChartCard>

          <ChartCard title="Miner reward (TXC)">
            <AreaChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} tickFormatter={(v) => satsToTxc(v)} />
              <Tooltip
                contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }}
                formatter={(v: number) => `${satsToTxc(Math.round(v))} TXC`}
              />
              <Area type="monotone" dataKey="reward" stroke="var(--color-success)" fill="var(--color-success)" fillOpacity={0.2} />
            </AreaChart>
          </ChartCard>

          <ChartCard title="Fees per block (TXC)">
            <AreaChart data={data}>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis dataKey="height" stroke="var(--color-muted-foreground)" fontSize={10} />
              <YAxis stroke="var(--color-muted-foreground)" fontSize={10} tickFormatter={(v) => satsToTxc(v)} />
              <Tooltip
                contentStyle={{ background: "var(--color-popover)", border: "1px solid var(--color-border)", borderRadius: 6 }}
                formatter={(v: number) => `${satsToTxc(Math.round(v))} TXC`}
              />
              <Area type="monotone" dataKey="fees" stroke="var(--color-fee-6)" fill="var(--color-fee-6)" fillOpacity={0.2} />
            </AreaChart>
          </ChartCard>
        </div>
      )}
    </div>
  );
}

function ChartCard({ title, children }: { title: string; children: React.ReactElement }) {
  return (
    <div className="rounded-md surface-2 border border-border p-4">
      <h2 className="font-display text-base uppercase tracking-wide mb-3">{title}</h2>
      <div className="h-64">
        <ResponsiveContainer>{children}</ResponsiveContainer>
      </div>
    </div>
  );
}
