/**
 * DOGE payout registration — write path.
 *
 * Reimplements yiimp's SiteController::actionDogeRegisterSubmit exactly,
 * so the rows this produces are indistinguishable from the 41 rows the PHP
 * page created. Nothing in the payout pipeline reads the web form; it only
 * reads these three tables:
 *
 *   accounts             — zero-balance LTC mining account (username = LTC addr)
 *   doge_token_history   — every token ever issued, UNIQUE, burned forever
 *   doge_address_links   — the live link the payout cron joins against
 *
 * Uses a SEPARATE MySQL user from the read-only API user. Grants required:
 *   SELECT, INSERT         ON yiimpfrontend.accounts
 *   SELECT, INSERT, UPDATE ON yiimpfrontend.doge_address_links
 *   SELECT, INSERT         ON yiimpfrontend.doge_token_history
 *   SELECT                 ON yiimpfrontend.coins
 * No DELETE anywhere. Additive only — an existing link is never rewritten.
 */
import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import mysql from "mysql2/promise";

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

export const REGISTER_ENABLED =
  (process.env.DOGE_REGISTER_ENABLED ?? "0") === "1";

const CAPTCHA_SECRET =
  process.env.REGISTER_CAPTCHA_SECRET ?? randomBytes(32).toString("hex");
const CAPTCHA_TTL_MS = 10 * 60 * 1000;

const REGISTER_RATE_PER_HOUR = Number(
  process.env.DOGE_REGISTER_RATE_LIMIT_PER_HOUR ?? 10,
);

// Mirrors dogeAddressNetworkMode() on the PHP side.
const ADDRESS_MODE = (process.env.DOGE_ADDRESS_MODE ?? "mainnet").toLowerCase();

const LTC_CONF = process.env.LTC_CONF ?? "/home/ubuntu/.litecoin/litecoin.conf";
const DOGE_CONF = process.env.DOGE_CONF ?? "/home/ubuntu/.dogecoin/dogecoin.conf";

// ---------------------------------------------------------------------------
// write-scoped pool (lazy — never created when registration is disabled)
// ---------------------------------------------------------------------------

let writePool: mysql.Pool | null = null;

export function getWritePool(): mysql.Pool {
  if (!writePool) {
    writePool = mysql.createPool({
      host: process.env.MYSQL_HOST ?? "127.0.0.1",
      port: Number(process.env.MYSQL_PORT ?? 3306),
      user: process.env.MYSQL_REG_USER ?? "yiimp_reg",
      password: process.env.MYSQL_REG_PASSWORD ?? "",
      database: process.env.MYSQL_DATABASE ?? "yiimpfrontend",
      connectionLimit: 5,
      waitForConnections: true,
      connectTimeout: 5_000,
    });
  }
  return writePool;
}

// ---------------------------------------------------------------------------
// address format validation — 1:1 with dogeValidateAddressFormat()
// ---------------------------------------------------------------------------

const B58 = "[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]";
const B32 = "[023456789acdefghjklmnpqrstuvwxyz]";

export function describeFormat(symbol: string): string {
  if (symbol === "LTC") {
    return ADDRESS_MODE === "mainnet"
      ? "mainnet Litecoin address (ltc1… or L/M/3…)"
      : "testnet Litecoin address (tltc1… or m/n/2/Q…)";
  }
  return ADDRESS_MODE === "mainnet"
    ? "mainnet Dogecoin address (D…, A… or 9…)"
    : "testnet Dogecoin address (m/n/2…)";
}

export function validateAddressFormat(
  symbol: "LTC" | "DOGE",
  raw: string,
): { ok: boolean; error?: string } {
  const address = (raw ?? "").trim();
  const bad = {
    ok: false,
    error: `Invalid ${symbol} address format. This server is configured for ${ADDRESS_MODE} addresses; use a ${describeFormat(symbol)}.`,
  };

  if (address === "" || /[^A-Za-z0-9]/.test(address)) {
    return {
      ok: false,
      error: `Invalid ${symbol} address. Use a ${describeFormat(symbol)}.`,
    };
  }

  if (symbol === "LTC") {
    if (ADDRESS_MODE === "mainnet") {
      if (new RegExp(`^ltc1${B32}{8,90}$`, "i").test(address)) return { ok: true };
      if (new RegExp(`^[LM3]${B58}{25,60}$`).test(address)) return { ok: true };
    } else {
      if (new RegExp(`^tltc1${B32}{8,90}$`, "i").test(address)) return { ok: true };
      if (new RegExp(`^[mn2Q]${B58}{25,60}$`).test(address)) return { ok: true };
    }
  } else {
    if (ADDRESS_MODE === "mainnet") {
      if (new RegExp(`^[DA9]${B58}{25,60}$`).test(address)) return { ok: true };
    } else {
      if (new RegExp(`^[mn2]${B58}{25,60}$`).test(address)) return { ok: true };
    }
  }

  return bad;
}

