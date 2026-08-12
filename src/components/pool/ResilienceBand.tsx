import {
  Activity,
  BellRing,
  Gauge,
  RefreshCcw,
  ServerCog,
  ShieldCheck,
} from "lucide-react";

type Pillar = {
  icon: React.ComponentType<{ className?: string }>;
  step: string;
  title: string;
  body: string;
  detail: string[];
};

const PILLARS: Pillar[] = [
  {
    icon: Activity,
    step: "01",
    title: "Always-on watchdog",
    body:
      "An outside-in monitor polls the stratum every 30 seconds and grades pool reachability, live hashrate, connected workers and per-chain block cadence.",
    detail: ["30s heartbeat", "5-min deep health check", "per-chain find-rate scoring"],
  },
  {
    icon: BellRing,
    step: "02",
    title: "Instant operator alerts",
    body:
      "Any degradation — a dry block hour, workers dropping off, hashrate under 75% of our 7-day average — pages the operations team on Telegram within seconds.",
    detail: ["Telegram paging", "de-duplicated with cooldowns", "auto-clears on recovery"],
  },
  {
    icon: Gauge,
    step: "03",
    title: "Automatic hashrate top-up",
    body:
      "When our own fleet dips — grid curtailment, a site outage, a container down — the pool rents replacement scrypt hashpower on the open market without a human in the loop.",
    detail: ["target = max(7-day avg, 19 TH/s)", "trigger at 75% of target", "live within minutes"],
  },
  {
    icon: ServerCog,
    step: "04",
    title: "Rental-grade front door",
    body:
      "A dedicated proxy endpoint speaks the exact handshake rented hashpower expects — high starting difficulty and sub-second job delivery — so borrowed miners hash productively from the first share.",
    detail: ["cached job push (~0.3s)", "difficulty negotiated per connection", "core stratum untouched"],
  },
  {
    icon: RefreshCcw,
    step: "05",
    title: "Cost-aware bidding",
    body:
      "Rentals are priced by walking the live order book to the true clearing price, then escalating one tick at a time only if the order underfills. We never blanket-overpay for liquidity.",
    detail: ["depth-aware clearing price", "tick-wise escalation", "auto-cancel on recovery"],
  },
  {
    icon: ShieldCheck,
    step: "06",
    title: "Miners feel nothing",
    body:
      "Failover happens upstream of your rig. Your connection, your worker names and your payout schedule stay exactly the same — the only thing you notice is that blocks keep landing.",
    detail: ["no reconnect required", "same payout cadence", "same fee"],
  },
];

export function ResilienceBand() {
  return (
    <div className="space-y-4">
      <div className="grid md:grid-cols-2 xl:grid-cols-3 gap-4">
        {PILLARS.map((p) => (
          <article
            key={p.step}
            className="pool-tick rounded-lg border border-pool-hairline p-4 flex flex-col gap-3"
          >
            <div className="flex items-start justify-between gap-3">
              <div className="flex items-center gap-2">
                <span className="pool-graphite rounded-md p-2 border border-pool-hairline">
                  <p.icon className="size-4 text-pool-mint" />
                </span>
                <h3 className="font-pool-display text-lg text-pool-steel-hi leading-tight">
                  {p.title}
                </h3>
              </div>
              <span className="text-[10px] font-mono tracking-widest text-pool-steel">
                {p.step}
              </span>
            </div>

            <p className="text-sm text-pool-steel leading-relaxed">{p.body}</p>

            <ul className="mt-auto flex flex-wrap gap-1.5">
              {p.detail.map((d) => (
                <li
                  key={d}
                  className="text-[10px] font-mono uppercase tracking-wider text-pool-steel border border-pool-hairline rounded px-1.5 py-0.5"
                >
                  {d}
                </li>
              ))}
            </ul>
          </article>
        ))}
      </div>

      <div className="pool-graphite rounded-lg border border-pool-hairline p-4 flex flex-wrap items-center gap-x-6 gap-y-2">
        <div className="flex items-center gap-2 text-xs font-mono text-pool-steel-hi">
          <span className="size-2 rounded-full bg-pool-mint animate-pulse-dot" />
          Failover armed · monitored 24/7
        </div>
        <p className="text-xs text-pool-steel">
          Curtailment, an offline site or a bad container reduces our hashrate — not your rewards.
          The pool buys back the shortfall automatically and keeps hunting blocks on all five chains.
        </p>
      </div>
    </div>
  );
}
