// HTTP server exposing Esplora-compatible address endpoints.
// Spec: https://github.com/Blockstream/esplora/blob/master/API.md

import Fastify from "fastify";
import { db, getTipHeight } from "./db.js";
import {
  getBlockCount,
  getBlockHash,
  getBlockVerbose,
  getRawMempool,
  getRawMempoolVerbose,
  getMempoolInfo,
  estimateSmartFee,
  feerateTxcKvbToSatVb,
  getRawTx,
  rpc,
  RpcError,
  txcToSats,
  voutAddress,
  type RpcBlock,
  type RpcTx,
} from "./rpc.js";

const PORT = Number(process.env.HTTP_PORT ?? 3001);

const app = Fastify({ logger: false });

// Accept raw hex bodies for POST /tx (Esplora broadcast spec).
app.addContentTypeParser("text/plain", { parseAs: "string" }, (_req, body, done) =>
  done(null, body),
);
app.addContentTypeParser(
  "application/octet-stream",
  { parseAs: "string" },
  (_req, body, done) => done(null, body),
);

// CORS — addresses are read-only and behind nginx anyway, but allow direct.
app.addHook("onSend", async (_req, reply, payload) => {
  reply.header("access-control-allow-origin", "*");
  reply.header("access-control-allow-methods", "GET, OPTIONS");
  reply.header("access-control-allow-headers", "Content-Type");
  return payload;
});
app.options("/*", async (_req, reply) => reply.code(204).send());

// ---------- helpers ----------

interface AddressStats {
  funded_txo_count: number;
  funded_txo_sum: number;
  spent_txo_count: number;
  spent_txo_sum: number;
  tx_count: number;
}

function chainStats(address: string): AddressStats {
  const funded = db
    .prepare("SELECT COUNT(*) AS c, COALESCE(SUM(value),0) AS s FROM outputs WHERE address = ?")
    .get(address) as { c: number; s: number };
  const spent = db
    .prepare(
      "SELECT COUNT(*) AS c, COALESCE(SUM(value),0) AS s FROM outputs WHERE address = ? AND spent_txid IS NOT NULL",
    )
    .get(address) as { c: number; s: number };
  const txCount = db
    .prepare("SELECT COUNT(*) AS c FROM address_txs WHERE address = ?")
    .get(address) as { c: number };
  return {
    funded_txo_count: funded.c,
    funded_txo_sum: funded.s,
    spent_txo_count: spent.c,
    spent_txo_sum: spent.s,
    tx_count: txCount.c,
  };
}

function mempoolStats(address: string): AddressStats {
  const rows = db
    .prepare("SELECT delta FROM mempool_address_txs WHERE address = ?")
    .all(address) as { delta: number }[];
  let fundedSum = 0;
  let spentSum = 0;
  let fundedCount = 0;
  let spentCount = 0;
  for (const r of rows) {
    if (r.delta >= 0) {
      fundedSum += r.delta;
      fundedCount++;
    } else {
      spentSum += -r.delta;
      spentCount++;
    }
  }
  return {
    funded_txo_count: fundedCount,
    funded_txo_sum: fundedSum,
    spent_txo_count: spentCount,
    spent_txo_sum: spentSum,
    tx_count: rows.length,
  };
}

// ---------- Esplora Tx shape conversion ----------
// We cache prevouts we resolve via RPC so a single page of address txs
// doesn't fan out into hundreds of duplicate calls.

