import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  Area,
  AreaChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { Loader2, Search, Activity, Wallet, Users, Coins } from "lucide-react";
import {
  getAccountOverview,
  type AccountOverview,
  type AccountWorker,
} from "@/lib/pool/account.functions";

export const Route = createFileRoute("/account")({
  validateSearch: (search: Record<string, unknown>) => ({
    address: typeof search.address === "string" ? search.address : "",
  }),
  head: () => ({
    meta: [
      { title: "My account · honest.money pool" },
      {
        name: "description",
        content:
          "Check how your mining account is doing: live hashrate, workers, unpaid balance, recent earnings and payouts on the honest.money merged-mining pool.",
      },
      { property: "og:title", content: "My mining account · honest.money pool" },
      {
        property: "og:description",
        content:
          "Live hashrate, workers, unpaid balance, earnings and payouts for your mining address.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: AccountPage,
});

const HS_UNITS = ["H/s", "KH/s", "MH/s", "GH/s", "TH/s", "PH/s"];

function fmtHash(hs: number): string {
  if (!Number.isFinite(hs) || hs <= 0) return "0 H/s";
  let v = hs;
  let i = 0;
  while (v >= 1000 && i < HS_UNITS.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v.toFixed(v >= 100 ? 0 : 2)} ${HS_UNITS[i]}`;
}

function fmtAmount(n: number, digits = 8): string {
  return Number(n ?? 0).toFixed(digits);
}

function fmtTime(t?: number | null): string {
  if (!t) return "—";
  const secs = Math.floor(Date.now() / 1000) - Number(t);
  if (secs < 0) return new Date(Number(t) * 1000).toLocaleString();
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
}

function Tile({
  label,
  value,
  sub,
  icon,
}: {
  label: string;
  value: string;
  sub?: string;
  icon: React.ReactNode;
}) {
  return (
    <div className="rounded-lg border border-pool-hairline p-4">
      <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] font-mono text-pool-steel">
        {icon}
        {label}
      </div>
      <div className="mt-2 font-display text-xl text-pool-steel-hi break-all">{value}</div>
      {sub ? <div className="mt-1 text-xs text-pool-steel">{sub}</div> : null}
    </div>
  );
}

function Section({
  title,
  note,
  children,
}: {
  title: string;
  note?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mt-8">
      <h2 className="font-display text-sm uppercase tracking-[0.2em] text-pool-steel-hi">
        {title}
      </h2>
      {note ? <p className="mt-1 text-xs text-pool-steel">{note}</p> : null}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function workerStatus(w: AccountWorker): { label: string; cls: string } {
  const hs = Number(w.hashrate ?? 0);
  const last = Number(w.last_share ?? 0);
  const age = last ? Math.floor(Date.now() / 1000) - last : Infinity;
  // Hashrate is measured over the last 10 minutes of accepted shares, so a
  // non-zero rate is itself proof the rig is live right now.
  if (hs > 0 || age < 900) return { label: "online", cls: "text-success" };
  if (!last) return { label: "idle", cls: "text-pool-steel" };
  if (age < 86400) return { label: "stale", cls: "text-warning" };
  return { label: "offline", cls: "text-destructive" };
}

function AccountPage() {
  const { address } = Route.useSearch();
  const navigate = Route.useNavigate();
  const [input, setInput] = useState(address);

  const fetchOverview = useServerFn(getAccountOverview);
  const q = useQuery<AccountOverview>({
    queryKey: ["pool", "account", address],
    queryFn: () => fetchOverview({ data: { address } }),
    enabled: address.length >= 20,
    refetchInterval: 60_000,
    retry: 0,
  });

  const data = q.data;
  // Per-algo rows already aggregate live (share-backed) hashrate.
  const totalHash = data?.algos.reduce((s, a) => s + Number(a.hashrate ?? 0), 0) ?? 0;
  const onlineWorkers =
    data?.workers.filter((w) => workerStatus(w).label === "online").length ?? 0;
  const totalWorkers = data?.workers.length ?? 0;


  return (
    <div className="max-w-6xl mx-auto px-4 py-10">
      <h1 className="font-display text-2xl tracking-wide text-pool-steel-hi">
        How's my account doing?
      </h1>
      <p className="mt-2 max-w-2xl text-sm text-pool-steel">
        Paste the mining address your workers point at (your LTC payout address). Everything
        below is read straight from the pool — hashrate, workers, unpaid balance, earnings and
        payouts.
      </p>

      <form
        className="mt-6 flex flex-col gap-3 sm:flex-row"
        onSubmit={(e) => {
          e.preventDefault();
          navigate({ to: ".", search: { address: input.trim() } });
        }}
      >
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="LTC mining address"
          spellCheck={false}
          autoComplete="off"
          className="flex-1 rounded-md border border-pool-hairline bg-transparent px-3 py-2.5 font-mono text-sm text-pool-steel-hi outline-none transition-colors placeholder:text-pool-steel/50 focus:border-pool-mint"
        />
        <button
          type="submit"
          className="inline-flex items-center justify-center gap-2 rounded-md bg-primary px-5 py-2.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90"
        >
          <Search className="size-4" />
          Look up
        </button>
      </form>

      {!address ? (
        <p className="mt-8 text-sm text-pool-steel">
          No address yet. Need to link a DOGE payout address first?{" "}
          <Link to="/register" className="underline decoration-dotted underline-offset-2 hover:text-primary">
            Register here
          </Link>
          .
        </p>
      ) : q.isLoading ? (
        <div className="mt-10 flex items-center gap-2 text-sm text-pool-steel">
          <Loader2 className="size-4 animate-spin" /> Reading pool records…
        </div>
      ) : q.isError ? (
        <p className="mt-8 text-sm text-destructive">
          {(q.error as Error)?.message ?? "Could not reach the pool right now."}
        </p>
      ) : data && !data.found ? (
        <p className="mt-8 text-sm text-pool-steel">
          No account found for <span className="font-mono">{address}</span>. Double-check the
          address, or point a miner at the pool once — the account is created on the first
          share.
        </p>
      ) : data ? (
        <>
          <div className="mt-8 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Tile
              label="Live hashrate"
              value={fmtHash(totalHash)}
              sub={`${onlineWorkers} of ${data.workers.length} workers reporting`}
              icon={<Activity className="size-3.5" />}
            />
            <Tile
              label="Unpaid balance"
              value={`${fmtAmount(data.balance)} LTC`}
              sub={`${fmtAmount(data.pending)} LTC pending`}
              icon={<Wallet className="size-3.5" />}
            />
            <Tile
              label="Total paid"
              value={`${fmtAmount(data.payouts_summary.total_paid ?? data.paid)} LTC`}
              sub={`${data.payouts_summary.payout_count} payouts · last ${fmtTime(
                data.payouts_summary.last_payout,
              )}`}
              icon={<Coins className="size-3.5" />}
            />
            <Tile
              label="Workers"
              value={`${onlineWorkers} online`}
              sub={`${totalWorkers} on record · ${data.algos.map((a) => a.algo).join(", ") || "—"}`}
              icon={<Users className="size-3.5" />}
            />

          </div>

          {data.hashrate_24h.length > 1 ? (
            <Section title="Hashrate — last 24 hours">
              <div className="h-56 rounded-lg border border-pool-hairline p-3">
                <ResponsiveContainer width="100%" height="100%">
                  <AreaChart data={data.hashrate_24h}>
                    <XAxis
                      dataKey="time"
                      tickFormatter={(t: number) =>
                        new Date(t * 1000).toLocaleTimeString([], { hour: "2-digit" })
                      }
                      tick={{ fontSize: 11 }}
                      stroke="currentColor"
                      className="text-pool-steel"
                    />
                    <YAxis
                      tickFormatter={(v: number) => fmtHash(v)}
                      tick={{ fontSize: 11 }}
                      width={78}
                      stroke="currentColor"
                      className="text-pool-steel"
                    />
                    <Tooltip
                      formatter={(v: number) => fmtHash(Number(v))}
                      labelFormatter={(t: number) => new Date(t * 1000).toLocaleString()}
                      contentStyle={{
                        background: "var(--color-background)",
                        border: "1px solid var(--color-border)",
                        fontSize: 12,
                      }}
                    />
                    <Area
                      type="monotone"
                      dataKey="hashrate"
                      stroke="var(--color-primary)"
                      fill="var(--color-primary)"
                      fillOpacity={0.15}
                      strokeWidth={2}
                    />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </Section>
          ) : null}

          <Section
            title="DOGE payout link"
            note="Merged-mined DOGE is paid to the linked address, separate from your LTC balance."
          >
            {data.doge.linked ? (
              <div className="rounded-lg border border-pool-hairline p-4 text-sm text-pool-steel">
                <div>
                  Linked DOGE address:{" "}
                  <span className="font-mono text-pool-steel-hi">
                    {data.doge.doge_address_masked}
                  </span>
                </div>
                <div className="mt-1">
                  Status: {data.doge.active ? "active" : "inactive"} · token last seen{" "}
                  {fmtTime(data.doge.token_last_seen)}
                </div>
              </div>
            ) : (
              <div className="rounded-lg border border-pool-hairline p-4 text-sm text-pool-steel">
                No DOGE payout address linked to this account.{" "}
                <Link
                  to="/register"
                  className="underline decoration-dotted underline-offset-2 hover:text-primary"
                >
                  Link one here
                </Link>
                .
              </div>
            )}
          </Section>

          <Section title="Workers">
            {data.workers.length === 0 ? (
              <p className="text-sm text-pool-steel">No workers on record yet.</p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-pool-hairline">
                <table className="w-full text-sm">
                  <thead className="text-[10px] uppercase tracking-[0.15em] font-mono text-pool-steel">
                    <tr className="border-b border-pool-hairline">
                      <th className="px-3 py-2 text-left">Worker</th>
                      <th className="px-3 py-2 text-left">Algo</th>
                      <th className="px-3 py-2 text-right">Hashrate</th>
                      <th className="px-3 py-2 text-right">Diff</th>
                      <th className="px-3 py-2 text-right">Shares 10m</th>
                      <th className="px-3 py-2 text-right">Rejects 10m</th>
                      <th className="px-3 py-2 text-left">Last share</th>
                      <th className="px-3 py-2 text-left">Status</th>
                    </tr>
                  </thead>
                  <tbody className="font-mono text-xs text-pool-steel-hi">
                    {data.workers.map((w, i) => {
                      const st = workerStatus(w);
                      return (
                        <tr key={i} className="border-b border-pool-hairline/50 last:border-0">
                          <td className="px-3 py-2">{w.worker ?? "—"}</td>
                          <td className="px-3 py-2">{w.algo ?? "—"}</td>
                          <td className="px-3 py-2 text-right">{fmtHash(Number(w.hashrate ?? 0))}</td>
                          <td className="px-3 py-2 text-right">{Number(w.difficulty ?? 0)}</td>
                          <td className="px-3 py-2 text-right">{Number(w.shares_10m ?? 0)}</td>
                          <td className="px-3 py-2 text-right">{Number(w.rejects_10m ?? 0)}</td>
                          <td className="px-3 py-2">
                            {w.last_share ? fmtTime(w.last_share) : "—"}
                          </td>
                          <td className={`px-3 py-2 ${st.cls}`}>{st.label}</td>
                        </tr>
                      );
                    })}
                  </tbody>

                </table>
              </div>
            )}
          </Section>

          <Section title="Recent earnings">
            {data.earnings.length === 0 ? (
              <p className="text-sm text-pool-steel">No earnings recorded yet.</p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-pool-hairline">
                <table className="w-full text-sm">
                  <thead className="text-[10px] uppercase tracking-[0.15em] font-mono text-pool-steel">
                    <tr className="border-b border-pool-hairline">
                      <th className="px-3 py-2 text-left">When</th>
                      <th className="px-3 py-2 text-left">Coin</th>
                      <th className="px-3 py-2 text-right">Block</th>
                      <th className="px-3 py-2 text-right">Amount</th>
                      <th className="px-3 py-2 text-left">Status</th>
                    </tr>
                  </thead>
                  <tbody className="font-mono text-xs text-pool-steel-hi">
                    {data.earnings.map((e) => (
                      <tr key={e.id} className="border-b border-pool-hairline/50 last:border-0">
                        <td className="px-3 py-2">{fmtTime(e.time)}</td>
                        <td className="px-3 py-2">{e.symbol ?? "—"}</td>
                        <td className="px-3 py-2 text-right">{e.height ?? "—"}</td>
                        <td className="px-3 py-2 text-right">{fmtAmount(e.amount)}</td>
                        <td className="px-3 py-2">
                          {Number(e.status) > 0 ? "confirmed" : "immature"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>

          <Section title="Recent payouts">
            {data.payouts.length === 0 ? (
              <p className="text-sm text-pool-steel">No payouts sent yet.</p>
            ) : (
              <div className="overflow-x-auto rounded-lg border border-pool-hairline">
                <table className="w-full text-sm">
                  <thead className="text-[10px] uppercase tracking-[0.15em] font-mono text-pool-steel">
                    <tr className="border-b border-pool-hairline">
                      <th className="px-3 py-2 text-left">When</th>
                      <th className="px-3 py-2 text-left">Coin</th>
                      <th className="px-3 py-2 text-right">Amount</th>
                      <th className="px-3 py-2 text-left">Transaction</th>
                    </tr>
                  </thead>
                  <tbody className="font-mono text-xs text-pool-steel-hi">
                    {data.payouts.map((p) => (
                      <tr key={p.id} className="border-b border-pool-hairline/50 last:border-0">
                        <td className="px-3 py-2">{fmtTime(p.time)}</td>
                        <td className="px-3 py-2">{p.symbol ?? "—"}</td>
                        <td className="px-3 py-2 text-right">{fmtAmount(p.amount)}</td>
                        <td className="px-3 py-2 break-all">{p.tx ?? "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Section>

          <p className="mt-8 text-xs text-pool-steel">
            Updated {fmtTime(data.fetched_at)} · refreshes every minute.
          </p>
        </>
      ) : null}
    </div>
  );
}
