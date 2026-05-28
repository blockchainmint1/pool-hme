import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { esplora } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { TxListRow } from "@/components/explorer/TxListRow";
import { formatBytes, formatDateTime, formatNumber, satsToTxc, shortHash, timeAgo } from "@/lib/txc/format";

export const Route = createFileRoute("/block/$hash")({
  head: ({ params }) => ({
    meta: [
      { title: `Block ${params.hash.slice(0, 12)}… — TXC Mempool` },
      { name: "description", content: `Block ${params.hash} on the TEXITcoin chain.` },
      { property: "og:title", content: `TXC Block ${params.hash.slice(0, 12)}…` },
    ],
  }),
  component: BlockPage,
});

function BlockPage() {
  const { hash } = Route.useParams();
  const [page, setPage] = useState(0);
  const block = useQuery({ queryKey: ["mempool", "block", hash], queryFn: () => esplora.blockByHash(hash) });
  const txs = useQuery({
    queryKey: ["mempool", "block-txs", hash, page],
    queryFn: () => esplora.blockTxs(hash, page * 25),
  });
  const b = block.data;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div>
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Block</div>
        <h1 className="font-display text-3xl mt-1">
          {b ? `#${formatNumber(b.height)}` : "Loading…"}
        </h1>
        <div className="mt-1 font-mono text-xs text-muted-foreground break-all">{hash}</div>
      </div>

      {b && (
        <>
          <div className="grid md:grid-cols-3 lg:grid-cols-5 gap-3">
            <StatTile label="Timestamp" value={timeAgo(b.timestamp)} hint={formatDateTime(b.timestamp)} />
            <StatTile label="Transactions" value={formatNumber(b.tx_count)} />
            <StatTile label="Size" value={formatBytes(b.size)} hint={`${formatNumber(b.weight)} wu`} />
            <StatTile
              label="Pool"
              value={b.extras?.pool?.name ?? "Unknown"}
              hint={b.extras?.reward != null ? `${satsToTxc(b.extras.reward)} TXC reward` : undefined}
            />
            <StatTile
              label="Median fee"
              value={b.extras?.medianFee != null ? `${b.extras.medianFee.toFixed(1)} sat/vB` : "—"}
              hint={
                b.extras?.feeRange?.length
                  ? `range ${b.extras.feeRange[0].toFixed(1)} – ${b.extras.feeRange[b.extras.feeRange.length - 1].toFixed(1)}`
                  : undefined
              }
            />
          </div>

          <div className="rounded-md surface-2 border border-border p-4 grid md:grid-cols-2 gap-4 font-mono text-xs">
            <div>
              <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Merkle root</div>
              <div className="break-all mt-1">{b.merkle_root}</div>
            </div>
            <div>
              <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Previous block</div>
              {b.previousblockhash ? (
                <Link
                  to="/block/$hash"
                  params={{ hash: b.previousblockhash }}
                  className="break-all mt-1 block hover:text-primary"
                >
                  {b.previousblockhash}
                </Link>
              ) : (
                <div className="mt-1 text-muted-foreground">—</div>
              )}
            </div>
            <div>
              <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Nonce</div>
              <div className="mt-1">{b.nonce}</div>
            </div>
            <div>
              <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Bits / Difficulty</div>
              <div className="mt-1">{b.bits.toString(16)} · {b.difficulty.toExponential(3)}</div>
            </div>
          </div>
        </>
      )}

      <div>
        <div className="flex items-center justify-between mb-2">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Transactions
          </h2>
          <div className="text-[11px] text-muted-foreground font-mono">
            page {page + 1}{b ? ` of ${Math.max(1, Math.ceil(b.tx_count / 25))}` : ""}
          </div>
        </div>
        <div className="space-y-2">
          {txs.isLoading && <div className="text-sm text-muted-foreground">Loading transactions…</div>}
          {txs.data?.map((t) => <TxListRow key={t.txid} tx={t} />)}
        </div>
        <div className="flex justify-between mt-4">
          <button
            disabled={page === 0}
            className="px-3 py-1.5 text-sm rounded-md surface-2 border border-border hover:border-primary disabled:opacity-40"
            onClick={() => { setPage((p) => Math.max(0, p - 1)); window.scrollTo({ top: 400 }); }}
          >
            ← Previous
          </button>
          <button
            disabled={!txs.data || txs.data.length < 25 || (b ? (page + 1) * 25 >= b.tx_count : false)}
            className="px-3 py-1.5 text-sm rounded-md surface-2 border border-border hover:border-primary disabled:opacity-40"
            onClick={() => { setPage((p) => p + 1); window.scrollTo({ top: 400 }); }}
          >
            Next →
          </button>
        </div>
      </div>

      <div className="text-xs text-muted-foreground font-mono">
        Permalink: <span>{shortHash(hash)}</span>
      </div>
    </div>
  );
}
