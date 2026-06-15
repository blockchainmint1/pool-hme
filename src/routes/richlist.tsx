import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Trophy, ExternalLink } from "lucide-react";

type Entry = { address: string; balance: number; utxo_count: number };
type RichlistResponse = {
  computed_at: number;
  indexed_tip: number;
  limit: number;
  total_entries: number;
  entries: Entry[];
};

export const Route = createFileRoute("/richlist")({
  head: () => ({
    meta: [
      { title: "TXC Richlist — Top 100 Wallets | TXC Mempool" },
      { name: "description", content: "Top 100 TEXITcoin wallets ranked by confirmed unspent balance. Live data from the on-chain address indexer." },
      { property: "og:title", content: "TXC Richlist — Top 100 Wallets" },
      { property: "og:description", content: "Top 100 TEXITcoin wallets ranked by confirmed unspent balance." },
    ],
  }),
  component: RichlistPage,
});

const SAT = 100_000_000;

function fmtTxc(sats: number) {
  const txc = sats / SAT;
  return txc.toLocaleString(undefined, { maximumFractionDigits: 8 });
}

function fmtAgo(unix: number) {
  const secs = Math.max(0, Math.floor(Date.now() / 1000 - unix));
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  return `${Math.floor(secs / 3600)}h ago`;
}

function RichlistPage() {
  const { data, isLoading, error } = useQuery<RichlistResponse>({
    queryKey: ["richlist", 100],
    queryFn: async () => {
      const r = await fetch("/api/public/v1/richlist?limit=100");
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json();
    },
    refetchInterval: 60_000,
    staleTime: 30_000,
  });

  const total = data?.entries.reduce((s, e) => s + e.balance, 0) ?? 0;

  return (
    <div className="max-w-5xl mx-auto px-4 py-6">
      <div className="mb-6">
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">On-chain</div>
        <h1 className="font-display text-3xl md:text-4xl font-semibold mt-1 flex items-center gap-2">
          <Trophy className="size-7 text-accent" /> TXC Richlist
        </h1>
        <p className="mt-2 text-sm text-muted-foreground max-w-3xl">
          Top 100 TEXITcoin addresses ranked by confirmed unspent balance.
          Indexed from the chain in real time and cached at the edge for 60 seconds.
        </p>
        {data && (
          <div className="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-xs text-muted-foreground font-mono">
            <span>indexed tip: <span className="text-foreground">#{data.indexed_tip.toLocaleString()}</span></span>
            <span>updated: <span className="text-foreground">{fmtAgo(data.computed_at)}</span></span>
            <span>top {data.total_entries} total: <span className="text-foreground">{fmtTxc(total)} TXC</span></span>
          </div>
        )}
      </div>

      {isLoading && <div className="text-sm text-muted-foreground">Loading richlist…</div>}
      {error && (
        <div className="surface-2 border border-destructive/40 rounded-md p-4 text-sm text-destructive">
          Failed to load richlist: {(error as Error).message}
        </div>
      )}

      {data && (
        <div className="surface-2 border border-border rounded-md overflow-hidden">
          <table className="w-full text-sm">
            <thead className="text-[10px] uppercase tracking-widest text-muted-foreground border-b border-border">
              <tr>
                <th className="text-left px-3 py-2 w-12">#</th>
                <th className="text-left px-3 py-2">Address</th>
                <th className="text-right px-3 py-2">Balance (TXC)</th>
                <th className="text-right px-3 py-2 hidden sm:table-cell">UTXOs</th>
                <th className="text-right px-3 py-2 hidden md:table-cell">Share</th>
              </tr>
            </thead>
            <tbody>
              {data.entries.map((e, i) => {
                const share = total > 0 ? (e.balance / total) * 100 : 0;
                return (
                  <tr key={e.address} className="border-b border-border/50 last:border-0 hover:bg-background/40">
                    <td className="px-3 py-2 font-mono text-xs text-muted-foreground">{i + 1}</td>
                    <td className="px-3 py-2">
                      <Link
                        to="/address/$addr"
                        params={{ addr: e.address }}
                        className="font-mono text-xs text-accent hover:underline inline-flex items-center gap-1 break-all"
                      >
                        {e.address}
                        <ExternalLink className="size-3 shrink-0 opacity-60" />
                      </Link>
                    </td>
                    <td className="px-3 py-2 text-right font-mono tabular-nums">{fmtTxc(e.balance)}</td>
                    <td className="px-3 py-2 text-right font-mono tabular-nums text-muted-foreground hidden sm:table-cell">
                      {e.utxo_count.toLocaleString()}
                    </td>
                    <td className="px-3 py-2 text-right font-mono tabular-nums text-muted-foreground hidden md:table-cell">
                      {share.toFixed(2)}%
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <p className="mt-4 text-xs text-muted-foreground">
        Powered by the open <Link to="/docs" className="text-accent hover:underline">/api/public/v1/richlist</Link> endpoint —
        free for anyone to use.
      </p>
    </div>
  );
}
