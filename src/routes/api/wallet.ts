import { createFileRoute } from "@tanstack/react-router";
import { optionsHandler, jsonResponse, errorResponse } from "@/lib/api/cors";
import { poolFetch } from "@/lib/api/pool-upstream";

const ADDR_RE = /^[a-zA-Z0-9]{20,120}$/;

interface MinerSummary {
  address: string;
  balance: number;
  pending: number;
  paid: number;
  algos: Array<{
    algo: string;
    workers_online: number;
    hashrate: number;
    last_share: number | null;
  }>;
}

interface Payouts {
  payouts: Array<{ amount: number; time: number; symbol: string | null; tx: string | null }>;
}

export interface WalletBody {
  unsold: number;
  balance: number;
  unpaid: number;
  paid24h: number;
  total: number;
}

/** Shared yiimp-compatible wallet payload builder, used by /api/wallet and /api/walletEx. */
export async function buildWallet(address: string): Promise<{
  wallet: WalletBody;
  miner: MinerSummary;
}> {
  const miner = await poolFetch<MinerSummary>(`/api/v1/miner/${encodeURIComponent(address)}`);
  let paid24h = 0;
  try {
    const p = await poolFetch<Payouts>(`/api/v1/miner/${encodeURIComponent(address)}/payouts?limit=200`);
    const cutoff = Math.floor(Date.now() / 1000) - 86_400;
    paid24h = p.payouts
      .filter((r) => Number(r.time) >= cutoff)
      .reduce((s, r) => s + Number(r.amount ?? 0), 0);
  } catch {
    paid24h = 0;
  }
  const balance = Number(miner.balance ?? 0);
  const unpaid = Number(miner.pending ?? 0) || balance;
  return {
    wallet: {
      unsold: 0,
      balance,
      unpaid,
      paid24h,
      total: balance + unpaid,
    },
    miner,
  };
}

export function readAddress(request: Request): string | null {
  const addr = new URL(request.url).searchParams.get("address")?.trim() ?? "";
  return ADDR_RE.test(addr) ? addr : null;
}

/** yiimp-compatible GET /api/wallet?address=ADDR */
export const Route = createFileRoute("/api/wallet")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ request }) => {
        const address = readAddress(request);
        if (!address) return errorResponse("missing or invalid address", 400);
        try {
          const { wallet } = await buildWallet(address);
          return jsonResponse(wallet, {
            headers: { "Cache-Control": "public, max-age=15, s-maxage=15" },
          });
        } catch (e) {
          const msg = (e as Error).message;
          return errorResponse(msg, /404/.test(msg) ? 404 : 502);
        }
      },
    },
  },
});
