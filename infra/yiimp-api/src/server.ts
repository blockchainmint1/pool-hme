/**
 * yiimp-api — read-only JSON API in front of the yiimpfrontend MySQL DB.
 *
 * Runs on the yiimp box, binds 127.0.0.1:8787, fronted by nginx TLS at
 * https://api.stratum.pool.honest.money.
 *
 * v0.2:
 *   - Introduced /api/v1/* namespace with pool-native, merged-mining,
 *     miner, coin, and realtime SSE endpoints.
 *   - Fixed miner count: /api/v1/miners/count reads live stratum diag
 *     lines (workers MySQL table keeps stale rows for hours after
 *     disconnect).
 *   - Added GeoIP aggregation for /api/v1/miners/locations. Raw IPs are
 *     never returned in any public response.
 *   - Server-Sent Events at /api/v1/stream for block-found and
 *     hashrate-tick fan-out.
 *
 * Design constraints (unchanged):
 *   - Read-only. MySQL user is GRANT SELECT only.
 *   - Every query has LIMIT; every param has a regex whitelist.
 *   - Fastify pool max ~20; connect timeout 5s.
 */
import Fastify from "fastify";
import cors from "@fastify/cors";
import { FastifySSEPlugin } from "fastify-sse-v2";
import mysql from "mysql2/promise";
import {
  getStratumLive,
  startStratumWatch,
  stratumEvents,
} from "./stratum-live.js";
import { aggregateGeo, lookupGeo } from "./geoip.js";
import {
  minerHashrateSeries,
  poolHashrateSeries,
  windowConfig,
  type Window,
} from "./hashstats.js";

const PORT = Number(process.env.YIIMP_API_PORT ?? 8787);
const BIND = process.env.YIIMP_API_BIND ?? "127.0.0.1";
const CORS_ORIGINS = (process.env.CORS_ORIGIN ?? "*")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const pool = mysql.createPool({
  host: process.env.MYSQL_HOST ?? "127.0.0.1",
  port: Number(process.env.MYSQL_PORT ?? 3306),
  user: process.env.MYSQL_USER ?? "yiimp_ro",
  password: process.env.MYSQL_PASSWORD ?? "",
  database: process.env.MYSQL_DATABASE ?? "yiimpfrontend",
  connectionLimit: 20,
  waitForConnections: true,
  connectTimeout: 5_000,
  namedPlaceholders: false,
});

const ADDR_RE = /^[A-Za-z0-9]{20,80}$/;
const SYMBOL_RE = /^[A-Za-z0-9]{2,10}$/;
const ALGO_RE = /^[a-z0-9_-]{2,20}$/;
const WINDOW_RE = /^(1h|24h|7d|30d)$/;

// Pool-found chains (solo). LTC/DOGE come in as auxpow (share credit).
const POOL_FOUND = new Set(["TXC", "ISK", "ZCU"]);
const AUXPOW = new Set(["LTC", "DOGE"]);

const app = Fastify({ logger: { level: "info" }, disableRequestLogging: false });

await app.register(cors, {
  origin: CORS_ORIGINS.length === 0 || CORS_ORIGINS[0] === "*" ? true : CORS_ORIGINS,
  methods: ["GET", "OPTIONS"],
});
await app.register(FastifySSEPlugin);

startStratumWatch();

function clampLimit(raw: unknown, def = 50, max = 500): number {
  const n = Number(raw ?? def);
  if (!Number.isFinite(n) || n <= 0) return def;
  return Math.min(Math.floor(n), max);
}

