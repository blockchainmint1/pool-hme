import { TXC_NETWORK } from "./network";

const SATS = TXC_NETWORK.satsPerCoin;

export function satsToTxc(sats: number): string {
  if (sats === 0) return "0";
  const sign = sats < 0 ? "-" : "";
  const abs = Math.abs(sats);
  const whole = Math.floor(abs / SATS);
  const frac = abs % SATS;
  if (frac === 0) return `${sign}${whole.toLocaleString()}`;
  const fracStr = frac.toString().padStart(8, "0").replace(/0+$/, "");
  return `${sign}${whole.toLocaleString()}.${fracStr}`;
}

export function formatTxc(sats: number, suffix = " TXC"): string {
  return `${satsToTxc(sats)}${suffix}`;
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(2)} kB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

export function formatVB(vsize: number): string {
  if (vsize < 1000) return `${vsize} vB`;
  return `${(vsize / 1000).toFixed(2)} kvB`;
}

export function formatNumber(n: number): string {
  return n.toLocaleString();
}

export function shortHash(h: string, head = 8, tail = 8): string {
  if (!h) return "";
  if (h.length <= head + tail + 3) return h;
  return `${h.slice(0, head)}…${h.slice(-tail)}`;
}

export function timeAgo(unixSec: number | undefined | null): string {
  if (!unixSec) return "—";
  const diff = Math.max(0, Math.floor(Date.now() / 1000 - unixSec));
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

export function formatDateTime(unixSec: number | undefined | null): string {
  if (!unixSec) return "—";
  const d = new Date(unixSec * 1000);
  return d.toLocaleString();
}

export function feeBucket(satPerVb: number): 1 | 2 | 3 | 4 | 5 | 6 {
  if (satPerVb < 2) return 1;
  if (satPerVb < 5) return 2;
  if (satPerVb < 10) return 3;
  if (satPerVb < 25) return 4;
  if (satPerVb < 50) return 5;
  return 6;
}

export function feeColorVar(satPerVb: number): string {
  return `var(--color-fee-${feeBucket(satPerVb)})`;
}

/** Classify an input string as block height, hash, txid, or TXC address. */
export type SearchKind = "height" | "hash" | "txid" | "address" | "unknown";
export function classifySearch(raw: string): SearchKind {
  const s = raw.trim();
  if (!s) return "unknown";
  if (/^\d+$/.test(s)) return "height";
  if (/^[0-9a-fA-F]{64}$/.test(s)) {
    // Could be a block hash OR a txid — both 32-byte hex. Block hashes
    // typically begin with several leading zeros; if so, treat as a hash.
    // Otherwise the caller should try tx first, then block.
    return s.startsWith("0000") ? "hash" : "txid";
  }
  if (/^T[1-9A-HJ-NP-Za-km-z]{25,40}$/.test(s)) return "address";
  // bech32 segwit (e.g. txc1q…) — HRP + "1" + data chars from bech32 alphabet
  if (/^txc1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,100}$/i.test(s)) return "address";
  return "unknown";
}
