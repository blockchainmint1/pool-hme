import { useMemo, useState } from "react";
import { Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { Tx } from "@/lib/txc/esplora";
import { satsToTxc } from "@/lib/txc/format";

/**
 * Build a balance time-series anchored to the address's *current* balance.
 *
 * The loaded `txs` are typically a recent page (e.g. 25), not the full
 * history. Summing deltas from 0 would understate the balance by orders
 * of magnitude on active addresses. Instead we start from `currentSats`
 * (= present balance) and walk newest → oldest, subtracting each delta
 * to recover the historical balance before each tx.
 */
function buildSeries(txs: Tx[], addr: string, currentSats: number) {
  const events: Array<{ t: number; delta: number }> = [];
  for (const tx of txs) {
    const t = tx.status.block_time ?? Math.floor(Date.now() / 1000);
    let delta = 0;
    for (const v of tx.vout) if (v.scriptpubkey_address === addr) delta += v.value;
    for (const i of tx.vin) if (i.prevout?.scriptpubkey_address === addr) delta -= i.prevout.value;
    if (delta !== 0) events.push({ t, delta });
  }
  // Newest first — walk back from current balance.
  events.sort((a, b) => b.t - a.t);
  const points: Array<{ t: number; balance: number }> = [];
  let bal = currentSats;
  // Plot the current balance "now".
  points.push({ t: Math.floor(Date.now() / 1000), balance: bal / 1e8 });
  for (const e of events) {
    // The point AT this tx's time = balance right after it confirmed = current bal.
    points.push({ t: e.t, balance: bal / 1e8 });
    // Then step back: before this tx, balance was bal - delta.
    bal -= e.delta;
  }
  // Anchor the start with the pre-history balance.
  if (events.length > 0) {
    points.push({ t: events[events.length - 1].t - 1, balance: bal / 1e8 });
  }
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
  const [range, setRange] = useState<"all" | "30d">("all");
  const series = useMemo(() => buildSeries(txs, address, currentSats), [txs, address, currentSats]);
  const data = useMemo(() => {
    if (range === "all") return series;
    const cutoff = Date.now() / 1000 - 30 * 86400;
    return series.filter((p) => p.t >= cutoff);
  }, [series, range]);

  if (series.length < 2) {
    return (
      <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground">
        Not enough transaction data to chart balance history.
      </div>
    );
  }

  // Pick tick formatter based on span: short windows show time, longer ones show date.
  const span = data.length > 1 ? data[data.length - 1].t - data[0].t : 0;
  const tickFmt = (v: number) => {
    const d = new Date(v * 1000);
    if (span < 2 * 86400) return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    if (span < 30 * 86400) return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "2-digit" });
  };

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
