import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useMempoolFeed } from "@/lib/txc/ws";
import { esplora } from "@/lib/txc/esplora";
import { MempoolBlocksViz } from "@/components/explorer/MempoolBlocksViz";
import { ConfirmedBlocksStrip } from "@/components/explorer/ConfirmedBlocksStrip";
import { FeeGauge } from "@/components/explorer/FeeGauge";
import { StatTile } from "@/components/explorer/StatTile";
import { SearchBar } from "@/components/explorer/SearchBar";
import { NetworkDifficultyChart } from "@/components/explorer/NetworkDifficultyChart";
import { formatBytes, formatNumber, satsToTxc, shortHash, timeAgo } from "@/lib/txc/format";
import { Activity, Clock, Zap } from "lucide-react";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "TXC Mempool — Live TEXITcoin Block Explorer" },
      { name: "description", content: "Live TEXITcoin mempool, projected blocks, fee estimator, and recent blocks." },
      { property: "og:title", content: "TXC Mempool — Live TEXITcoin Block Explorer" },
      { property: "og:description", content: "Live TEXITcoin mempool, projected blocks, fee estimator, and recent blocks." },
    ],
  }),
  component: Dashboard,
});

function Dashboard() {
  const feed = useMempoolFeed();
  const diff = useQuery({
    queryKey: ["mempool", "difficulty"],
    queryFn: () => esplora.difficultyAdjustment(),
    refetchInterval: 60_000,
    retry: 0,
  });

  const dot =
    feed.status === "live"
      ? "bg-success"
      : feed.status === "polling"
      ? "bg-warning"
      : "bg-muted-foreground";

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* Hero / search */}
      <section className="rounded-xl surface border border-border p-6 md:p-10 shadow-card relative overflow-hidden">
        <div className="relative">
          <div className="flex items-center gap-2 text-xs uppercase tracking-widest text-muted-foreground">
            <span className={`size-2 rounded-full ${dot} animate-pulse-dot`} />
            {feed.status === "live" && "Live · WebSocket"}
            {feed.status === "polling" && "Live · polling 10s"}
            {feed.status === "connecting" && "Connecting…"}
            {feed.status === "offline" && "Offline"}
            {feed.tipHeight != null && (
              <span className="ml-2 font-mono text-foreground">
                tip {formatNumber(feed.tipHeight)}
              </span>
            )}
          </div>
          <h1 className="font-display text-4xl md:text-5xl font-bold mt-2 text-balance">
            TEXITcoin <span className="text-primary">mempool</span>, right now.
          </h1>
          <p className="mt-2 text-sm md:text-base text-muted-foreground max-w-2xl">
            Real-time view of the TXC chain — projected next blocks, fees,
            Omni-Layer token activity, and the address/tx/block you came here to find.
          </p>
          <div className="mt-6">
            <SearchBar variant="hero" />
          </div>
        </div>
      </section>

      <NetworkDifficultyChart />

      {/* Mempool + confirmed strips */}
      <section className="grid lg:grid-cols-2 gap-6">
        <div>
          <div className="flex items-center justify-between mb-3">
            <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground flex items-center gap-2">
              <Zap className="size-4 text-primary" /> Mempool · projected blocks
            </h2>
            <Link to="/mempool" className="text-[11px] text-muted-foreground hover:text-primary font-medium">
              {feed.mempool ? `${formatNumber(feed.mempool.count)} txs waiting →` : "view mempool →"}
            </Link>
          </div>
          <MempoolBlocksViz blocks={feed.mempoolBlocks} />
        </div>
        <div>
          <div className="flex items-center justify-between mb-3">
            <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground flex items-center gap-2">
              <Activity className="size-4 text-accent" /> Recent confirmed blocks
            </h2>
            <a href="/blocks" className="text-[11px] text-muted-foreground hover:text-primary font-medium">
              view all →
            </a>
          </div>
          <ConfirmedBlocksStrip blocks={feed.blocks} />
        </div>
      </section>

      {/* Stats + fees */}
      <section className="grid md:grid-cols-3 lg:grid-cols-5 gap-3">
        <StatTile
          label="Tip height"
          value={feed.tipHeight != null ? formatNumber(feed.tipHeight) : "—"}
          hint={feed.blocks[0] ? timeAgo(feed.blocks[0].timestamp) : ""}
        />
        <StatTile
          label="Mempool size"
          value={feed.mempool ? formatNumber(feed.mempool.count) + " tx" : "—"}
          hint={feed.mempool ? formatBytes(feed.mempool.vsize) : ""}
        />
        <StatTile
          label="Difficulty"
          value={feed.blocks[0]?.difficulty ? feed.blocks[0].difficulty.toExponential(3) : "—"}
          hint={
            diff.data
              ? `${diff.data.progressPercent.toFixed(1)}% · ${diff.data.remainingBlocks} blocks left`
              : ""
          }
        />
        <StatTile
          label="Next retarget"
          value={
            diff.data
              ? `${diff.data.difficultyChange >= 0 ? "+" : ""}${diff.data.difficultyChange.toFixed(2)}%`
              : "—"
          }
          hint={diff.data && diff.data.remainingTime > 0 ? `in ~${Math.round(diff.data.remainingTime / 3600)}h` : ""}
        />
        <StatTile
          label="Mined in"
          value="Texas"
          hint="by individuals · 3-min blocks"
        />
      </section>

      <section className="grid lg:grid-cols-3 gap-6">
        <div className="lg:col-span-1">
          <FeeGauge fees={feed.fees} />
        </div>
        <div className="lg:col-span-2 rounded-md surface-2 border border-border p-4">
          <h3 className="font-display text-base uppercase tracking-wide mb-2">
            What you're looking at
          </h3>
          <p className="text-sm text-muted-foreground leading-relaxed">
            The colored boxes on the left are <strong className="text-foreground">projected blocks</strong> —
            transactions currently in the mempool, bucketed by fee rate. The strip on
            the right is the most recent <strong className="text-foreground">confirmed blocks</strong>.
            Click any block to see its txs, click any tx to see inputs/outputs, and
            paste a TXC address (starting with <span className="font-mono">T</span>) in
            the search bar to see history. <strong className="text-foreground">Omni-Layer</strong> token
            operations (POP, ImagineNation tokens, anything using <span className="font-mono">"omni"</span> OP_RETURN)
            are decoded automatically on the transaction page.
          </p>
        </div>
      </section>

      <RecentTransactions />
    </div>
  );
}

