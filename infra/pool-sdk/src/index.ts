/**
 * @honestmoney/pool-sdk
 *
 * TypeScript client for the honest.money pool API.
 * Works in Node 18+ and modern browsers (uses fetch + EventSource).
 *
 *   const pool = new PoolClient();
 *   const summary = await pool.getSummary();
 *   pool.stream({ onBlockFound: (b) => console.log(b) });
 */

export const DEFAULT_BASE_URL = "https://api.stratum.pool.honest.money";

export type Window = "1h" | "24h" | "7d" | "30d";

export interface PoolBlock {
  height: number;
  blockhash: string;
  amount: number;
  difficulty: number;
  time: number;
  confirmations: number;
  category: string;
  algo: string;
  symbol: string;
  name: string;
}

export interface StratumLive {
  algo: string;
  clients: number;
  active: number;
  accepted_ghs: number;
  valid: number;
  invalid: number;
  stales: number;
  updated_at: number;
}

export interface PoolSummary {
  algos: unknown[];
  stratum_live: Record<string, StratumLive>;
  last_blocks: unknown[];
  blocks_24h_by_symbol: Record<string, number>;
  blocks_24h_pool_found: number;
  effort: { symbol: string; network_difficulty: number; effort_pct: number }[];
  fetched_at: number;
}

export interface MergedMiningRound {
  primary: { symbol: string; height: number; hash: string; time: number; amount: number };
  auxpow_credited: { symbol: string; height: number; hash: string; amount: number }[];
}

export interface StreamHandlers {
  onHello?: (msg: { time: number; version: string }) => void;
  onBlockFound?: (b: {
    algo: string;
    symbol: string;
    height: number;
    hash: string;
    time: number;
  }) => void;
  onHashrateTick?: (t: {
    algo: string;
    clients: number;
    accepted_ghs: number;
    time: number;
  }) => void;
  onError?: (err: unknown) => void;
}

export class PoolClient {
  constructor(private readonly baseUrl: string = DEFAULT_BASE_URL) {}

  private async json<T>(path: string): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new Error(`${path} ${res.status}: ${await res.text().catch(() => "")}`);
    return (await res.json()) as T;
  }

  health() {
    return this.json<{ ok: boolean; db: boolean; uptime: number; version: string }>(
      "/api/v1/health",
    );
  }

  getCoins() {
    return this.json<{ coins: unknown[] }>("/api/v1/coins");
  }

  getCoin(symbol: string) {
    return this.json<{ coin: unknown }>(`/api/v1/coins/${encodeURIComponent(symbol)}`);
  }

  getSummary() {
    return this.json<PoolSummary>("/api/v1/pool/summary");
  }

  getPoolHashrate(window: Window = "24h", algo = "scrypt") {
    return this.json<{ points: { time: number; hashrate: number }[] }>(
      `/api/v1/pool/hashrate?window=${window}&algo=${algo}`,
    );
  }

  getEffort() {
    return this.json<{ effort: PoolSummary["effort"] }>("/api/v1/pool/effort");
  }

  getBlocks(opts: { coin?: string; algo?: string; limit?: number } = {}) {
    const q = new URLSearchParams();
    if (opts.coin) q.set("coin", opts.coin);
    if (opts.algo) q.set("algo", opts.algo);
    if (opts.limit) q.set("limit", String(opts.limit));
    return this.json<{ blocks: PoolBlock[] }>(
      `/api/v1/blocks${q.toString() ? "?" + q : ""}`,
    );
  }

  getMergedMiningRounds(window: Window = "24h") {
    return this.json<{ rounds: MergedMiningRound[] }>(
      `/api/v1/mergedmining/summary?window=${window}`,
    );
  }

  getMinerCount() {
    return this.json<{
      by_algo: Record<string, StratumLive>;
      totals: { clients: number; active: number; accepted_ghs: number };
    }>("/api/v1/miners/count");
  }

  getTopMiners(limit = 50) {
    return this.json<{ miners: unknown[] }>(`/api/v1/miners/top?limit=${limit}`);
  }

  getLocations() {
    return this.json<{
      locations: { country: string; region: string; miner_count: number; hashrate: number }[];
    }>("/api/v1/miners/locations");
  }

  getMiner(address: string) {
    return this.json(`/api/v1/miner/${encodeURIComponent(address)}`);
  }

  getMinerWorkers(address: string) {
    return this.json(`/api/v1/miner/${encodeURIComponent(address)}/workers`);
  }

  getMinerHashrate(address: string, window: Window = "24h") {
    return this.json(
      `/api/v1/miner/${encodeURIComponent(address)}/hashrate?window=${window}`,
    );
  }

  getMinerPayouts(address: string, limit = 50) {
    return this.json(
      `/api/v1/miner/${encodeURIComponent(address)}/payouts?limit=${limit}`,
    );
  }

  getMinerEarnings(address: string, limit = 100) {
    return this.json(
      `/api/v1/miner/${encodeURIComponent(address)}/earnings?limit=${limit}`,
    );
  }

  /**
   * Subscribe to the realtime SSE stream. Returns a cleanup function.
   *
   * In browsers this uses the global EventSource. In Node 18+ it uses the
   * built-in EventSource (Node 22+) or falls back to fetch + ReadableStream.
   */
  stream(handlers: StreamHandlers): () => void {
    const url = `${this.baseUrl}/api/v1/stream`;
    const ES: typeof EventSource | undefined =
      (globalThis as unknown as { EventSource?: typeof EventSource }).EventSource;
    if (ES) {
      const es = new ES(url);
      es.addEventListener("hello", (e) =>
        handlers.onHello?.(JSON.parse((e as MessageEvent).data)),
      );
      es.addEventListener("block-found", (e) =>
        handlers.onBlockFound?.(JSON.parse((e as MessageEvent).data)),
      );
      es.addEventListener("hashrate-tick", (e) =>
        handlers.onHashrateTick?.(JSON.parse((e as MessageEvent).data)),
      );
      es.onerror = (e) => handlers.onError?.(e);
      return () => es.close();
    }
    // Fallback: fetch + reader (Node 18+, browsers where EventSource is disabled).
    const controller = new AbortController();
    void (async () => {
      try {
        const res = await fetch(url, {
          headers: { Accept: "text/event-stream" },
          signal: controller.signal,
        });
        if (!res.body) throw new Error("no body");
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          let idx;
          while ((idx = buf.indexOf("\n\n")) !== -1) {
            const frame = buf.slice(0, idx);
            buf = buf.slice(idx + 2);
            const lines = frame.split("\n");
            let event = "message";
            let data = "";
            for (const l of lines) {
              if (l.startsWith("event:")) event = l.slice(6).trim();
              else if (l.startsWith("data:")) data += l.slice(5).trim();
            }
            try {
              const payload = data ? JSON.parse(data) : {};
              if (event === "block-found") handlers.onBlockFound?.(payload);
              else if (event === "hashrate-tick") handlers.onHashrateTick?.(payload);
              else if (event === "hello") handlers.onHello?.(payload);
            } catch (e) {
              handlers.onError?.(e);
            }
          }
        }
      } catch (e) {
        handlers.onError?.(e);
      }
    })();
    return () => controller.abort();
  }
}
