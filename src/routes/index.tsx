import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { queryOptions, useQuery, useSuspenseQuery } from "@tanstack/react-query";
import {
  Activity,
  ArrowUpRight,
  Cpu,
  Gauge,
  Copy,
  Check,
  ChevronRight,
  Layers,
  ShieldCheck,
  Zap,
  CircuitBoard,
  Wallet,
  BookOpen,
  Radio,
} from "lucide-react";
import { getPoolSummary } from "@/lib/pool/pool.functions";
import { getCoinBlocks } from "@/lib/pool/coin.functions";
import { PoolHashrateChart } from "@/components/pool/PoolHashrateChart";
import { ResilienceBand } from "@/components/pool/ResilienceBand";
import { CoinBlocksTable, CoinDot } from "@/components/pool/CoinBlocksTable";

// ---------------------------------------------------------------------------
// Recent blocks — one combined table with per-chain visibility toggles. All
// five ledgers load together and share one stable set of columns; toggles only
// filter rows, so the table layout never changes between selections.
// ---------------------------------------------------------------------------
const CHAIN_FILTERS = ["TXC", "ISK", "LTC", "DOGE", "ZCU"] as const;
type ChainFilter = (typeof CHAIN_FILTERS)[number];

const chainBlocksQuery = (symbol: ChainFilter) =>
  queryOptions({
    queryKey: ["pool", "chain-blocks", symbol],
    queryFn: () => getCoinBlocks({ data: { symbol, limit: 200 } }),
    staleTime: 30_000,
    refetchInterval: 60_000,
  });

function ChainBlocksPanel() {
  const [visibleChains, setVisibleChains] = useState<Set<ChainFilter>>(
    () => new Set(CHAIN_FILTERS),
  );

  const txcQuery = useQuery(chainBlocksQuery("TXC"));
  const iskQuery = useQuery(chainBlocksQuery("ISK"));
  const ltcQuery = useQuery(chainBlocksQuery("LTC"));
  const dogeQuery = useQuery(chainBlocksQuery("DOGE"));
  const zcuQuery = useQuery(chainBlocksQuery("ZCU"));
  const queries = [txcQuery, iskQuery, ltcQuery, dogeQuery, zcuQuery];

  const isInitialLoading = queries.some((query) => query.isLoading && !query.data);
  const nowSec = Math.max(
    ...queries.map((query) => query.data?.fetchedAt ?? 0),
    Math.floor(Date.now() / 1000),
  );
  const blocks = queries
    .flatMap((query) => query.data?.blocks ?? [])
    .filter((block) => visibleChains.has(block.symbol as ChainFilter))
    .sort((a, b) => b.time - a.time || b.height - a.height);
  const visibleKey = CHAIN_FILTERS.filter((symbol) => visibleChains.has(symbol)).join("-") || "none";

  const toggleChain = (symbol: ChainFilter) => {
    setVisibleChains((current) => {
      const next = new Set(current);
      if (next.has(symbol)) next.delete(symbol);
      else next.add(symbol);
      return next;
    });
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-1.5 font-mono">
        <span className="mr-1 text-[10px] uppercase tracking-widest text-pool-steel">
          Show
        </span>
        {CHAIN_FILTERS.map((sym) => {
          const selected = visibleChains.has(sym);
          return (
            <button
              key={sym}
              type="button"
              aria-pressed={selected}
              title={`${selected ? "Hide" : "Show"} ${sym} blocks`}
              onClick={() => toggleChain(sym)}
              className={`inline-flex items-center gap-2 rounded-md border px-3 py-1.5 text-[11px] tracking-widest transition-all ${
                selected
                  ? "border-pool-mint/50 bg-pool-mint/10 text-pool-steel-hi"
                  : "border-pool-hairline text-pool-steel opacity-55 hover:opacity-100 hover:text-pool-steel-hi"
              }`}
            >
              <CoinDot symbol={sym} />
              {sym}
            </button>
          );
        })}
        <button
          type="button"
          onClick={() => setVisibleChains(new Set(CHAIN_FILTERS))}
          disabled={visibleChains.size === CHAIN_FILTERS.length}
          className="ml-1 rounded-md border border-pool-hairline px-2.5 py-1.5 text-[10px] uppercase tracking-widest text-pool-steel hover:text-pool-steel-hi disabled:opacity-35 disabled:cursor-not-allowed transition-colors"
        >
          All
        </button>
      </div>

      {isInitialLoading ? (
        <div className="pool-kpi-panel rounded-lg p-6 text-sm text-pool-steel font-mono">
          Loading recent blocks…
        </div>
      ) : (
        <CoinBlocksTable
          key={visibleKey}
          blocks={blocks}
          symbol="selected"
          nowSec={nowSec}
          pageSize={10}
          emptyLabel={
            visibleChains.size === 0
              ? "All chains are hidden. Toggle a chain back on to see blocks."
              : "No blocks recorded for the selected chains yet."
          }
        />
      )}

      <p className="text-[11px] font-mono text-pool-steel">
        LTC is the parent chain; DOGE / ISK / TXC / ZCU are merge-mined via auxpow on the
        same shares.{" "}
        <Link to="/ltc" className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint">
          LTC
        </Link>{" "}
        and{" "}
        <Link to="/doge" className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint">
          DOGE
        </Link>{" "}
        also have full coin pages with charts and payout history.
      </p>
    </div>
  );
}


