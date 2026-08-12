import { createServerFn } from "@tanstack/react-start";

export interface WalletBalance {
  symbol: "DOGE" | "LTC";
  label: string;
  address: string;
  explorer: string;
  balance: number | null;
  received: number | null;
  spent: number | null;
  txCount: number | null;
  lastSeen: string | null;
  error: string | null;
}

export interface WalletBalancesResult {
  wallets: WalletBalance[];
  fetchedAt: number;
}

const WALLETS = [
  {
    symbol: "DOGE" as const,
    label: "DOGE pool hot wallet",
    chain: "dogecoin",
    address: "DJvCw7eu1PBMjp8N99QsLxUohpVq6EEyjU",
    explorer: "https://blockchair.com/dogecoin/address/DJvCw7eu1PBMjp8N99QsLxUohpVq6EEyjU",
  },
  {
    symbol: "LTC" as const,
    label: "LTC pool hot wallet",
    chain: "litecoin",
    address: "LTyp1No4skV378NbYrR7p6d7wRzDCHgFAa",
    explorer: "https://blockchair.com/litecoin/address/LTyp1No4skV378NbYrR7p6d7wRzDCHgFAa",
  },
];

let cache: { at: number; value: WalletBalancesResult } | null = null;
const TTL_MS = 60_000;

async function fetchOne(w: (typeof WALLETS)[number]): Promise<WalletBalance> {
  const base: WalletBalance = {
    symbol: w.symbol,
    label: w.label,
    address: w.address,
    explorer: w.explorer,
    balance: null,
    received: null,
    spent: null,
    txCount: null,
    lastSeen: null,
    error: null,
  };
  try {
    const res = await fetch(
      `https://api.blockchair.com/${w.chain}/dashboards/address/${w.address}?limit=0`,
      { headers: { accept: "application/json" } },
    );
    if (!res.ok) {
      return { ...base, error: `explorer ${res.status}` };
    }
    const json = (await res.json()) as {
      data?: Record<string, { address?: Record<string, unknown> }>;
    };
    const a = json.data?.[w.address]?.address;
    if (!a) return { ...base, error: "no data for address" };
    const num = (v: unknown) => (typeof v === "number" ? v : null);
    const div = (v: number | null) => (v === null ? null : v / 1e8);
    return {
      ...base,
      balance: div(num(a["balance"])),
      received: div(num(a["received"])),
      spent: div(num(a["spent"])),
      txCount: num(a["transaction_count"]),
      lastSeen: typeof a["last_seen_receiving"] === "string" ? a["last_seen_receiving"] : null,
    };
  } catch (e) {
    return { ...base, error: e instanceof Error ? e.message : "fetch failed" };
  }
}

export const getWalletBalances = createServerFn({ method: "GET" }).handler(
  async (): Promise<WalletBalancesResult> => {
    if (cache && Date.now() - cache.at < TTL_MS) return cache.value;
    const wallets = await Promise.all(WALLETS.map(fetchOne));
    const value: WalletBalancesResult = { wallets, fetchedAt: Math.floor(Date.now() / 1000) };
    cache = { at: Date.now(), value };
    return value;
  },
);
