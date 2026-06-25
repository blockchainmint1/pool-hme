import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMempoolFeed } from "@/lib/txc/ws";
import { esplora } from "@/lib/txc/esplora";
import { MempoolBlocksViz } from "@/components/explorer/MempoolBlocksViz";
import { FeeGauge } from "@/components/explorer/FeeGauge";
import { StatTile } from "@/components/explorer/StatTile";
import { formatBytes, formatNumber, satsToTxc, shortHash } from "@/lib/txc/format";
import { Activity, Clock, Zap } from "lucide-react";

export const Route = createFileRoute("/mempool/")({
  head: () => ({
    meta: [
      { title: "Mempool — Live unconfirmed TXC transactions" },
      { name: "description", content: "What's currently in the TEXITcoin mempool: projected blocks, fee histogram, and the most recent unconfirmed transactions." },
    ],
  }),
  component: MempoolPage,
});

function MempoolPage() {
  const feed = useMempoolFeed();

  const recent = useQuery({
    queryKey: ["mempool", "recent"],
    queryFn: () => esplora.mempoolRecent(),
    refetchInterval: 8_000,
    retry: 0,
  });

  // Upstream fee_histogram is sometimes empty even when txs are queued. Fall
  // back to synthesizing buckets from the projected mempool blocks so the
  // chart reflects what the "next blocks" tiles show.
  let histogram: [number, number][] = feed.mempool?.fee_histogram ?? [];
  if (histogram.length === 0 && feed.mempoolBlocks.length > 0) {
    const buckets: [number, number][] = [];
    for (const b of feed.mempoolBlocks) {
      const range = b.feeRange && b.feeRange.length > 0 ? b.feeRange : [b.medianFee];
      const per = b.blockVSize / range.length;
      for (const fee of range) buckets.push([fee, per]);
    }
    histogram = buckets.sort((a, z) => a[0] - z[0]);
  }
  const maxBucketVsize = histogram.reduce((m, [, v]) => Math.max(m, v), 0);
  const hasMempool = (feed.mempool?.count ?? 0) > 0 || feed.mempoolBlocks.length > 0;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <header className="flex items-end justify-between flex-wrap gap-3">
        <div>
          <div className="text-xs uppercase tracking-widest text-muted-foreground flex items-center gap-2">
            <Zap className="size-3.5 text-primary" /> Live mempool
          </div>
          <h1 className="font-display text-3xl md:text-4xl font-bold mt-1">
            What's <span className="text-primary">in the mempool</span> right now
          </h1>
          <p className="text-sm text-muted-foreground mt-1 max-w-2xl">
            Transactions broadcast to the TXC network but not yet confirmed in a block.
            Refreshes every few seconds.
          </p>
        </div>
        <Link to="/" className="text-xs text-muted-foreground hover:text-primary font-mono">
          ← back to dashboard
        </Link>
      </header>

      {/* Stats */}
      <section className="grid md:grid-cols-2 lg:grid-cols-4 gap-3">
        <StatTile
          label="Unconfirmed txs"
          value={feed.mempool ? formatNumber(feed.mempool.count) : "—"}
          hint="waiting for a block"
        />
        <StatTile
          label="Mempool size"
          value={feed.mempool ? formatBytes(feed.mempool.vsize) : "—"}
          hint="virtual bytes"
        />
        <StatTile
          label="Total fees waiting"
          value={feed.mempool ? `${satsToTxc(feed.mempool.total_fee)} TXC` : "—"}
          hint="if all confirmed"
        />
        <StatTile
          label="Projected blocks"
          value={String(feed.mempoolBlocks.length || 0)}
          hint={feed.mempoolBlocks.length ? `~${feed.mempoolBlocks.length * 3} min to clear` : ""}
        />
      </section>

      {/* Projected blocks */}
      <section>
        <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground mb-3 flex items-center gap-2">
          <Activity className="size-4 text-primary" /> Projected next blocks
        </h2>
        <MempoolBlocksViz blocks={feed.mempoolBlocks} />
      </section>

      <section className="grid lg:grid-cols-3 gap-6">
        {/* Fee histogram */}
        <div className="lg:col-span-2 surface-2 border border-border rounded-md p-4">
          <h3 className="font-display text-sm uppercase tracking-wide mb-3">
            Fee-rate histogram
          </h3>
          {histogram.length === 0 ? (
            <div className="text-sm text-muted-foreground py-8 text-center">
              {hasMempool ? "Fee histogram unavailable." : "Mempool is empty."}
            </div>
          ) : (
            <div className="flex items-end gap-1 h-40">
              {histogram.map(([feeRate, vsize], i) => {
                const h = maxBucketVsize > 0 ? (vsize / maxBucketVsize) * 100 : 0;
                return (
                  <div key={i} className="flex-1 flex flex-col items-center gap-1 group">
                    <div
                      className="w-full bg-primary/70 hover:bg-primary rounded-t transition-colors relative"
                      style={{ height: `${h}%`, minHeight: "2px" }}
                      title={`${feeRate.toFixed(1)} sat/vB · ${formatBytes(vsize)}`}
                    />
                    <div className="text-[9px] text-muted-foreground font-mono">
                      {feeRate.toFixed(0)}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
          <div className="mt-2 text-[11px] text-muted-foreground">
            x: fee rate (sat/vB) · y: vsize at that rate
          </div>
        </div>
        <FeeGauge fees={feed.fees} />
      </section>

      {/* Recent unconfirmed txs */}
      <section>
        <div className="flex items-center justify-between mb-3">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground flex items-center gap-2">
            <Clock className="size-4 text-accent" /> Most recent broadcasts
          </h2>
          <span className="text-[11px] text-muted-foreground font-mono">
            updates every 8s
          </span>
        </div>
        {recent.isLoading ? (
          <div className="text-sm text-muted-foreground">Loading…</div>
        ) : !recent.data?.length ? (
          <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground text-center">
            No recent unconfirmed transactions.
          </div>
        ) : (
          <div className="grid gap-1.5">
            {recent.data.slice(0, 40).map((t) => {
              const feeRate = t.vsize > 0 ? t.fee / t.vsize : 0;
              return (
                <Link
                  key={t.txid}
                  to="/tx/$txid"
                  params={{ txid: t.txid }}
                  className="surface-2 border border-border rounded-md px-3 py-2 hover:border-primary/60 transition-colors flex items-center justify-between gap-3 text-xs"
                >
                  <span className="font-mono truncate">{shortHash(t.txid, 16, 16)}</span>
                  <div className="flex items-center gap-4 flex-shrink-0 font-mono">
                    <span className="text-muted-foreground">{t.vsize} vB</span>
                    <span className="text-accent">{feeRate.toFixed(2)} sat/vB</span>
                    <span className="text-foreground">{satsToTxc(t.value)} TXC</span>
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