async function toEsploraTx(tx: RpcTx, cache: Map<string, RpcTx>): Promise<unknown> {
  const tipHeight = getTipHeight();
  const confirmed = !!tx.blockhash;
  const blockHeight = confirmed && tx.confirmations ? tipHeight - tx.confirmations + 1 : undefined;

  let totalIn = 0;
  const vin = await Promise.all(
    tx.vin.map(async (vi) => {
      if (vi.coinbase !== undefined) {
        return {
          is_coinbase: true,
          sequence: vi.sequence,
          scriptsig: vi.coinbase,
          scriptsig_asm: "",
          witness: vi.txinwitness ?? [],
          txid: "0000000000000000000000000000000000000000000000000000000000000000",
          vout: 0xffffffff,
          prevout: null,
        };
      }
      if (!vi.txid || vi.vout === undefined) return null;
      // Prefer our DB; fall back to RPC for txs not yet indexed.
      const row = db
        .prepare("SELECT address, value FROM outputs WHERE txid = ? AND vout = ?")
        .get(vi.txid, vi.vout) as { address: string | null; value: number } | undefined;
      let prevAddress: string | null = null;
      let prevValue = 0;
      let prevScript = "";
      let prevType = "";
      if (row) {
        prevAddress = row.address;
        prevValue = row.value;
        // Pull scriptPubKey hex from cached prev tx if available
        let prev = cache.get(vi.txid);
        if (!prev) {
          try {
            prev = await getRawTx(vi.txid);
            cache.set(vi.txid, prev);
          } catch {
            /* ignore */
          }
        }
        const vo = prev?.vout[vi.vout];
        if (vo) {
          prevScript = vo.scriptPubKey.hex;
          prevType = vo.scriptPubKey.type;
        }
      }
      totalIn += prevValue;
      return {
        txid: vi.txid,
        vout: vi.vout,
        sequence: vi.sequence,
        scriptsig: vi.scriptSig?.hex ?? "",
        scriptsig_asm: vi.scriptSig?.asm ?? "",
        witness: vi.txinwitness ?? [],
        is_coinbase: false,
        prevout: row
          ? {
              scriptpubkey: prevScript,
              scriptpubkey_address: prevAddress ?? undefined,
              scriptpubkey_type: prevType,
              value: prevValue,
            }
          : null,
      };
    }),
  );

  let totalOut = 0;
  const vout = tx.vout.map((vo) => {
    const sats = txcToSats(vo.value);
    totalOut += sats;
    return {
      scriptpubkey: vo.scriptPubKey.hex,
      scriptpubkey_asm: vo.scriptPubKey.asm,
      scriptpubkey_type: vo.scriptPubKey.type,
      scriptpubkey_address: voutAddress(vo) ?? undefined,
      value: sats,
    };
  });

  const isCoinbase = tx.vin.some((v) => v.coinbase !== undefined);
  const fee = isCoinbase ? 0 : Math.max(0, totalIn - totalOut);

  return {
    txid: tx.txid,
    version: tx.version,
    locktime: tx.locktime,
    vin,
    vout,
    size: tx.size,
    weight: tx.weight,
    fee,
    status: confirmed
      ? {
          confirmed: true,
          block_height: blockHeight,
          block_hash: tx.blockhash,
          block_time: tx.blocktime,
        }
      : { confirmed: false },
  };
}

// ---------- routes ----------

app.get("/health", async () => ({
  ok: true,
  tip: getTipHeight(),
}));

// ---------- broadcast + raw tx (Esplora spec) ----------
// POST /tx — body is the signed raw transaction as hex (text/plain or
// application/octet-stream). Returns the txid as plain text on success,
// or a 400 with the node's error message (e.g. "min relay fee not met",
// "bad-txns-inputs-missingorspent") on rejection.
app.post("/tx", async (req, reply) => {
  const body = req.body as unknown;
  let hex: string | undefined;
  if (typeof body === "string") hex = body.trim();
  else if (body && typeof body === "object" && typeof (body as { hex?: unknown }).hex === "string") {
    hex = ((body as { hex: string }).hex).trim();
  }
  if (!hex) return reply.code(400).type("text/plain").send("missing raw tx hex in body");
  if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) {
    return reply.code(400).type("text/plain").send("invalid hex");
  }
  try {
    const txid = await rpc<string>("sendrawtransaction", [hex]);
    return reply.type("text/plain").send(txid);
  } catch (e) {
    const msg = e instanceof RpcError ? e.message : (e as Error).message ?? "broadcast failed";
    return reply.code(400).type("text/plain").send(msg);
  }
});