function RecentTransactions() {
  const recent = useQuery({
    queryKey: ["mempool", "recent", "home"],
    queryFn: () => esplora.mempoolRecent(),
    refetchInterval: 10_000,
    retry: 0,
  });

  return (
    <section>
      <div className="flex items-center justify-between mb-3">
        <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground flex items-center gap-2">
          <Clock className="size-4 text-accent" /> Recent transactions
        </h2>
        <Link to="/mempool" className="text-[11px] text-muted-foreground hover:text-primary font-medium">
          view all in mempool →
        </Link>
      </div>
      {recent.isLoading ? (
        <div className="text-sm text-muted-foreground">Loading…</div>
      ) : !recent.data?.length ? (
        <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground text-center">
          No recent unconfirmed transactions.
        </div>
      ) : (
        <div className="grid gap-1.5">
          {recent.data.slice(0, 12).map((t) => {
            const feeRate = t.vsize > 0 ? t.fee / t.vsize : 0;
            return (
              <Link
                key={t.txid}
                to="/tx/$txid"
                params={{ txid: t.txid }}
                className="surface-2 border border-border rounded-md px-3 py-2 hover:border-primary/60 transition-colors flex items-center justify-between gap-3 text-xs"
              >
                <span className="font-mono truncate">{shortHash(t.txid, 14, 14)}</span>
                <div className="flex items-center gap-4 flex-shrink-0 font-mono">
                  <span className="text-muted-foreground hidden sm:inline">{t.vsize} vB</span>
                  <span className="text-accent">{feeRate.toFixed(2)} sat/vB</span>
                  <span className="text-foreground">{satsToTxc(t.value)} TXC</span>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </section>
  );
}
