import { useMemo } from "react";
import type { Tx } from "@/lib/txc/esplora";

/**
 * GitHub-style 52-week activity heatmap of transactions touching this address.
 */
export function ActivityHeatmap({ txs }: { txs: Tx[] }) {
  const { weeks, max, total } = useMemo(() => {
    const counts = new Map<string, number>();
    for (const tx of txs) {
      const t = tx.status.block_time;
      if (!t) continue;
      const d = new Date(t * 1000);
      d.setHours(0, 0, 0, 0);
      const k = d.toISOString().slice(0, 10);
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }

    // Build a 53-week x 7-day grid ending today.
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const start = new Date(today);
    start.setDate(start.getDate() - 52 * 7 - today.getDay());

    const weeks: Array<Array<{ date: string; count: number }>> = [];
    let max = 0;
    let total = 0;
    for (let w = 0; w < 53; w++) {
      const week: Array<{ date: string; count: number }> = [];
      for (let d = 0; d < 7; d++) {
        const cur = new Date(start);
        cur.setDate(start.getDate() + w * 7 + d);
        const k = cur.toISOString().slice(0, 10);
        const c = counts.get(k) ?? 0;
        if (cur > today) {
          week.push({ date: k, count: -1 });
        } else {
          week.push({ date: k, count: c });
          if (c > max) max = c;
          total += c;
        }
      }
      weeks.push(week);
    }
    return { weeks, max, total };
  }, [txs]);

  const intensity = (c: number) => {
    if (c <= 0) return "var(--color-surface-2)";
    const t = Math.min(1, c / Math.max(max, 1));
    if (t > 0.75) return "var(--color-fee-6)";
    if (t > 0.5) return "var(--color-fee-5)";
    if (t > 0.25) return "var(--color-fee-4)";
    return "var(--color-fee-3)";
  };

  return (
    <div className="surface border border-border rounded-md p-4 overflow-x-auto">
      <div className="flex items-center justify-between mb-3">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
          Activity · last 52 weeks
        </h3>
        <div className="text-[11px] text-muted-foreground font-mono">{total} txs · busiest day {max}</div>
      </div>
      <div className="flex gap-[3px]">
        {weeks.map((week, wi) => (
          <div key={wi} className="flex flex-col gap-[3px]">
            {week.map((cell, ci) => (
              <div
                key={ci}
                className="size-[11px] rounded-[2px]"
                style={{
                  background: cell.count < 0 ? "transparent" : intensity(cell.count),
                  outline: cell.count < 0 ? "none" : "none",
                }}
                title={cell.count < 0 ? "" : `${cell.date}: ${cell.count} tx`}
              />
            ))}
          </div>
        ))}
      </div>
      <div className="mt-2 flex items-center gap-1 text-[10px] text-muted-foreground">
        Less
        <span className="size-[10px] rounded-sm" style={{ background: "var(--color-surface-2)" }} />
        <span className="size-[10px] rounded-sm" style={{ background: "var(--color-fee-3)" }} />
        <span className="size-[10px] rounded-sm" style={{ background: "var(--color-fee-4)" }} />
        <span className="size-[10px] rounded-sm" style={{ background: "var(--color-fee-5)" }} />
        <span className="size-[10px] rounded-sm" style={{ background: "var(--color-fee-6)" }} />
        More
      </div>
    </div>
  );
}
