/**
 * nicehash-api.cjs — NiceHash API v2 client.
 *
 * Auth: HMAC-SHA256 over null-byte-delimited fields
 *   [apiKey, time, nonce, "", orgId, "", method, path, query, (body)]
 * with empty fields producing adjacent separators (double-null). The secret
 * key is used as a UTF-8 string. X-Auth header = "<apiKey>:<hexSig>".
 *
 * Reference cross-checked against nicehashjs2.generateInputBuffer docs and the
 * nicehash-api2 signing implementation. Node 18+ global fetch is used.
 */
"use strict";

const crypto = require("crypto");

const BASE = "https://api2.nicehash.com";

class NiceHashAPI {
  constructor({ apiKey, apiSecret, orgId }) {
    if (!apiKey || !apiSecret || !orgId) {
      throw new Error("NiceHashAPI requires apiKey, apiSecret, orgId");
    }
    this.apiKey = apiKey;
    this.apiSecret = apiSecret;
    this.orgId = orgId;
    this._timeOffset = 0; // serverTime - localTime (ms)
    this._timeCheckedAt = 0;
  }

  // ---- time sync -----------------------------------------------------------
  async syncTime() {
    const now = Date.now();
    if (this._timeCheckedAt && now - this._timeCheckedAt < 60000) {
      return this._timeOffset;
    }
    try {
      const res = await this._unsigned("GET", "/main/api/v2/time");
      const server = Number(res.milliseconds);
      if (server) {
        this._timeOffset = server - Date.now();
        this._timeCheckedAt = now;
      }
      return this._timeOffset;
    } catch (e) {
      // fall back to local time (box is NTP-synced)
      return this._timeOffset;
    }
  }

  serverTime() {
    return Date.now() + this._timeOffset;
  }

  // ---- signing -------------------------------------------------------------
  _buildQuery(params) {
    if (!params) return "";
    const sp = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined || v === null || v === "") continue;
      sp.set(k, String(v));
    }
    return sp.toString();
  }

  _sign(method, path, queryStr, bodyStr) {
    const time = String(this.serverTime());
    const nonce = crypto.randomUUID();
    const fields = [
      this.apiKey,
      time,
      nonce,
      "",
      this.orgId,
      "",
      method.toUpperCase(),
      path,
      queryStr,
    ];
    if (bodyStr) fields.push(bodyStr);
    const bufs = [];
    for (let i = 0; i < fields.length; i++) {
      bufs.push(Buffer.from(fields[i], "latin1"));
      if (i < fields.length - 1) bufs.push(Buffer.from([0x00]));
    }
    const input = Buffer.concat(bufs);
    const sig = crypto
      .createHmac("sha256", this.apiSecret)
      .update(input)
      .digest("hex");
    return { sig, time, nonce };
  }

  async _request(method, path, { params, body } = {}) {
    await this.syncTime();
    const queryStr = this._buildQuery(params);
    const bodyStr = body !== undefined ? JSON.stringify(body) : "";
    const { sig, time, nonce } = this._sign(method, path, queryStr, bodyStr);

    const url = BASE + path + (queryStr ? `?${queryStr}` : "");
    const headers = {
      "X-Auth": `${this.apiKey}:${sig}`,
      "X-Time": time,
      "X-Nonce": nonce,
      "X-Organization-Id": this.orgId,
      "X-Request-Id": nonce,
      "User-Agent": "honest-money-nicehash-watcher/1.0",
    };
    if (bodyStr) {
      headers["Content-Type"] = "application/json";
    }

    const res = await fetch(url, {
      method: method.toUpperCase(),
      headers,
      body: bodyStr || undefined,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch (_) {
      /* non-json */
    }
    if (!res.ok) {
      const err = new Error(
        `NiceHash ${method} ${path} -> ${res.status}: ${text.slice(0, 500)}`,
      );
      err.status = res.status;
      err.body = json;
      throw err;
    }
    return json;
  }

  async _unsigned(method, path, params) {
    const queryStr = this._buildQuery(params);
    const url = BASE + path + (queryStr ? `?${queryStr}` : "");
    const res = await fetch(url, {
      method,
      headers: { "User-Agent": "honest-money-nicehash-watcher/1.0" },
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`NiceHash ${path} -> ${res.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : null;
  }

  // ---- public endpoints ---------------------------------------------------
  /** Public order book — no auth needed. */
  async getOrderBook(algorithm = "SCRYPT", market = "BTC") {
    return this._unsigned("GET", "/main/api/v2/hashpower/orderBook", {
      algorithm,
      market,
    });
  }

  // ---- pools --------------------------------------------------------------
  async getPools(size = 100) {
    return this._request("GET", "/main/api/v2/pools", {
      params: { price: 0, size },
    });
  }

  async createPool(pool) {
    return this._request("POST", "/main/api/v2/pool", { body: pool });
  }

  /** Find a pool by username or host; create if missing. Returns pool id. */
  async ensurePool({ name, algorithm, host, username, password, coin, location = 0, type = "PROP", fee = 0.0 }) {
    const { list } = (await this.getPools(100)) || {};
    const existing = (list || []).find(
      (p) => p.username === username || (p.pool || "").includes(host),
    );
    if (existing) return existing.id;
    const created = await this.createPool({
      name,
      algorithm,
      pool: host,
      username,
      password,
      coin,
      location,
      type,
      fee,
      enabled: true,
    });
    return created.id;
  }

  // ---- orders -------------------------------------------------------------
  async createOrder(order) {
    return this._request("POST", "/main/api/v2/hashpower/order", { body: order });
  }

  async getOrder(id) {
    return this._request("GET", `/main/api/v2/hashpower/order/${id}`);
  }

  async cancelOrder(id) {
    return this._request("DELETE", `/main/api/v2/hashpower/order/${id}`);
  }

  async refillOrder(id, amount) {
    return this._request("POST", `/main/api/v2/hashpower/order/${id}/refill`, {
      body: { amount },
    });
  }

  async updatePriceAndLimit(id, { price, limit }) {
    return this._request(
      "POST",
      `/main/api/v2/hashpower/order/${id}/updatePriceAndLimit`,
      { body: { price, limit } },
    );
  }

  /** Active orders for an algorithm. */
  async getActiveOrders(algorithm = "SCRYPT", market = "BTC") {
    const ts = Math.floor(Date.now() / 1000);
    const data = await this._request("GET", "/main/api/v2/hashpower/myOrders", {
      params: { op: "GT", limit: 100, ts, algorithm, status: "ACTIVE", active: true, market },
    });
    return data;
  }
}

module.exports = { NiceHashAPI };
