// HTTP server exposing Esplora-compatible address endpoints.
// Spec: https://github.com/Blockstream/esplora/blob/master/API.md

import Fastify from "fastify";
import { db, getTipHeight } from "./db.js";
import { getRawTx, txcToSats, voutAddress, type RpcTx } from "./rpc.js";

const PORT = Number(process.env.HTTP_PORT ?? 3001);

const app = Fastify({ logger: false });

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

// GET /address/:addr
app.get<{ Params: { addr: string } }>("/address/:addr", async ({ params }) => {
  const { addr } = params;
  return {
    address: addr,
    chain_stats: chainStats(addr),
    mempool_stats: mempoolStats(addr),
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

export async function startHttp(): Promise<void> {
  await app.listen({ host: "0.0.0.0", port: PORT });
  console.log(`[indexer] HTTP listening on :${PORT}`);
}
