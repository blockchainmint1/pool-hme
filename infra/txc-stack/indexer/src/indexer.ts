// Chain walker. Pulls blocks one at a time via RPC and inserts outputs +
// address↔tx links into SQLite. Handles reorgs by checking the parent hash
// of the next block against what we have stored; if it diverges, we roll
// back blocks until they line up, then move forward again.

import {
  getBlockCount,
  getBlockHash,
  getBlockVerbose,
  getRawMempool,
  getRawTx,
  txcToSats,
  voutAddress,
  type RpcBlock,
} from "./rpc.js";
import { db, getBlockHashAt, getTipHeight } from "./db.js";

const POLL_MS = Number(process.env.POLL_MS ?? 5_000);
const MEMPOOL_REFRESH_MS = Number(process.env.MEMPOOL_REFRESH_MS ?? 15_000);

const insertBlock = db.prepare(
  "INSERT OR REPLACE INTO blocks(height, hash, time) VALUES (?, ?, ?)",
);
const insertOutput = db.prepare(
  "INSERT OR REPLACE INTO outputs(txid, vout, address, value, height) VALUES (?, ?, ?, ?, ?)",
);
const markSpent = db.prepare(
  "UPDATE outputs SET spent_txid = ?, spent_height = ? WHERE txid = ? AND vout = ?",
);
const getPrevOut = db.prepare(
  "SELECT address, value FROM outputs WHERE txid = ? AND vout = ?",
);
const insertAddrTx = db.prepare(
  "INSERT OR IGNORE INTO address_txs(address, txid, height) VALUES (?, ?, ?)",
);

// Balance maintenance — incrementally update the materialized balances
// table so the richlist endpoint is a simple ORDER BY LIMIT, not a full
// GROUP BY scan of outputs on every cache miss.
const bumpBalance = db.prepare(
  `INSERT INTO balances(address, balance, utxo_count) VALUES (?, ?, 1)
   ON CONFLICT(address) DO UPDATE SET
     balance    = balance + excluded.balance,
     utxo_count = utxo_count + 1`,
);
const dropBalance = db.prepare(
  `INSERT INTO balances(address, balance, utxo_count) VALUES (?, ?, -1)
   ON CONFLICT(address) DO UPDATE SET
     balance    = balance - ?,
     utxo_count = utxo_count - 1`,
);

const deleteBlock = db.prepare("DELETE FROM blocks WHERE height = ?");
const deleteOutputsAt = db.prepare("DELETE FROM outputs WHERE height = ?");
const selectOutputsAt = db.prepare(
  "SELECT address, value FROM outputs WHERE height = ? AND address IS NOT NULL",
);
const selectSpentAt = db.prepare(
  "SELECT o.address, o.value FROM outputs o WHERE o.spent_height = ? AND o.address IS NOT NULL",
);
const unspendAt = db.prepare(
  "UPDATE outputs SET spent_txid = NULL, spent_height = NULL WHERE spent_height = ?",
);
const deleteAddrTxAt = db.prepare("DELETE FROM address_txs WHERE height = ?");

const ingestBlock = db.transaction((block: RpcBlock) => {
  insertBlock.run(block.height, block.hash, block.time);
  for (const tx of block.tx) {
    // outputs
    for (const vo of tx.vout) {
      const addr = voutAddress(vo);
      const sats = txcToSats(vo.value);
      insertOutput.run(tx.txid, vo.n, addr, sats, block.height);
      if (addr) {
        insertAddrTx.run(addr, tx.txid, block.height);
        bumpBalance.run(addr, sats);
      }
    }
    // inputs (skip coinbase)
    for (const vi of tx.vin) {
      if (!vi.txid || vi.vout === undefined) continue;
      const prev = getPrevOut.get(vi.txid, vi.vout) as
        | { address: string | null; value: number }
        | undefined;
      markSpent.run(tx.txid, block.height, vi.txid, vi.vout);
      if (prev?.address) {
        insertAddrTx.run(prev.address, tx.txid, block.height);
        // negative sats so the INSERT branch is also self-consistent if
        // we somehow see this address for the first time on a spend.
        dropBalance.run(prev.address, -prev.value, prev.value);
      }
    }
  }
});

