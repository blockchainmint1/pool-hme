#!/usr/bin/env node
/**
 * nicehash-proxy — a tiny stratum shim that makes the yiimp scrypt stratum
 * pass NiceHash / MiningRigRentals pool verification without touching
 * /var/stratum/scrypt.conf.
 *
 * Why it exists (measured against stratum.pool.honest.money:3433):
 *
 *   1. The subscribe reply advertises  [["mining.set_difficulty","16"], ...]
 *      NiceHash reads THAT string, not the later set_difficulty notification,
 *      and rejects with "Pool difficulty too low (provided=16, minimum=50000)".
 *   2. The first real mining.notify only lands 6-11s after connect (yiimp
 *      pushes on the next broadcast tick). Verifiers time out at ~5-10s and
 *      log "Unknown message".
 *
 * What the proxy does per client connection:
 *   - forwards everything to the real stratum, byte for byte, both ways
 *   - rewrites the difficulty string inside the subscribe reply to MIN_DIFF
 *   - appends `d=<MIN_DIFF>` to mining.authorize passwords that lack it
 *   - raises any upstream mining.set_difficulty below MIN_DIFF to MIN_DIFF
 *     (raising is always safe: shares that meet a higher target also meet
 *     the lower one the pool is checking against)
 *   - immediately emits set_difficulty + the most recent cached job so the
 *     verifier sees work in <1s; the genuine job replaces it moments later
 *
 * The cached job comes from a persistent "sentinel" connection this process
 * keeps open upstream. mining.notify carries no extranonce1, and yiimp job
 * ids are pool-global, so a sentinel job is valid work for any connection.
 *
 * Config via env (see /etc/nicehash-proxy/env):
 *   LISTEN_PORT    default 3533
 *   UPSTREAM_HOST  default 127.0.0.1
 *   UPSTREAM_PORT  default 3433
 *   MIN_DIFF       default 65536
 *   SENTINEL_USER  LTC address used by the sentinel connection
 */

const net = require("net");

const LISTEN_PORT = Number(process.env.LISTEN_PORT || 3533);
const UPSTREAM_HOST = process.env.UPSTREAM_HOST || "127.0.0.1";
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT || 3433);
const MIN_DIFF = Number(process.env.MIN_DIFF || 65536);
const SENTINEL_USER = process.env.SENTINEL_USER || "";

const log = (...a) => console.log(new Date().toISOString(), ...a);

/* ------------------------------------------------------------------ */
/* sentinel: keeps one upstream session alive purely to cache jobs      */
/* ------------------------------------------------------------------ */

let cachedJob = null; // last mining.notify params array
let cachedAt = 0;

function startSentinel() {
  if (!SENTINEL_USER) {
    log("sentinel disabled (SENTINEL_USER unset) — cold start will be slow");
    return;
  }
  let sock;
  const connect = () => {
    sock = net.connect(UPSTREAM_PORT, UPSTREAM_HOST);
    sock.setKeepAlive(true, 30000);
    let buf = "";
    sock.on("connect", () => {
      log("sentinel connected");
      sock.write(
        JSON.stringify({ id: 1, method: "mining.subscribe", params: ["nicehash-proxy/1.0"] }) +
          "\n" +
          JSON.stringify({
            id: 2,
            method: "mining.authorize",
            params: [SENTINEL_USER, `d=${MIN_DIFF}`],
          }) +
          "\n",
      );
    });
    sock.on("data", (chunk) => {
      buf += chunk.toString();
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        let m;
        try {
          m = JSON.parse(line);
        } catch {
          continue;
        }
        if (m.method === "mining.notify" && Array.isArray(m.params)) {
          cachedJob = m.params;
          cachedAt = Date.now();
        }
      }
    });
    const retry = () => {
      sock.destroy();
      setTimeout(connect, 5000);
    };
    sock.on("error", (e) => {
      log("sentinel error", e.message);
      retry();
    });
    sock.on("close", retry);
  };
  connect();
}

/* ------------------------------------------------------------------ */
/* per-client proxying                                                  */
/* ------------------------------------------------------------------ */

