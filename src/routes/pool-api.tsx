import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Copy, Check } from "lucide-react";

const ORIGIN = "https://pool.honest.money";

interface Endpoint {
  id: string;
  method: string;
  path: string;
  title: string;
  desc: string;
  example: string;
}

const YIIMP: Endpoint[] = [
  {
    id: "status",
    method: "GET",
    path: "/api/status",
    title: "Pool status (per algo)",
    desc: "Live hashrate, connected workers, miner count and enabled coin count for each algorithm. Drop-in replacement for the legacy yiimp /api/status.",
    example: `{
  "scrypt": {
    "name": "scrypt",
    "port": 3433,
    "coins": 5,
    "fees": 0,
    "hashrate": 18836133794863,
    "workers": 1212,
    "miners": 11,
    "blocks24h": 877
  }
}`,
  },
  {
    id: "currencies",
    method: "GET",
    path: "/api/currencies",
    title: "Currencies (per coin)",
    desc: "One entry per coin mined on the pool, including merged-mining aux chains. Heights, network difficulty, 24h block counts and seconds since the last block found.",
    example: `{
  "TXC": {
    "algo": "scrypt",
    "port": 3433,
    "name": "Texitcoin",
    "symbol": "TXC",
    "height": 332175,
    "workers": 1212,
    "hashrate": 18836133794863,
    "difficulty": 770771.568,
    "24h_blocks": 438,
    "lastblock": 332175,
    "timesincelast": 42
  }
}`,
  },
  {
    id: "wallet",
    method: "GET",
    path: "/api/wallet?address=ADDRESS",
    title: "Wallet status",
    desc: "Balance, unpaid amount and 24h payouts for a mining address.",
    example: `{
  "unsold": 0,
  "balance": 0.00000000,
  "unpaid": 0.00050362,
  "paid24h": 0.00000000,
  "total": 0.00050362
}`,
  },
  {
    id: "walletex",
    method: "GET",
    path: "/api/walletEx?address=ADDRESS",
    title: "Wallet status + workers",
    desc: "Everything /api/wallet returns, plus a `miners` array with one row per worker (algo, difficulty, hashrate, accepted/rejected shares in the last 10 minutes).",
    example: `{
  "unsold": 0,
  "balance": 0,
  "unpaid": 0.00050362,
  "paid24h": 0,
  "total": 0.00050362,
  "miners": [
    {
      "version": "cgminer/4.11",
      "ID": "L9-container3-042",
      "algo": "scrypt",
      "difficulty": 65536,
      "subscribe": 1,
      "accepted": 812,
      "rejected": 0,
      "hashrate": 15600000000
    }
  ]
}`,
  },
  {
    id: "time",
    method: "GET",
    path: "/api/time",
    title: "Server time",
    desc: "Current pool server time as a unix timestamp (plain text).",
    example: `1785227497`,
  },
];

const V1: Endpoint[] = [
  {
    id: "summary",
    method: "GET",
    path: "/api/pool/pool/summary",
    title: "Pool summary",
    desc: "One-shot dashboard payload: per-algo hashrate and worker counts, last block per coin, 24h blocks by symbol, active miners and current round effort.",
    example: `{
  "algos": [{ "algo": "scrypt", "live_clients": 1212, "hashrate_hs": 18836133794863 }],
  "last_blocks": [{ "symbol": "TXC", "height": 332175, "time": 1785227199 }],
  "blocks_24h_by_symbol": { "TXC": 438, "ISK": 439, "DOGE": 13, "LTC": 3 },
  "active_miners_10m": 1212,
  "effort": [{ "symbol": "LTC", "effort_pct": 76.3 }]
}`,
  },
  {
    id: "hashrate",
    method: "GET",
    path: "/api/pool/pool/hashrate?window=24h&algo=scrypt",
    title: "Pool hashrate series",
    desc: "Bucketed hashrate time series. Windows: 1h, 6h, 24h, 7d, 30d.",
    example: `{ "algo": "scrypt", "window": "24h", "bucket_seconds": 600, "points": [[1785227199, 18836133794863]] }`,
  },
  {
    id: "coins",
    method: "GET",
    path: "/api/pool/coins",
    title: "Coins",
    desc: "Coins configured on the pool. Add /api/pool/coins/TXC for detail, /api/pool/coins/TXC/blocks for found blocks.",
    example: `{ "coins": [{ "symbol": "TXC", "name": "Texitcoin", "algo": "scrypt" }] }`,
  },
  {
    id: "blocks",
    method: "GET",
    path: "/api/pool/blocks?coin=TXC&limit=100",
    title: "Found blocks",
    desc: "Blocks found by the pool, newest first, with height, hash, amount, difficulty and confirmations.",
    example: `{ "blocks": [{ "height": 332175, "symbol": "TXC", "confirmations": 1, "category": "immature" }] }`,
  },
  {
    id: "merged",
    method: "GET",
    path: "/api/pool/mergedmining/summary",
    title: "Merged mining summary",
    desc: "Parent (LTC) and aux chain (DOGE / TXC / ISK / ZCU) submission health for the scrypt merged-mining stack.",
    example: `{ "parent": { "symbol": "LTC" }, "aux": [{ "symbol": "DOGE" }, { "symbol": "TXC" }] }`,
  },
  {
    id: "miner",
    method: "GET",
    path: "/api/pool/miner/ADDRESS",
    title: "Miner summary",
    desc: "Per-address rollup. Also: /workers, /hashrate?window=24h, /payouts, /earnings.",
    example: `{ "address": "Lg7J2d...", "balance": 0, "algos": [{ "algo": "scrypt", "workers_online": 112 }] }`,
  },
  {
    id: "health",
    method: "GET",
    path: "/api/pool/health",
    title: "Health",
    desc: "Backend liveness and database connectivity.",
    example: `{ "ok": true, "db": true, "uptime": 128374.2 }`,
  },
];

