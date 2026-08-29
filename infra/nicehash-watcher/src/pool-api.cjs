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
    if (!hs) throw new Error(`PoolAPI: scrypt hashrate not found in summary`);
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
}

module.exports = { PoolAPI };
