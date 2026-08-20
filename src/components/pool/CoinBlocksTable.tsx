import { Link } from "@tanstack/react-router";
import { useState } from "react";
import { ArrowUpRight, ChevronLeft, ChevronRight } from "lucide-react";
import type { PoolBlock } from "@/lib/pool/pool.functions";

export function coinAgo(sec: number) {
  if (sec < 60) return `${sec}s ago`;
  if (sec < 3600) return `${Math.round(sec / 60)}m ago`;
  if (sec < 86400) return `${Math.round(sec / 3600)}h ago`;
  return `${Math.round(sec / 86400)}d ago`;
}

export function CoinDot({ symbol }: { symbol: string }) {
  const colorMap: Record<string, string> = {
    TXC: "bg-pool-amber",
    LTC: "bg-pool-steel",
    DOGE: "bg-pool-amber",
    ISK: "bg-pool-mint",
    ZCU: "bg-pool-mint",
  };
  return (
    <span
      className={`inline-flex size-6 rounded-full items-center justify-center text-[10px] font-mono font-semibold text-pool-obsidian ${
        colorMap[symbol] ?? "bg-pool-steel"
      }`}
    >
      {symbol.slice(0, 1)}
    </span>
  );
}

/**
 * Status reported by the pool database, not the chain.
 *
 * LTC/DOGE merge-mined rows can arrive with `amount: 0` and
 * `confirmations: null` when yiimp's confirmation pass could not read the
 * coinbase transaction back (multi-wallet RPC without -rpcwallet). Those rows
 * are labelled `orphan` with no reward even though the block is valid
 * on-chain, so we must not render that as a real "0 LTC" reward — we show
 * "not recorded" and flag the row as unverified rather than inventing a value.
 */
export function blockStatus(b: PoolBlock) {
  const amount = b.amount ?? 0;
  const confirmations = b.confirmations ?? 0;
  const unrecorded = !b.amount && b.confirmations == null;

  if (b.category === "orphan")
    return {
      label: unrecorded ? "unverified" : "orphan",
      color: "text-pool-steel",
      amount,
      unrecorded,
      title: unrecorded
        ? "The pool database could not read this block's coinbase, so it has no reward recorded. The block itself may still be valid on-chain."
        : "Recorded as orphan by the pool database.",
    };
  if (b.confirmations == null)
    return { label: "pending", color: "text-pool-steel", amount, unrecorded, title: "Awaiting confirmation data." };
  if (b.category === "immature" || confirmations < 100)
    return {
      label: `${confirmations} conf`,
      color: "text-pool-amber",
      amount,
      unrecorded: false,
      title: "Maturing — reward is not spendable yet.",
    };
  return { label: "confirmed", color: "text-pool-mint", amount, unrecorded: false, title: "Confirmed and mature." };
}


export function CoinBlocksTable({
  blocks,
  symbol,
  nowSec,
  pageSize = 10,
  detailsTo,
  emptyLabel = "No blocks recorded yet.",
}: {
  blocks: PoolBlock[];
  symbol: string;
  nowSec: number;
  pageSize?: number;
  detailsTo?: "/ltc" | "/doge";
  emptyLabel?: string;
}) {
  const [page, setPage] = useState(0);
  const pageCount = Math.max(1, Math.ceil(blocks.length / pageSize));
  const safePage = Math.min(page, pageCount - 1);
  const rows = blocks.slice(safePage * pageSize, safePage * pageSize + pageSize);

  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
              <th className="text-left px-5 py-3 font-normal">Coin</th>
              <th className="text-left px-3 py-3 font-normal">Height</th>
              <th className="text-left px-3 py-3 font-normal">Age</th>
              <th className="text-right px-3 py-3 font-normal">Reward</th>
              <th className="text-right px-5 py-3 font-normal">Status</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="px-5 py-6 text-center text-pool-steel">
                  {emptyLabel}
                </td>
              </tr>
            )}
            {rows.map((b) => {
              const s = blockStatus(b);
              return (
                <tr
                  key={`${b.symbol}-${b.height}-${(b.blockhash ?? "").slice(0, 8)}`}
                  className="border-b border-pool-hairline last:border-b-0 hover:pool-graphite-2 transition-colors"
                >
                  <td className="px-5 py-3">
                    <span className="inline-flex items-center gap-2">
                      <CoinDot symbol={b.symbol} />
                      <span className="text-pool-steel-hi">{b.symbol}</span>
                    </span>
                  </td>
                  <td className="px-3 py-3 text-pool-steel-hi tabular-nums">
                    {b.height.toLocaleString()}
                  </td>
                  <td className="px-3 py-3 text-pool-steel">
                    {coinAgo(Math.max(0, nowSec - b.time))}
                  </td>
                  <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">
                    {s.amount.toLocaleString(undefined, { maximumFractionDigits: 4 })}{" "}
                    <span className="text-pool-steel">{b.symbol}</span>
                  </td>
                  <td className={`px-5 py-3 text-right tabular-nums ${s.color}`}>{s.label}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="border-t border-pool-hairline px-5 py-3 flex items-center justify-between gap-3 flex-wrap">
        <div className="text-[11px] font-mono text-pool-steel">
          {blocks.length === 0
            ? "—"
            : `${safePage * pageSize + 1}–${safePage * pageSize + rows.length} of ${blocks.length.toLocaleString()}`}
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => setPage((p) => Math.max(0, p - 1))}
            disabled={safePage === 0}
            aria-label={`Previous page of ${symbol} blocks`}
            className="inline-flex items-center gap-1 rounded-md border border-pool-hairline px-2 py-1 text-[11px] font-mono text-pool-steel hover:text-pool-steel-hi disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            <ChevronLeft className="size-3.5" /> Prev
          </button>
          <span className="text-[11px] font-mono text-pool-steel tabular-nums">
            {safePage + 1}/{pageCount}
          </span>
          <button
            type="button"
            onClick={() => setPage((p) => Math.min(pageCount - 1, p + 1))}
            disabled={safePage >= pageCount - 1}
            aria-label={`Next page of ${symbol} blocks`}
            className="inline-flex items-center gap-1 rounded-md border border-pool-hairline px-2 py-1 text-[11px] font-mono text-pool-steel hover:text-pool-steel-hi disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            Next <ChevronRight className="size-3.5" />
          </button>
          {detailsTo && (
            <Link
              to={detailsTo}
              className="inline-flex items-center gap-1 rounded-md border border-pool-hairline px-2 py-1 text-[11px] font-mono text-pool-steel-hi hover:pool-graphite transition-colors"
            >
              All {symbol} data <ArrowUpRight className="size-3.5" />
            </Link>
          )}
        </div>
      </div>
    </div>
  );
}
