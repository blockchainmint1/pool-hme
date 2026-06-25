import { Link } from "@tanstack/react-router";
import { feeBucket } from "@/lib/txc/format";
import type { BlockSummary } from "@/lib/txc/esplora";

const FEE_VAR: Record<number, string> = {
  1: "var(--color-fee-1)",
  2: "var(--color-fee-2)",
  3: "var(--color-fee-3)",
  4: "var(--color-fee-4)",
  5: "var(--color-fee-5)",
  6: "var(--color-fee-6)",
};

interface Props {
  blocks: BlockSummary[];
  emptyLabel?: string;
}

/**
 * Confirmed (mined) blocks — flat rectangular tiles in the classic
 * mempool.space style. Newest block is on the left.
 */
export function ConfirmedBlocksStrip({ blocks, emptyLabel = "Waiting for blocks…" }: Props) {
  if (!blocks.length) {
    return (
      <div className="rounded-md surface-2 border border-border px-4 py-8 text-sm text-muted-foreground text-center">
        {emptyLabel}
      </div>
    );
  }
  const items = blocks.slice(0, 6);
  return (
    <div className="flex items-end gap-3 overflow-x-auto pb-2">
      {items.map((b) => {
        const median = b.extras?.medianFee ?? 0;
        const color = FEE_VAR[feeBucket(median || 1)];
        const fees = b.extras?.totalFees;
        const reward = b.extras?.reward;
        return (
          <Link
            key={b.id}
            to="/block/$hash"
            params={{ hash: b.id }}
            className="group flex flex-col items-center flex-shrink-0"
          >
            <div
              className="relative w-32 h-32 rounded-md border border-border overflow-hidden transition-transform group-hover:-translate-y-1 group-hover:shadow-lg"
              style={{
                background: `linear-gradient(180deg, color-mix(in oklab, ${color} 85%, transparent), color-mix(in oklab, ${color} 55%, transparent))`,
                boxShadow: `inset 0 0 0 1px color-mix(in oklab, ${color} 60%, transparent), 0 8px 20px -10px ${color}`,
              }}
            >
              <div className="relative h-full flex flex-col items-center justify-center text-center px-2 text-white drop-shadow-[0_1px_2px_rgba(0,0,0,0.6)]">
                <div className="font-display text-xl font-bold leading-none">
                  {b.height.toLocaleString()}
                </div>
                <div className="text-[9px] uppercase tracking-widest opacity-80 mt-1">height</div>
                <div className="text-[10px] font-semibold mt-2 opacity-95">
                  ~{median ? median.toFixed(1) : "—"} sat/vB
                </div>
                {fees != null && (
                  <div className="text-[10px] mt-2 opacity-90">
                    {(fees / 1e8).toFixed(4)} TXC
                  </div>
                )}
                <div className="text-[9px] mt-1 opacity-75">
                  {b.tx_count} tx · {Math.round(b.size / 1024)} kB
                </div>
              </div>
            </div>
            <div className="mt-2 text-[10px] font-mono text-muted-foreground group-hover:text-primary transition-colors truncate max-w-[140px]">
              {b.extras?.pool?.name ?? (reward ? `${(reward / 1e8).toFixed(2)} TXC` : "—")}
            </div>
          </Link>
        );
      })}
    </div>
  );
}
