import { Link } from "@tanstack/react-router";
import { feeBucket } from "@/lib/txc/format";
import type { MempoolBlock } from "@/lib/txc/esplora";
import { Block3D } from "./Block3D";

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
 * Mempool projected blocks — a chain of real 3D cubes receding into the
 * distance. Next block is closest (largest); subsequent projected blocks
 * fall back into perspective.
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
    <div className="relative scene-3d pt-8 pb-12 px-2 overflow-hidden rounded-lg surface-2 border border-border">
      <div className="chain-stars" />
      <div className="chain-floor" />
      <div className="chain-row chain-row-mempool relative flex items-end gap-3 justify-start">
        {items.map((b, i) => {
          // Receding chain: each subsequent block sits a little smaller & deeper
          const scale = 1 - i * 0.07;
          const filledPct = Math.max(2, Math.min(100, (b.blockVSize / 1_000_000) * 100));
          const emptyPct = 100 - filledPct;
          return (
            <Link
              key={i}
              to="/mempool/block/$index"
              params={{ index: String(i) }}
              className="group flex flex-col items-center animate-block-pop"
              style={{
                animationDelay: `${i * 80}ms`,
                transformStyle: "preserve-3d",
              }}
            >
              <Block3D
                color={FEE_VAR[feeBucket(b.medianFee || 1)]}
                size={140}
                depth={44}
                scale={scale}
                emptyPct={emptyPct}
                rotateY={-32}
                rotateX={-18}
              >
                <div className="font-display text-2xl font-bold leading-none drop-shadow-[0_2px_3px_rgba(0,0,0,0.5)]">
                  ~{b.medianFee.toFixed(1)}
                </div>
                <div className="text-[9px] uppercase tracking-widest opacity-80 mt-1">sat/vB</div>
                <div className="text-[10px] font-semibold mt-2 opacity-95">
                  {b.feeRange?.length >= 2
                    ? `${b.feeRange[0].toFixed(1)} – ${b.feeRange[b.feeRange.length - 1].toFixed(1)}`
                    : ""}
                </div>
                <div className="text-[10px] mt-3 opacity-90">{b.nTx.toLocaleString()} tx</div>
                <div className="text-[9px] opacity-70">{(b.blockVSize / 1000).toFixed(0)} kvB</div>
              </Block3D>
              <div className="mt-4 text-[10px] font-mono text-muted-foreground group-hover:text-primary transition-colors">
                {i === 0 ? "next block" : `in ~${(i + 1) * 3} min`}
              </div>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