// GET /tx/:txid/hex — raw signed transaction hex.
app.get<{ Params: { txid: string } }>("/tx/:txid/hex", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) {
    return reply.code(400).type("text/plain").send("invalid txid");
  }
  try {
    const tx = await getRawTx(params.txid);
    return reply.type("text/plain").send(tx.hex);
  } catch (e) {
    const msg = e instanceof RpcError ? e.message : (e as Error).message ?? "not found";
    return reply.code(404).type("text/plain").send(msg);
  }
});

// GET /address/_status — indexer sync status, reachable via nginx /api/address/_status
app.get("/address/_status", async () => ({
  ok: true,
  indexed_tip: getTipHeight(),
}));

// GET /address/_richlist?limit=100 — top N addresses by unspent (confirmed) balance.
// Cached in-memory for RICHLIST_TTL_MS to keep this cheap even under traffic.
interface RichlistEntry {
  address: string;
  balance: number; // sats
  utxo_count: number;
}
interface RichlistSnapshot {
  computed_at: number; // unix seconds
  indexed_tip: number;
  total_entries: number;
  entries: RichlistEntry[];
}
const RICHLIST_TTL_MS = Number(process.env.RICHLIST_TTL_MS ?? 60_000);
const RICHLIST_MAX = Number(process.env.RICHLIST_MAX ?? 500);
let richlistCache: { at: number; snapshot: RichlistSnapshot } | null = null;

function computeRichlist(limit: number): RichlistSnapshot {
  // Reads the materialized balances table maintained incrementally by the
  // indexer. The partial index `idx_balances_balance` on (balance DESC)
  // WHERE balance > 0 makes this an index range scan — sub-millisecond
  // even with hundreds of thousands of addresses.
  const rows = db
    .prepare(
      `SELECT address, balance, utxo_count
       FROM balances
       WHERE balance > 0
       ORDER BY balance DESC
       LIMIT ?`,
    )
    .all(limit) as Array<{ address: string; balance: number; utxo_count: number }>;
  return {
    computed_at: Math.floor(Date.now() / 1000),
    indexed_tip: getTipHeight(),
    total_entries: rows.length,
    entries: rows,
  };
}


app.get<{ Querystring: { limit?: string } }>("/address/_richlist", async ({ query }, reply) => {
  const requested = Math.max(1, Math.min(RICHLIST_MAX, Number(query.limit ?? 100) || 100));
  const now = Date.now();
  if (!richlistCache || now - richlistCache.at > RICHLIST_TTL_MS) {
    richlistCache = { at: now, snapshot: computeRichlist(RICHLIST_MAX) };
  }
  const snap = richlistCache.snapshot;
  reply.header("cache-control", `public, max-age=${Math.floor(RICHLIST_TTL_MS / 1000)}`);
  return {
    computed_at: snap.computed_at,
    indexed_tip: snap.indexed_tip,
    limit: requested,
    total_entries: Math.min(requested, snap.entries.length),
    entries: snap.entries.slice(0, requested),
  };
});

// GET /address/_supply — real circulating TXC supply computed from the live
// UTXO set (SUM(balance) across the materialized balances table). Sub-ms
// thanks to the small table + partial index. Cached briefly to avoid
// repeated scans under load.
const SUPPLY_TTL_MS = Number(process.env.SUPPLY_TTL_MS ?? 30_000);
let supplyCache: {
  at: number;
  computed_at: number;
  indexed_tip: number;
  circulating_sats: number;
  address_count: number;
  utxo_count: number;
} | null = null;
app.get("/address/_supply", async (_req, reply) => {
  const now = Date.now();
  if (!supplyCache || now - supplyCache.at > SUPPLY_TTL_MS) {
    const row = db
      .prepare(
        `SELECT COALESCE(SUM(balance), 0) AS sats,
                COUNT(*)                 AS addrs,
                COALESCE(SUM(utxo_count), 0) AS utxos
         FROM balances
         WHERE balance > 0`,
      )
      .get() as { sats: number; addrs: number; utxos: number };
    supplyCache = {
      at: now,
      computed_at: Math.floor(now / 1000),
      indexed_tip: getTipHeight(),
      circulating_sats: row.sats,
      address_count: row.addrs,
      utxo_count: row.utxos,
    };
  }
  reply.header("cache-control", `public, max-age=${Math.floor(SUPPLY_TTL_MS / 1000)}`);
  return {
    computed_at: supplyCache.computed_at,
    indexed_tip: supplyCache.indexed_tip,
    circulating_sats: supplyCache.circulating_sats,
    circulating: supplyCache.circulating_sats / 1e8,
    address_count: supplyCache.address_count,
    utxo_count: supplyCache.utxo_count,
  };
});