export const Route = createFileRoute("/pool-api")({
  head: () => ({
    meta: [
      { title: "Pool API — HME Pool (scrypt merged mining)" },
      {
        name: "description",
        content:
          "Free public REST API for the HME scrypt merged-mining pool: pool status, currencies, wallet lookups and v1 endpoints. yiimp-compatible, no API key.",
      },
      { property: "og:title", content: "HME Pool — Public Pool API" },
      {
        property: "og:description",
        content:
          "yiimp-compatible /api/status, /api/currencies, /api/wallet plus v1 endpoints for hashrate, blocks, merged mining and per-miner stats.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: PoolApiPage,
});

function PoolApiPage() {
  const [tab, setTab] = useState<"yiimp" | "v1">("yiimp");
  const list = tab === "yiimp" ? YIIMP : V1;

  return (
    <div className="max-w-5xl mx-auto px-4 py-8">
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Developers</div>
      <h1 className="font-display text-3xl md:text-4xl font-semibold mt-1">Pool API</h1>
      <p className="mt-3 text-sm text-muted-foreground max-w-3xl leading-relaxed">
        Free, open, no API key. Base URL{" "}
        <span className="font-mono text-foreground">{ORIGIN}</span>. Every endpoint returns JSON
        with permissive CORS, so you can call it straight from a browser, a shell script or a rig
        monitor. The legacy yiimp endpoints below are drop-in replacements for the ones on the old
        pool interface — swap the hostname and your tooling keeps working.
      </p>
      <p className="mt-3 text-sm text-muted-foreground max-w-3xl leading-relaxed">
        Miners connect to{" "}
        <span className="font-mono text-foreground">stratum+tcp://stratum.pool.honest.money:3433</span>{" "}
        (scrypt). Chain-level data for TEXITcoin lives in the{" "}
        <a href="/docs" className="text-accent hover:underline">
          explorer API
        </a>
        , and you can read about the TEXITcoin chain and Omni layer 2 at{" "}
        <a
          href="https://texitcoin.org/build"
          target="_blank"
          rel="noreferrer"
          className="text-accent hover:underline"
        >
          texitcoin.org/build
        </a>
        .
      </p>

      <div className="mt-6 inline-flex rounded-md border border-border surface-2 p-1 text-xs">
        <button
          onClick={() => setTab("yiimp")}
          className={`px-3 py-1.5 rounded-sm font-medium transition-colors ${
            tab === "yiimp"
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:text-foreground"
          }`}
        >
          yiimp-compatible
        </button>
        <button
          onClick={() => setTab("v1")}
          className={`px-3 py-1.5 rounded-sm font-medium transition-colors ${
            tab === "v1"
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:text-foreground"
          }`}
        >
          v1 (extended)
        </button>
      </div>

      <div className="mt-6 space-y-4">
        {list.map((e) => (
          <EndpointCard key={e.id} endpoint={e} />
        ))}
      </div>

      <div className="mt-10 rounded-md border border-border surface-2 p-4 text-xs text-muted-foreground leading-relaxed">
        <div className="font-display text-sm text-foreground mb-1">Fair use</div>
        Responses are cached at the edge for 15–30 seconds; please poll no faster than that and
        cache on your side. If you need higher volume or a data mirror, get in touch and we will
        sort it out.
      </div>
    </div>
  );
}

function EndpointCard({ endpoint }: { endpoint: Endpoint }) {
  const [copied, setCopied] = useState(false);
  const url = `${ORIGIN}${endpoint.path}`;

  return (
    <div className="rounded-md border border-border surface-2 overflow-hidden">
      <div className="px-4 py-3 border-b border-border">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-[10px] font-mono px-1.5 py-0.5 rounded-sm bg-primary/15 text-primary">
            {endpoint.method}
          </span>
          <code className="font-mono text-xs text-foreground break-all">{endpoint.path}</code>
          <button
            onClick={() => {
              navigator.clipboard?.writeText(url);
              setCopied(true);
              setTimeout(() => setCopied(false), 1200);
            }}
            className="ml-auto inline-flex items-center gap-1 text-[11px] text-muted-foreground hover:text-foreground"
            aria-label={`Copy ${endpoint.path}`}
          >
            {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
            {copied ? "Copied" : "Copy URL"}
          </button>
        </div>
        <div className="mt-2 text-sm font-medium">{endpoint.title}</div>
        <p className="mt-1 text-xs text-muted-foreground leading-relaxed">{endpoint.desc}</p>
      </div>
      <pre className="px-4 py-3 text-[11px] font-mono overflow-x-auto text-muted-foreground">
        {endpoint.example}
      </pre>
    </div>
  );
}
