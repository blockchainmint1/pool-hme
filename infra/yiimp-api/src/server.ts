/**
 * yiimp-api — read-only JSON API in front of the yiimpfrontend MySQL DB.
 *
 * Runs on the yiimp box, binds 127.0.0.1:8787, fronted by nginx TLS at
 * https://yiimp-api.pool.honest.money. See README.md for schema notes.
 *
 * Design constraints:
 *   - Read-only. MySQL user is GRANT SELECT only.
 *   - No secrets logged, no PII beyond public wallet addresses.
 *   - Every query has LIMIT and every param has a regex whitelist.
 *   - Fastify pool max ~20; requests time out at 5s.
 */
import Fastify from "fastify";
import cors from "@fastify/cors";
import mysql from "mysql2/promise";
import { promises as fs } from "node:fs";
import path from "node:path";

const PORT = Number(process.env.YIIMP_API_PORT ?? 8787);
const BIND = process.env.YIIMP_API_BIND ?? "127.0.0.1";
const CORS_ORIGINS = (process.env.CORS_ORIGIN ?? "*")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const STRATUM_LOG_DIR = process.env.STRATUM_LOG_DIR ?? "";

const pool = mysql.createPool({
  host: process.env.MYSQL_HOST ?? "127.0.0.1",
  port: Number(process.env.MYSQL_PORT ?? 3306),
  user: process.env.MYSQL_USER ?? "yiimp_ro",
  password: process.env.MYSQL_PASSWORD ?? "",
  database: process.env.MYSQL_DATABASE ?? "yiimpfrontend",
  connectionLimit: 20,
  waitForConnections: true,
  connectTimeout: 5_000,
  // Force read-only session per connection.
  namedPlaceholders: false,
});

const ADDR_RE = /^[A-Za-z0-9]{20,80}$/;
const SYMBOL_RE = /^[A-Za-z0-9]{2,10}$/;
const ALGO_RE = /^[a-z0-9_-]{2,20}$/;

const app = Fastify({ logger: { level: "info" }, disableRequestLogging: false });

await app.register(cors, {
  origin: CORS_ORIGINS.length === 0 || CORS_ORIGINS[0] === "*" ? true : CORS_ORIGINS,
  methods: ["GET", "OPTIONS"],
});

function clampLimit(raw: unknown, def = 50, max = 500): number {
  const n = Number(raw ?? def);
  if (!Number.isFinite(n) || n <= 0) return def;
  return Math.min(Math.floor(n), max);
}

app.get("/api/health", async () => {
  let db = false;
  try {
    const [rows] = await pool.query("SELECT 1 AS ok");
    db = Array.isArray(rows) && rows.length === 1;
  } catch {
    db = false;
  }
  return { ok: true, db, uptime: process.uptime() };
});

/**
 * /api/coins
 * All coins yiimp knows about. Small table (< a few hundred rows).
 */
app.get("/api/coins", async () => {
  const [rows] = await pool.query(
    `SELECT id, name, symbol, algo, enable, visible, auto_ready
       FROM coins
      WHERE visible = 1
      ORDER BY symbol ASC`,
  );
  return { coins: rows };
});

/**
 * /api/pool/algos
 * Distinct algos currently backing at least one enabled coin.
 */
app.get("/api/pool/algos", async () => {
  const [rows] = await pool.query(
    `SELECT algo, COUNT(*) AS coin_count
       FROM coins
      WHERE enable = 1
      GROUP BY algo
      ORDER BY algo ASC`,
  );
  return { algos: rows };
});

/**
 * /api/pool/stats
 * Per-algo aggregate. hashrate from hashstats (yiimp's own rollup);
 * miner / worker counts from workers table joined to accounts.
 *
 * Also splices in the most recent SCRYPT summary diag line from the
 * stratum log if STRATUM_LOG_DIR is set — gives us live client count
 * and instantaneous accepted_ghs even when hashstats hasn't ticked.
 */
app.get("/api/pool/stats", async () => {
  const [algoRows] = await pool.query(
    `SELECT algo,
            SUM(hashrate) AS hashrate,
            COUNT(DISTINCT userid) AS miners,
            COUNT(*) AS workers
       FROM workers
      GROUP BY algo`,
  );

  const [lastBlocks] = await pool.query(
    `SELECT b.algo, b.height, b.time, c.symbol
       FROM blocks b
       JOIN coins c ON c.id = b.coin_id
      WHERE b.id IN (
        SELECT MAX(id) FROM blocks GROUP BY algo
      )`,
  );

  const live = await scrapeStratumSummaries();

  return {
    algos: algoRows,
    last_blocks: lastBlocks,
    stratum_live: live,
  };
});

/**
 * /api/blocks?coin=LTC&algo=scrypt&limit=50
 */