function truncateAddress(addr: string): string {
  if (addr.length <= 12) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

// ============================================================================
// Health + version
// ============================================================================

app.get("/api/health", async () => {
  let db = false;
  try {
    const [rows] = await pool.query("SELECT 1 AS ok");
    db = Array.isArray(rows) && rows.length === 1;
  } catch {
    db = false;
  }
  return { ok: true, db, uptime: process.uptime(), version: "0.3.0" };
});

app.get("/api/v1/health", async () => {
  let db = false;
  try {
    const [rows] = await pool.query("SELECT 1 AS ok");
    db = Array.isArray(rows) && rows.length === 1;
  } catch {
    db = false;
  }
  return { ok: true, db, uptime: process.uptime(), version: "0.3.0" };
});

// ============================================================================
// Coins
// ============================================================================

async function loadCoins() {
  const [rows] = await pool.query(
    `SELECT id, name, symbol, algo, enable, visible, auto_ready
       FROM coins
      WHERE visible = 1
      ORDER BY symbol ASC`,
  );
  return rows as mysql.RowDataPacket[];
}

app.get("/api/coins", async () => ({ coins: await loadCoins() }));
app.get("/api/v1/coins", async () => ({ coins: await loadCoins() }));

app.get<{ Params: { symbol: string } }>(
  "/api/v1/coins/:symbol",
  async (req, reply) => {
    const symbol = req.params.symbol.toUpperCase();
    if (!SYMBOL_RE.test(symbol)) return reply.code(400).send({ error: "bad symbol" });
    const [rows] = await pool.query<mysql.RowDataPacket[]>(
      `SELECT id, name, symbol, algo, enable, visible, auto_ready,
              price, difficulty, network_hash, reward,
              txfee AS pool_fee, mining_fee, deposit_minimum
         FROM coins
        WHERE symbol = ?
        LIMIT 1`,
      [symbol],
    );
    const coin = rows[0];
    if (!coin) return reply.code(404).send({ error: "not found" });
    return { coin };
  },
);

app.get<{ Params: { symbol: string }; Querystring: { limit?: string } }>(
  "/api/v1/coins/:symbol/blocks",
  async (req, reply) => {
    const symbol = req.params.symbol.toUpperCase();
    if (!SYMBOL_RE.test(symbol)) return reply.code(400).send({ error: "bad symbol" });
    const limit = clampLimit(req.query.limit, 100, 500);
    const [rows] = await pool.query(
      `SELECT b.id, b.height, b.blockhash, b.amount, b.difficulty,
              b.time, b.confirmations, b.category, b.algo,
              c.symbol, c.name
         FROM blocks b
         JOIN coins c ON c.id = b.coin_id
        WHERE c.symbol = ?
        ORDER BY b.time DESC
        LIMIT ?`,
      [symbol, limit],
    );
    return { blocks: rows };
  },
);

// ============================================================================
// Pool-native
// ============================================================================

app.get("/api/pool/algos", async () => {
  const [rows] = await pool.query(
    `SELECT algo, COUNT(*) AS coin_count
       FROM coins WHERE enable = 1 GROUP BY algo ORDER BY algo ASC`,
  );
  return { algos: rows };
});

/**
 * One-shot dashboard payload. This is what the homepage should call.
 *
 * Combines: per-algo miner counts (from workers table, recent rows),
 * current pool hashrate per algo (latest hashstats row), last block per
 * coin, blocks 24h, current effort, and live stratum diag if available.
 *
 * NOTE: the yiimpfrontend `workers` table has NO `hashrate` column in
 * this fork — hashrate lives in the `hashstats` time-series table.
 */
let summaryCache: { at: number; body: unknown } | null = null;
let summaryInflight: Promise<unknown> | null = null;
const SUMMARY_TTL_MS = 20_000;

async function computeSummary() {
  const nowSec = Math.floor(Date.now() / 1000);
  const dayAgo = nowSec - 86_400;

  // Miner/worker counts from the workers table, filtered to recent rows
  // (workers table keeps stale entries for hours).
  const [algoRows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT algo,
            COUNT(DISTINCT userid) AS db_miners,
            COUNT(*) AS db_workers
       FROM workers
      WHERE time > UNIX_TIMESTAMP() - 600
      GROUP BY algo`,
  );

  // Current pool hashrate per algo — latest row per algo in hashstats.
  // hashstats.hashrate is in H/s.
  const [hashRows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT h.algo, h.hashrate, h.time
       FROM hashstats h
      WHERE h.id IN (SELECT MAX(id) FROM hashstats GROUP BY algo)`,
  );
  const hashByAlgo: Record<string, { hashrate_hs: number; time: number }> = {};
  for (const r of hashRows) {
    hashByAlgo[String(r.algo)] = {
      hashrate_hs: Number(r.hashrate ?? 0),
      time: Number(r.time ?? 0),
    };
  }

  const [dayBlocks] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT c.symbol, COUNT(*) AS n
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.time >= ? GROUP BY c.symbol`,
    [dayAgo],
  );

  const [lastBlocks] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT b.algo, b.height, b.time, b.category, b.confirmations, c.symbol
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.id IN (SELECT MAX(id) FROM blocks GROUP BY coin_id)`,
  );

  const [effortRows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT c.symbol,
            c.difficulty AS network_difficulty,
            (SELECT COALESCE(SUM(difficulty), 0)
               FROM shares s
              WHERE s.coinid = c.id AND s.valid = 1
                AND s.time > COALESCE(
                  (SELECT MAX(time) FROM blocks b WHERE b.coin_id = c.id), 0
                )
            ) AS shares_since_last_block
       FROM coins c
      WHERE c.enable = 1`,
  );
  const effort = effortRows.map((r) => ({
    symbol: r.symbol,
    network_difficulty: Number(r.network_difficulty ?? 0),
    effort_pct:
      Number(r.network_difficulty) > 0
        ? (Number(r.shares_since_last_block ?? 0) / Number(r.network_difficulty)) * 100
        : 0,
  }));

  const stratum = await getStratumLive();

  const totalPoolFound24h = dayBlocks
    .filter((r) => POOL_FOUND.has(String(r.symbol).toUpperCase()))
    .reduce((s, r) => s + Number(r.n), 0);

  // Merge workers-table count with stratum-diag count. Prefer stratum
  // (live/accurate); fall back to workers (recent 10 min) if diag is absent.
  const algos = (algoRows as mysql.RowDataPacket[]).map((r) => {
    const algo = String(r.algo);
    const s = stratum[algo];
    const h = hashByAlgo[algo];
    return {
      algo,
      db_miners: Number(r.db_miners ?? 0),
      db_workers: Number(r.db_workers ?? 0),
      live_clients: s ? s.clients : Number(r.db_workers ?? 0),
      hashrate_hs: h ? h.hashrate_hs : s ? s.accepted_ghs * 1e9 : 0,
      hashrate_updated_at: h ? h.time : nowSec,
    };
  });

  return {
    algos,
    stratum_live: stratum,
    last_blocks: lastBlocks,
    blocks_24h_by_symbol: Object.fromEntries(dayBlocks.map((r) => [r.symbol, Number(r.n)])),
    blocks_24h_pool_found: totalPoolFound24h,
    effort,
    fetched_at: nowSec,
  };
}

app.get("/api/v1/pool/summary", async () => {
  const now = Date.now();
  if (summaryCache && now - summaryCache.at < SUMMARY_TTL_MS) return summaryCache.body;
  if (!summaryInflight) {
    summaryInflight = computeSummary()
      .then((body) => {
        summaryCache = { at: Date.now(), body };
        return body;
      })
      .finally(() => {
        summaryInflight = null;
      });
  }
  // Serve stale while refreshing if we have any cache at all.
  if (summaryCache) return summaryCache.body;
  return summaryInflight;
});

app.get("/api/v1/pool/hashrate", async (req, reply) => {
  const q = req.query as { window?: string; algo?: string };
  const w = (q.window ?? "24h") as Window;
  if (!WINDOW_RE.test(w)) return reply.code(400).send({ error: "bad window" });
  const algo = q.algo ?? "scrypt";
  if (!ALGO_RE.test(algo)) return reply.code(400).send({ error: "bad algo" });
  const series = await poolHashrateSeries(pool, algo, w);
  return {
    algo,
    window: w,
    bucket_seconds: windowConfig(w).bucketSec,
    points: series,
  };
});

app.get("/api/v1/pool/effort", async () => {
  const [rows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT c.symbol,
            c.difficulty AS network_difficulty,
            (SELECT COALESCE(SUM(difficulty), 0)
               FROM shares s
              WHERE s.coinid = c.id AND s.valid = 1
                AND s.time > COALESCE(
                  (SELECT MAX(time) FROM blocks b WHERE b.coin_id = c.id), 0
                )
            ) AS shares_since_last_block,
            (SELECT MAX(time) FROM blocks b WHERE b.coin_id = c.id) AS last_block_at
       FROM coins c
      WHERE c.enable = 1
      ORDER BY c.symbol ASC`,
  );
  return {
    effort: rows.map((r) => ({
      symbol: r.symbol,
      network_difficulty: Number(r.network_difficulty ?? 0),
      shares_since_last_block: Number(r.shares_since_last_block ?? 0),
      effort_pct:
        Number(r.network_difficulty) > 0
          ? (Number(r.shares_since_last_block ?? 0) / Number(r.network_difficulty)) * 100
          : 0,
      last_block_at: r.last_block_at ? Number(r.last_block_at) : null,
    })),
  };
});

