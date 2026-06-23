import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { Tx } from "@/lib/txc/esplora";
import { satsToTxc } from "@/lib/txc/format";

interface HistoryPoint {
  t: number;
  balance: number; // TXC (decimal)
}

interface IndexerResponse {
  address: string;
  bucket: "day" | "hour";
  currentBalance: number; // sats
  points: number;
  history: Array<{ t: number; balance: number; delta: number }>;
}

type Range = "all" | "30d" | "7d";

const RANGE_TO_BUCKET: Record<Range, "day" | "hour"> = {
  all: "day",
  "30d": "day",
  "7d": "hour",
};

const RANGE_SECONDS: Record<Range, number | null> = {
  all: null,
  "30d": 30 * 86400,
  "7d": 7 * 86400,
};

/**
 * Fallback: anchor to current balance and walk newest→oldest through the
 * txs we *do* have loaded. Only used when the indexer endpoint is
 * unavailable.
 */
function buildFallbackSeries(txs: Tx[], addr: string, currentSats: number): HistoryPoint[] {
  const events: Array<{ t: number; delta: number }> = [];
  for (const tx of txs) {
    const t = tx.status.block_time ?? Math.floor(Date.now() / 1000);
    let delta = 0;
    for (const v of tx.vout) if (v.scriptpubkey_address === addr) delta += v.value;
    for (const i of tx.vin) if (i.prevout?.scriptpubkey_address === addr) delta -= i.prevout.value;
    if (delta !== 0) events.push({ t, delta });
  }
  events.sort((a, b) => b.t - a.t);
  const points: HistoryPoint[] = [{ t: Math.floor(Date.now() / 1000), balance: currentSats / 1e8 }];
  let bal = currentSats;
  for (const e of events) {
    points.push({ t: e.t, balance: bal / 1e8 });
    bal -= e.delta;
  }
  if (events.length) points.push({ t: events[events.length - 1].t - 1, balance: bal / 1e8 });
  return points.sort((a, b) => a.t - b.t);
}

export function BalanceHistoryChart({
  txs,
  address,
  currentSats,
}: {
  txs: Tx[];
  address: string;
  currentSats: number;
}) {
  const [range, setRange] = useState<Range>("all");
  const bucket = RANGE_TO_BUCKET[range];

  const indexer = useQuery<IndexerResponse | null>({
    queryKey: ["balance-history", address, bucket],
    queryFn: async () => {
      const r = await fetch(`/api/v1/address/${address}/balance-history?bucket=${bucket}&limit=500`);
      if (!r.ok) return null;
      return (await r.json()) as IndexerResponse;
    },
    staleTime: 60_000,
    retry: 0,
  });

  const series: HistoryPoint[] = useMemo(() => {
    if (indexer.data?.history?.length) {
      return indexer.data.history.map((p) => ({ t: p.t, balance: p.balance / 1e8 }));
    }
    return buildFallbackSeries(txs, address, currentSats);
  }, [indexer.data, txs, address, currentSats]);

  const data = useMemo(() => {
    const span = RANGE_SECONDS[range];
    if (span == null) return series;
    const cutoff = Date.now() / 1000 - span;
    return series.filter((p) => p.t >= cutoff);
  }, [series, range]);

  if (series.length < 2) {
    return (
      <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground">
        Not enough transaction data to chart balance history.
      </div>
    );
  }

  const visibleSpan = data.length > 1 ? data[data.length - 1].t - data[0].t : 0;
  const tickFmt = (v: number) => {
    const d = new Date(v * 1000);
    if (visibleSpan < 2 * 86400) return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    if (visibleSpan < 60 * 86400) return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
    return d.toLocaleDateString(undefined, { month: "short", year: "2-digit" });
  };

  const sourceLabel = indexer.data
    ? `indexer · ${indexer.data.history.length} ${indexer.data.bucket}s`
    : "estimated from loaded txs";

  return (
    <div className="surface border border-border rounded-md p-4">
      <div className="flex items-center justify-between mb-3">
        <div>
          <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Balance history
          </h3>
          <div className="text-[10px] text-muted-foreground font-mono mt-0.5">{sourceLabel}</div>
        </div>
        <div className="inline-flex rounded-md border border-border surface-2 p-0.5 text-[11px]">
          {(["7d", "30d", "all"] as Range[]).map((r) => (
            <button
              key={r}
              onClick={() => setRange(r)}
              className={`px-2 py-0.5 rounded-sm uppercase ${
                range === r ? "bg-primary text-primary-foreground" : "text-muted-foreground"
              }`}
            >
              {r}
            </button>
          ))}
        </div>
      </div>
      <div className="h-64 w-full">
        <ResponsiveContainer>
          <AreaChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <defs>
              <linearGradient id="balGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="var(--color-primary)" stopOpacity={0.55} />
                <stop offset="100%" stopColor="var(--color-primary)" stopOpacity={0.05} />
              </linearGradient>
            </defs>
            <XAxis
              dataKey="t"
              tickFormatter={tickFmt}
              tick={{ fontSize: 10, fill: "var(--color-muted-foreground)" }}
              stroke="var(--color-border)"
              minTickGap={50}
            />
            <YAxis
              tick={{ fontSize: 10, fill: "var(--color-muted-foreground)" }}
              tickFormatter={(v) => Intl.NumberFormat(undefined, { notation: "compact" }).format(v)}
              stroke="var(--color-border)"
              width={56}
            />
            <Tooltip
              contentStyle={{ background: "var(--color-surface)", border: "1px solid var(--color-border)", borderRadius: 6, fontSize: 12 }}
              labelFormatter={(v) => new Date((v as number) * 1000).toLocaleString()}
              formatter={(v: number) => [`${satsToTxc(Math.round(v * 1e8))} TXC`, "Balance"]}
            />
            <Area type="monotone" dataKey="balance" stroke="var(--color-primary)" strokeWidth={2} fill="url(#balGrad)" />
          </AreaChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