const poolSummaryQuery = queryOptions({
  queryKey: ["pool", "summary"],
  queryFn: () => getPoolSummary(),
  staleTime: 20_000,
  refetchInterval: 30_000,
});

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "TEXITcoin Pool — Sound-money mining, made simple" },
      {
        name: "description",
        content:
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, LTC payouts daily and DOGE payouts hourly over threshold. Part of the honest.money ecosystem.",
      },
      { property: "og:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      {
        property: "og:description",
        content:
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, LTC payouts daily and DOGE payouts hourly over threshold. Part of the honest.money ecosystem.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      {
        name: "twitter:description",
        content:
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, LTC payouts daily and DOGE payouts hourly over threshold. Part of the honest.money ecosystem.",
      },
    ],
  }),
  loader: ({ context }) => context.queryClient.ensureQueryData(poolSummaryQuery),
  component: PoolHome,
});

// ---------------------------------------------------------------------------
// Static pool metadata. Numeric fields (hashrate, miners, hashrate history)
// come from getPoolSummary + getPoolHashrate; only presentation-level
// constants live here.
// ---------------------------------------------------------------------------

const POOL = {
  fee: 0, // percent
  region: "US · Texas",
  stratum: "stratum+tcp://stratum.pool.honest.money:3433",
  algos: [
    { symbol: "LTC",  name: "Litecoin",     port: 3433, note: "dedicated port for LTC" },
    { symbol: "DOGE", name: "Dogecoin",     port: null, note: "merged-mined via LTC" },
    { symbol: "ISK",  name: "Iskander",     port: null, note: "merged-mined via LTC" },
    { symbol: "TXC",  name: "TEXITcoin",    port: null, note: "merged-mined via LTC" },
    { symbol: "ZCU",  name: "Zero Chill U", port: null, note: "merged-mined via LTC" },
  ] as const,
};

function formatThs(n: number) {
  if (!Number.isFinite(n) || n <= 0) return "—";
  if (n >= 1000) return `${(n / 1000).toFixed(2)} PH/s`;
  if (n >= 1) return `${n.toFixed(2)} TH/s`;
  return `${(n * 1000).toFixed(1)} GH/s`;
}
function ago(sec: number) {
  if (sec < 60) return `${sec}s ago`;
  if (sec < 3600) return `${Math.round(sec / 60)}m ago`;
  return `${Math.round(sec / 3600)}h ago`;
}

// ---------------------------------------------------------------------------