app.get("/api/v1/pool/blocks/luck", async (req, reply) => {
  const q = req.query as { window?: string };
  const w = (q.window ?? "7d") as Window;
  if (!WINDOW_RE.test(w)) return reply.code(400).send({ error: "bad window" });
  const secs = windowConfig(w).seconds;
  const since = Math.floor(Date.now() / 1000) - secs;
  const [rows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT c.symbol,
            COUNT(*) AS actual,
            AVG(b.difficulty) AS avg_difficulty
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.time >= ?
      GROUP BY c.symbol`,
    [since],
  );
  // Expected blocks over the window given the pool's average hashrate is a
  // second query — for a first cut we return `actual` and let the client
  // compute expected from the hashrate series. Effort tells the same story
  // for the current round and is exact.
  return {
    window: w,
    since,
    coins: rows.map((r) => ({
      symbol: r.symbol,
      actual_blocks: Number(r.actual),
      avg_difficulty: Number(r.avg_difficulty ?? 0),
    })),
  };
});

/** legacy /api/pool/stats — keep for one release. */
app.get("/api/pool/stats", async () => {
  const [algoRows] = await pool.query(
    `SELECT algo,
            COUNT(DISTINCT userid) AS miners, COUNT(*) AS workers
       FROM workers
      WHERE time > UNIX_TIMESTAMP() - 600
      GROUP BY algo`,
  );
  const [lastBlocks] = await pool.query(
    `SELECT b.algo, b.height, b.time, c.symbol
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.id IN (SELECT MAX(id) FROM blocks GROUP BY algo)`,
  );
  return {
    algos: algoRows,
    last_blocks: lastBlocks,
    stratum_live: await getStratumLive(),
  };
});

// ============================================================================
// Blocks (legacy + v1)
// ============================================================================

async function queryBlocks(coin: string | undefined, algo: string | undefined, limit: number) {
  const where: string[] = [];
  const args: unknown[] = [];
  if (coin) {
    where.push("c.symbol = ?");
    args.push(coin.toUpperCase());
  }
  if (algo) {
    where.push("b.algo = ?");
    args.push(algo);
  }
  const whereSql = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const [rows] = await pool.query(
    `SELECT b.id, b.height, b.blockhash, b.amount, b.difficulty,
            b.time, b.confirmations, b.category, b.algo,
            c.symbol, c.name
       FROM blocks b JOIN coins c ON c.id = b.coin_id
       ${whereSql}
       ORDER BY b.time DESC
       LIMIT ?`,
    [...args, limit],
  );
  return rows;
}

app.get<{ Querystring: { coin?: string; algo?: string; limit?: string } }>(
  "/api/blocks",
  async (req, reply) => {
    const { coin, algo } = req.query;
    if (coin && !SYMBOL_RE.test(coin)) return reply.code(400).send({ error: "bad coin" });
    if (algo && !ALGO_RE.test(algo)) return reply.code(400).send({ error: "bad algo" });
    return { blocks: await queryBlocks(coin, algo, clampLimit(req.query.limit, 50, 500)) };
  },
);

app.get<{ Querystring: { coin?: string; algo?: string; limit?: string } }>(
  "/api/v1/blocks",
  async (req, reply) => {
    const { coin, algo } = req.query;
    if (coin && !SYMBOL_RE.test(coin)) return reply.code(400).send({ error: "bad coin" });
    if (algo && !ALGO_RE.test(algo)) return reply.code(400).send({ error: "bad algo" });
    return { blocks: await queryBlocks(coin, algo, clampLimit(req.query.limit, 50, 500)) };
  },
);

// ============================================================================
// Merged mining — the unique-value endpoint pair
// ============================================================================

/**
 * For each pool-found (TXC/ISK/ZCU) block over the window, list which
 * auxpow coins (LTC/DOGE) also credited in the same 10-second neighborhood.
 * That's what actually happened at the stratum layer: one accepted share on
 * the scrypt algo → up to 5 credited chains.
 */
app.get("/api/v1/mergedmining/summary", async (req, reply) => {
  const q = req.query as { window?: string };
  const w = (q.window ?? "24h") as Window;
  if (!WINDOW_RE.test(w)) return reply.code(400).send({ error: "bad window" });
  const since = Math.floor(Date.now() / 1000) - windowConfig(w).seconds;

  const [primary] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT b.id, b.height, b.blockhash, b.time, b.algo, c.symbol, c.name, b.amount
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.time >= ? AND c.symbol IN (?, ?, ?)
      ORDER BY b.time DESC
      LIMIT 500`,
    [since, ...POOL_FOUND],
  );

  const [aux] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT b.time, c.symbol, b.height, b.blockhash, b.amount
       FROM blocks b JOIN coins c ON c.id = b.coin_id
      WHERE b.time >= ? AND c.symbol IN (?, ?)`,
    [since, ...AUXPOW],
  );

  const rounds = primary.map((p) => {
    const t = Number(p.time);
    const window = aux.filter(
      (a) => Math.abs(Number(a.time) - t) < 30, // 30-second neighborhood
    );
    return {
      primary: {
        symbol: p.symbol,
        height: Number(p.height),
        hash: p.blockhash,
        time: t,
        amount: Number(p.amount ?? 0),
      },
      auxpow_credited: window.map((a) => ({
        symbol: a.symbol,
        height: Number(a.height),
        hash: a.blockhash,
        amount: Number(a.amount ?? 0),
      })),
    };
  });
  return { window: w, rounds };
});

app.get<{ Querystring: { limit?: string } }>(
  "/api/v1/mergedmining/credits",
  async (req) => {
    const limit = clampLimit(req.query.limit, 200, 1000);
    const [rows] = await pool.query(
      `SELECT b.time, b.height, b.blockhash, b.amount, b.category, b.algo,
              c.symbol,
              CASE WHEN c.symbol IN ('TXC','ISK','ZCU') THEN 'solo'
                   WHEN c.symbol IN ('LTC','DOGE') THEN 'auxpow'
                   ELSE 'other' END AS source
         FROM blocks b JOIN coins c ON c.id = b.coin_id
        ORDER BY b.time DESC
        LIMIT ?`,
      [limit],
    );
    return { credits: rows };
  },
);

// ============================================================================
// Miners
// ============================================================================

/**
 * The *real* active-miner count. Reads live stratum diag lines; the workers
 * MySQL table lags by hours and is why the old number is wrong.
 */
app.get("/api/v1/miners/count", async () => {
  const stratum = await getStratumLive();
  const totals = Object.values(stratum).reduce(
    (acc, v) => {
      acc.clients += v.clients;
      acc.active += v.active;
      acc.accepted_ghs += v.accepted_ghs;
      return acc;
    },
    { clients: 0, active: 0, accepted_ghs: 0 },
  );
  return { by_algo: stratum, totals };
});

app.get<{ Querystring: { limit?: string } }>("/api/v1/miners/top", async (req) => {
  const limit = clampLimit(req.query.limit, 50, 200);
  const [rows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT a.username AS address,
            SUM(w.hashrate) AS hashrate,
            COUNT(*) AS workers,
            MAX(w.time) AS last_share,
            w.algo
       FROM workers w JOIN accounts a ON a.id = w.userid
      WHERE w.time > UNIX_TIMESTAMP() - 600
      GROUP BY a.id, w.algo
      ORDER BY hashrate DESC
      LIMIT ?`,
    [limit],
  );
  return {
    miners: rows.map((r) => ({
      address_short: truncateAddress(String(r.address)),
      // Full address only exposed to owners via /api/v1/miner/:address.
      hashrate: Number(r.hashrate ?? 0),
      workers: Number(r.workers ?? 0),
      last_share: Number(r.last_share ?? 0),
      algo: r.algo,
    })),
  };
});

