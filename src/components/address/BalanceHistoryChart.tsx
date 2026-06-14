import { useMemo, useState } from "react";
import { Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { Tx } from "@/lib/txc/esplora";
import { satsToTxc } from "@/lib/txc/format";

/**
 * Compute a balance time-series by walking the address's tx history.
 * For each tx, the delta to *this address* = sum of outputs to addr - sum of inputs from addr.
 * We sort ascending by block_time and accumulate.
 */
function buildSeries(txs: Tx[], addr: string) {
  const events: Array<{ t: number; delta: number }> = [];
  for (const tx of txs) {
    const t = tx.status.block_time ?? Math.floor(Date.now() / 1000);
    let delta = 0;
    for (const v of tx.vout) if (v.scriptpubkey_address === addr) delta += v.value;
    for (const i of tx.vin) if (i.prevout?.scriptpubkey_address === addr) delta -= i.prevout.value;
    if (delta !== 0) events.push({ t, delta });
  }
  events.sort((a, b) => a.t - b.t);
  let bal = 0;
  return events.map((e) => {
    bal += e.delta;
    return { t: e.t, balance: bal / 1e8 };
  });
}

export function BalanceHistoryChart({ txs, address }: { txs: Tx[]; address: string }) {
  const [range, setRange] = useState<"all" | "30d">("all");
  const series = useMemo(() => buildSeries(txs, address), [txs, address]);
  const data = useMemo(() => {
    if (range === "all") return series;
    const cutoff = Date.now() / 1000 - 30 * 86400;
    return series.filter((p) => p.t >= cutoff);
  }, [series, range]);

  if (series.length === 0) {
    return (
      <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground">
        Not enough transaction data to chart balance history.
      </div>
    );
  }

  return (
    <div className="surface border border-border rounded-md p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">Balance history</h3>
        <div className="inline-flex rounded-md border border-border surface-2 p-0.5 text-[11px]">
          <button onClick={() => setRange("all")} className={`px-2 py-0.5 rounded-sm ${range === "all" ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>All</button>
          <button onClick={() => setRange("30d")} className={`px-2 py-0.5 rounded-sm ${range === "30d" ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>30d</button>
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
              tickFormatter={(v) => new Date(v * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" })}
              tick={{ fontSize: 10, fill: "var(--color-muted-foreground)" }}
              stroke="var(--color-border)"
              minTickGap={50}
            />
            <YAxis
              tick={{ fontSize: 10, fill: "var(--color-muted-foreground)" }}
              tickFormatter={(v) => Intl.NumberFormat(undefined, { notation: "compact" }).format(v)}
              stroke="var(--color-border)"
              width={48}
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