// GET /address/:addr
app.get<{ Params: { addr: string } }>("/address/:addr", async ({ params }) => {
  const { addr } = params;
  return {
    address: addr,
    chain_stats: chainStats(addr),
    mempool_stats: mempoolStats(addr),
  };
});

// GET /address/:addr/balance-history?bucket=day|hour&limit=400
//
// Materialises a balance time-series directly from the indexed outputs.
// For each address we union two event streams:
//   - credits: (height, +value) for every output paying the address
//   - debits:  (spent_height, -value) for every output of theirs that's spent
// We join each event to its block timestamp, bucket by day (default), sum the
// deltas per bucket, and accumulate into a running balance. This is O(n) over
// the address's tx history and runs as a single SQL statement.
//
// Response: { address, bucket, currentBalance, history: [{ t, balance, delta }] }
// `t` is unix seconds at the START of each bucket, `balance` is the balance
// AT THE END of that bucket (so the latest bucket equals currentBalance).
app.get<{
  Params: { addr: string };
  Querystring: { bucket?: string; limit?: string };
}>("/address/:addr/balance-history", async ({ params, query }) => {
  const { addr } = params;
  const bucket = query.bucket === "hour" ? "hour" : "day";
  const limit = Math.max(10, Math.min(2000, Number(query.limit ?? 400) || 400));
  const secs = bucket === "hour" ? 3600 : 86400;

  // Per-bucket delta in satoshis. SQLite integer arithmetic — exact.
  const rows = db
    .prepare(
      `WITH events AS (
         SELECT b.time AS t, o.value AS delta
           FROM outputs o JOIN blocks b ON b.height = o.height
          WHERE o.address = ?
         UNION ALL
         SELECT b.time AS t, -o.value AS delta
           FROM outputs o JOIN blocks b ON b.height = o.spent_height
          WHERE o.address = ? AND o.spent_txid IS NOT NULL
       )
       SELECT (t / ?) * ? AS bucket_t, SUM(delta) AS delta
         FROM events
        GROUP BY bucket_t
        ORDER BY bucket_t ASC`,
    )
    .all(addr, addr, secs, secs) as Array<{ bucket_t: number; delta: number }>;

  // Running balance.
  let bal = 0;
  const full = rows.map((r) => {
    bal += r.delta;
    return { t: r.bucket_t, balance: bal, delta: r.delta };
  });
  const current = bal;

  // Downsample evenly to `limit` points so the wire payload stays small
  // even for ancient addresses with thousands of buckets.
  const history =
    full.length <= limit
      ? full
      : (() => {
          const step = full.length / limit;
          const out: typeof full = [];
          for (let i = 0; i < limit; i++) out.push(full[Math.floor(i * step)]);
          // Always include the final point so the chart ends at "now".
          if (out[out.length - 1] !== full[full.length - 1]) out.push(full[full.length - 1]);
          return out;
        })();

  return {
    address: addr,
    bucket,
    currentBalance: current,
    indexedTip: getTipHeight(),
    computedAt: Math.floor(Date.now() / 1000),
    points: history.length,
    history,
  };
});