function PoolHome() {
  return (
    <div className="font-pool-body pool-grid-bg -mt-[1px]">

      <div className="max-w-7xl mx-auto px-4 py-8 grid grid-cols-12 gap-6">
        {/* Left rail nav — dashboard shell */}
        <aside className="hidden lg:block col-span-3 xl:col-span-2 space-y-1 sticky top-20 self-start">
          <RailLink href="#overview"  icon={Gauge}         label="Overview" active />
          <RailLink href="#algos"     icon={CircuitBoard}  label="Algos" />
          <RailLink href="#stats"     icon={Activity}      label="Pool stats" />
          <RailLink href="#graphs"    icon={Activity}      label="Graphs" />
          <RailLink href="#connect"   icon={Radio}         label="Connect" />
          <RailLink href="#workers"   icon={Cpu}           label="Workers" />
          <RailLink href="#blocks"    icon={Layers}        label="Found blocks" />
          <RailLink href="#payouts"   icon={Wallet}        label="Payouts" />

          <RailLink href="#learn"     icon={BookOpen}      label="Learn" />
          <RailLink href="#resilience" icon={ShieldCheck}  label="Failover" />
          <Link
            to="/ltc"
            className="flex items-center gap-2 px-3 py-2 rounded-md text-sm text-pool-steel hover:text-pool-steel-hi hover:pool-graphite border border-transparent"
          >
            <Layers className="size-4" />
            <span>LTC blocks</span>
          </Link>
          <Link
            to="/doge"
            className="flex items-center gap-2 px-3 py-2 rounded-md text-sm text-pool-steel hover:text-pool-steel-hi hover:pool-graphite border border-transparent"
          >
            <Layers className="size-4" />
            <span>DOGE blocks</span>
          </Link>
          <Link
            to="/diagnostics"
            className="flex items-center gap-2 px-3 py-2 rounded-md text-sm text-pool-steel hover:text-pool-steel-hi hover:pool-graphite border border-transparent"
          >
            <Activity className="size-4" />
            <span>Diagnostics</span>
          </Link>
          <div className="mt-6 pool-tick rounded-md p-3">
            <div className="text-[10px] uppercase tracking-widest text-pool-steel">Status</div>
            <div className="mt-1 flex items-center gap-2 text-xs font-mono">
              <span className="size-2 rounded-full bg-pool-mint animate-pulse-dot" />
              <span className="text-pool-steel-hi">Pool online</span>
            </div>
            <div className="mt-3 text-[10px] uppercase tracking-widest text-pool-steel">Region</div>
            <div className="mt-1 text-xs font-mono text-pool-steel-hi">{POOL.region}</div>
          </div>
        </aside>

        <div className="col-span-12 lg:col-span-9 xl:col-span-10 space-y-10">
          <PoolHero />

          <section id="algos" className="space-y-3">
            <SectionHeader
              eyebrow="Merged mining"
              title="One hash, five chains."
              hint="scrypt · one connection, five rewards"
            />
            <AlgoTable />
          </section>

          <section id="stats" className="space-y-3">
            <SectionHeader
              eyebrow="Pool activity"
              title="Coins mined by the pool."
              hint="rolling windows · scrypt"
            />
            <PoolStatsTable />
          </section>
          <section id="graphs" className="space-y-3">
            <SectionHeader
              eyebrow="Time-series"
              title="Hashrate over time."
              hint="scrypt · from hashstats"
            />
            <PoolHashrateChart />
          </section>

          <section id="connect" className="grid lg:grid-cols-5 gap-6">
            <div className="lg:col-span-3 space-y-3">
              <SectionHeader
                eyebrow="Point a rig"
                title="Connect in ~30 seconds."
                hint="LTC wallet + DOGE payout link"
              />
              <ConnectCard />
            </div>
            <div className="lg:col-span-2 space-y-3">
              <SectionHeader eyebrow="Fair share" title="Payouts." hint="once a day, 06:15 UTC" />
              <PayoutCard />
            </div>
          </section>

          <section id="workers" className="space-y-3">
            <SectionHeader
              eyebrow="Connected miners"
              title="Workers by version."
              hint="scrypt · live from stratum"
            />
            <WorkersTable />
          </section>

          <section id="blocks" className="space-y-3">
            <SectionHeader
              eyebrow="Found by the pool"
              title="Recent blocks."
              hint="all five chains · newest first"
            />
            <ChainBlocksPanel />
          </section>



          <section id="resilience" className="space-y-3">
            <SectionHeader
              eyebrow="Failover strategy"
              title="The pool heals itself."
              hint="watchdog · alerts · auto-rented hashpower"
            />
            <ResilienceBand />
          </section>

          <section id="learn" className="space-y-3">
            <SectionHeader
              eyebrow="Learn & build"
              title="TEXITcoin, from first principles."
              hint="chain spec · Omni L2 · APIs"
            />
            <LearnBand />
          </section>
        </div>

      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Rail link
// ---------------------------------------------------------------------------
function RailLink({
  href,
  icon: Icon,
  label,
  active,
}: {
  href: string;
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  active?: boolean;
}) {
  return (
    <a
      href={href}
      className={`flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-colors border ${
        active
          ? "pool-tick text-pool-steel-hi border-pool-hairline"
          : "text-pool-steel border-transparent hover:text-pool-steel-hi hover:pool-graphite"
      }`}
    >
      <Icon className="size-4" />
      <span>{label}</span>
    </a>
  );
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------
function SectionHeader({
  eyebrow,
  title,
  hint,
}: {
  eyebrow: string;
  title: string;
  hint?: string;
}) {
  return (
    <div className="flex items-baseline justify-between gap-3 flex-wrap">
      <div>
        <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
          {eyebrow}
        </div>
        <h2 className="font-pool-display text-2xl md:text-3xl text-pool-steel-hi mt-1">
          {title}
        </h2>
      </div>
      {hint && (
        <div className="text-[11px] font-mono uppercase tracking-widest text-pool-steel">
          {hint}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Hero — big live hashrate + KPI band
// ---------------------------------------------------------------------------
function PoolHero() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  // Real pool hashrate in TH/s from hashstats via the API (v0.3+).
  const ths = data.liveHashrateGhs / 1000;

  return (
    <section id="overview" className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="relative p-6 md:p-10 pool-scanline">
        <div className="flex items-center gap-2 text-[11px] font-mono uppercase tracking-[0.2em] text-pool-steel">
          <span className="size-1.5 rounded-full bg-pool-mint animate-pulse-dot" />
          Live · TXC–ISK merged pool
          <span className="mx-2 text-pool-hairline">·</span>
          scrypt
          <span className="mx-2 text-pool-hairline">·</span>
          fee <span className="text-pool-steel-hi">0%</span>
        </div>

        <h1 className="mt-3 font-pool-display text-4xl md:text-6xl leading-[1.02] text-pool-steel-hi max-w-3xl text-balance">
          Mine sound money.<br />
          <span className="text-pool-steel">One connection.</span>{" "}
          <span className="text-pool-mint pool-hash-live"></span>
        </h1>
        <p className="mt-4 text-sm md:text-base text-pool-steel max-w-2xl leading-relaxed">
          The TEXITcoin pool merges LTC, DOGE, ISK, TXC and ZCU into a single scrypt work
          unit. Point one worker, get paid on the two coins that pay — while TXC and its
          siblings secure themselves for free.
        </p>

        {/* Big live hashrate */}
        <div className="mt-8 grid md:grid-cols-5 gap-4">
          <div className="md:col-span-2 pool-tick rounded-md p-5">
            <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
              Network hashrate · pool
            </div>
            <div className="mt-2 flex items-baseline gap-2">
              <span className="font-pool-display font-semibold text-5xl md:text-6xl text-pool-steel-hi pool-hash-live tabular-nums">
                {ths > 0 ? ths.toFixed(2) : "—"}
              </span>
              <span className="font-mono text-pool-steel text-sm">TH/s</span>
            </div>
            <div className="mt-2 text-[11px] font-mono text-pool-steel">
              rolling · scrypt · live from hashstats
            </div>
          </div>

          <LiveMinersKpi />
          <Kpi label="Pool fee" value="0%" hint="no take · ever" />
          <Kpi
            label="Payouts"
            value="LTC daily · DOGE hourly"
            hint="over threshold · batched"
          />
        </div>

        {/* Blocks found — the headline dataset, full width */}
        <BlocksFoundPanel />

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a
            href="#connect"
            className="inline-flex items-center gap-2 rounded-md bg-pool-mint text-pool-obsidian px-4 py-2.5 text-sm font-semibold hover:opacity-90 transition"
          >
            Connect a miner <ArrowUpRight className="size-4" />
          </a>
          <Link
            to="/register"
            className="inline-flex items-center gap-2 rounded-md border border-pool-hairline pool-tick text-pool-steel-hi px-4 py-2.5 text-sm font-medium hover:pool-graphite-2 transition"
          >
            Register LTC/DOGE <ChevronRight className="size-4" />
          </Link>
          <span className="text-[11px] font-mono text-pool-steel ml-auto">
            <ShieldCheck className="inline size-3.5 -mt-0.5 mr-1 text-pool-mint" />
            self-hosted · no custody · no logs
          </span>
        </div>
      </div>
    </section>
  );
}

function Kpi({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="pool-tick rounded-md p-5">
      <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
        {label}
      </div>
      <div className="mt-2 font-pool-display font-semibold text-3xl text-pool-steel-hi tabular-nums">
        {value}
      </div>
      {hint && <div className="mt-1 text-[11px] font-mono text-pool-steel">{hint}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Algo table — the "Pool Status" analog
// ---------------------------------------------------------------------------
function AlgoTable() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  // All 5 coins share the scrypt algo (merged mining). Pull the scrypt
  // aggregate once; every row displays the same live values.
  const scrypt = data.algos.find((x) => x.algo === "scrypt");
  // Prefer connected count (stratum diag TCP sessions = full fleet). The
  // 10-min share-active count undercounts miners that haven't hit their diff
  // recently, and confuses operators used to the old dashboard's "Miners" col.
  const miners = scrypt?.live_clients || data.activeMiners || 0;
  const ths = (scrypt?.hashrate_hs ?? data.liveHashrateGhs * 1e9) / 1e12;
  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
              <th className="text-left px-5 py-3 font-normal">Coin</th>
              <th className="text-left px-3 py-3 font-normal">Symbol</th>
              <th className="text-left px-3 py-3 font-normal">Port</th>
              <th className="text-left px-3 py-3 font-normal">Miners</th>
              <th className="text-left px-3 py-3 font-normal">Hashrate</th>
              <th className="text-left px-3 py-3 font-normal">Fee</th>
              <th className="text-left px-3 py-3 font-normal">Merged via</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {POOL.algos.map((a, i) => (
              <tr
                key={a.symbol}
                className={`border-b border-pool-hairline last:border-b-0 ${
                  i % 2 === 1 ? "pool-graphite/40" : ""
                } hover:pool-graphite-2 transition-colors`}
              >
                <td className="px-5 py-3 text-pool-steel-hi">{a.name}</td>
                <td className="px-3 py-3 text-pool-steel">{a.symbol}</td>
                <td className="px-3 py-3">
                  {a.port ? (
                    <span className="text-pool-mint">{a.port}</span>
                  ) : (
                    <span className="text-pool-steel">—</span>
                  )}
                </td>
                <td className="px-3 py-3 text-pool-steel-hi tabular-nums">
                  {miners > 0 ? miners.toLocaleString() : "—"}
                </td>
                <td className="px-3 py-3 text-pool-steel-hi tabular-nums">
                  {formatThs(ths)}
                </td>
                <td className="px-3 py-3 text-pool-steel-hi">{POOL.fee}%</td>
                <td className="px-3 py-3 text-pool-steel">{a.note}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-pool-hairline px-5 py-3 text-[11px] font-mono text-pool-steel">
        Payouts are settled on LTC + DOGE. TXC / ISK / ZCU are mined for chain security and
        distributed under their own economics — see the{" "}
        <Link to="/manifesto" className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint">
          manifesto
        </Link>
        .
      </div>
    </div>
  );
}


// ---------------------------------------------------------------------------
// Pool stats table — coins × time-windows
// ---------------------------------------------------------------------------
function PoolStatsTable() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  const now = data.fetchedAt;

  // 24h counts come from the API's DB-side aggregate. The `blocks` list is a
  // truncated recent window (20 rows), so counting it per-window silently
  // capped every coin at the same number — use it only for names/last-found.
  const nameBySymbol: Record<string, string> = {};
  for (const b of data.blocks) nameBySymbol[b.symbol] ??= b.name;

  const list = Object.entries(data.blocks24hBySymbol)
    .map(([symbol, count]) => ({
      symbol,
      name: nameBySymbol[symbol] ?? symbol,
      h24: Number(count) || 0,
      last: data.lastFoundBySymbol[symbol] ?? 0,
    }))
    .sort((a, b) => b.h24 - a.h24);

  const interval = (n: number) => {
    if (!n) return "—";
    const secs = Math.round(86_400 / n);
    if (secs < 90) return `${secs}s`;
    if (secs < 5400) return `${Math.round(secs / 60)}m`;
    return `${(secs / 3600).toFixed(1)}h`;
  };

  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
              <th className="text-left px-5 py-3 font-normal">Coin</th>
              <th className="text-left px-3 py-3 font-normal">Symbol</th>
              <th className="text-right px-3 py-3 font-normal">Blocks 24 h</th>
              <th className="text-right px-3 py-3 font-normal">Avg interval</th>
              <th className="text-right px-5 py-3 font-normal">Last found</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {list.length === 0 && (
              <tr>
                <td colSpan={5} className="px-5 py-6 text-center text-pool-steel">
                  No pool-found blocks yet in the current window.
                </td>
              </tr>
            )}
            {list.map((r) => (
              <tr
                key={r.symbol}
                className="border-b border-pool-hairline last:border-b-0 hover:pool-graphite-2 transition-colors"
              >
                <td className="px-5 py-3 text-pool-steel-hi">{r.name}</td>
                <td className="px-3 py-3 text-pool-steel">{r.symbol}</td>
                <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">{r.h24}</td>
                <td className="px-3 py-3 text-right text-pool-steel tabular-nums">
                  {interval(r.h24)}
                </td>
                <td className="px-5 py-3 text-right text-pool-steel tabular-nums">
                  {r.last ? ago(Math.max(0, now - r.last)) : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-pool-hairline px-5 py-3 text-[11px] font-mono text-pool-steel">
        Counts are 24 h totals from the pool database. TXC · ISK · ZCU are solo-found here;
        LTC / DOGE are credited via auxpow and land far less often.
      </div>
    </div>
  );
}


// ---------------------------------------------------------------------------
// Connect card — copy-able stratum config
// ---------------------------------------------------------------------------
function ConnectCard() {
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const copy = async (key: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedKey(key);
      setTimeout(() => setCopiedKey((k) => (k === key ? null : k)), 1400);
    } catch {
      /* clipboard unavailable */
    }
  };

  const cmd = `-o ${POOL.stratum} -u <LTC_WALLET_ADDRESS> -p dogelink=<MINER_PASSWORD_TOKEN>`;

  return (
    <div className="pool-kpi-panel rounded-lg p-5 space-y-5">
      <div className="space-y-1">
        <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
          Stratum connection · LTC/DOGE merged mining
        </div>
        <div className="text-pool-steel-hi text-sm">Paste this into your miner:</div>
      </div>

      <CodeCopy
        id="cmd"
        value={cmd}
        copied={copiedKey === "cmd"}
        onCopy={() => copy("cmd", cmd)}
      />

      <ol className="space-y-2 text-sm text-pool-steel">
        <li className="flex gap-3">
          <span className="font-mono text-pool-steel-hi">1.</span>
          <span>
            <Link
              to="/register"
              className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            >
              Register LTC/DOGE
            </Link>{" "}
            before mining. You'll receive a{" "}
            <span className="font-mono text-pool-steel-hi">dogelink</span> token.
          </span>
        </li>
        <li className="flex gap-3">
          <span className="font-mono text-pool-steel-hi">2.</span>
          <span>
            Use your <span className="text-pool-steel-hi">LTC wallet address only</span> as
            the stratum username — never your DOGE address.
          </span>
        </li>
        <li className="flex gap-3">
          <span className="font-mono text-pool-steel-hi">3.</span>
          <span>
            Pass the <span className="font-mono">dogelink=…</span> token as the stratum
            password.
          </span>
        </li>
      </ol>

      <div className="rounded-md border border-pool-hairline pool-graphite p-3 text-[12px] font-mono text-pool-steel">
        Stratum lives at{" "}
        <span className="text-pool-steel-hi">{POOL.stratum}</span>. Port 3433, scrypt only,
        with LTC/DOGE/ISK/TXC/ZCU merge-mined on every share.
      </div>
    </div>
  );
}

function CodeCopy({
  value,
  copied,
  onCopy,
}: {
  id: string;
  value: string;
  copied: boolean;
  onCopy: () => void;
}) {
  return (
    <div className="relative rounded-md border border-pool-hairline pool-obsidian">
      <pre className="overflow-x-auto px-4 py-3 pr-14 text-[12px] leading-relaxed font-mono text-pool-steel-hi whitespace-pre">
        {value}
      </pre>
      <button
        onClick={onCopy}
        aria-label="Copy"
        className="absolute top-2 right-2 inline-flex items-center gap-1.5 rounded-sm border border-pool-hairline pool-tick px-2 py-1 text-[11px] font-mono text-pool-steel hover:text-pool-steel-hi transition"
      >
        {copied ? <Check className="size-3.5 text-pool-mint" /> : <Copy className="size-3.5" />}
        {copied ? "copied" : "copy"}
      </button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Payout card + countdown
// ---------------------------------------------------------------------------
function PayoutCard() {
  const [remainingSec, setRemainingSec] = useState(0);
  useEffect(() => {
    const tick = () =>
      setRemainingSec(Math.max(0, nextDailyPayoutEpoch() - Math.floor(Date.now() / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);

  const hh = String(Math.floor(remainingSec / 3600)).padStart(2, "0");
  const mm = String(Math.floor((remainingSec % 3600) / 60)).padStart(2, "0");
  const ss = String(remainingSec % 60).padStart(2, "0");

  return (
    <div id="payouts" className="pool-kpi-panel rounded-lg p-5 space-y-4">
      <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
        Next payout
      </div>
      <div className="font-pool-display font-semibold text-5xl text-pool-steel-hi tabular-nums pool-hash-live">
        {hh}
        <span className="text-pool-steel">:</span>
        {mm}
        <span className="text-pool-steel">:</span>
        {ss}
      </div>
      <ul className="space-y-2 text-sm text-pool-steel">
        <li className="flex items-center justify-between border-b border-pool-hairline pb-2">
          <span>LTC</span>
          <span className="text-pool-steel-hi font-mono">daily · 06:15 UTC · ≥ 0.01</span>
        </li>
        <li className="flex items-center justify-between border-b border-pool-hairline pb-2">
          <span>DOGE</span>
          <span className="text-pool-steel-hi font-mono">hourly cycle · ≥ 200</span>
        </li>
        <li className="flex items-center justify-between">
          <span>Payout coins</span>
          <span className="text-pool-steel-hi font-mono">LTC · DOGE</span>
        </li>
      </ul>
      <div className="text-[11px] font-mono text-pool-steel leading-relaxed">
        LTC pays out once a day in one batched send; the countdown above is to the next
        LTC batch. DOGE pays every hour your balance clears 200 DOGE — that's why payouts
        land several times a day. Balances below threshold roll into the next cycle.
        TXC / ISK / ZCU are mined for chain security and are not part of the pool payout —
        by design, so the pool never becomes a distribution bottleneck for TEXITcoin itself.
      </div>
    </div>
  );
}

function nextDailyPayoutEpoch() {
  const now = new Date();
  const then = new Date(now);
  then.setUTCHours(6, 15, 0, 0);
  if (then.getTime() <= now.getTime()) then.setUTCDate(then.getUTCDate() + 1);
  return Math.floor(then.getTime() / 1000);
}

// ---------------------------------------------------------------------------
// Found blocks
// ---------------------------------------------------------------------------
type BlocksWindow = "24h" | "7d" | "30d";
const BLOCKS_WINDOWS: { id: BlocksWindow; label: string }[] = [
  { id: "24h", label: "24H" },
  { id: "7d", label: "7D" },
  { id: "30d", label: "30D" },
];

function BlocksFoundPanel() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  const [window_, setWindow] = useState<BlocksWindow>("24h");
  // 5 chains. LTC/DOGE come in as auxpow credit — not solo-found —
  // so their tiles will normally read lower. That's intentional (see manifesto).
  const chains = ["LTC", "DOGE", "TXC", "ISK", "ZCU"] as const;
  const counts =
    window_ === "7d"
      ? data.blocks7dBySymbol
      : window_ === "30d"
        ? data.blocks30dBySymbol
        : data.blocks24hBySymbol;
  const windowLabel = window_ === "24h" ? "24 hours" : window_ === "7d" ? "7 days" : "30 days";
  return (
    <div className="mt-4 pool-tick rounded-md p-5 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
            Blocks found · last {windowLabel}
          </div>
          <div className="mt-1 text-[11px] font-mono text-pool-steel">
            TXC · ISK · ZCU pool-found · LTC / DOGE via auxpow credit
            {counts == null && (
              <> · 7d/30d available after the pool API update is installed on the box</>
            )}
          </div>
        </div>
        <div
          role="tablist"
          aria-label="Block count window"
          className="grid grid-cols-3 rounded border border-pool-hairline overflow-hidden font-mono"
        >
          {BLOCKS_WINDOWS.map((w) => (
            <button
              key={w.id}
              role="tab"
              aria-selected={window_ === w.id}
              onClick={() => setWindow(w.id)}
              className={`px-4 py-1.5 text-[11px] tracking-widest transition-colors ${
                window_ === w.id
                  ? "bg-pool-mint/15 text-pool-mint"
                  : "text-pool-steel hover:text-pool-steel-hi"
              }`}
            >
              {w.label}
            </button>
          ))}
        </div>
      </div>
      <div className="mt-5 grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 gap-3">
        {chains.map((sym) => (
          <div
            key={sym}
            className="rounded-md border border-pool-hairline pool-graphite/40 px-4 py-4"
          >
            <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
              {sym}
            </div>
            <div className="mt-1 font-pool-display font-semibold text-4xl md:text-5xl tabular-nums text-pool-steel-hi">
              {counts == null ? "—" : (counts?.[sym] ?? 0).toLocaleString()}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function LiveMinersKpi() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  const scrypt = data.algos.find((x) => x.algo === "scrypt");
  // Connected = full fleet (stratum TCP sessions). Hashing = shares submitted
  // in last 10 min. Show both — the gap is a diagnostic signal on its own.
  const connected = scrypt?.live_clients || 0;
  const hashing = data.activeMiners || 0;
  const value = connected > 0 ? connected.toLocaleString() : "—";
  const hint =
    hashing > 0 && connected > 0
      ? `${hashing.toLocaleString()} hashing · last 10 min`
      : "connected · stratum sessions";
  return <Kpi label="Active miners" value={value} hint={hint} />;
}

// ---------------------------------------------------------------------------
// Workers table — miner-version breakdown, modeled on pool.txc
// ---------------------------------------------------------------------------
function WorkersTable() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  const scrypt = data.algos.find((x) => x.algo === "scrypt");
  const totalCount = scrypt?.live_clients || data.activeMiners || 0;
  const totalThs = (scrypt?.hashrate_hs ?? data.liveHashrateGhs * 1e9) / 1e12;
  const avgGhs = totalCount > 0 ? (totalThs * 1000) / totalCount : 0;

  const fmtHash = (ths: number) => {
    if (!Number.isFinite(ths) || ths <= 0) return "—";
    if (ths >= 1) return `${ths.toFixed(2)} TH/s`;
    const ghs = ths * 1000;
    if (ghs >= 1) return `${ghs.toFixed(1)} GH/s`;
    return `${(ghs * 1000).toFixed(1)} MH/s`;
  };
  const fmtAvg = (ghs: number) => {
    if (!Number.isFinite(ghs) || ghs <= 0) return "—";
    if (ghs >= 1) return `${ghs.toFixed(1)} GH/s`;
    return `${(ghs * 1000).toFixed(1)} MH/s`;
  };

  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
              <th className="text-left  px-5 py-3 font-normal">Algo</th>
              <th className="text-right px-3 py-3 font-normal">Connected workers</th>
              <th className="text-right px-3 py-3 font-normal">Hashrate</th>
              <th className="text-right px-5 py-3 font-normal">Avg / worker</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            <tr className="border-b border-pool-hairline hover:pool-graphite-2 transition-colors">
              <td className="px-5 py-3 text-pool-steel-hi font-semibold">scrypt</td>
              <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">
                {totalCount > 0 ? totalCount.toLocaleString() : "—"}
              </td>
              <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">
                {fmtHash(totalThs)}
              </td>
              <td className="px-5 py-3 text-right text-pool-steel-hi tabular-nums">
                {fmtAvg(avgGhs)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div className="border-t border-pool-hairline px-5 py-3 text-[11px] font-mono text-pool-steel">
        Per-miner-version breakdown lands in the next API drop — will pull from stratum's
        <span className="mx-1 font-mono text-pool-steel-hi">subscribe</span> user-agent
        field.
      </div>
    </div>
  );
}


// ---------------------------------------------------------------------------
// Learn band
// ---------------------------------------------------------------------------
function LearnBand() {
  return (
    <div className="grid md:grid-cols-3 gap-4">
      <LearnCard
        icon={Zap}
        title="Chain spec"
        body="3-min blocks, scrypt PoW, T-prefix addresses, Omni-Layer L2."
        cta="texitcoin.org/build"
        href="https://texitcoin.org/build"
      />
      <LearnCard
        icon={CircuitBoard}
        title="Merged mining"
        body="One scrypt hash contributes to LTC, DOGE, ISK, TXC and ZCU simultaneously."
        cta="How it works"
        href="https://en.bitcoin.it/wiki/Merged_mining_specification"
      />
      <LearnCard
        icon={ShieldCheck}
        title="Manifesto"
        body="Sound money is a right. This pool exists so anyone with a rig can secure it."
        cta="Read the manifesto"
        to="/manifesto"
      />
    </div>
  );
}

function LearnCard({
  icon: Icon,
  title,
  body,
  cta,
  href,
  to,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  body: string;
  cta: string;
  href?: string;
  to?: string;
}) {
  const inner = (
    <div className="group pool-kpi-panel rounded-lg p-5 h-full flex flex-col hover:border-pool-hairline transition-colors">
      <Icon className="size-5 text-pool-mint" />
      <div className="mt-3 font-pool-display text-lg text-pool-steel-hi">{title}</div>
      <p className="mt-1 text-sm text-pool-steel flex-1 leading-relaxed">{body}</p>
      <div className="mt-4 inline-flex items-center gap-1 text-[12px] font-mono text-pool-steel-hi group-hover:text-pool-mint">
        {cta} <ArrowUpRight className="size-3.5" />
      </div>
    </div>
  );
  if (to) return <Link to={to}>{inner}</Link>;
  return (
    <a href={href} target="_blank" rel="noreferrer">
      {inner}
    </a>
  );
}
