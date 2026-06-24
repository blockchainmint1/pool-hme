import { Link } from "@tanstack/react-router";
import { cn } from "@/lib/utils";
import { feeBucket } from "@/lib/txc/format";
import type { MempoolBlock } from "@/lib/txc/esplora";

const FEE_CLASS: Record<number, string> = {
  1: "bg-fee-1",
  2: "bg-fee-2",
  3: "bg-fee-3",
  4: "bg-fee-4",
  5: "bg-fee-5",
  6: "bg-fee-6",
};

interface Props {
  blocks: MempoolBlock[];
}

/** Projected mempool blocks — the colored boxes mempool.space is famous for. */
export function MempoolBlocksViz({ blocks }: Props) {
  if (!blocks.length) {
    return (
      <div className="rounded-md surface-2 border border-border px-4 py-6 text-sm text-muted-foreground text-center">
        Mempool is empty — next block has nothing waiting.
      </div>
    );
  }
  return (
    <div className="flex gap-3 overflow-x-auto pb-2">
      {blocks.slice(0, 6).map((b, i) => {
        const cls = FEE_CLASS[feeBucket(b.medianFee || 1)];
        const filledPct = Math.min(100, (b.blockVSize / 1_000_000) * 100);
        return (
          <Link
            key={i}
            to="/mempool/block/$index"
            params={{ index: String(i) }}
            className="flex-shrink-0 w-36 rounded-md overflow-hidden border border-border shadow-card animate-block-pop hover:border-primary/60 transition-colors"
          >
            <div
              className={cn(
                "relative h-28 flex flex-col items-center justify-center text-white p-2 overflow-hidden",
                cls,
              )}
            >
              <div className="absolute inset-x-0 bottom-0 bg-black/20" style={{ height: `${100 - filledPct}%` }} />
              <div className="relative font-display text-xl font-bold tracking-tight">
                ~{b.medianFee.toFixed(1)}
              </div>
              <div className="relative text-[10px] uppercase opacity-90">sat/vB median</div>
              {b.feeRange?.length >= 2 && (
                <div className="relative text-[10px] opacity-85 mt-0.5">
                  {b.feeRange[0].toFixed(1)}–{b.feeRange[b.feeRange.length - 1].toFixed(1)}
                </div>
              )}
            </div>
            <div className="bg-card px-2 py-1.5 text-[11px] text-muted-foreground font-mono flex flex-col gap-0.5">
              <div className="flex justify-between">
                <span>{b.nTx} tx</span>
                <span>{(b.blockVSize / 1000).toFixed(0)} kvB</span>
              </div>
              <div className="text-[10px]">
                {i === 0 ? "next block" : `in ~${(i + 1) * 3} min`}
              </div>
            </div>
          </Link>
        );
      })}
    </div>
  );
}
