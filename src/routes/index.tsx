import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { queryOptions, useSuspenseQuery } from "@tanstack/react-query";
import {
  Activity,
  ArrowUpRight,
  Cpu,
  Gauge,
  Copy,
  Check,
  ChevronRight,
  ShieldCheck,
  Zap,
  CircuitBoard,
  Wallet,
  BookOpen,
  Radio,
} from "lucide-react";
import { getPoolSummary, type PoolBlock } from "@/lib/pool/pool.functions";
import { PoolHashrateChart } from "@/components/pool/PoolHashrateChart";

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
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem.",
      },
      { property: "og:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      {
        property: "og:description",
        content:
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      {
        name: "twitter:description",
        content:
          "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem.",
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
      {/* preview banner */}
      <div className="border-b border-pool-hairline pool-graphite">
        <div className="max-w-7xl mx-auto px-4 py-2 flex items-center justify-between gap-3 text-[11px] font-mono uppercase tracking-widest">
          <div className="flex items-center gap-2 text-pool-steel">
            <span className="size-1.5 rounded-full bg-pool-amber animate-pulse-dot" />
            preview build · stratum lands soon on{" "}
            <span className="text-pool-steel-hi">stratum.pool.texitcoin.org</span>
          </div>
          <div className="hidden md:block text-pool-steel">honest.money · TXC ecosystem</div>
        </div>
      </div>

      <div className="max-w-7xl mx-auto px-4 py-8 grid grid-cols-12 gap-6">
        {/* Left rail nav — dashboard shell */}
        <aside className="hidden lg:block col-span-3 xl:col-span-2 space-y-1 sticky top-20 self-start">
          <RailLink href="#overview"  icon={Gauge}         label="Overview" active />
          <RailLink href="#algos"     icon={CircuitBoard}  label="Algos" />
          <RailLink href="#stats"     icon={Activity}      label="Pool stats" />
          <RailLink href="#graphs"    icon={Activity}      label="Graphs" />
          <RailLink href="#connect"   icon={Radio}         label="Connect" />
          <RailLink href="#workers"   icon={Cpu}           label="Workers" />
          <RailLink href="#blocks"    icon={Cpu}           label="Found blocks" />
          <RailLink href="#payouts"   icon={Wallet}        label="Payouts" />
          <RailLink href="#learn"     icon={BookOpen}      label="Learn" />
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
              <SectionHeader eyebrow="Fair share" title="Payouts." hint="every 30 minutes" />
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
              hint="TXC · ISK · ZCU · newest first"
            />
            <FoundBlocks />
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
          <LiveBlocks24hKpi />
        </div>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <a
            href="#connect"
            className="inline-flex items-center gap-2 rounded-md bg-pool-mint text-pool-obsidian px-4 py-2.5 text-sm font-semibold hover:opacity-90 transition"
          >
            Connect a miner <ArrowUpRight className="size-4" />
          </a>
          <a
            href="https://pool.texitcoin.org/site/dogeRegister"
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-md border border-pool-hairline pool-tick text-pool-steel-hi px-4 py-2.5 text-sm font-medium hover:pool-graphite-2 transition"
          >
            Register LTC/DOGE <ChevronRight className="size-4" />
          </a>
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
  const miners = data.activeMiners || scrypt?.live_clients || 0;
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
  // Derive per-coin counts + last-found from the pool-found blocks list.
  // Windows: 1h / 24h / 7d — computed from block timestamps.
  const now = data.fetchedAt;
  const buckets = { h1: 3600, h24: 86_400, d7: 7 * 86_400 };
  type Row = { symbol: string; name: string; h1: number; h24: number; d7: number; last: number };
  const rows: Record<string, Row> = {};
  for (const b of data.blocks) {
    const r = rows[b.symbol] ?? {
      symbol: b.symbol,
      name: b.name,
      h1: 0,
      h24: 0,
      d7: 0,
      last: 0,
    };
    const age = now - b.time;
    if (age <= buckets.h1) r.h1 += 1;
    if (age <= buckets.h24) r.h24 += 1;
    if (age <= buckets.d7) r.d7 += 1;
    if (b.time > r.last) r.last = b.time;
    rows[b.symbol] = r;
  }
  const list = Object.values(rows).sort((a, b) => b.d7 - a.d7);

  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-pool-steel font-mono border-b border-pool-hairline">
              <th className="text-left px-5 py-3 font-normal">Coin</th>
              <th className="text-left px-3 py-3 font-normal">Symbol</th>
              <th className="text-right px-3 py-3 font-normal">Blocks 1 h</th>
              <th className="text-right px-3 py-3 font-normal">24 h</th>
              <th className="text-right px-3 py-3 font-normal">7 d</th>
              <th className="text-right px-5 py-3 font-normal">Last found</th>
            </tr>
          </thead>
          <tbody className="font-mono">
            {list.length === 0 && (
              <tr>
                <td colSpan={6} className="px-5 py-6 text-center text-pool-steel">
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
                <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">{r.h1}</td>
                <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">{r.h24}</td>
                <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">{r.d7}</td>
                <td className="px-5 py-3 text-right text-pool-steel tabular-nums">
                  {r.last ? ago(Math.max(0, now - r.last)) : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="border-t border-pool-hairline px-5 py-3 text-[11px] font-mono text-pool-steel">
        Only TXC · ISK · ZCU are solo-found by this pool. LTC / DOGE credit via auxpow and
        are not counted here.
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
            <a
              href="https://pool.texitcoin.org/site/dogeRegister"
              target="_blank"
              rel="noreferrer"
              className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            >
              Register LTC/DOGE
            </a>{" "}
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
  const nextPayout = useMemo(() => nextHalfHourEpoch(), []);
  const [remainingSec, setRemainingSec] = useState(0);
  useEffect(() => {
    const tick = () => setRemainingSec(Math.max(0, nextPayout - Math.floor(Date.now() / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [nextPayout]);

  const mm = String(Math.floor(remainingSec / 60)).padStart(2, "0");
  const ss = String(remainingSec % 60).padStart(2, "0");

  return (
    <div id="payouts" className="pool-kpi-panel rounded-lg p-5 space-y-4">
      <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
        Next payout
      </div>
      <div className="font-pool-display font-semibold text-5xl text-pool-steel-hi tabular-nums pool-hash-live">
        {mm}
        <span className="text-pool-steel">:</span>
        {ss}
      </div>
      <ul className="space-y-2 text-sm text-pool-steel">
        <li className="flex items-center justify-between border-b border-pool-hairline pb-2">
          <span>Interval</span>
          <span className="text-pool-steel-hi font-mono">every 30 min</span>
        </li>
        <li className="flex items-center justify-between border-b border-pool-hairline pb-2">
          <span>Threshold</span>
          <span className="text-pool-steel-hi font-mono">≥ 0.001</span>
        </li>
        <li className="flex items-center justify-between border-b border-pool-hairline pb-2">
          <span>Sunday sweep</span>
          <span className="text-pool-steel-hi font-mono">≥ 0.0001</span>
        </li>
        <li className="flex items-center justify-between">
          <span>Payout coins</span>
          <span className="text-pool-steel-hi font-mono">LTC · DOGE</span>
        </li>
      </ul>
      <div className="text-[11px] font-mono text-pool-steel leading-relaxed">
        TXC / ISK / ZCU are mined for chain security and are not part of the pool payout —
        by design, so the pool never becomes a distribution bottleneck for TEXITcoin itself.
      </div>
    </div>
  );
}

function nextHalfHourEpoch() {
  const now = new Date();
  const m = now.getUTCMinutes();
  const bump = m < 30 ? 30 - m : 60 - m;
  const then = new Date(now);
  then.setUTCMinutes(m + bump, 0, 0);
  return Math.floor(then.getTime() / 1000);
}

// ---------------------------------------------------------------------------
// Found blocks
// ---------------------------------------------------------------------------
function LiveBlocks24hKpi() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  // 5 chains + Total. LTC/DOGE come in as auxpow credit — not solo-found —
  // so their tiles will normally read 0. That's intentional (see manifesto).
  const chains = ["LTC", "DOGE", "TXC", "ISK", "ZCU"] as const;
  const total = data.blocks24h;
  return (
    <div className="pool-tick rounded-md p-5">
      <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
        Blocks / 24h
      </div>
      <div className="mt-3 grid grid-cols-3 gap-2">
        <MiniBlockTile label="Total" value={total} accent />
        {chains.map((sym) => (
          <MiniBlockTile
            key={sym}
            label={sym}
            value={data.blocks24hBySymbol[sym] ?? 0}
          />
        ))}
      </div>
      <div className="mt-3 text-[10px] font-mono text-pool-steel leading-relaxed">
        TXC · ISK · ZCU pool-found · LTC / DOGE via auxpow credit
      </div>
    </div>
  );
}

function MiniBlockTile({
  label,
  value,
  accent,
}: {
  label: string;
  value: number;
  accent?: boolean;
}) {
  return (
    <div className="rounded border border-pool-hairline pool-graphite/40 px-2 py-1.5">
      <div className="text-[9px] uppercase tracking-widest text-pool-steel font-mono">
        {label}
      </div>
      <div
        className={`mt-0.5 font-pool-display font-semibold text-lg tabular-nums ${
          accent ? "text-pool-mint" : "text-pool-steel-hi"
        }`}
      >
        {value.toLocaleString()}
      </div>
    </div>
  );
}

function LiveMinersKpi() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  // `activeMiners` = distinct workers with a share submit in the last 10 min
  // (yiimp's `workers` table, filtered by `time`). More honest than stratum
  // diag's TCP snapshot, which undercounts fleets that reconnect (cellular).
  const value = data.activeMiners > 0 ? data.activeMiners.toLocaleString() : "—";
  return <Kpi label="Active miners" value={value} hint="active in last 10 min" />;
}

function FoundBlocks() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  // Anchor "age" to data.fetchedAt (already in the SSR payload) so server and
  // client render identical strings on first paint. A live re-tick happens on
  // the next Query refetch (30s) — good enough, and no hydration drift.
  const nowSec = data.fetchedAt;
  const rows = data.blocks.slice(0, 8);

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
                  Waiting for the next pool-found block…
                </td>
              </tr>
            )}
            {rows.map((b: PoolBlock) => {
              const isImmature = b.category === "immature" || b.confirmations < 100;
              const statusColor = isImmature ? "text-pool-amber" : "text-pool-mint";
              const statusLabel = isImmature
                ? `${b.confirmations} conf`
                : b.category === "orphan"
                  ? "orphan"
                  : "confirmed";
              return (
                <tr
                  key={`${b.symbol}-${b.height}-${b.blockhash.slice(0, 8)}`}
                  className="border-b border-pool-hairline last:border-b-0 hover:pool-graphite-2 transition-colors"
                >
                  <td className="px-5 py-3">
                    <span className="inline-flex items-center gap-2">
                      <CoinBadge symbol={b.symbol} />
                      <span className="text-pool-steel-hi">{b.symbol}</span>
                    </span>
                  </td>
                  <td className="px-3 py-3 text-pool-steel-hi tabular-nums">
                    {b.height.toLocaleString()}
                  </td>
                  <td className="px-3 py-3 text-pool-steel">
                    {ago(Math.max(0, nowSec - b.time))}
                  </td>
                  <td className="px-3 py-3 text-right text-pool-steel-hi tabular-nums">
                    {b.amount.toLocaleString(undefined, { maximumFractionDigits: 4 })}{" "}
                    <span className="text-pool-steel">{b.symbol}</span>
                  </td>
                  <td className={`px-5 py-3 text-right tabular-nums ${statusColor}`}>
                    {statusLabel}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="border-t border-pool-hairline px-5 py-3 flex items-center justify-between">
        <div className="text-[11px] font-mono text-pool-steel">
          Live from stratum · snapshot age {ago(0)}. LTC / DOGE are
          merge-mined via auxpow (share credit, not solo-found) and are not listed here.
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Workers table — miner-version breakdown, modeled on pool.txc
// ---------------------------------------------------------------------------
function WorkersTable() {
  const { data } = useSuspenseQuery(poolSummaryQuery);
  const scrypt = data.algos.find((x) => x.algo === "scrypt");
  const totalCount = scrypt?.live_clients ?? data.liveClients;
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

function CoinBadge({ symbol }: { symbol: string }) {
  const colorMap: Record<string, string> = {
    TXC:  "bg-pool-amber",
    LTC:  "bg-pool-steel",
    DOGE: "bg-pool-amber",
    ISK:  "bg-pool-mint",
    ZCU:  "bg-pool-mint",
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