// ---------------------------------------------------------------------------
// captcha — stateless, HMAC-signed arithmetic challenge
// ---------------------------------------------------------------------------

export interface CaptchaChallenge {
  question: string;
  nonce: string;
  expires: number;
  sig: string;
}

function captchaSign(nonce: string, expires: number, answer: number): string {
  return createHmac("sha256", CAPTCHA_SECRET)
    .update(`${nonce}.${expires}.${answer}`)
    .digest("hex");
}

export function issueCaptcha(): CaptchaChallenge {
  const a = 2 + Math.floor(Math.random() * 8);
  const b = 2 + Math.floor(Math.random() * 8);
  const plus = Math.random() < 0.5;
  const answer = plus ? a + b : a * b;
  const nonce = randomUUID();
  const expires = Date.now() + CAPTCHA_TTL_MS;
  return {
    question: `What is ${a} ${plus ? "+" : "×"} ${b}?`,
    nonce,
    expires,
    sig: captchaSign(nonce, expires, answer),
  };
}

const usedNonces = new Map<string, number>();

export function verifyCaptcha(input: {
  nonce?: unknown;
  expires?: unknown;
  sig?: unknown;
  answer?: unknown;
}): { ok: boolean; error?: string } {
  const nonce = String(input.nonce ?? "");
  const expires = Number(input.expires ?? 0);
  const sig = String(input.sig ?? "");
  const answer = Number(input.answer ?? NaN);

  const fail = { ok: false, error: "Captcha answer was incorrect. Please try again." };
  if (!nonce || !sig || !Number.isFinite(expires) || !Number.isFinite(answer)) return fail;
  if (Date.now() > expires) {
    return { ok: false, error: "Captcha expired. Please try again." };
  }

  // one-shot: a signed challenge can never be replayed
  const now = Date.now();
  for (const [k, exp] of usedNonces) if (exp < now) usedNonces.delete(k);
  if (usedNonces.has(nonce)) return fail;

  const expected = Buffer.from(captchaSign(nonce, expires, answer), "utf8");
  const given = Buffer.from(sig, "utf8");
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return fail;

  usedNonces.set(nonce, expires);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// rate limiting — IP bucket, matches the PHP hourly window
// ---------------------------------------------------------------------------

const buckets = new Map<string, number[]>();

export function checkRateLimit(ip: string, limit = REGISTER_RATE_PER_HOUR): boolean {
  const now = Date.now();
  const windowStart = now - 3600_000;
  const hits = (buckets.get(ip) ?? []).filter((t) => t > windowStart);
  if (hits.length >= limit) {
    buckets.set(ip, hits);
    return false;
  }
  hits.push(now);
  buckets.set(ip, hits);
  return true;
}

// ---------------------------------------------------------------------------
// daemon RPC — validateaddress is the authoritative wrong-chain check
// ---------------------------------------------------------------------------

interface RpcConf {
  url: string;
  user: string;
  pass: string;
}

function parseConf(path: string, defaultPort: number): RpcConf | null {
  try {
    const text = readFileSync(path, "utf8");
    const get = (key: string) => {
      const m = text.match(new RegExp(`^\\s*${key}\\s*=\\s*(.+)\\s*$`, "mi"));
      return m ? m[1].trim() : "";
    };
    const user = get("rpcuser");
    const pass = get("rpcpassword");
    if (!user || !pass) return null;
    const port = Number(get("rpcport") || defaultPort);
    return { url: `http://127.0.0.1:${port}/`, user, pass };
  } catch {
    return null;
  }
}

function rpcConf(symbol: "LTC" | "DOGE"): RpcConf | null {
  const envUser = process.env[`${symbol}_RPC_USER`];
  const envPass = process.env[`${symbol}_RPC_PASSWORD`];
  const envUrl = process.env[`${symbol}_RPC_URL`];
  if (envUser && envPass) {
    return {
      url: envUrl ?? `http://127.0.0.1:${symbol === "LTC" ? 9332 : 22555}/`,
      user: envUser,
      pass: envPass,
    };
  }
  return symbol === "LTC"
    ? parseConf(LTC_CONF, 9332)
    : parseConf(DOGE_CONF, 22555);
}

export function rpcAvailable(): { ltc: boolean; doge: boolean } {
  return { ltc: !!rpcConf("LTC"), doge: !!rpcConf("DOGE") };
}

/**
 * Returns true when the daemon says the address is valid, false when it says
 * it is not, and null when we could not reach the daemon at all.
 */
export async function daemonValidateAddress(
  symbol: "LTC" | "DOGE",
  address: string,
): Promise<boolean | null> {
  const conf = rpcConf(symbol);
  if (!conf) return null;
  try {
    const res = await fetch(conf.url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization:
          "Basic " + Buffer.from(`${conf.user}:${conf.pass}`).toString("base64"),
      },
      body: JSON.stringify({
        jsonrpc: "1.0",
        id: "yiimp-api",
        method: "validateaddress",
        params: [address],
      }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { result?: { isvalid?: boolean } };
    if (!json.result || typeof json.result.isvalid !== "boolean") return null;
    return json.result.isvalid;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// token minting — 24 uppercase hex chars, burned into history forever
// ---------------------------------------------------------------------------

async function createPermanentToken(
  conn: mysql.PoolConnection,
  ltcAccountId: number,
  ltcAddress: string,
  dogeAddress: string,
  reason: string,
): Promise<string> {
  for (let i = 0; i < 100; i++) {
    const token = randomBytes(16).toString("hex").slice(0, 24).toUpperCase();

    const [existing] = await conn.query<mysql.RowDataPacket[]>(
      "SELECT id FROM doge_address_links WHERE permanent_token = ? LIMIT 1",
      [token],
    );
    if (existing.length) continue;

    try {
      await conn.query(
        `INSERT INTO doge_token_history
           (permanent_token, ltc_account_id, ltc_address, doge_address, issued_at, reason)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [token, ltcAccountId, ltcAddress, dogeAddress, Math.floor(Date.now() / 1000), reason],
      );
      return token;
    } catch {
      // duplicate-key race — the history table is the real guard, retry
      continue;
    }
  }
  throw new Error("Unable to issue a unique DOGE token. Please try again.");
}

// ---------------------------------------------------------------------------
// register
// ---------------------------------------------------------------------------

export interface RegisterResult {
  status: number;
  body: Record<string, unknown>;
}

export async function registerDogeLink(input: {
  ltcAddress: string;
  dogeAddress: string;
  ip: string;
}): Promise<RegisterResult> {
  const ltcAddress = input.ltcAddress.trim();
  const dogeAddress = input.dogeAddress.trim();

  const ltcFmt = validateAddressFormat("LTC", ltcAddress);
  if (!ltcFmt.ok) return { status: 400, body: { error: ltcFmt.error, field: "ltc_address" } };
  const dogeFmt = validateAddressFormat("DOGE", dogeAddress);
  if (!dogeFmt.ok) return { status: 400, body: { error: dogeFmt.error, field: "doge_address" } };

  const db = getWritePool();

  // duplicate check before touching the daemons
  const [dupes] = await db.query<mysql.RowDataPacket[]>(
    `SELECT ltc_address, doge_address FROM doge_address_links
      WHERE ltc_address = ? OR doge_address = ? LIMIT 1`,
    [ltcAddress, dogeAddress],
  );
  if (dupes.length) {
    const row = dupes[0];
    const which = row.ltc_address === ltcAddress ? "LTC mining address" : "DOGE payout address";
    return {
      status: 409,
      body: {
        error: `That ${which} is already registered. Use the wallet page to update an existing registration.`,
        field: row.ltc_address === ltcAddress ? "ltc_address" : "doge_address",
      },
    };
  }

  // authoritative wrong-chain check
  const ltcValid = await daemonValidateAddress("LTC", ltcAddress);
  if (ltcValid === false) {
    return { status: 400, body: { error: "LTC wallet rejected this mining address.", field: "ltc_address" } };
  }
  const dogeValid = await daemonValidateAddress("DOGE", dogeAddress);
  if (dogeValid === false) {
    return { status: 400, body: { error: "DOGE wallet rejected this payout address.", field: "doge_address" } };
  }
  if (ltcValid === null || dogeValid === null) {
    return {
      status: 503,
      body: { error: "Address verification is temporarily unavailable. Please try again shortly." },
    };
  }

  const [coinRows] = await db.query<mysql.RowDataPacket[]>(
    "SELECT id, symbol FROM coins WHERE symbol = 'LTC' LIMIT 1",
  );
  const ltcCoin = coinRows[0];
  if (!ltcCoin) {
    return { status: 503, body: { error: "LTC is not configured on this pool right now." } };
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    const now = Math.floor(Date.now() / 1000);
    const [accountRes] = await conn.query<mysql.ResultSetHeader>(
      `INSERT INTO accounts (username, coinid, coinsymbol, balance, donation, hostaddr)
       VALUES (?, ?, ?, 0, 0, ?)`,
      [ltcAddress, ltcCoin.id, ltcCoin.symbol, input.ip],
    );
    const accountId = accountRes.insertId;

    const token = await createPermanentToken(
      conn,
      accountId,
      ltcAddress,
      dogeAddress,
      "register",
    );

    await conn.query(
      `INSERT INTO doge_address_links
         (ltc_account_id, ltc_address, doge_address, permanent_token, active,
          token_last_seen, created_at, updated_at)
       VALUES (?, ?, ?, ?, 1, NULL, ?, ?)`,
      [accountId, ltcAddress, dogeAddress, token, now, now],
    );

    await conn.commit();

    return {
      status: 201,
      body: {
        ok: true,
        ltc_address: ltcAddress,
        doge_address: dogeAddress,
        permanent_token: token,
        stratum_password: `dogelink=${token}`,
        message:
          "DOGE payout registration created. Copy the permanent token now — it is only shown once.",
      },
    };
  } catch (err) {
    try {
      await conn.rollback();
    } catch {
      /* connection already gone */
    }
    const msg = err instanceof Error ? err.message : "";
    if (/Duplicate entry/i.test(msg)) {
      return {
        status: 409,
        body: { error: "That address pair is already registered." },
      };
    }
    return {
      status: 500,
      body: { error: "Unable to create DOGE payout registration. Please try again." },
    };
  } finally {
    conn.release();
  }
}

// ---------------------------------------------------------------------------
// lookup / token status — read paths, never return the token or full addresses
// ---------------------------------------------------------------------------

function mask(addr: string): string {
  if (addr.length <= 12) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export async function lookupLink(
  db: mysql.Pool,
  ltcAddress: string,
): Promise<Record<string, unknown>> {
  const [rows] = await db.query<mysql.RowDataPacket[]>(
    `SELECT doge_address, active, token_last_seen, created_at
       FROM doge_address_links WHERE ltc_address = ? LIMIT 1`,
    [ltcAddress],
  );
  const row = rows[0];
  if (!row) return { registered: false };
  return {
    registered: true,
    doge_address_masked: mask(String(row.doge_address)),
    active: Number(row.active) === 1,
    token_last_seen: Number(row.token_last_seen ?? 0),
    created_at: Number(row.created_at ?? 0),
  };
}

const TOKEN_WINDOW_SECONDS = Number(process.env.DOGE_TOKEN_WINDOW ?? 86400);

export async function tokenStatus(
  db: mysql.Pool,
  token: string,
): Promise<Record<string, unknown>> {
  const [rows] = await db.query<mysql.RowDataPacket[]>(
    `SELECT active, token_last_seen FROM doge_address_links
      WHERE permanent_token = ? LIMIT 1`,
    [token.toUpperCase()],
  );
  const row = rows[0];
  if (!row) return { known: false };
  const lastSeen = Number(row.token_last_seen ?? 0);
  const nowSec = Math.floor(Date.now() / 1000);
  return {
    known: true,
    active: Number(row.active) === 1,
    token_last_seen: lastSeen,
    seen_in_payout_window: lastSeen > 0 && nowSec - lastSeen < TOKEN_WINDOW_SECONDS,
    payout_window_seconds: TOKEN_WINDOW_SECONDS,
  };
}
