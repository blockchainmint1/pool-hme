import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import { queryOptions, useSuspenseQuery } from "@tanstack/react-query";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { ArrowLeft, Coins, Wallet, Users, Layers, ExternalLink } from "lucide-react";
import { COINBASE, explorerAddress } from "@/lib/pool/coinbase";
import { getCoinPageData } from "@/lib/pool/coin.functions";
import { CoinBlocksTable, CoinDot } from "./CoinBlocksTable";

export type CoinSymbol = "LTC" | "DOGE";

export function coinPageQuery(symbol: CoinSymbol) {
  return queryOptions({
    queryKey: ["pool", "coin", symbol],
    queryFn: () => getCoinPageData({ data: { symbol, limit: 500 } }),
    staleTime: 30_000,
    refetchInterval: 60_000,
  });
}

const COPY: Record<CoinSymbol, { name: string; blurb: string; explorer: (a: string) => string }> = {
  LTC: {
    name: "Litecoin",
    blurb:
      "Litecoin is the parent chain of the scrypt merge-mining stack. Every accepted share is submitted to LTC first; when one clears the Litecoin network target, the pool finds an LTC block.",
    explorer: (a) => `https://litecoinspace.org/address/${a}`,
  },
  DOGE: {
    name: "Dogecoin",
    blurb:
      "Dogecoin is merge-mined as an auxiliary chain alongside Litecoin. The same scrypt work is submitted as an auxpow proof, so DOGE blocks cost no extra hashrate.",
    explorer: (a) => `https://dogechain.info/address/${a}`,
  },
};

function fmt(n: number, digits = 4) {
  return n.toLocaleString(undefined, { maximumFractionDigits: digits });
}

function shortAddr(a: string) {
  return a.length > 22 ? `${a.slice(0, 10)}…${a.slice(-8)}` : a;
}