function rewriteSubscribeReply(msg) {
  // result: [[["mining.set_difficulty","16"],["mining.notify","<id>"]], extranonce1, size]
  const r = msg.result;
  if (!Array.isArray(r) || !Array.isArray(r[0])) return false;
  let changed = false;
  for (const pair of r[0]) {
    if (Array.isArray(pair) && pair[0] === "mining.set_difficulty") {
      if (String(pair[1]) !== String(MIN_DIFF)) {
        pair[1] = String(MIN_DIFF);
        changed = true;
      }
    }
  }
  return changed;
}

function withMinDiffPassword(params) {
  const p = Array.isArray(params) ? [...params] : [];
  const pass = typeof p[1] === "string" ? p[1] : "";
  if (/(^|,)\s*d=/i.test(pass)) return p; // caller already set difficulty
  p[1] = pass ? `d=${MIN_DIFF},${pass}` : `d=${MIN_DIFF}`;
  return p;
}

const server = net.createServer((client) => {
  const tag = `${client.remoteAddress}:${client.remotePort}`;
  const up = net.connect(UPSTREAM_PORT, UPSTREAM_HOST);
  up.setKeepAlive(true, 30000);
  client.setKeepAlive(true, 30000);

  let subscribeId = null;
  let primed = false;
  let sawRealJob = false;
  let cbuf = "";
  let ubuf = "";

  const send = (sock, obj) => {
    if (!sock.destroyed) sock.write(JSON.stringify(obj) + "\n");
  };

  // Give the verifier difficulty + work immediately after it authorizes.
  const prime = () => {
    if (primed) return;
    primed = true;
    send(client, { id: null, method: "mining.set_difficulty", params: [MIN_DIFF] });
    if (cachedJob && Date.now() - cachedAt < 120000) {
      const job = [...cachedJob];
      job[8] = true; // clean_jobs
      send(client, { id: null, method: "mining.notify", params: job });
      log(`${tag} primed with cached job ${job[0]}`);
    }
  };

  client.on("data", (chunk) => {
    cbuf += chunk.toString();
    let i;
    while ((i = cbuf.indexOf("\n")) >= 0) {
      const line = cbuf.slice(0, i);
      cbuf = cbuf.slice(i + 1);
      if (!line.trim()) continue;
      let m;
      try {
        m = JSON.parse(line);
      } catch {
        up.write(line + "\n");
        continue;
      }
      if (m.method === "mining.subscribe") subscribeId = m.id;
      if (m.method === "mining.authorize") {
        m.params = withMinDiffPassword(m.params);
        up.write(JSON.stringify(m) + "\n");
        setTimeout(prime, 300);
        continue;
      }
      up.write(JSON.stringify(m) + "\n");
    }
  });

  up.on("data", (chunk) => {
    ubuf += chunk.toString();
    let i;
    while ((i = ubuf.indexOf("\n")) >= 0) {
      const line = ubuf.slice(0, i);
      ubuf = ubuf.slice(i + 1);
      if (!line.trim()) continue;
      let m;
      try {
        m = JSON.parse(line);
      } catch {
        client.write(line + "\n");
        continue;
      }

      if (subscribeId !== null && m.id === subscribeId && m.result) {
        rewriteSubscribeReply(m);
      }
      if (m.method === "mining.set_difficulty" && Array.isArray(m.params)) {
        if (Number(m.params[0]) < MIN_DIFF) m.params[0] = MIN_DIFF;
      }
      if (m.method === "mining.notify") sawRealJob = true;

      if (!client.destroyed) client.write(JSON.stringify(m) + "\n");
    }
  });

  const shut = () => {
    client.destroy();
    up.destroy();
  };
  client.on("error", shut);
  client.on("close", () => {
    if (!sawRealJob) log(`${tag} closed before first real job`);
    shut();
  });
  up.on("error", (e) => {
    log(`${tag} upstream error ${e.message}`);
    shut();
  });
  up.on("close", shut);
});

server.on("error", (e) => {
  log("listener error", e.message);
  process.exit(1);
});

startSentinel();
server.listen(LISTEN_PORT, "0.0.0.0", () =>
  log(
    `nicehash-proxy listening :${LISTEN_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT} (min_diff=${MIN_DIFF})`,
  ),
);
