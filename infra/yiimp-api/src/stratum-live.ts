/**
 * Stratum live-state tailer.
 *
 * The yiimp `workers` MySQL table keeps stale rows for hours after a miner
 * disconnects, which is why /api/pool/stats reports a made-up miner count.
 * The truth is the "summary diag" line each stratum daemon writes to its
 * log every minute:
 *
 *   05:43:36: SCRYPT summary diag clients=380 active=0 accepted_ghs=0.000 valid=0 invalid=0 stales=0 ...
 *
 * We tail every ${algo}.log in STRATUM_LOG_DIR, parse the last summary line,
 * cache the parsed value for 30s, and expose it as a real number.
 *
 * The same tailer is the source for the SSE stream (/api/v1/stream): new
 * "block found ..." and "share accepted ..." lines get fanned out to
 * subscribers with backpressure (bounded per-connection queue, drop oldest).
 */
import { promises as fs, watch } from "node:fs";
import path from "node:path";
import { EventEmitter } from "node:events";

const STRATUM_LOG_DIR = process.env.STRATUM_LOG_DIR ?? "";
// Which algos to look for. We only run scrypt in prod today, but pawelhash
// is wired so a future rollout is a config change, not a code change.
const ALGOS = (process.env.STRATUM_ALGOS ?? "scrypt,pawelhash")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

export interface StratumLive {
  algo: string;
  clients: number;
  active: number;
  accepted_ghs: number;
  valid: number;
  invalid: number;
  stales: number;
  updated_at: number; // unix seconds
}

interface CacheEntry {
  value: StratumLive;
  fetchedAt: number;
}

const cache = new Map<string, CacheEntry>();
const CACHE_MS = 30_000;

export const stratumEvents = new EventEmitter();
stratumEvents.setMaxListeners(1000);

/** Return { scrypt: {...}, pawelhash: {...} } for all algos that have a log. */
export async function getStratumLive(): Promise<Record<string, StratumLive>> {
  if (!STRATUM_LOG_DIR) return {};
  const out: Record<string, StratumLive> = {};
  await Promise.all(
    ALGOS.map(async (algo) => {
      const cached = cache.get(algo);
      const now = Date.now();
      if (cached && now - cached.fetchedAt < CACHE_MS) {
        out[algo] = cached.value;
        return;
      }
      const parsed = await readSummary(algo);
      if (parsed) {
        cache.set(algo, { value: parsed, fetchedAt: now });
        out[algo] = parsed;
      } else if (cached) {
        out[algo] = cached.value;
      }
    }),
  );
  return out;
}

async function readSummary(algo: string): Promise<StratumLive | null> {
  try {
    const p = path.join(STRATUM_LOG_DIR, `${algo}.log`);
    const buf = await tailFile(p, 32 * 1024);
    const line = lastMatch(buf, /summary diag[^\n]+/gi);
    if (!line) return null;
    const kv: Record<string, string> = {};
    for (const m of line.matchAll(/(\w+)=([-+]?[\d.]+)/g)) kv[m[1]] = m[2];
    return {
      algo,
      clients: intOr(kv.clients, 0),
      active: intOr(kv.active, 0),
      accepted_ghs: floatOr(kv.accepted_ghs, 0),
      valid: intOr(kv.valid, 0),
      invalid: intOr(kv.invalid, 0),
      stales: intOr(kv.stales, 0),
      updated_at: Math.floor(Date.now() / 1000),
    };
  } catch {
    return null;
  }
}

async function tailFile(p: string, bytes: number): Promise<string> {
  const fh = await fs.open(p, "r");
  try {
    const stat = await fh.stat();
    const start = Math.max(0, stat.size - bytes);
    const len = stat.size - start;
    const b = Buffer.alloc(len);
    await fh.read(b, 0, len, start);
    return b.toString("utf8");
  } finally {
    await fh.close();
  }
}

function lastMatch(hay: string, re: RegExp): string | null {
  let last: string | null = null;
  for (const m of hay.matchAll(re)) last = m[0];
  return last;
}

function intOr(v: string | undefined, d: number) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.floor(n) : d;
}
function floatOr(v: string | undefined, d: number) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

// ---------------------------------------------------------------------------
// Log-tailing fan-out. Lightweight — we only look at lines added since we
// last read. Emits typed events other modules can subscribe to.
// ---------------------------------------------------------------------------

const offsets = new Map<string, number>();

/** Start watching every ${algo}.log. Safe to call once at boot. */
export function startStratumWatch() {
  if (!STRATUM_LOG_DIR) return;
  for (const algo of ALGOS) {
    const p = path.join(STRATUM_LOG_DIR, `${algo}.log`);
    // Initial offset = current EOF, so we only surface *new* activity.
    fs.stat(p)
      .then((s) => offsets.set(p, s.size))
      .catch(() => offsets.set(p, 0));
    try {
      watch(p, { persistent: false }, () => {
        void drain(algo, p);
      });
    } catch {
      // File may not exist yet — that's fine.
    }
    // Also poll every 5s in case fs.watch misses events (common on ext4).
    setInterval(() => void drain(algo, p), 5_000).unref();
  }
}

async function drain(algo: string, p: string) {
  try {
    const stat = await fs.stat(p);
    const prev = offsets.get(p) ?? stat.size;
    if (stat.size < prev) {
      // Log rotated.
      offsets.set(p, 0);
      return;
    }
    if (stat.size === prev) return;
    const fh = await fs.open(p, "r");
    try {
      const len = stat.size - prev;
      const buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, prev);
      offsets.set(p, stat.size);
      for (const line of buf.toString("utf8").split("\n")) {
        if (!line) continue;
        emitFromLine(algo, line);
      }
    } finally {
      await fh.close();
    }
  } catch {
    // File gone / not created yet — try again next tick.
  }
}

function emitFromLine(algo: string, line: string) {
  // block found <coin> height <n> hash <h> ...
  const blk = /block\s+found\s+(\w+)\s+height\s+(\d+)\s+hash\s+([0-9a-fA-F]+)/i.exec(
    line,
  );
  if (blk) {
    stratumEvents.emit("block-found", {
      algo,
      symbol: blk[1].toUpperCase(),
      height: Number(blk[2]),
      hash: blk[3],
      time: Math.floor(Date.now() / 1000),
    });
    return;
  }
  // summary diag: emit a hashrate tick
  if (/summary diag/i.test(line)) {
    const kv: Record<string, string> = {};
    for (const m of line.matchAll(/(\w+)=([-+]?[\d.]+)/g)) kv[m[1]] = m[2];
    stratumEvents.emit("hashrate-tick", {
      algo,
      clients: intOr(kv.clients, 0),
      accepted_ghs: floatOr(kv.accepted_ghs, 0),
      time: Math.floor(Date.now() / 1000),
    });
  }
}
