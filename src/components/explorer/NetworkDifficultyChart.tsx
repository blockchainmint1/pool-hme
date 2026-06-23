import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";

interface HashrateResponse {
  currentHashrate: number;
  currentDifficulty: number;
  hashrates: { timestamp: number; avgHashrate: number }[];
  difficulty: { timestamp: number; difficulty: number; height: number }[];
}

type Window = "1d" | "1w" | "1m" | "3m" | "1y";
const WINDOWS: { value: Window; label: string }[] = [
  { value: "1d", label: "Day" },
  { value: "1w", label: "Week" },
  { value: "1m", label: "Month" },
  { value: "3m", label: "3 Months" },
  { value: "1y", label: "Year" },
];

function formatHashrate(h: number): string {
  if (h >= 1e18) return `${(h / 1e18).toFixed(2)} EH/s`;
  if (h >= 1e15) return `${(h / 1e15).toFixed(2)} PH/s`;
  if (h >= 1e12) return `${(h / 1e12).toFixed(2)} TH/s`;
  if (h >= 1e9) return `${(h / 1e9).toFixed(2)} GH/s`;
  if (h >= 1e6) return `${(h / 1e6).toFixed(2)} MH/s`;
  if (h >= 1e3) return `${(h / 1e3).toFixed(2)} kH/s`;
  return `${h.toFixed(0)} H/s`;
}

function formatDifficulty(d: number): string {
  if (d >= 1e9) return `${(d / 1e9).toFixed(2)}B`;
  if (d >= 1e6) return `${(d / 1e6).toFixed(2)}M`;
  if (d >= 1e3) return `${(d / 1e3).toFixed(2)}k`;
  return d.toFixed(2);
}

export function NetworkDifficultyChart() {
  const [win, setWin] = useState<Window>("1m");
  const q = useQuery({
    queryKey: ["network-hashrate", win],
    queryFn: async (): Promise<HashrateResponse> => {
      const res = await fetch(`/api/v1/mining/hashrate?window=${win}`);
      if (!res.ok) throw new Error(`hashrate ${res.status}`);
      return res.json();
    },
    refetchInterval: 5 * 60_000,
    staleTime: 5 * 60_000,
    retry: 0,
  });

  const xTickFormat = (t: number) => {
    const d = new Date(t * 1000);
    if (win === "1d") return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    if (win === "1y") return d.toLocaleDateString(undefined, { month: "short", year: "2-digit" });
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  };

  return (
    <div className="rounded-md surface-2 border border-border p-4">
      <div className="flex items-baseline justify-between mb-3 gap-3 flex-wrap">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
          Network hashrate
        </h3>
        <div className="flex items-baseline gap-4 font-mono text-xs">
          {q.data && (
            <>
              <span>
                <span className="text-muted-foreground">now </span>
                <span className="text-foreground">{formatHashrate(q.data.currentHashrate)}</span>
              </span>
              <span>
                <span className="text-muted-foreground">diff </span>
                <span className="text-foreground">{formatDifficulty(q.data.currentDifficulty)}</span>
              </span>
            </>
          )}
        </div>
      </div>

      <div className="mb-3 inline-flex rounded-sm border border-border bg-surface-1 p-0.5 font-mono text-[11px]">
        {WINDOWS.map((w) => (
          <button
            key={w.value}
            onClick={() => setWin(w.value)}
            className={`px-2.5 py-1 rounded-sm uppercase tracking-wider transition-colors ${
              win === w.value
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            {w.label}
          </button>
        ))}
      </div>

      {q.isLoading && (
        <div className="h-56 flex items-center justify-center text-xs text-muted-foreground">
          Computing from block headers…
        </div>
      )}
      {q.isError && (
        <div className="h-56 flex items-center justify-center text-xs text-muted-foreground">
          Couldn't compute hashrate right now.
        </div>
      )}
      {q.data && q.data.hashrates.length > 0 && (
        <div className="h-56">
          <ResponsiveContainer>
            <AreaChart data={q.data.hashrates}>
              <defs>
                <linearGradient id="hashFill" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="var(--color-primary)" stopOpacity={0.4} />
                  <stop offset="100%" stopColor="var(--color-primary)" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid stroke="var(--color-border)" strokeDasharray="3 3" />
              <XAxis
                dataKey="timestamp"
                tickFormatter={xTickFormat}
                stroke="var(--color-muted-foreground)"
                fontSize={10}
              />
              <YAxis
                stroke="var(--color-muted-foreground)"
                fontSize={10}
                tickFormatter={(v) => formatHashrate(v)}
                width={70}
              />
              <Tooltip
                contentStyle={{
                  background: "var(--color-popover)",
                  border: "1px solid var(--color-border)",
                  borderRadius: 6,
                  fontFamily: "var(--font-mono)",
                  fontSize: 11,
                }}
                labelFormatter={(l) => new Date((l as number) * 1000).toLocaleString()}
                formatter={(v: number) => [formatHashrate(v), "hashrate"]}
              />
              <Area
                type="monotone"
                dataKey="avgHashrate"
                stroke="var(--color-primary)"
                strokeWidth={2}
                fill="url(#hashFill)"
              />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      )}
      <p className="mt-2 text-[10px] font-mono text-muted-foreground/70">
        computed locally · difficulty × 2³² ÷ avg block time · cached 5 min
      </p>
    </div>
  );
}