// GET /address/:addr/utxo
app.get<{ Params: { addr: string } }>("/address/:addr/utxo", async ({ params }) => {
  const rows = db
    .prepare(
      `SELECT o.txid, o.vout, o.value, o.height, b.hash AS block_hash, b.time AS block_time
       FROM outputs o
       JOIN blocks b ON b.height = o.height
       WHERE o.address = ? AND o.spent_txid IS NULL
       ORDER BY o.height DESC, o.txid, o.vout`,
    )
    .all(params.addr) as Array<{
    txid: string;
    vout: number;
    value: number;
    height: number;
    block_hash: string;
    block_time: number;
  }>;
  return rows.map((r) => ({
    txid: r.txid,
    vout: r.vout,
    value: r.value,
    status: {
      confirmed: true,
      block_height: r.height,
      block_hash: r.block_hash,
      block_time: r.block_time,
    },
  }));
});

// GET /address/:addr/txs            → mempool (up to 50) + 25 most recent confirmed
// GET /address/:addr/txs/chain/:last → next 25 confirmed after :last
app.get<{ Params: { addr: string; last?: string }; Querystring: Record<string, never> }>(
  "/address/:addr/txs",
  async ({ params }) => listConfirmed(params.addr, undefined, true),
);
app.get<{ Params: { addr: string; last: string } }>(
  "/address/:addr/txs/chain/:last",
  async ({ params }) => listConfirmed(params.addr, params.last, false),
);
app.get<{ Params: { addr: string } }>("/address/:addr/txs/mempool", async ({ params }) => {
  const rows = db
    .prepare("SELECT txid FROM mempool_address_txs WHERE address = ?")
    .all(params.addr) as { txid: string }[];
  const cache = new Map<string, RpcTx>();
  const out = [] as unknown[];
  for (const r of rows.slice(0, 50)) {
    try {
      const tx = await getRawTx(r.txid);
      out.push(await toEsploraTx(tx, cache));
    } catch {
      /* dropped */
    }
  }
  return out;
});

async function listConfirmed(address: string, lastSeen: string | undefined, includeMempool: boolean) {
  // Pagination — Esplora pages by the last-seen txid's (height, txid).
  let beforeHeight = Number.MAX_SAFE_INTEGER;
  let beforeTxid = "z".repeat(64); // sorts after any hex txid
  if (lastSeen) {
    const row = db
      .prepare("SELECT height FROM address_txs WHERE address = ? AND txid = ?")
      .get(address, lastSeen) as { height: number } | undefined;
    if (row) {
      beforeHeight = row.height;
      beforeTxid = lastSeen;
    }
  }
  const rows = db
    .prepare(
      `SELECT txid, height FROM address_txs
       WHERE address = ?
         AND (height < ? OR (height = ? AND txid > ?))
       ORDER BY height DESC, txid
       LIMIT 25`,
    )
    .all(address, beforeHeight, beforeHeight, beforeTxid) as { txid: string; height: number }[];

  const cache = new Map<string, RpcTx>();
  const out: unknown[] = [];

  if (includeMempool && !lastSeen) {
    const mp = db
      .prepare("SELECT txid FROM mempool_address_txs WHERE address = ?")
      .all(address) as { txid: string }[];
    for (const r of mp.slice(0, 50)) {
      try {
        const tx = await getRawTx(r.txid);
        out.push(await toEsploraTx(tx, cache));
      } catch {
        /* skip */
      }
    }
  }

  for (const r of rows) {
    try {
      const tx = await getRawTx(r.txid);
      out.push(await toEsploraTx(tx, cache));
    } catch {
      /* skip */
    }
  }
  return out;
}

// ---------- Esplora block + tx + mempool REST ----------
// Implements the bare /blocks, /block/:hash, /block-height/:h, /mempool,
// /fee-estimates, /tx/:txid, /tx/:txid/status, /tx/:txid/outspends paths.
// Nginx maps both bare `/api/*` and `/api/v1/*` to these.

