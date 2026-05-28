import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { QRCodeSVG } from "qrcode.react";
import { Copy, ExternalLink } from "lucide-react";
import { useState } from "react";
import { addressBalanceSats, esplora } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { TxListRow } from "@/components/explorer/TxListRow";
import { formatNumber, satsToTxc } from "@/lib/txc/format";
import { upstreamAddrUrl } from "@/lib/txc/network";

export const Route = createFileRoute("/address/$addr")({
  head: ({ params }) => ({
    meta: [
      { title: `Address ${params.addr.slice(0, 10)}… — TXC Mempool` },
      { name: "description", content: `TEXITcoin address ${params.addr}: balance, UTXOs, and transaction history.` },
      { property: "og:title", content: `TXC Address ${params.addr.slice(0, 10)}…` },
    ],
  }),
  component: AddressPage,
});

function AddressPage() {
  const { addr } = Route.useParams();
  const info = useQuery({ queryKey: ["mempool", "addr", addr], queryFn: () => esplora.address(addr) });
  const txs = useQuery({ queryKey: ["mempool", "addr-txs", addr], queryFn: () => esplora.addressTxs(addr) });
  const utxos = useQuery({ queryKey: ["mempool", "addr-utxos", addr], queryFn: () => esplora.addressUtxos(addr) });

  const [copied, setCopied] = useState(false);
  const bal = info.data ? addressBalanceSats(info.data) : null;

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      <div className="rounded-md surface border border-border p-5 flex flex-col md:flex-row gap-5">
        <div className="flex-shrink-0 bg-white p-2 rounded-md self-start">
          <QRCodeSVG value={addr} size={120} />
        </div>
        <div className="min-w-0 flex-1">
          <div className="text-[10px] uppercase tracking-widest text-muted-foreground">TEXITcoin address</div>
          <div className="mt-1 flex items-center gap-2 flex-wrap">
            <h1 className="font-mono text-base md:text-lg break-all">{addr}</h1>
            <button
              onClick={async () => { await navigator.clipboard.writeText(addr); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-sm bg-surface-2 border border-border text-xs hover:border-primary"
            >
              <Copy className="size-3" />
              {copied ? "Copied" : "Copy"}
            </button>
            <a
              href={upstreamAddrUrl(addr)}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-sm bg-surface-2 border border-border text-xs hover:border-primary"
            >
              <ExternalLink className="size-3" /> upstream
            </a>
          </div>

          {info.isLoading && <div className="mt-3 text-sm text-muted-foreground">Loading address…</div>}

          {info.data && bal && (
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mt-4">
              <StatTile label="Balance" value={`${satsToTxc(bal.total)} TXC`} hint={bal.unconfirmed !== 0 ? `${satsToTxc(bal.unconfirmed)} pending` : undefined} />
              <StatTile label="Confirmed" value={`${satsToTxc(bal.confirmed)} TXC`} />
              <StatTile label="Transactions" value={formatNumber(info.data.chain_stats.tx_count + info.data.mempool_stats.tx_count)} hint={`${formatNumber(info.data.mempool_stats.tx_count)} in mempool`} />
              <StatTile label="UTXOs" value={utxos.data ? formatNumber(utxos.data.length) : "—"} />
            </div>
          )}
        </div>
      </div>

      <div>
        <div className="flex items-center justify-between mb-2">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Transaction history
          </h2>
          <Link
            to="/address/$addr"
            params={{ addr }}
            className="text-[11px] text-muted-foreground"
          >
            most recent first
          </Link>
        </div>
        <div className="space-y-2">
          {txs.isLoading && <div className="text-sm text-muted-foreground">Loading transactions…</div>}
          {txs.data?.length === 0 && <div className="text-sm text-muted-foreground">No transactions yet.</div>}
          {txs.data?.map((t) => <TxListRow key={t.txid} tx={t} />)}
        </div>
      </div>
    </div>
  );
}
