import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { QRCodeSVG } from "qrcode.react";
import { Copy } from "lucide-react";
import { useMemo, useState } from "react";
import { addressBalanceSats, esplora } from "@/lib/txc/esplora";
import { StatTile } from "@/components/explorer/StatTile";
import { UsdValue } from "@/components/explorer/UsdValue";
import { TxListRow } from "@/components/explorer/TxListRow";
import { formatNumber, satsToTxc, timeAgo } from "@/lib/txc/format";
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
  const utxos = useQuery({ queryKey: ["mempool", "addr-utxos", addr], queryFn: () => esplora.addressUtxos(addr) });
  const tip = useQuery({ queryKey: ["mempool", "tip-height"], queryFn: () => esplora.tipHeight(), refetchInterval: 30_000 });
  const indexerStatus = useQuery({
    queryKey: ["indexer", "status"],
    queryFn: () => esplora.indexerStatus(),
    refetchInterval: 15_000,
  });

  // Paginated tx history — esplora returns 25 confirmed + all mempool per page,
  // keyed by the last-seen txid. Some addresses (e.g. coinbase) have thousands.
  const [pages, setPages] = useState<import("@/lib/txc/esplora").Tx[][]>([]);
  const [loadingMore, setLoadingMore] = useState(false);
  const [exhausted, setExhausted] = useState(false);

  const firstPage = useQuery({
    queryKey: ["mempool", "addr-txs", addr],
    queryFn: async () => {
      const list = await esplora.addressTxs(addr);
      setPages([list]);
      setExhausted(list.length < 25);
      return list;
    },
  });

  const allTxs = useMemo(() => pages.flat(), [pages]);

  async function loadMore() {
    const last = allTxs[allTxs.length - 1];
    if (!last || loadingMore) return;
    setLoadingMore(true);
    try {
      const next = await esplora.addressTxs(addr, last.txid);
      setPages((p) => [...p, next]);
      if (next.length < 25) setExhausted(true);
    } finally {
      setLoadingMore(false);
    }
  }

  const [copied, setCopied] = useState(false);
  const [filter, setFilter] = useState<Filter>("all");
  const bal = info.data ? addressBalanceSats(info.data) : null;

  const addrType = useMemo(() => {
    if (/^txc1/i.test(addr)) return addr.length > 44 ? "P2WSH" : "P2WPKH";
    if (addr.startsWith("T") && addr.length < 36) return "P2PKH";
    if (addr.startsWith("3")) return "P2SH";
    return "Unknown";
  }, [addr]);

  const filtered = useMemo(() => {
    if (filter === "all") return allTxs;
    return allTxs.filter((tx) => {
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
  }, [allTxs, filter, addr]);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-6">
      {/* INDEXER SYNC STATUS */}
      {indexerStatus.data && tip.data && indexerStatus.data.indexed_tip < tip.data - 2 && (() => {
        const indexed = indexerStatus.data.indexed_tip;
        const node = tip.data;
        const pct = Math.min(100, Math.max(0, (indexed / node) * 100));
        const behind = node - indexed;
        return (
          <div className="rounded-md border border-warning/40 bg-warning/10 px-4 py-3 text-sm">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <div>
                <span className="font-semibold text-warning">Indexer catching up</span>
                <span className="ml-2 text-muted-foreground">
                  Block {formatNumber(indexed)} / {formatNumber(node)} ({pct.toFixed(1)}%) ·{" "}
                  {formatNumber(behind)} behind. Transactions in unindexed blocks aren't visible yet.
                </span>
              </div>
              <span className="text-[10px] uppercase tracking-widest text-muted-foreground">auto-refresh</span>
            </div>
            <div className="mt-2 h-1.5 w-full rounded-full bg-surface-2 overflow-hidden">
              <div className="h-full bg-warning transition-all" style={{ width: `${pct}%` }} />
            </div>
          </div>
        );
      })()}


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
              <StatTile label="Balance" value={`${satsToTxc(bal.total)} TXC`} hint={<><UsdValue sats={bal.total} />{bal.unconfirmed !== 0 ? <> · {satsToTxc(bal.unconfirmed)} pending</> : null}</>} />
              <StatTile label="Total received" value={`${satsToTxc(info.data.chain_stats.funded_txo_sum)} TXC`} hint={<UsdValue sats={info.data.chain_stats.funded_txo_sum} />} />
              <StatTile label="Transactions" value={formatNumber(info.data.chain_stats.tx_count + info.data.mempool_stats.tx_count)} />
              <StatTile label="UTXOs" value={utxos.data ? formatNumber(utxos.data.length) : "—"} hint={allTxs.length ? `last seen ${timeAgo(allTxs[0]?.status.block_time)}` : undefined} />
            </div>
          )}
        </div>
      </div>

      {/* BALANCE HISTORY */}
      {allTxs.length > 0 && (
        <BalanceHistoryChart txs={allTxs} address={addr} currentSats={bal?.total ?? 0} />
      )}

      {/* UTXO BUBBLES + HEATMAP */}
      <div className="grid lg:grid-cols-2 gap-4">
        {utxos.data && <UtxoBubbleChart utxos={utxos.data} tipHeight={tip.data ?? undefined} />}
        {allTxs.length > 0 && <ActivityHeatmap txs={allTxs} />}
      </div>

      {/* COUNTERPARTIES */}
      {allTxs.length > 0 && (
        <CounterpartiesPanel txs={allTxs} address={addr} />
      )}

      {/* TX LIST */}
      <div>
        <div className="flex items-center justify-between mb-2 gap-2 flex-wrap">
          <h2 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
            Transaction history
            {info.data && (
              <span className="ml-2 text-foreground font-mono normal-case tracking-normal">
                {formatNumber(allTxs.length)} loaded / {formatNumber(info.data.chain_stats.tx_count + info.data.mempool_stats.tx_count)} total
              </span>
            )}
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
          {firstPage.isLoading && <div className="text-sm text-muted-foreground">Loading transactions…</div>}
          {firstPage.isError && (
            <div className="text-sm text-destructive">
              Failed to load transactions: {(firstPage.error as Error)?.message}
            </div>
          )}
          {filtered.length === 0 && !firstPage.isLoading && !firstPage.isError && (
            <div className="text-sm text-muted-foreground">No transactions match this filter.</div>
          )}
          {filtered.map((t) => <TxListRow key={t.txid} tx={t} />)}
        </div>
        {allTxs.length > 0 && !exhausted && (
          <div className="mt-3 flex justify-center">
            <button
              onClick={loadMore}
              disabled={loadingMore}
              className="px-4 py-2 rounded-md border border-border surface-2 hover:border-primary text-xs font-medium disabled:opacity-50"
            >
              {loadingMore ? "Loading…" : "Load 25 more"}
            </button>
          </div>
        )}
        {exhausted && allTxs.length >= 25 && (
          <div className="mt-3 text-center text-[11px] text-muted-foreground">
            End of history · use <Link to="/docs" className="text-accent hover:underline">the API</Link> for programmatic access.
          </div>
        )}
      </div>
    </div>
  );
}
