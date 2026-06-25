import { Link } from "@tanstack/react-router";
import { feeBucket } from "@/lib/txc/format";
import type { MempoolBlock } from "@/lib/txc/esplora";

const FEE_VAR: Record<number, string> = {
  1: "var(--color-fee-1)",
  2: "var(--color-fee-2)",
  3: "var(--color-fee-3)",
  4: "var(--color-fee-4)",
  5: "var(--color-fee-5)",
  6: "var(--color-fee-6)",
};

interface Props {
  blocks: MempoolBlock[];
}

/**
 * Mempool projected blocks — flat rectangular tiles in the classic
 * mempool.space style. Next block is leftmost; subsequent projected
 * blocks queue to the right.
 */
export function MempoolBlocksViz({ blocks }: Props) {
  if (!blocks.length) {
    return (
      <div className="rounded-md surface-2 border border-border px-4 py-8 text-sm text-muted-foreground text-center">
        Mempool is empty — next block has nothing waiting.
      </div>
    );
  }
  const items = blocks.slice(0, 6);
  return (
    <div className="flex items-end gap-3 overflow-x-auto pb-2">
      {items.map((b, i) => {
        const color = FEE_VAR[feeBucket(b.medianFee || 1)];
        const filledPct = Math.max(2, Math.min(100, (b.blockVSize / 1_000_000) * 100));
        return (
          <Link
            key={i}
            to="/mempool/block/$index"
            params={{ index: String(i) }}
            className="group flex flex-col items-center flex-shrink-0"
          >
            <div
              className="relative w-32 h-32 rounded-md border border-border overflow-hidden transition-transform group-hover:-translate-y-1 group-hover:shadow-lg"
              style={{
                background: `linear-gradient(180deg, color-mix(in oklab, ${color} 85%, transparent), color-mix(in oklab, ${color} 55%, transparent))`,
                boxShadow: `inset 0 0 0 1px color-mix(in oklab, ${color} 60%, transparent), 0 8px 20px -10px ${color}`,
              }}
            >
              {/* fill indicator */}
              <div
                className="absolute inset-x-0 bottom-0 bg-black/25"
                style={{ height: `${100 - filledPct}%` }}
              />
              <div className="relative h-full flex flex-col items-center justify-center text-center px-2 text-white drop-shadow-[0_1px_2px_rgba(0,0,0,0.6)]">
                <div className="font-display text-2xl font-bold leading-none">
                  ~{b.medianFee.toFixed(1)}
                </div>
                <div className="text-[9px] uppercase tracking-widest opacity-80 mt-1">sat/vB</div>
                <div className="text-[10px] font-semibold mt-2 opacity-95">
                  {b.feeRange?.length >= 2
                    ? `${b.feeRange[0].toFixed(1)} – ${b.feeRange[b.feeRange.length - 1].toFixed(1)}`
                    : ""}
                </div>
                <div className="text-[10px] mt-2 opacity-90">{b.nTx.toLocaleString()} tx</div>
                <div className="text-[9px] opacity-70">{(b.blockVSize / 1000).toFixed(0)} kvB</div>
              </div>
            </div>
            <div className="mt-2 text-[10px] font-mono text-muted-foreground group-hover:text-primary transition-colors">
              {i === 0 ? "next block" : `in ~${(i + 1) * 3} min`}
            </div>
          </Link>
        );
      })}
    </div>
  );
}