const rollback = db.transaction((height: number) => {
  // Reverse balance effects before mutating the underlying outputs rows.
  // 1) Outputs spent AT this height become unspent again → add back.
  for (const row of selectSpentAt.all(height) as Array<{ address: string; value: number }>) {
    bumpBalance.run(row.address, row.value);
  }
  // 2) Outputs CREATED at this height go away → subtract.
  //    (Anything that was spent at a later height is impossible because
  //    rollback only ever runs for the current tip.)
  for (const row of selectOutputsAt.all(height) as Array<{ address: string; value: number }>) {
    dropBalance.run(row.address, -row.value, row.value);
  }
  unspendAt.run(height);
  deleteAddrTxAt.run(height);
  deleteOutputsAt.run(height);
  deleteBlock.run(height);
});


async function syncOnce(): Promise<void> {
  const nodeHeight = await getBlockCount();
  let localHeight = getTipHeight();

  // Reorg detection: if our tip exists and doesn't match the node's block at
  // that height, roll back until we re-converge.
  while (localHeight >= 0) {
    const localHash = getBlockHashAt(localHeight);
    if (!localHash) break;
    const nodeHash = await getBlockHash(localHeight).catch(() => null);
    if (nodeHash && nodeHash === localHash) break;
    console.log(`[indexer] reorg at ${localHeight}, rolling back`);
    rollback(localHeight);
    localHeight--;
  }

  for (let h = localHeight + 1; h <= nodeHeight; h++) {
    const hash = await getBlockHash(h);
    const block = await getBlockVerbose(hash);
    ingestBlock(block);
    if (h % 100 === 0 || h === nodeHeight) {
      console.log(`[indexer] indexed block ${h} / ${nodeHeight} (${block.tx.length} tx)`);
    }
  }
}

export async function runIndexerLoop(): Promise<void> {
  // Block sync loop
  (async () => {
    for (;;) {
      try {
        await syncOnce();
      } catch (err) {
        console.error("[indexer] sync error:", (err as Error).message);
      }
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  })();

  // Mempool refresh loop
  (async () => {
    for (;;) {
      try {
        await refreshMempool();
      } catch (err) {
        console.error("[indexer] mempool refresh error:", (err as Error).message);
      }
      await new Promise((r) => setTimeout(r, MEMPOOL_REFRESH_MS));
    }
  })();
}

// ----------------- Mempool snapshot -----------------

const clearMempool = db.prepare("DELETE FROM mempool_address_txs");
const insertMempoolAddrTx = db.prepare(
  "INSERT OR REPLACE INTO mempool_address_txs(address, txid, delta) VALUES (?, ?, ?)",
);

async function refreshMempool(): Promise<void> {
  const txids = await getRawMempool();
  // Per-tx, sum funded and spent amounts per address.
  const perTx = new Map<string, Map<string, number>>(); // txid -> addr -> delta sats
  for (const txid of txids.slice(0, 5000)) {
    let tx;
    try {
      tx = await getRawTx(txid);
    } catch {
      continue; // dropped between getrawmempool and getrawtransaction
    }
    const addrDelta = new Map<string, number>();
    for (const vo of tx.vout) {
      const addr = voutAddress(vo);
      if (!addr) continue;
      addrDelta.set(addr, (addrDelta.get(addr) ?? 0) + txcToSats(vo.value));
    }
    for (const vi of tx.vin) {
      if (!vi.txid || vi.vout === undefined) continue;
      const prev = getPrevOut.get(vi.txid, vi.vout) as
        | { address: string | null; value: number }
        | undefined;
      if (prev?.address) {
        addrDelta.set(prev.address, (addrDelta.get(prev.address) ?? 0) - prev.value);
      }
    }
    if (addrDelta.size) perTx.set(txid, addrDelta);
  }

  const writeAll = db.transaction(() => {
    clearMempool.run();
    for (const [txid, addrDelta] of perTx) {
      for (const [addr, delta] of addrDelta) {
        insertMempoolAddrTx.run(addr, txid, delta);
      }
    }
  });
  writeAll();
}
