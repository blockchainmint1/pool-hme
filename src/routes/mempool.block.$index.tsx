import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { hierarchy, treemap, treemapSquarify } from "d3-hierarchy";
import { esplora } from "@/lib/txc/esplora";
import { useMempoolFeed } from "@/lib/txc/ws";
import { feeBucket, formatBytes, formatNumber, satsToTxc, shortHash } from "@/lib/txc/format";
import { cn } from "@/lib/utils";
import { ArrowLeft, ChevronLeft, ChevronRight } from "lucide-react";

export const Route = createFileRoute("/mempool/block/$index")({
  head: () => ({
    meta: [
      { title: "Projected mempool block — TEXITcoin" },
      { name: "description", content: "Live treemap of transactions waiting to confirm in an upcoming TXC block." },
    ],
  }),
  component: BlockVizPage,
});

const FEE_CLASS: Record<number, string> = {
  1: "fill-fee-1",
  2: "fill-fee-2",
  3: "fill-fee-3",
  4: "fill-fee-4",
  5: "fill-fee-5",
  6: "fill-fee-6",
};

type Tx = { txid: string; fee: number; vsize: number; value: number };

function BlockVizPage() {
  const { index } = Route.useParams();
  const navigate = useNavigate();
  const idx = Math.max(0, Math.min(7, parseInt(index, 10) || 0));
  const feed = useMempoolFeed();

  const recent = useQuery({
    queryKey: ["mempool", "recent", "viz"],
    queryFn: () => esplora.mempoolRecent(),
    refetchInterval: 5_000,
    retry: 0,
  });

  // Approximate the contents of the idx-th projected block by sorting all
  // mempool txs by fee-rate desc and slicing the cumulative-vsize window
  // that matches that block. The upstream WS pushes exact contents per
  // block, but the REST surface only gives us the recent unconfirmed set —
  // good enough for a visual.
  const { blockTxs, totals, summary } = useMemo(() => {
    const all: Tx[] = (recent.data ?? []).slice().sort((a, b) => {
      const fa = a.vsize > 0 ? a.fee / a.vsize : 0;
      const fb = b.vsize > 0 ? b.fee / b.vsize : 0;
      return fb - fa;
    });
    const blocks = feed.mempoolBlocks;
    const target = blocks[idx]?.blockVSize ?? 1_000_000;
    const prior = blocks.slice(0, idx).reduce((s, b) => s + b.blockVSize, 0);
    let cum = 0;
    const out: Tx[] = [];
    for (const t of all) {
      const next = cum + t.vsize;
      if (next <= prior) {
        cum = next;
        continue;
      }
      if (cum >= prior + target) break;
      out.push(t);
      cum = next;
    }
    const totVsize = out.reduce((s, t) => s + t.vsize, 0);
    const totFee = out.reduce((s, t) => s + t.fee, 0);
    const totValue = out.reduce((s, t) => s + t.value, 0);
    return {
      blockTxs: out,
      totals: { vsize: totVsize, fee: totFee, value: totValue },
      summary: blocks[idx],
    };
  }, [recent.data, feed.mempoolBlocks, idx]);

  const width = 1200;
  const height = 720;

  const layout = useMemo(() => {
    if (!blockTxs.length) return [];
    type Node = { children?: Node[]; tx?: Tx };
    const root = hierarchy<Node>({ children: blockTxs.map((tx) => ({ tx })) })
      .sum((d) => (d.tx ? Math.max(1, d.tx.vsize) : 0))
      .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
    const tm = treemap<Node>().size([width, height]).tile(treemapSquarify).paddingInner(1);
    const laid = tm(root);
    return laid.leaves().map((n) => ({
      tx: n.data.tx!,
      x: n.x0,
      y: n.y0,
      w: Math.max(0, n.x1 - n.x0),
      h: Math.max(0, n.y1 - n.y0),
    }));
  }, [blockTxs]);

  const [hover, setHover] = useState<Tx | null>(null);
  const totalBlocks = feed.mempoolBlocks.length || 1;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-5">
      <header className="flex items-end justify-between flex-wrap gap-3">
        <div>
          <Link to="/mempool" className="text-xs text-muted-foreground hover:text-primary font-mono inline-flex items-center gap-1">
            <ArrowLeft className="size-3" /> back to mempool
          </Link>
          <h1 className="font-display text-3xl md:text-4xl font-bold mt-1">
            Projected block <span className="text-primary">#{idx + 1}</span>
            <span className="text-base text-muted-foreground font-mono ml-3">
              {idx === 0 ? "next" : `in ~${(idx + 1) * 3} min`}
            </span>
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Each rectangle is a transaction. Area = vsize, color = fee rate. Click any tile to inspect.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            disabled={idx === 0}
            onClick={() => navigate({ to: "/mempool/block/$index", params: { index: String(idx - 1) } })}
            className="p-2 rounded-md surface-2 border border-border hover:border-primary/60 disabled:opacity-30 disabled:cursor-not-allowed"
            aria-label="Previous block"
          >
            <ChevronLeft className="size-4" />
          </button>
          <span className="font-mono text-xs text-muted-foreground px-2">
            {idx + 1} / {totalBlocks}
          </span>
          <button
            disabled={idx >= totalBlocks - 1}
            onClick={() => navigate({ to: "/mempool/block/$index", params: { index: String(idx + 1) } })}
            className="p-2 rounded-md surface-2 border border-border hover:border-primary/60 disabled:opacity-30 disabled:cursor-not-allowed"
            aria-label="Next block"
          >
            <ChevronRight className="size-4" />
          </button>
        </div>
      </header>

      <section className="grid grid-cols-2 md:grid-cols-4 gap-3 text-xs">
        <Stat label="Transactions" value={formatNumber(blockTxs.length)} />
        <Stat label="Block weight" value={formatBytes(totals.vsize)} />
        <Stat label="Total fees" value={`${satsToTxc(totals.fee)} TXC`} />
        <Stat
          label="Median fee"
          value={summary ? `${summary.medianFee.toFixed(1)} sat/vB` : "—"}
        />
      </section>

      <section className="relative surface-2 border border-border rounded-md overflow-hidden">
        {recent.isLoading ? (
          <div className="aspect-[5/3] flex items-center justify-center text-sm text-muted-foreground">
            Loading mempool…
          </div>
        ) : !blockTxs.length ? (
          <div className="aspect-[5/3] flex items-center justify-center text-sm text-muted-foreground">
            No transactions projected for this block.
          </div>
        ) : (
          <svg
            viewBox={`0 0 ${width} ${height}`}
            className="w-full h-auto block"
            onMouseLeave={() => setHover(null)}
          >
            {layout.map(({ tx, x, y, w, h }) => {
              const feeRate = tx.vsize > 0 ? tx.fee / tx.vsize : 0;
              const cls = FEE_CLASS[feeBucket(feeRate)];
              return (
                <g
                  key={tx.txid}
                  className="cursor-pointer transition-opacity hover:opacity-90"
                  onMouseEnter={() => setHover(tx)}
                  onClick={() => navigate({ to: "/tx/$txid", params: { txid: tx.txid } })}
                  style={{ transition: "transform 400ms ease" }}
                >
                  <rect
                    x={x}
                    y={y}
                    width={w}
                    height={h}
                    className={cn(cls, "stroke-background")}
                    strokeWidth={0.5}
                    style={{ transition: "x 400ms ease, y 400ms ease, width 400ms ease, height 400ms ease" }}
                  />
                  {w > 60 && h > 28 && (
                    <text
                      x={x + 6}
                      y={y + 16}
                      className="fill-white/90 font-mono pointer-events-none"
                      fontSize={11}
                    >
                      {feeRate.toFixed(1)} sat/vB
                    </text>
                  )}
                  {w > 90 && h > 46 && (
                    <text
                      x={x + 6}
                      y={y + 32}
                      className="fill-white/70 font-mono pointer-events-none"
                      fontSize={10}
                    >
                      {shortHash(tx.txid, 6, 4)}
                    </text>
                  )}
                </g>
              );
            })}
          </svg>
        )}

        {hover && (
          <div className="absolute top-3 right-3 surface-1 border border-border rounded-md px-3 py-2 text-xs font-mono space-y-0.5 pointer-events-none shadow-card">
            <div className="text-primary">{shortHash(hover.txid, 10, 8)}</div>
            <div className="text-muted-foreground">
              {(hover.vsize > 0 ? hover.fee / hover.vsize : 0).toFixed(2)} sat/vB
            </div>
            <div className="text-muted-foreground">{hover.vsize} vB · {satsToTxc(hover.value)} TXC</div>
          </div>
        )}
      </section>

      <div className="flex items-center gap-3 text-[11px] text-muted-foreground font-mono flex-wrap">
        <span>fee rate:</span>
        {[1, 2, 3, 4, 5, 6].map((b) => (
          <span key={b} className="inline-flex items-center gap-1.5">
            <span className={cn("inline-block w-3 h-3 rounded-sm", `bg-fee-${b}`)} />
            {b === 1 ? "<2" : b === 2 ? "2–5" : b === 3 ? "5–10" : b === 4 ? "10–25" : b === 5 ? "25–50" : "50+"}
          </span>
        ))}
      </div>

      <section className="space-y-2">
        <div className="flex items-center justify-between">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Transactions in this projected block
          </h2>
          <span className="text-[11px] text-muted-foreground font-mono">
            {blockTxs.length} tx · sorted by fee rate
          </span>
        </div>
        {blockTxs.length === 0 ? (
          <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground text-center">
            No transactions to list.
          </div>
        ) : (
          <div className="surface-2 border border-border rounded-md overflow-hidden">
            <div className="grid grid-cols-[1fr_auto_auto_auto_auto] gap-3 px-3 py-2 text-[10px] uppercase tracking-widest text-muted-foreground border-b border-border bg-background/40">
              <div>Txid</div>
              <div className="text-right">Fee rate</div>
              <div className="text-right">vSize</div>
              <div className="text-right">Fee</div>
              <div className="text-right">Value</div>
            </div>
            <div className="max-h-[480px] overflow-y-auto divide-y divide-border">
              {blockTxs.map((t) => {
                const feeRate = t.vsize > 0 ? t.fee / t.vsize : 0;
                const bucket = feeBucket(feeRate);
                return (
                  <Link
                    key={t.txid}
                    to="/tx/$txid"
                    params={{ txid: t.txid }}
                    className="grid grid-cols-[1fr_auto_auto_auto_auto] gap-3 px-3 py-2 text-xs font-mono hover:bg-background/40 transition-colors items-center"
                  >
                    <div className="flex items-center gap-2 min-w-0">
                      <span className={cn("inline-block w-2 h-4 rounded-sm flex-shrink-0", `bg-fee-${bucket}`)} />
                      <span className="truncate">{shortHash(t.txid, 14, 10)}</span>
                    </div>
                    <div className="text-right text-accent">{feeRate.toFixed(2)} sat/vB</div>
                    <div className="text-right text-muted-foreground">{t.vsize.toLocaleString()} vB</div>
                    <div className="text-right text-muted-foreground">{satsToTxc(t.fee)}</div>
                    <div className="text-right">{satsToTxc(t.value)} TXC</div>
                  </Link>
                );
              })}
            </div>
          </div>
        )}
      </section>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="surface-2 border border-border rounded-md px-3 py-2">
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground">{label}</div>
      <div className="font-display text-lg mt-0.5">{value}</div>
    </div>
  );
}