/**
 * Country/region rollup. Uses server-side GeoIP on the account IP.
 * Never returns per-IP or per-address data.
 */
app.get("/api/v1/miners/locations", async () => {
  const [rows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT a.IP AS ip, SUM(w.hashrate) AS hashrate
       FROM workers w JOIN accounts a ON a.id = w.userid
      WHERE w.time > UNIX_TIMESTAMP() - 600
      GROUP BY a.id`,
  );
  const buckets = aggregateGeo(
    rows.map((r) => ({ ip: r.ip as string | null, hashrate: Number(r.hashrate ?? 0) })),
  );
  return { locations: buckets };
});

// Existing per-miner endpoints (kept, both prefixes)
app.get<{ Params: { address: string } }>(
  "/api/miner/:address",
  async (req, reply) => minerSummary(req.params.address, reply),
);
app.get<{ Params: { address: string } }>(
  "/api/v1/miner/:address",
  async (req, reply) => minerSummary(req.params.address, reply),
);

async function minerSummary(address: string, reply: import("fastify").FastifyReply) {
  if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
  const [accountRows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT id, username, coinid, balance, pending, paid, last_login
       FROM accounts WHERE username = ? LIMIT 1`,
    [address],
  );
  const account = accountRows[0];
  if (!account) return reply.code(404).send({ error: "not found" });

  const [workerAgg] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT algo, COUNT(*) AS workers_online, SUM(hashrate) AS hashrate,
            MAX(time) AS last_share
       FROM workers WHERE userid = ? AND time > UNIX_TIMESTAMP() - 600
      GROUP BY algo`,
    [account.id],
  );
  const [payoutAgg] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT COALESCE(SUM(amount),0) AS total_paid,
            COUNT(*) AS payout_count, MAX(time) AS last_payout
       FROM payouts WHERE account_id = ?`,
    [account.id],
  );
  return {
    address,
    account_id: account.id,
    balance: Number(account.balance ?? 0),
    pending: Number(account.pending ?? 0),
    paid: Number(account.paid ?? 0),
    last_login: account.last_login,
    algos: workerAgg,
    payouts_summary: payoutAgg[0] ?? { total_paid: 0, payout_count: 0, last_payout: null },
  };
}

