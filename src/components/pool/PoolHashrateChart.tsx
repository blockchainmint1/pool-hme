import { useMemo, useState } from "react";
import { queryOptions, useQuery } from "@tanstack/react-query";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Line,
} from "recharts";
import { getPoolHashrate, type HashrateWindow } from "@/lib/pool/pool.functions";

// yiimp's hashstats records H/s. Format with SI suffixes so 1 TH/s = 1e12 H/s
// renders nicely on the Y axis and tooltip.
function fmtHash(h: number): string {
  if (!isFinite(h) || h <= 0) return "0 H/s";
  const units = [
    { v: 1e18, s: "EH/s" },
    { v: 1e15, s: "PH/s" },
    { v: 1e12, s: "TH/s" },
    { v: 1e9, s: "GH/s" },
    { v: 1e6, s: "MH/s" },
    { v: 1e3, s: "KH/s" },
  ];
  for (const u of units) {
    if (h >= u.v) return `${(h / u.v).toFixed(2)} ${u.s}`;
  }
  return `${h.toFixed(2)} H/s`;
}

const WINDOWS: { key: HashrateWindow; label: string }[] = [
  { key: "1h", label: "1H" },
  { key: "24h", label: "24H" },
  { key: "7d", label: "7D" },
  { key: "30d", label: "30D" },
];

function hashrateQuery(window: HashrateWindow) {
  return queryOptions({
    queryKey: ["pool", "hashrate", window],
    queryFn: () => getPoolHashrate({ data: { window, algo: "scrypt" } }),
    staleTime: 30_000,
    refetchInterval: window === "1h" ? 30_000 : 5 * 60_000,
  });
}

function tickFormatter(window: HashrateWindow) {
  return (unix: number) => {
    const d = new Date(unix * 1000);
    if (window === "1h" || window === "24h") {
      return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    }
    return d.toLocaleDateString([], { month: "short", day: "numeric" });
  };
}

export function PoolHashrateChart() {
  const [window, setWindow] = useState<HashrateWindow>("24h");
  const { data, isLoading } = useQuery(hashrateQuery(window));

  const { chartData, avg, peak, current } = useMemo(() => {
    const pts = data?.points ?? [];
    if (pts.length === 0) {
      return { chartData: [], avg: 0, peak: 0, current: 0 };
    }
    let sum = 0;
    let peak = 0;
    for (const p of pts) {
      sum += p.hashrate;
      if (p.hashrate > peak) peak = p.hashrate;
    }
    return {
      chartData: pts,
      avg: sum / pts.length,
      peak,
      current: pts[pts.length - 1].hashrate,
    };
  }, [data]);

  return (
    <div className="pool-kpi-panel rounded-lg overflow-hidden">
      {/* header row */}
      <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 border-b border-pool-hairline">
        <div className="flex items-center gap-4 text-[11px] font-mono uppercase tracking-widest text-pool-steel">
          <span className="flex items-center gap-2">
            <span className="size-1.5 rounded-full bg-pool-mint animate-pulse-dot" />
            scrypt · pool hashrate
          </span>
          {data?.synthetic && (
            <span className="text-pool-amber">
              preview series · live from stratum once api box is upgraded
            </span>
          )}
        </div>
        <div className="inline-flex rounded-md border border-pool-hairline pool-tick overflow-hidden text-[11px] font-mono">
          {WINDOWS.map((w) => (
            <button
              key={w.key}
              onClick={() => setWindow(w.key)}
              className={`px-3 py-1.5 uppercase tracking-widest transition ${
                window === w.key
                  ? "bg-pool-mint text-pool-obsidian"
                  : "text-pool-steel hover:text-pool-steel-hi"
              }`}
            >
              {w.label}
            </button>
          ))}
        </div>
      </div>

      {/* stat strip */}
      <div className="grid grid-cols-3 border-b border-pool-hairline">
        <StatCell label="Current" value={fmtHash(current)} accent />
        <StatCell label={`Avg · ${window}`} value={fmtHash(avg)} />
        <StatCell label={`Peak · ${window}`} value={fmtHash(peak)} />
      </div>

      {/* chart */}
      <div className="h-72 p-3">
        {isLoading && chartData.length === 0 ? (
          <div className="h-full flex items-center justify-center text-xs font-mono text-pool-steel">
            Loading hashrate…
          </div>
        ) : (
          <ResponsiveContainer>
            <AreaChart data={chartData} margin={{ top: 8, right: 12, left: 0, bottom: 4 }}>
              <defs>
                <linearGradient id="poolHashGradient" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="var(--pool-mint)" stopOpacity={0.35} />
                  <stop offset="100%" stopColor="var(--pool-mint)" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid stroke="var(--pool-hairline)" strokeDasharray="2 4" />
              <XAxis
                dataKey="time"
                tickFormatter={tickFormatter(window)}
                stroke="var(--pool-steel)"
                fontSize={10}
                minTickGap={40}
              />
              <YAxis
                tickFormatter={(v) => fmtHash(v).replace(/\.\d+ /, " ")}
                stroke="var(--pool-steel)"
                fontSize={10}
                width={72}
              />
              <Tooltip
                labelFormatter={(v: number) => new Date(v * 1000).toLocaleString()}
                formatter={(v: number, name: string) => [fmtHash(v), name]}
                contentStyle={{
                  background: "var(--pool-obsidian)",
                  border: "1px solid var(--pool-hairline)",
                  borderRadius: 6,
                  fontFamily: "var(--font-mono)",
                  fontSize: 12,
                }}
              />
              <Area
                type="monotone"
                dataKey="hashrate"
                name="pool"
                stroke="var(--pool-mint)"
                strokeWidth={1.75}
                fill="url(#poolHashGradient)"
                isAnimationActive={false}
              />
              {chartData.some((p) => p.network_hashrate > 0) && (
                <Line
                  type="monotone"
                  dataKey="network_hashrate"
                  name="network"
                  stroke="var(--color-pool-steel-hi)"
                  strokeWidth={1}
                  strokeDasharray="3 3"
                  dot={false}
                  isAnimationActive={false}
                />
              )}
            </AreaChart>
          </ResponsiveContainer>
        )}
      </div>
    </div>
  );
}

function StatCell({
  label,
  value,
  accent,
}: {
  label: string;
  value: string;
  accent?: boolean;
}) {
  return (
    <div className="px-5 py-3 border-r border-pool-hairline last:border-r-0">
      <div className="text-[10px] uppercase tracking-widest text-pool-steel font-mono">
        {label}
      </div>
      <div
        className={`mt-1 font-pool-display tabular-nums text-xl ${
          accent ? "text-pool-mint" : "text-pool-steel-hi"
        }`}
      >
        {value}
      </div>
    </div>
  );
}
