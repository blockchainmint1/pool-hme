import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import {
  AreaChart, Area, BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";
import { esplora } from "@/lib/txc/esplora";
import { formatBytes } from "@/lib/txc/format";

export const Route = createFileRoute("/graphs")({
  head: () => ({
    meta: [
      { title: "Graphs — TXC Mempool Explorer" },
      { name: "description", content: "TEXITcoin chain charts: block sizes, fees, and tx counts over recent history." },
      { property: "og:title", content: "TXC Graphs" },
      { property: "og:description", content: "Charts of recent TEXITcoin chain activity." },
    ],
  }),
  component: GraphsPage,
});

function GraphsPage() {
  const blocks = useQuery({
    queryKey: ["mempool", "graphs-blocks"],
    queryFn: async () => {
      // Pull the last ~50 blocks for chart data.
      const out: Awaited<ReturnType<typeof esplora.recentBlocks>> = [];
      let from: number | undefined = undefined;
      for (let i = 0; i < 5; i++) {
        const batch = await esplora.recentBlocks(from);
        if (!batch.length) break;
        out.push(...batch);
        from = batch[batch.length - 1].height - 1;
      }
      return out.sort((a, b) => a.height - b.height);
    },
    refetchInterval: 60_000,
  });

  const data = (blocks.data ?? []).map((b) => ({
    height: b.height,
    size: b.size,
    tx_count: b.tx_count,
    medianFee: b.extras?.medianFee ?? 0,
    avgFeeRate: b.extras?.avgFeeRate ?? 0,
  }));

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div>
        <h1 className="font-display text-3xl">Graphs</h1>
        <p className="text-sm text-muted-foreground mt-1">Recent on-chain activity, derived from the most recent ~50 blocks.</p>
      </div>

      {blocks.isLoading && <div className="text-sm text-muted-foreground">Loading…</div>}

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
