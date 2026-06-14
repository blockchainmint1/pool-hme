import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { QRCodeSVG } from "qrcode.react";
import { Copy, ExternalLink } from "lucide-react";
import { useMemo, useState } from "react";
import { addressBalanceSats, esplora } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { TxListRow } from "@/components/explorer/TxListRow";
import { formatNumber, satsToTxc, timeAgo } from "@/lib/txc/format";
import { upstreamAddrUrl } from "@/lib/txc/network";
import { BalanceHistoryChart } from "@/components/address/BalanceHistoryChart";
import { UtxoBubbleChart } from "@/components/address/UtxoBubbleChart";
import { ActivityHeatmap } from "@/components/address/ActivityHeatmap";
import { CounterpartiesPanel } from "@/components/address/CounterpartiesPanel";
import { isOpReturn } from "@/lib/txc/omni";

type Filter = "all" | "received" | "sent" | "omni" | "coinbase";

export const Route = createFileRoute("/address/$addr")({
  head: ({ params }) => ({
    meta: [
      { title: `Address ${params.addr.slice(0, 10)}… — TXC Mempool` },
      { name: "description", content: `TEXITcoin address ${params.addr}: balance history, UTXOs, activity heatmap, counterparties, and full transaction history.` },
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
  const tip = useQuery({ queryKey: ["mempool", "tip-height"], queryFn: () => esplora.tipHeight(), refetchInterval: 30_000 });

  const [copied, setCopied] = useState(false);
  const [filter, setFilter] = useState<Filter>("all");
  const bal = info.data ? addressBalanceSats(info.data) : null;

  const addrType = useMemo(() => {
    if (addr.startsWith("T") && addr.length < 36) return "P2PKH";
    if (addr.startsWith("3")) return "P2SH";
    return "Unknown";
  }, [addr]);

  const filtered = useMemo(() => {
    const list = txs.data ?? [];
    if (filter === "all") return list;
    return list.filter((tx) => {
      const inFromMe = tx.vin.some((v) => v.prevout?.scriptpubkey_address === addr);
      const outToMe = tx.vout.some((v) => v.scriptpubkey_address === addr);
      switch (filter) {
        case "received": return outToMe && !inFromMe;
        case "sent": return inFromMe;
        case "coinbase": return !!tx.vin[0]?.is_coinbase;
        case "omni":
          return tx.vout.some((v) => isOpReturn(v) && /^6a[0-9a-f]{0,8}6f6d6e69/i.test(v.scriptpubkey));
        default: return true;
      }
    });
  }, [txs.data, filter, addr]);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* HEADER */}
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
            <span className="px-1.5 py-0.5 rounded-sm bg-accent/20 text-accent text-[10px] uppercase font-semibold">{addrType}</span>
            {info.data && info.data.mempool_stats.tx_count > 0 && (
              <span className="px-1.5 py-0.5 rounded-sm bg-warning/20 text-warning text-[10px] uppercase font-semibold animate-pulse-dot">
                {info.data.mempool_stats.tx_count} pending
              </span>
            )}
          </div>

          {info.isLoading && <div className="mt-3 text-sm text-muted-foreground">Loading address…</div>}

          {info.data && bal && (
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mt-4">
              <StatTile label="Balance" value={`${satsToTxc(bal.total)} TXC`} hint={bal.unconfirmed !== 0 ? `${satsToTxc(bal.unconfirmed)} pending` : undefined} />
              <StatTile label="Total received" value={`${satsToTxc(info.data.chain_stats.funded_txo_sum)} TXC`} />
              <StatTile label="Transactions" value={formatNumber(info.data.chain_stats.tx_count + info.data.mempool_stats.tx_count)} />
              <StatTile label="UTXOs" value={utxos.data ? formatNumber(utxos.data.length) : "—"} hint={txs.data?.length ? `last seen ${timeAgo(txs.data[0]?.status.block_time)}` : undefined} />
            </div>
          )}
        </div>
      </div>

      {/* BALANCE HISTORY */}
      {txs.data && txs.data.length > 0 && (
        <BalanceHistoryChart txs={txs.data} address={addr} />
      )}

      {/* UTXO BUBBLES + HEATMAP */}
      <div className="grid lg:grid-cols-2 gap-4">
        {utxos.data && <UtxoBubbleChart utxos={utxos.data} tipHeight={tip.data ?? undefined} />}
        {txs.data && <ActivityHeatmap txs={txs.data} />}
      </div>

      {/* COUNTERPARTIES */}
      {txs.data && txs.data.length > 0 && (
        <CounterpartiesPanel txs={txs.data} address={addr} />
      )}

      {/* TX LIST */}
      <div>
        <div className="flex items-center justify-between mb-2 gap-2 flex-wrap">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Transaction history
          </h2>
          <div className="inline-flex rounded-md border border-border surface-2 p-0.5 text-[11px]">
            {(["all", "received", "sent", "omni", "coinbase"] as Filter[]).map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                className={`px-2 py-0.5 rounded-sm capitalize ${filter === f ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"}`}
              >
                {f}
              </button>
            ))}
          </div>
        </div>
        <div className="space-y-2">
          {txs.isLoading && <div className="text-sm text-muted-foreground">Loading transactions…</div>}
          {filtered.length === 0 && !txs.isLoading && (
            <div className="text-sm text-muted-foreground">No transactions match this filter.</div>
          )}
          {filtered.map((t) => <TxListRow key={t.txid} tx={t} />)}
        </div>
        {txs.data && txs.data.length >= 25 && (
          <div className="mt-3 text-center text-[11px] text-muted-foreground">
            Showing most recent {txs.data.length} transactions · use <Link to="/docs" className="text-accent hover:underline">the API</Link> for full pagination.
          </div>
        )}
      </div>
    </div>
  );
}