export function CoinPage({ symbol }: { symbol: CoinSymbol }) {
  const { data } = useSuspenseQuery(coinPageQuery(symbol));
  const copy = COPY[symbol];
  const report = data.report;
  const known = COINBASE[symbol];
  const coinbaseAddress = report?.coin.master_wallet ?? known.address;

  const daily = useMemo(() => {
    if (report?.daily?.length) {
      return report.daily.slice(-45).map((d) => ({
        label: new Date(d.day * 1000).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        }),
        blocks: d.blocks,
        amount: d.amount,
      }));
    }
    // Fall back to bucketing the block list when the pool API is older.
    const buckets = new Map<number, { blocks: number; amount: number }>();
    for (const b of data.blocks) {
      const day = Math.floor(b.time / 86400) * 86400;
      const cur = buckets.get(day) ?? { blocks: 0, amount: 0 };
      cur.blocks += 1;
      cur.amount += b.amount ?? 0;
      buckets.set(day, cur);
    }
    return [...buckets.entries()]
      .sort((a, b) => a[0] - b[0])
      .slice(-45)
      .map(([day, v]) => ({
        label: new Date(day * 1000).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        }),
        ...v,
      }));
  }, [report, data.blocks]);

  const totals = report?.totals ?? {
    blocks: data.blocks.length,
    total_amount: data.blocks.reduce((s, b) => s + (b.amount ?? 0), 0),
    confirmed: data.blocks.filter((b) => b.category === "generate").length,
    immature: data.blocks.filter((b) => b.category === "immature").length,
    orphan: data.blocks.filter((b) => b.category === "orphan").length,
    first_time: 0,
    last_time: data.blocks[0]?.time ?? 0,
  };

  return (
    <div className="font-pool-body pool-grid-bg -mt-[1px]">
      <div className="max-w-6xl mx-auto px-4 py-10 space-y-8">
        <div>
          <Link
            to="/"
            className="inline-flex items-center gap-1.5 text-[11px] font-mono text-pool-steel hover:text-pool-steel-hi transition-colors"
          >
            <ArrowLeft className="size-3.5" /> Pool dashboard
          </Link>
          <div className="mt-4 flex items-center gap-3">
            <CoinDot symbol={symbol} />
            <h1 className="text-2xl md:text-3xl font-semibold text-pool-steel-hi">
              {copy.name} blocks
            </h1>
          </div>
          <p className="mt-3 max-w-2xl text-sm text-pool-steel leading-relaxed">{copy.blurb}</p>
        </div>

        <section className="grid sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <Stat icon={Layers} label="Blocks recorded" value={totals.blocks.toLocaleString()} />
          <Stat
            icon={Coins}
            label="Total rewards"
            value={`${fmt(totals.total_amount, symbol === "DOGE" ? 0 : 4)} ${symbol}`}
          />
          <Stat
            icon={Layers}
            label="Confirmed / immature"
            value={`${totals.confirmed.toLocaleString()} / ${totals.immature.toLocaleString()}`}
          />
          <Stat
            icon={Users}
            label="Paid to miners"
            value={
              report
                ? `${fmt(report.payouts.total_paid, symbol === "DOGE" ? 0 : 4)} ${symbol}`
                : "—"
            }
            hint={report ? `${report.payouts.count.toLocaleString()} payouts` : undefined}
          />
        </section>

        <section className="space-y-3">
          <Header eyebrow="Where the coinbase goes" title="Reward destination." />
          <div className="pool-kpi-panel rounded-lg p-5 space-y-4">
            <div className="flex items-start gap-3">
              <Wallet className="size-4 text-pool-steel mt-0.5 shrink-0" />
              <div className="min-w-0 space-y-1">
                <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
                  Current coinbase address
                </div>
                <a
                  href={explorerAddress(symbol, coinbaseAddress)}
                  target="_blank"
                  rel="noreferrer"
                  className="block font-mono text-sm text-pool-steel-hi break-all hover:underline"
                >
                  {coinbaseAddress}
                  <ExternalLink className="inline size-3 ml-1.5 -mt-0.5 opacity-70" />
                </a>
                <div className="text-[11px] font-mono text-pool-steel">
                  live since {known.since} · view on{" "}
                  {symbol === "LTC" ? "litecoinspace.org" : "blockchair.com"}
                </div>
              </div>
            </div>

            {known.previous && (
              <div className="flex items-start gap-3 pt-3 border-t border-pool-hairline">
                <Wallet className="size-4 text-pool-steel mt-0.5 shrink-0 opacity-50" />
                <div className="min-w-0 space-y-1">
                  <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
                    Previous coinbase address
                  </div>
                  <a
                    href={explorerAddress(symbol, known.previous)}
                    target="_blank"
                    rel="noreferrer"
                    className="block font-mono text-sm text-pool-steel break-all hover:underline"
                  >
                    {known.previous}
                    <ExternalLink className="inline size-3 ml-1.5 -mt-0.5 opacity-70" />
                  </a>
                  <div className="text-[11px] font-mono text-pool-steel">
                    blocks found before {known.since} paid here
                  </div>
                </div>
              </div>
            )}

            <p className="text-sm text-pool-steel leading-relaxed">
              Block rewards are paid to the pool&apos;s {symbol} coinbase address, which then settles
              miner balances on the payout schedule. The wallet keeps only a working float;
              everything above outstanding miner liabilities is swept to cold storage the operator
              controls.
            </p>
          </div>
        </section>


        <section className="space-y-3">
          <Header
            eyebrow="Cadence"
            title="Blocks per day."
            hint={daily.length ? `last ${daily.length} days` : undefined}
          />
          <div className="pool-kpi-panel rounded-lg p-4 h-72">
            {daily.length === 0 ? (
              <div className="h-full grid place-items-center text-sm text-pool-steel">
                No block history yet.
              </div>
            ) : (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={daily} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="currentColor" opacity={0.12} />
                  <XAxis
                    dataKey="label"
                    tick={{ fontSize: 10 }}
                    stroke="currentColor"
                    opacity={0.6}
                    interval="preserveStartEnd"
                  />
                  <YAxis
                    tick={{ fontSize: 10 }}
                    stroke="currentColor"
                    opacity={0.6}
                    allowDecimals={false}
                    width={32}
                  />
                  <Tooltip
                    contentStyle={{
                      background: "hsl(var(--popover))",
                      border: "1px solid hsl(var(--border))",
                      borderRadius: 8,
                      fontSize: 12,
                    }}
                    formatter={(v: number, k) =>
                      k === "blocks" ? [v, "blocks"] : [fmt(v, 4), symbol]
                    }
                  />
                  <Bar dataKey="blocks" fill="currentColor" className="text-pool-amber" radius={[2, 2, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            )}
          </div>
        </section>

        <section className="space-y-3">
          <Header
            eyebrow="Ledger"
            title={`${symbol} blocks.`}
            hint="newest first · 10 per page"
          />
          <CoinBlocksTable
            blocks={data.blocks}
            symbol={symbol}
            nowSec={data.fetchedAt}
            pageSize={10}
            emptyLabel={`No ${symbol} blocks recorded yet.`}
          />
          <p className="text-[11px] font-mono text-pool-steel">
            Status reflects the pool database. A block marked orphan there can still be valid
            on-chain — the chain is the source of truth.
          </p>
        </section>

        {report && report.payouts.top.length > 0 && (
          <section className="space-y-3">
            <Header
              eyebrow="Distribution"
              title="Where the payouts went."
              hint="top 25 recipients, all time"
            />
            <div className="pool-kpi-panel rounded-lg overflow-hidden">
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
                      <th className="text-left px-5 py-3 font-normal">Miner</th>
                      <th className="text-right px-3 py-3 font-normal">Payouts</th>
                      <th className="text-right px-3 py-3 font-normal">Total</th>
                      <th className="text-right px-5 py-3 font-normal">Share</th>
                    </tr>
                  </thead>
                  <tbody className="font-mono">
                    {report.payouts.top.map((p) => {
                      const share =
                        report.payouts.total_paid > 0
                          ? (p.amount / report.payouts.total_paid) * 100
                          : 0;
                      return (
                        <tr
                          key={p.address}
                          className="border-b border-pool-hairline last:border-b-0 hover:pool-graphite-2 transition-colors"
                        >
                          <td className="px-5 py-3 text-pool-steel-hi">{shortAddr(p.address)}</td>
                          <td className="px-3 py-3 text-right text-pool-steel tabular-nums">
                            {p.payouts.toLocaleString()}
                          </td>
                          <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">
                            {fmt(p.amount, symbol === "DOGE" ? 0 : 4)}
                          </td>
                          <td className="px-5 py-3 text-right text-pool-steel tabular-nums">
                            {share.toFixed(1)}%
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          </section>
        )}

        {!report && (
          <p className="text-[11px] font-mono text-pool-steel">
            Totals and distribution need pool API v0.6.0 — showing what the block feed provides.
          </p>
        )}
      </div>
    </div>
  );
}

function Header({ eyebrow, title, hint }: { eyebrow: string; title: string; hint?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3 flex-wrap">
      <div>
        <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
          {eyebrow}
        </div>
        <h2 className="text-lg font-semibold text-pool-steel-hi">{title}</h2>
      </div>
      {hint && <div className="text-[11px] font-mono text-pool-steel">{hint}</div>}
    </div>
  );
}

function Stat({
  icon: Icon,
  label,
  value,
  hint,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="pool-kpi-panel rounded-lg p-4">
      <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
        <Icon className="size-3.5" />
        {label}
      </div>
      <div className="mt-2 text-lg font-mono text-pool-steel-hi tabular-nums break-all">
        {value}
      </div>
      {hint && <div className="text-[11px] font-mono text-pool-steel mt-1">{hint}</div>}
    </div>
  );
}