function toEsploraBlockSummary(b: RpcBlock): unknown {
  return {
    id: b.hash,
    height: b.height,
    version: b.version,
    timestamp: b.time,
    tx_count: b.nTx,
    size: b.size,
    weight: b.weight,
    merkle_root: b.merkleroot,
    previousblockhash: b.previousblockhash ?? null,
    mediantime: b.mediantime,
    nonce: b.nonce,
    bits: parseInt(b.bits, 16),
    difficulty: b.difficulty,
  };
}

// GET /blocks/tip/height — current chain height (text/plain integer)
app.get("/blocks/tip/height", async (_req, reply) => {
  const h = await getBlockCount();
  return reply.type("text/plain").send(String(h));
});

// GET /blocks/tip/hash — tip hash (text/plain)
app.get("/blocks/tip/hash", async (_req, reply) => {
  const h = await getBlockCount();
  const hash = await getBlockHash(h);
  return reply.type("text/plain").send(hash);
});

// GET /blocks  -or-  /blocks/:start_height — last 10 blocks starting from tip or given height
app.get<{ Params: { start?: string } }>("/blocks/:start", async ({ params }, reply) => {
  return listBlocks(Number(params.start), reply);
});
app.get("/blocks", async (_req, reply) => listBlocks(undefined, reply));

async function listBlocks(start: number | undefined, reply: import("fastify").FastifyReply) {
  const tip = await getBlockCount();
  const top = start === undefined || Number.isNaN(start) ? tip : Math.min(start, tip);
  const out: unknown[] = [];
  for (let i = 0; i < 10 && top - i >= 0; i++) {
    const hash = await getBlockHash(top - i);
    const blk = await getBlockVerbose(hash);
    out.push(toEsploraBlockSummary(blk));
  }
  return reply.send(out);
}

// GET /block-height/:height — returns the block hash for a height (text/plain)
app.get<{ Params: { height: string } }>("/block-height/:height", async ({ params }, reply) => {
  const h = Number(params.height);
  if (!Number.isInteger(h) || h < 0) return reply.code(400).type("text/plain").send("invalid height");
  try {
    const hash = await getBlockHash(h);
    return reply.type("text/plain").send(hash);
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
});

// GET /block/:hash — block summary by hash
app.get<{ Params: { hash: string } }>("/block/:hash", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.hash)) return reply.code(400).send("invalid hash");
  try {
    const blk = await getBlockVerbose(params.hash);
    return reply.send(toEsploraBlockSummary(blk));
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
});

// GET /block/:hash/txids — list of txids in the block
app.get<{ Params: { hash: string } }>("/block/:hash/txids", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.hash)) return reply.code(400).send("invalid hash");
  try {
    const blk = await getBlockVerbose(params.hash);
    return reply.send(blk.tx.map((t) => t.txid));
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
});

// GET /block/:hash/txs[/:start_index] — paginated txs (25 per page)
app.get<{ Params: { hash: string; start?: string } }>(
  "/block/:hash/txs/:start",
  async ({ params }, reply) => blockTxs(params.hash, Number(params.start), reply),
);
app.get<{ Params: { hash: string } }>("/block/:hash/txs", async ({ params }, reply) =>
  blockTxs(params.hash, 0, reply),
);
async function blockTxs(hash: string, start: number, reply: import("fastify").FastifyReply) {
  if (!/^[0-9a-fA-F]{64}$/.test(hash)) return reply.code(400).send("invalid hash");
  const s = Number.isInteger(start) && start >= 0 ? start : 0;
  try {
    const blk = await getBlockVerbose(hash);
    const slice = blk.tx.slice(s, s + 25);
    const cache = new Map<string, RpcTx>();
    const out: unknown[] = [];
    for (const tx of slice) out.push(await toEsploraTx(tx, cache));
    return reply.send(out);
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
}

// GET /tx/:txid — full Esplora tx
app.get<{ Params: { txid: string } }>("/tx/:txid", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) return reply.code(400).send("invalid txid");
  try {
    const tx = await getRawTx(params.txid);
    const cache = new Map<string, RpcTx>();
    return reply.send(await toEsploraTx(tx, cache));
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
});

