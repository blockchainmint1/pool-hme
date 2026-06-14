// Tiny JSON-RPC client for texitcoind. Uses fetch with HTTP basic auth.
// We deliberately avoid the heavy bitcoin-core npm clients — TexitCoin uses
// the same RPC surface as Bitcoin Core but we only need a handful of calls.

const RPC_URL = process.env.RPC_URL ?? "http://host.docker.internal:15739";
const RPC_USER = process.env.RPC_USER ?? "";
const RPC_PASS = process.env.RPC_PASSWORD ?? "";
const RPC_TIMEOUT_MS = Number(process.env.RPC_TIMEOUT_MS ?? 60_000);

const AUTH = "Basic " + Buffer.from(`${RPC_USER}:${RPC_PASS}`).toString("base64");

let nextId = 1;

export class RpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  const id = nextId++;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), RPC_TIMEOUT_MS);
  try {
    const res = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: AUTH },
      body: JSON.stringify({ jsonrpc: "1.0", id, method, params }),
      signal: ctrl.signal,
    });
    if (!res.ok && res.status !== 500) {
      throw new RpcError(res.status, `HTTP ${res.status} from ${method}`);
    }
    const body = (await res.json()) as { result: T; error: { code: number; message: string } | null };
    if (body.error) throw new RpcError(body.error.code, body.error.message);
    return body.result;
  } finally {
    clearTimeout(timer);
  }
}

// ---- Typed helpers for the calls we actually use ----

export interface RpcVin {
  txid?: string;
  vout?: number;
  coinbase?: string;
  sequence: number;
  scriptSig?: { asm: string; hex: string };
  txinwitness?: string[];
}
export interface RpcVout {
  value: number; // TXC (not sats)
  n: number;
  scriptPubKey: {
    asm: string;
    hex: string;
    type: string;
    address?: string;
    addresses?: string[];
  };
}
export interface RpcTx {
  txid: string;
  hash: string;
  version: number;
  size: number;
  vsize: number;
  weight: number;
  locktime: number;
  vin: RpcVin[];
  vout: RpcVout[];
  hex: string;
  blockhash?: string;
  confirmations?: number;
  time?: number;
  blocktime?: number;
}
export interface RpcBlock {
  hash: string;
  confirmations: number;
  height: number;
  version: number;
  versionHex: string;
  merkleroot: string;
  time: number;
  mediantime: number;
  nonce: number;
  bits: string;
  difficulty: number;
  previousblockhash?: string;
  nextblockhash?: string;
  size: number;
  weight: number;
  nTx: number;
  tx: RpcTx[]; // when verbosity=2
}

export const getBlockCount = () => rpc<number>("getblockcount");
export const getBlockHash = (h: number) => rpc<string>("getblockhash", [h]);
export const getBlockVerbose = (hash: string) => rpc<RpcBlock>("getblock", [hash, 2]);
export const getRawTx = (txid: string) => rpc<RpcTx>("getrawtransaction", [txid, true]);
export const getRawMempool = () => rpc<string[]>("getrawmempool");

export function voutAddress(v: RpcVout): string | null {
  if (v.scriptPubKey.address) return v.scriptPubKey.address;
  const arr = v.scriptPubKey.addresses;
  if (arr && arr.length === 1) return arr[0];
  return null;
}

// TXC → sats. RPC returns floating-point TXC; round to satoshis.
export function txcToSats(v: number): number {
  return Math.round(v * 1e8);
}