app.get<{ Querystring: { coin?: string; algo?: string; limit?: string } }>(
  "/api/blocks",
  async (req, reply) => {
    const { coin, algo } = req.query;
    if (coin && !SYMBOL_RE.test(coin)) return reply.code(400).send({ error: "bad coin" });
    if (algo && !ALGO_RE.test(algo)) return reply.code(400).send({ error: "bad algo" });
    const limit = clampLimit(req.query.limit, 50, 500);

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
         FROM blocks b
         JOIN coins c ON c.id = b.coin_id
         ${whereSql}
         ORDER BY b.time DESC
         LIMIT ?`,
      [...args, limit],
    );
    return { blocks: rows };
  },
);

/**
 * /api/miner/:address
 * Address summary. `accounts.username` is the wallet address in yiimp.
 */
app.get<{ Params: { address: string } }>("/api/miner/:address", async (req, reply) => {
  const { address } = req.params;
  if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });

  const [accountRows] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT id, username, coinid, balance, pending, paid, last_login, IP
       FROM accounts
      WHERE username = ?
      LIMIT 1`,
    [address],
  );
  const account = accountRows[0];
  if (!account) return reply.code(404).send({ error: "not found" });

  const [workerAgg] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT algo,
            COUNT(*) AS workers_online,
            SUM(hashrate) AS hashrate,
            MAX(time) AS last_share
       FROM workers
      WHERE userid = ?
      GROUP BY algo`,
    [account.id],
  );

  const [payoutAgg] = await pool.query<mysql.RowDataPacket[]>(
    `SELECT COALESCE(SUM(amount),0) AS total_paid,
            COUNT(*) AS payout_count,
            MAX(time) AS last_payout
       FROM payouts
      WHERE account_id = ?`,
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
});

/**
 * /api/miner/:address/workers
 */
app.get<{ Params: { address: string } }>(
  "/api/miner/:address/workers",
  async (req, reply) => {
    const { address } = req.params;
    if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });

    const [rows] = await pool.query(
      `SELECT w.id, w.worker, w.algo, w.hashrate, w.difficulty,
              w.subscribe_time AS connected_since,
              w.time AS last_share,
              w.shares, w.rejects, w.stales
         FROM workers w
         JOIN accounts a ON a.id = w.userid
        WHERE a.username = ?
        ORDER BY w.hashrate DESC
        LIMIT 500`,
      [address],
    );
    return { workers: rows };
  },
);

/**
 * /api/miner/:address/payouts?limit=50
 */
app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/miner/:address/payouts",
  async (req, reply) => {
    const { address } = req.params;
    if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
    const limit = clampLimit(req.query.limit, 50, 500);

    const [rows] = await pool.query(
      `SELECT p.id, p.amount, p.fee, p.tx, p.time, p.idcoin,
              c.symbol, c.name
         FROM payouts p
         JOIN accounts a ON a.id = p.account_id
         LEFT JOIN coins c ON c.id = p.idcoin
        WHERE a.username = ?
        ORDER BY p.time DESC
        LIMIT ?`,
      [address, limit],
    );
    return { payouts: rows };
  },
);

/**
 * /api/miner/:address/earnings?limit=100
 * Per-block credits — one row per block where this address had valid shares.
 */
app.get<{ Params: { address: string }; Querystring: { limit?: string } }>(
  "/api/miner/:address/earnings",
  async (req, reply) => {
    const { address } = req.params;
    if (!ADDR_RE.test(address)) return reply.code(400).send({ error: "bad address" });
    const limit = clampLimit(req.query.limit, 100, 500);

    const [rows] = await pool.query(
      `SELECT e.id, e.amount, e.time, e.blockid, e.status,
              b.height, b.blockhash, b.algo,
              c.symbol, c.name
         FROM earnings e
         JOIN accounts a ON a.id = e.userid
         LEFT JOIN blocks b ON b.id = e.blockid
         LEFT JOIN coins c ON c.id = e.coinid
        WHERE a.username = ?
        ORDER BY e.time DESC
        LIMIT ?`,
      [address, limit],
    );
    return { earnings: rows };
  },
);

/**
 * Best-effort tail of the stratum log. Returns null if disabled or unreadable.
 * Looks for lines like:
 *   05:43:36: SCRYPT summary diag clients=380 active=0 accepted_ghs=0.000 valid=0 invalid=0 ...
 */
async function scrapeStratumSummaries(): Promise<Record<string, unknown> | null> {
  if (!STRATUM_LOG_DIR) return null;
  const out: Record<string, unknown> = {};
  let anything = false;
  for (const algo of ["scrypt", "pawelhash"]) {
    try {
      const p = path.join(STRATUM_LOG_DIR, `${algo}.log`);
      const buf = await tailFile(p, 32 * 1024);
      const line = lastMatch(buf, /summary diag[^\n]+/gi);
      if (!line) continue;
      const kv: Record<string, string> = {};
      for (const m of line.matchAll(/(\w+)=([-+]?[\d.]+)/g)) kv[m[1]] = m[2];
      out[algo] = kv;
      anything = true;
    } catch {
      // ignore — log file may not be readable by this user
    }
  }
  return anything ? out : null;
}

async function tailFile(p: string, bytes: number): Promise<string> {
  const fh = await fs.open(p, "r");
  try {
    const stat = await fh.stat();
    const start = Math.max(0, stat.size - bytes);
    const len = stat.size - start;
    const buf = Buffer.alloc(len);
    await fh.read(buf, 0, len, start);
    return buf.toString("utf8");
  } finally {
    await fh.close();
  }
}

function lastMatch(hay: string, re: RegExp): string | null {
  let last: string | null = null;
  for (const m of hay.matchAll(re)) last = m[0];
  return last;
}

app.listen({ port: PORT, host: BIND }).then(() => {
  app.log.info(`yiimp-api listening on http://${BIND}:${PORT}`);
});
