import Database from "better-sqlite3";

const DB_PATH = process.env.DB_PATH ?? "./indexer.sqlite";

export const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("synchronous = NORMAL");
db.pragma("temp_store = MEMORY");
db.pragma("mmap_size = 268435456"); // 256 MiB

db.exec(`
  CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  -- Outputs: every tx output we've seen. Address may be NULL for
  -- nonstandard / OP_RETURN / multisig-without-single-address outputs.
  CREATE TABLE IF NOT EXISTS outputs (
    txid         TEXT NOT NULL,
    vout         INTEGER NOT NULL,
    address      TEXT,
    value        INTEGER NOT NULL,   -- satoshis
    height       INTEGER NOT NULL,   -- block height where created
    spent_txid   TEXT,
    spent_height INTEGER,
    PRIMARY KEY (txid, vout)
  );
  CREATE INDEX IF NOT EXISTS idx_outputs_address
    ON outputs(address, height);
  CREATE INDEX IF NOT EXISTS idx_outputs_unspent
    ON outputs(address) WHERE spent_txid IS NULL AND address IS NOT NULL;

  -- (address, txid) pairs — both funding txs and spending txs for an address.
  -- Used to answer "list all txs touching address X".
  CREATE TABLE IF NOT EXISTS address_txs (
    address TEXT NOT NULL,
    txid    TEXT NOT NULL,
    height  INTEGER NOT NULL,
    PRIMARY KEY (address, txid)
  );
  CREATE INDEX IF NOT EXISTS idx_addrtx_addr_height
    ON address_txs(address, height DESC, txid);

  -- Track which blocks we've ingested so we can detect reorgs / resume.
  CREATE TABLE IF NOT EXISTS blocks (
    height INTEGER PRIMARY KEY,
    hash   TEXT NOT NULL,
    time   INTEGER NOT NULL
  );

  -- Mempool snapshot (refreshed on a timer). Lets address pages report
  -- pending activity without scanning the whole mempool on every request.
  CREATE TABLE IF NOT EXISTS mempool_address_txs (
    address  TEXT NOT NULL,
    txid     TEXT NOT NULL,
    delta    INTEGER NOT NULL, -- sats: +funded -spent for this address in this tx
    PRIMARY KEY (address, txid)
  );
  CREATE INDEX IF NOT EXISTS idx_mempool_addr ON mempool_address_txs(address);
`);

export function getMeta(key: string): string | null {
  const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key) as
    | { value: string }
    | undefined;
  return row?.value ?? null;
}
export function setMeta(key: string, value: string): void {
  db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)").run(key, value);
}

export function getTipHeight(): number {
  const row = db.prepare("SELECT MAX(height) AS h FROM blocks").get() as { h: number | null };
  return row.h ?? -1;
}

export function getBlockHashAt(height: number): string | null {
  const row = db.prepare("SELECT hash FROM blocks WHERE height = ?").get(height) as
    | { hash: string }
    | undefined;
  return row?.hash ?? null;
}