// GET /tx/:txid/status — confirmation status only
app.get<{ Params: { txid: string } }>("/tx/:txid/status", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) return reply.code(400).send("invalid txid");
  try {
    const tx = await getRawTx(params.txid);
    const tip = getTipHeight();
    if (tx.blockhash && tx.confirmations) {
      return reply.send({
        confirmed: true,
        block_height: tip - tx.confirmations + 1,
        block_hash: tx.blockhash,
        block_time: tx.blocktime,
      });
    }
    return reply.send({ confirmed: false });
  } catch {
    return reply.code(404).type("text/plain").send("not found");
  }
});

// GET /tx/:txid/outspends — which outputs are spent and where
app.get<{ Params: { txid: string } }>("/tx/:txid/outspends", async ({ params }, reply) => {
  if (!/^[0-9a-fA-F]{64}$/.test(params.txid)) return reply.code(400).send("invalid txid");
  const rows = db
    .prepare("SELECT vout, spent_txid, spent_height FROM outputs WHERE txid = ? ORDER BY vout")
    .all(params.txid) as { vout: number; spent_txid: string | null; spent_height: number | null }[];
  if (rows.length === 0) {
    // Fall back to RPC for non-indexed (very recent) txs — return unspent placeholders.
    try {
      const tx = await getRawTx(params.txid);
      return reply.send(tx.vout.map(() => ({ spent: false })));
    } catch {
      return reply.code(404).type("text/plain").send("not found");
    }
  }
  const tip = getTipHeight();
  return reply.send(
    rows.map((r) =>
      r.spent_txid
        ? {
            spent: true,
            txid: r.spent_txid,
            vin: 0,
            status: r.spent_height
              ? { confirmed: true, block_height: r.spent_height }
              : { confirmed: false },
          }
        : { spent: false },
    ),
  );
});

// GET /mempool — real summary of the unconfirmed pool.
// Uses getrawmempool verbose to sum vsize + fees across every entry, and
// builds an Esplora-style fee_histogram: buckets of [feerate_satvb, vsize]
// sorted by feerate DESC (highest paying first) so the mempool viz can walk
// it top-down to project the next few blocks.
app.get("/mempool", async (_req, reply) => {
  try {
    const entries = await getRawMempoolVerbose();
    let count = 0;
    let vsize = 0;
    let totalFeeSats = 0;
    // Group into fee-rate buckets in sat/vB.
    const buckets: Array<{ feerate: number; vsize: number }> = [];
    for (const [, e] of Object.entries(entries)) {
      const feeTxc = e.fees?.base ?? e.fee ?? 0;
      const feeSats = Math.round(feeTxc * 1e8);
      const vs = e.vsize || e.size || 0;
      if (vs <= 0) continue;
      count++;
      vsize += vs;
      totalFeeSats += feeSats;
      const rate = feeSats / vs; // sat/vB
      buckets.push({ feerate: rate, vsize: vs });
    }
    // Sort DESC by feerate, then merge into coarse buckets so the payload
    // stays small (mempool.space frontends expect ~O(bands), not O(txs)).
    buckets.sort((a, b) => b.feerate - a.feerate);
    const bands = [1000, 500, 200, 100, 50, 20, 10, 5, 2, 1, 0];
    const histogram: [number, number][] = [];
    let bi = 0;
    for (const band of bands) {
      let sum = 0;
      while (bi < buckets.length && buckets[bi].feerate >= band) {
        sum += buckets[bi].vsize;
        bi++;
      }
      if (sum > 0) histogram.push([band, sum]);
    }
    return reply.send({
      count,
      vsize,
      total_fee: totalFeeSats,
      fee_histogram: histogram,
    });
  } catch (err) {
    console.error("[indexer] /mempool failed:", (err as Error).message);
    return reply.send({ count: 0, vsize: 0, total_fee: 0, fee_histogram: [] });
  }
});

