import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { esplora, txFeeRate } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { TxFlow } from "@/components/explorer/TxFlow";
import { formatBytes, formatDateTime, formatNumber, satsToTxc, shortHash, timeAgo } from "@/lib/txc/format";
import { upstreamTxUrl } from "@/lib/txc/network";

export const Route = createFileRoute("/tx/$txid")({
  head: ({ params }) => ({
    meta: [
      { title: `Tx ${params.txid.slice(0, 12)}… — TXC Mempool` },
      { name: "description", content: `TEXITcoin transaction ${params.txid}: inputs, outputs, fees, and Omni-Layer decoded payload.` },
      { property: "og:title", content: `TXC Tx ${params.txid.slice(0, 12)}…` },
    ],
  }),
  component: TxPage,
});

function TxPage() {
  const { txid } = Route.useParams();
  const tx = useQuery({ queryKey: ["mempool", "tx", txid], queryFn: () => esplora.tx(txid) });
  const tip = useQuery({ queryKey: ["mempool", "tip-height"], queryFn: () => esplora.tipHeight(), refetchInterval: 30_000 });

  const t = tx.data;
  if (tx.isLoading) return <div className="max-w-7xl mx-auto px-4 py-6 text-muted-foreground">Loading transaction…</div>;
  if (tx.isError || !t) {
    return (
      <div className="max-w-7xl mx-auto px-4 py-10 text-center">
        <h1 className="font-display text-2xl mb-2">Transaction not found</h1>
        <p className="text-sm text-muted-foreground font-mono break-all">{txid}</p>
      </div>
    );
  }

  const totalIn = t.vin.reduce((s, v) => s + (v.prevout?.value ?? 0), 0);
  const totalOut = t.vout.reduce((s, v) => s + v.value, 0);
  const fr = txFeeRate(t);
  const confirmations = t.status.confirmed && tip.data != null && t.status.block_height != null
    ? tip.data - t.status.block_height + 1
    : 0;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div>
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Transaction</div>
        <h1 className="font-display text-2xl md:text-3xl mt-1 font-mono break-all">{shortHash(txid, 16, 16)}</h1>
        <div className="mt-1 font-mono text-xs text-muted-foreground break-all">{txid}</div>
        <div className="mt-2 flex flex-wrap gap-2 items-center">
          {t.status.confirmed ? (
            <span className="px-2 py-0.5 rounded-sm bg-success/20 text-success text-[11px] uppercase font-semibold">
              Confirmed · {formatNumber(confirmations)} conf
            </span>
          ) : (
            <span className="px-2 py-0.5 rounded-sm bg-warning/20 text-warning text-[11px] uppercase font-semibold animate-pulse-dot">
              In mempool
            </span>
          )}
          {t.status.confirmed && t.status.block_hash && (
            <Link
              to="/block/$hash"
              params={{ hash: t.status.block_hash }}
              className="text-xs text-accent hover:underline"
            >
              block #{formatNumber(t.status.block_height ?? 0)}
            </Link>
          )}
          <a
            href={upstreamTxUrl(txid)}
            target="_blank"
            rel="noreferrer"
            className="text-xs text-muted-foreground hover:text-foreground ml-auto"
          >
            view upstream ↗
          </a>
        </div>
      </div>

      <div className="grid md:grid-cols-3 lg:grid-cols-5 gap-3">
        <StatTile label="Fee" value={`${satsToTxc(t.fee)} TXC`} hint={`${fr.toFixed(2)} sat/vB`} />
        <StatTile label="Size" value={formatBytes(t.size)} hint={`vsize ${(t.weight / 4).toFixed(0)}`} />
        <StatTile label="Weight" value={`${formatNumber(t.weight)} wu`} />
        <StatTile
          label="Total out"
          value={`${satsToTxc(totalOut)} TXC`}
          hint={t.vin[0]?.is_coinbase ? "coinbase issuance" : `in ${satsToTxc(totalIn)}`}
        />
        <StatTile
          label="Time"
          value={t.status.block_time ? timeAgo(t.status.block_time) : "pending"}
          hint={t.status.block_time ? formatDateTime(t.status.block_time) : undefined}
        />
      </div>

      <TxFlow tx={t} />
    </div>
  );
}