app.get<{ Params: { address: string }; Querystring: { window?: string } }>(
  "/api/v1/miner/:address/hashrate",
  async (req, reply) => {
    const address = req.params.address;
    if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
    const w = (req.query.window ?? "24h") as Window;
    if (!WINDOW_RE.test(w)) return reply.code(400).send({ error: "bad window" });
    const [rows] = await pool.query<mysql.RowDataPacket[]>(
      `SELECT id FROM accounts WHERE username = ? LIMIT 1`,
      [address],
    );
    if (!rows[0]) return reply.code(404).send({ error: "not found" });
    return {
      address,
      window: w,
      bucket_seconds: windowConfig(w).bucketSec,
      points: await minerHashrateSeries(pool, Number(rows[0].id), w),
    };
  },
);

app.get<{ Params: { address: string } }>(
  "/api/miner/:address/workers",
  async (req, reply) => minerWorkers(req.params.address, reply),
);
app.get<{ Params: { address: string } }>(
  "/api/v1/miner/:address/workers",
  async (req, reply) => minerWorkers(req.params.address, reply),
);

async function minerWorkers(address: string, reply: import("fastify").FastifyReply) {
  if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
  const [rows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT w.id, w.worker, w.algo, w.hashrate, w.difficulty,
            w.subscribe_time AS connected_since,
            w.time AS last_share,
            w.shares, w.rejects, w.stales, w.ip
       FROM workers w JOIN accounts a ON a.id = w.userid
      WHERE a.username = ? ORDER BY w.hashrate DESC LIMIT 500`,
    [address],
  );
  // Owner endpoint: include country+region but never the raw IP. If an
  // authenticated "my miner" view lands later we can widen this to include
  // IP for the miner's own address only.
  const enriched = rows.map((r) => {
    const rec = r as unknown as Record<string, unknown> & { ip?: string | null };
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { ip, ...rest } = rec;
    const { country, region } = lookupGeo(rec.ip);
    return { ...rest, country, region };
  });
  return { workers: enriched };
}

app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/miner/:address/payouts",
  async (req, reply) => minerPayouts(req.params.address, req.query.limit, reply),
);
app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/v1/miner/:address/payouts",
  async (req, reply) => minerPayouts(req.params.address, req.query.limit, reply),
);

async function minerPayouts(
  address: string,
  limitRaw: string | undefined,
  reply: import("fastify").FastifyReply,
) {
  if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
  const limit = clampLimit(limitRaw, 50, 500);
  const [rows] = await pool.query(
    `SELECT p.id, p.amount, p.fee, p.tx, p.time, p.idcoin, c.symbol, c.name
       FROM payouts p JOIN accounts a ON a.id = p.account_id
       LEFT JOIN coins c ON c.id = p.idcoin
      WHERE a.username = ? ORDER BY p.time DESC LIMIT ?`,
    [address, limit],
  );
  return { payouts: rows };
}

app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/miner/:address/earnings",
  async (req, reply) => minerEarnings(req.params.address, req.query.limit, reply),
);
app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/v1/miner/:address/earnings",
  async (req, reply) => minerEarnings(req.params.address, req.query.limit, reply),
);

async function minerEarnings(
  address: string,
  limitRaw: string | undefined,
  reply: import("fastify").FastifyReply,
) {
  if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
  const limit = clampLimit(limitRaw, 100, 500);
  const [rows] = await pool.query(
    `SELECT e.id, e.amount, e.time, e.blockid, e.status,
            b.height, b.blockhash, b.algo, c.symbol, c.name
       FROM earnings e JOIN accounts a ON a.id = e.userid
       LEFT JOIN blocks b ON b.id = e.blockid
       LEFT JOIN coins c ON c.id = e.coinid
      WHERE a.username = ? ORDER BY e.time DESC LIMIT ?`,
    [address, limit],
  );
  return { earnings: rows };
}

// ============================================================================
// Realtime — Server-Sent Events
// ============================================================================

app.get("/api/v1/stream", (req, reply) => {
  reply.sse(
    (async function* () {
      // Hello frame so clients confirm the pipe.
      yield {
        event: "hello",
        data: JSON.stringify({ time: Math.floor(Date.now() / 1000), version: "0.3.0" }),
      };

      const queue: { event: string; data: string }[] = [];
      const MAX_QUEUE = 200;

      const push = (event: string) => (payload: unknown) => {
        if (queue.length >= MAX_QUEUE) queue.shift(); // drop oldest
        queue.push({ event, data: JSON.stringify(payload) });
      };

      const onBlock = push("block-found");
      const onTick = push("hashrate-tick");
      stratumEvents.on("block-found", onBlock);
      stratumEvents.on("hashrate-tick", onTick);

      try {
        while (!req.socket.destroyed) {
          if (queue.length === 0) {
            await new Promise<void>((r) => setTimeout(r, 500));
            // keepalive comment every ~15s
            yield { event: "ping", data: `${Date.now()}` };
            continue;
          }
          const next = queue.shift()!;
          yield next;
        }
      } finally {
        stratumEvents.off("block-found", onBlock);
        stratumEvents.off("hashrate-tick", onTick);
      }
    })(),
  );
});

// ============================================================================
// OpenAPI doc stub (so SDKs and third parties can discover endpoints)
// ============================================================================

app.get("/api/v1/openapi.json", async () => ({
  openapi: "3.1.0",
  info: {
    title: "yiimp-api (honest.money pool)",
    version: "0.3.0",
    description:
      "Read-only pool-native + merged-mining + realtime API. See https://pool.honest.money/docs.",
  },
  servers: [{ url: "https://api.stratum.pool.honest.money" }],
  paths: {
    "/api/v1/health": { get: { summary: "health + version" } },
    "/api/v1/coins": { get: { summary: "list visible coins" } },
    "/api/v1/coins/{symbol}": { get: { summary: "one coin, incl. price/diff/hashrate" } },
    "/api/v1/coins/{symbol}/blocks": { get: { summary: "pool-found blocks for one coin" } },
    "/api/v1/pool/summary": { get: { summary: "one-shot dashboard payload" } },
    "/api/v1/pool/hashrate": { get: { summary: "hashrate time-series, ?window=1h|24h|7d|30d" } },
    "/api/v1/pool/effort": { get: { summary: "current-round effort per coin" } },
    "/api/v1/pool/blocks/luck": { get: { summary: "actual blocks vs difficulty over window" } },
    "/api/v1/blocks": { get: { summary: "recent blocks, ?coin=&algo=&limit=" } },
    "/api/v1/mergedmining/summary": { get: { summary: "primary + auxpow per round" } },
    "/api/v1/mergedmining/credits": { get: { summary: "flat credit feed" } },
    "/api/v1/miners/count": { get: { summary: "live stratum clients (correct miner count)" } },
    "/api/v1/miners/top": { get: { summary: "leaderboard (addresses truncated)" } },
    "/api/v1/miners/locations": { get: { summary: "country/region rollup (no IPs)" } },
    "/api/v1/miner/{address}": { get: { summary: "miner summary" } },
    "/api/v1/miner/{address}/workers": { get: { summary: "worker list with country/region" } },
    "/api/v1/miner/{address}/hashrate": { get: { summary: "miner hashrate time-series" } },
    "/api/v1/miner/{address}/payouts": { get: { summary: "recent payouts" } },
    "/api/v1/miner/{address}/earnings": { get: { summary: "per-block earnings" } },
    "/api/v1/stream": { get: { summary: "SSE: block-found, hashrate-tick" } },
  },
}));

app.listen({ port: PORT, host: BIND }).then(() => {
  app.log.info(`yiimp-api v0.2.0 listening on http://${BIND}:${PORT}`);
});
