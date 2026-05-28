import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { esplora } from "@/lib/txc/esplora";
import { formatBytes, formatNumber, satsToTxc, shortHash, timeAgo } from "@/lib/txc/format";
import { useState } from "react";

export const Route = createFileRoute("/blocks")({
  head: () => ({
    meta: [
      { title: "Blocks — TXC Mempool Explorer" },
      { name: "description", content: "Browse recent TEXITcoin blocks: height, age, transactions, size, miner, fees." },
      { property: "og:title", content: "TEXITcoin Blocks" },
      { property: "og:description", content: "Recent blocks on the TXC chain." },
    ],
  }),
  component: BlocksPage,
});

function BlocksPage() {
  const [startHeight, setStartHeight] = useState<number | undefined>(undefined);
  const q = useQuery({
    queryKey: ["mempool", "blocks-v1", startHeight ?? "tip"],
    queryFn: () => esplora.blocksV1(startHeight),
  });

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      <h1 className="font-display text-3xl">Blocks</h1>
      <div className="rounded-md surface border border-border overflow-hidden">
        <table className="w-full text-sm">
          <thead className="text-[10px] uppercase tracking-widest text-muted-foreground">
            <tr className="border-b border-border">
              <th className="text-left px-3 py-2.5">Height</th>
              <th className="text-left px-3 py-2.5">Age</th>
              <th className="text-left px-3 py-2.5">Txs</th>
              <th className="text-left px-3 py-2.5">Size</th>
              <th className="text-left px-3 py-2.5">Pool</th>
              <th className="text-left px-3 py-2.5">Median fee</th>
              <th className="text-left px-3 py-2.5">Reward</th>
              <th className="text-left px-3 py-2.5">Hash</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {q.isLoading && (
              <tr><td colSpan={8} className="px-3 py-6 text-center text-muted-foreground">Loading…</td></tr>
            )}
            {q.data?.map((b) => (
              <tr key={b.id} className="border-b border-border last:border-b-0 hover:surface-2">
                <td className="px-3 py-2.5">
                  <Link to="/block/$hash" params={{ hash: b.id }} className="text-primary hover:underline">
                    {formatNumber(b.height)}
                  </Link>
                </td>
                <td className="px-3 py-2.5 text-muted-foreground">{timeAgo(b.timestamp)}</td>
                <td className="px-3 py-2.5">{b.tx_count}</td>
                <td className="px-3 py-2.5 text-muted-foreground">{formatBytes(b.size)}</td>
                <td className="px-3 py-2.5">{b.extras?.pool?.name ?? "—"}</td>
                <td className="px-3 py-2.5">{b.extras?.medianFee != null ? b.extras.medianFee.toFixed(1) : "—"}</td>
                <td className="px-3 py-2.5">{b.extras?.reward != null ? satsToTxc(b.extras.reward) : "—"}</td>
                <td className="px-3 py-2.5">
                  <Link to="/block/$hash" params={{ hash: b.id }} className="text-muted-foreground hover:text-primary">
                    {shortHash(b.id)}
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="flex justify-between">
        <button
          className="px-3 py-1.5 text-sm rounded-md surface-2 border border-border hover:border-primary disabled:opacity-40"
          disabled={!q.data?.length}
          onClick={() => {
            if (!q.data?.length) return;
            const last = q.data[q.data.length - 1];
            setStartHeight(last.height - 1);
            window.scrollTo({ top: 0 });
          }}
        >
          ← Older
        </button>
        <button
          className="px-3 py-1.5 text-sm rounded-md surface-2 border border-border hover:border-primary disabled:opacity-40"
          disabled={startHeight == null}
          onClick={() => { setStartHeight(undefined); window.scrollTo({ top: 0 }); }}
        >
          Newest →
        </button>
      </div>
    </div>
  );
}