// GET /mempool/txids — raw txid list
app.get("/mempool/txids", async (_req, reply) => {
  try {
    const txids = await getRawMempool();
    return reply.send(txids);
  } catch {
    return reply.send([]);
  }
});

// GET /mempool/recent — last N mempool entries with REAL fee/vsize.
// Fees come from getrawmempool verbose (Core computes them from prevouts,
// including chains of unconfirmed txs) so we don't have to resolve inputs
// ourselves.
app.get("/mempool/recent", async (_req, reply) => {
  try {
    const entries = await getRawMempoolVerbose();
    // Sort by mempool arrival time DESC and take the top 10.
    const rows = Object.entries(entries)
      .map(([txid, e]) => ({ txid, e }))
      .sort((a, b) => (b.e.time ?? 0) - (a.e.time ?? 0))
      .slice(0, 10);
    const out: unknown[] = [];
    for (const { txid, e } of rows) {
      const feeTxc = e.fees?.base ?? e.fee ?? 0;
      const feeSats = Math.round(feeTxc * 1e8);
      let value = 0;
      try {
        const tx = await getRawTx(txid);
        value = tx.vout.reduce((a, v) => a + txcToSats(v.value), 0);
      } catch {
        /* keep value=0 if tx dropped between calls */
      }
      out.push({ txid, fee: feeSats, vsize: e.vsize || e.size || 0, value });
    }
    return reply.send(out);
  } catch (err) {
    console.error("[indexer] /mempool/recent failed:", (err as Error).message);
    return reply.send([]);
  }
});

// GET /fee-estimates — Esplora fee estimator.
// Calls estimatesmartfee for each Esplora confirmation target and returns
// the result in sat/vB. Falls back to the node's mempoolminfee / minrelaytxfee
// (whichever is higher) when Core has no estimate for that target (common on
// low-traffic chains). Cached briefly to avoid hammering RPC.
const FEE_TARGETS = [1, 2, 3, 4, 6, 10, 20, 144, 504, 1008] as const;
const FEE_TTL_MS = Number(process.env.FEE_TTL_MS ?? 30_000);
let feeCache: { at: number; body: Record<string, number> } | null = null;
app.get("/fee-estimates", async (_req, reply) => {
  const now = Date.now();
  if (feeCache && now - feeCache.at < FEE_TTL_MS) {
    reply.header("cache-control", `public, max-age=${Math.floor(FEE_TTL_MS / 1000)}`);
    return reply.send(feeCache.body);
  }
  try {
    const info = await getMempoolInfo().catch(() => null);
    const floor =
      feerateTxcKvbToSatVb(
        Math.max(info?.mempoolminfee ?? 0, info?.minrelaytxfee ?? 0),
      ) ?? 1;
    const out: Record<string, number> = {};
    for (const t of FEE_TARGETS) {
      let rate: number | null = null;
      try {
        const est = await estimateSmartFee(t);
        rate = feerateTxcKvbToSatVb(est.feerate);
      } catch {
        /* fall back below */
      }
      // Round to 2 decimals, never below the relay floor.
      const val = Math.max(rate ?? floor, floor);
      out[String(t)] = Math.round(val * 100) / 100;
    }
    feeCache = { at: now, body: out };
    reply.header("cache-control", `public, max-age=${Math.floor(FEE_TTL_MS / 1000)}`);
    return reply.send(out);
  } catch (err) {
    console.error("[indexer] /fee-estimates failed:", (err as Error).message);
    // Very last-resort: 1 sat/vB across the board. Better than crashing wallets.
    const flat = 1;
    return reply.send(Object.fromEntries(FEE_TARGETS.map((t) => [String(t), flat])));
  }
});


export async function startHttp(): Promise<void> {
  await app.listen({ host: "0.0.0.0", port: PORT });
  console.log(`[indexer] HTTP listening on :${PORT}`);
}
