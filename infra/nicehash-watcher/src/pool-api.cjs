/**
 * pool-api.cjs — reads live pool hashrate and the 7-day average from the
 * yiimp-api service running on (or reachable from) the stratum box.
 *
 *   GET {POOL_API_BASE}/api/v1/pool/summary          -> { algos: [{algo, hashrate_hs}] }
 *   GET {POOL_API_BASE}/api/v1/pool/hashrate?window=7d&algo=scrypt
 *        -> { points: [{ time, hashrate, earnings }] }  (hashrate in H/s)
 */
"use strict";

class PoolAPI {
  constructor(base) {
    this.base = (base || "").replace(/\/$/, "");
  }

  async _get(path) {
    const res = await fetch(this.base + path, {
      headers: { "User-Agent": "honest-money-nicehash-watcher/1.0" },
      signal: AbortSignal.timeout(10000),
    });
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`PoolAPI ${path} -> ${res.status}: ${text.slice(0, 300)}`);
    }
    return text ? JSON.parse(text) : null;
  }

  /** Current scrypt hashrate in TH/s. */
  async currentHashrateThs(algo = "scrypt") {
    const data = await this._get("/api/v1/pool/hashrate/current");
    const algos = data.algos || [];
    const a =
      algos.find((x) => String(x.algo).toLowerCase() === algo) ||
      algos.find((x) => String(x.algo).toLowerCase() === "scrypt");
    if (!a || !a.reliable) {
      throw new Error(`PoolAPI: current scrypt sample is missing or unreliable`);
    }
    const hs = Number(a.hashrate_hs || 0);
    if (!hs) throw new Error(`PoolAPI: scrypt hashrate not found in current sample`);
    return hs / 1e12;
  }

  /** 7-day average hashrate in TH/s (averaged over the 7d series points). */
  async avg7dHashrateThs(algo = "scrypt") {
    const data = await this._get(
      `/api/v1/pool/hashrate?window=7d&algo=${encodeURIComponent(algo)}`,
    );
    const pts = data.points || [];
    if (!pts.length) return 0;
    const sum = pts.reduce((acc, p) => acc + Number(p.hashrate || 0), 0);
    return sum / pts.length / 1e12;
  }

  /**
   * Seconds since the last block found for a coin symbol (TXC, ISK, ...).
   * Returns null if the call fails or no block is found.
   * Uses the yiimp-api /api/v1/coins/:symbol/blocks endpoint, which returns
   * blocks newest-first with a unix-epoch `time` column.
   */
  async lastBlockAgeSec(symbol = "TXC") {
    const data = await this._get(
      `/api/v1/coins/${encodeURIComponent(symbol)}/blocks?limit=1`,
    );
    const block = (data.blocks || [])[0];
    if (!block || block.time == null) return null;
    const now = Math.floor(Date.now() / 1000);
    const age = now - Number(block.time);
    return Number.isFinite(age) && age >= 0 ? age : null;
  }
}

module.exports = { PoolAPI };
