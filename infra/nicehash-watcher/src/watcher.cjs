/**
 * watcher.cjs — NiceHash auto-purchase watcher.
 *
 * Goal: keep the pool's scrypt hashrate at TARGET = max(MIN_TARGET, 7d average)
 * "at any cost." When actual hashrate drops below TRIGGER_FRACTION of TARGET,
 * it rents scrypt hashpower on NiceHash, bidding top-of-market + margin, and
 * actively refills orders until the pool fully recovers, then cancels.
 *
 * Config via environment (see install.sh for the systemd unit + defaults).
 *   NICEHASH_API_KEY, NICEHASH_API_SECRET, NICEHASH_ORG_ID
 *     (aliases: NICEHASH_API, NICEHASH_SECRET, NICEHASH_ORGANIZATION)
 *   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID   alerts (optional)
 *   ALERTS_ENABLED=true  ALERT_COOLDOWN_MIN=30
 *   RENTAL_LTC_ADDR           payout address for the rental NiceHash pool
 *   POOL_API_BASE             e.g. https://api.stratum.pool.honest.money
 *   POOL_HOST                 stratum.pool.honest.money:3533
 *   MIN_TARGET_THS=19  TRIGGER_FRACTION=0.75  RENT_CAP_THS=19
 *   ORDER_AMOUNT_BTC=0.02  REFILL_AMOUNT_BTC=0.02
 *   REFILL_THRESHOLD_BTC=0.005
 *   DAILY_BTC_CAP=0  (0 = disabled; set a number to enforce a hard daily guard)
 *   MAX_CONCURRENT_ORDERS=2
 *   BID_MARGIN=0.10  BID_FLOOR_PRICE=0.0088  BID_MAX_PRICE=0.05
 *   POLL_INTERVAL_SEC=30  RECOVER_CONFIRMATIONS=3
 *   STATE_FILE=/var/lib/nicehash-watcher/state.json
 *   DRY_RUN=false
 *
 * Run: node watcher.cjs
 */
"use strict";

const fs = require("fs");
const path = require("path");
const { NiceHashAPI } = require("./nicehash-api.cjs");
const { PoolAPI } = require("./pool-api.cjs");
const tg = require("./telegram.cjs");

// Accept either the canonical names or the shorter secret names used in the
// Lovable secret store (NICEHASH_API / NICEHASH_SECRET / NICEHASH_ORGANIZATION).
function env(...names) {
  for (const n of names) {
    const v = process.env[n];
    if (v !== undefined && v !== "") return v;
  }
  return "";
}

const CFG = {
  apiKey: env("NICEHASH_API_KEY", "NICEHASH_API"),
  apiSecret: env("NICEHASH_API_SECRET", "NICEHASH_SECRET"),
  orgId: env("NICEHASH_ORG_ID", "NICEHASH_ORGANIZATION", "NICEHASH_ORG"),
  rentalAddr: process.env.RENTAL_LTC_ADDR || "",
  poolApiBase: process.env.POOL_API_BASE || "https://api.stratum.pool.honest.money",
  poolHost: process.env.POOL_HOST || "stratum.pool.honest.money:3533",
  minTargetThs: num("MIN_TARGET_THS", 19),
  triggerFraction: num("TRIGGER_FRACTION", 0.75),
  rentCapThs: num("RENT_CAP_THS", 19),
  orderAmountBtc: num("ORDER_AMOUNT_BTC", 0.02),
  refillAmountBtc: num("REFILL_AMOUNT_BTC", 0.02),
  refillThresholdBtc: num("REFILL_THRESHOLD_BTC", 0.005),
  dailyBtcCap: num("DAILY_BTC_CAP", 0),
  maxConcurrentOrders: num("MAX_CONCURRENT_ORDERS", 2),
  bidMargin: num("BID_MARGIN", 0.10),
  bidFloorPrice: num("BID_FLOOR_PRICE", 0.0088),
  bidMaxPrice: num("BID_MAX_PRICE", 0.05),
  pollIntervalSec: num("POLL_INTERVAL_SEC", 30),
  recoverConfirmations: num("RECOVER_CONFIRMATIONS", 3),
  alertCooldownMin: num("ALERT_COOLDOWN_MIN", 30),
  stateFile: process.env.STATE_FILE || "/var/lib/nicehash-watcher/state.json",
  dryRun: /^1|true|yes$/i.test(process.env.DRY_RUN || "false"),
};

function num(name, def) {
  const v = process.env[name];
  const n = v === undefined || v === "" ? def : Number(v);
  return Number.isFinite(n) ? n : def;
}

function log(msg, obj) {
  const ts = new Date().toISOString();
  const line = obj ? `${ts} ${msg} ${JSON.stringify(obj)}` : `${ts} ${msg}`;
  console.log(line);
}

// ---- state -----------------------------------------------------------------
function loadState() {
  try {
    return JSON.parse(fs.readFileSync(CFG.stateFile, "utf8"));
  } catch (_) {
    return {
      active_orders: [],
      spend_today: { date: utcDate(), btc: 0 },
      target_ths: CFG.minTargetThs,
      target_updated_at: 0,
      recover_count: 0,
      last_pool_hashrate: null,
      last_action: "init",
      pool_id: null,
    };
  }
}

function saveState(state) {
  try {
    fs.mkdirSync(path.dirname(CFG.stateFile), { recursive: true });
    fs.writeFileSync(CFG.stateFile, JSON.stringify(state, null, 2));
  } catch (e) {
    log("WARN: could not persist state file:", { error: String(e.message) });
  }
}

function utcDate() {
  return new Date().toISOString().slice(0, 10);
}

function resetDailySpendIfNewDay(state) {
  const d = utcDate();
  if (state.spend_today.date !== d) {
    state.spend_today = { date: d, btc: 0 };
  }
}

function dailyCapReached(state) {
  if (CFG.dailyBtcCap <= 0) return false;
  return state.spend_today.btc >= CFG.dailyBtcCap;
}

// ---- bidding ----------------------------------------------------------------
function computeBid(orderBook) {
  const orders =
    (orderBook && orderBook.stats && orderBook.stats.BTC &&
      orderBook.stats.BTC.orders) ||
    [];
  const alive = orders.filter((o) => o.alive && Number(o.acceptedSpeed) > 0);
  const top = alive.length
    ? Math.max(...alive.map((o) => Number(o.price)))
    : CFG.bidFloorPrice;
  let bid = top * (1 + CFG.bidMargin);
  if (bid < CFG.bidFloorPrice) bid = CFG.bidFloorPrice;
  const capped = bid > CFG.bidMaxPrice;
  if (capped) bid = CFG.bidMaxPrice;
  // round to 8 decimals
  return { bid: Math.round(bid * 1e8) / 1e8, top, capped };
}

function orderRemainingBtc(o) {
  if (o == null) return null;
  if (o.remainingAmount != null) return Number(o.remainingAmount);
  if (o.availableAmount != null) return Number(o.availableAmount);
  if (o.amount != null && o.paidAmount != null)
    return Number(o.amount) - Number(o.paidAmount);
  if (o.amount != null && o.spentAmount != null)
    return Number(o.amount) - Number(o.spentAmount);
  return null;
}

function round8(n) {
  return Math.round(n * 1e8) / 1e8;
}

// ---- main loop --------------------------------------------------------------
async function main() {
  log("nicehash-watcher starting", {
    pool: CFG.poolApiBase,
    stratum: CFG.poolHost,
    minTarget: CFG.minTargetThs,
    trigger: CFG.triggerFraction,
    rentCap: CFG.rentCapThs,
    dryRun: CFG.dryRun,
    dailyCap: CFG.dailyBtcCap > 0 ? CFG.dailyBtcCap : "disabled",
    alerts: tg.describe(),
  });

  if (!CFG.apiKey || !CFG.apiSecret || !CFG.orgId) {
    log("No NiceHash API credentials configured — standing by (no actions).");
    log("Set NICEHASH_API / NICEHASH_SECRET / NICEHASH_ORGANIZATION to activate.");
  }

  const pool = new PoolAPI(CFG.poolApiBase);
  let nh = null;
  let poolId = null;

  async function ensureNh() {
    if (!CFG.apiKey || !CFG.apiSecret || !CFG.orgId) return null;
    if (!nh) nh = new NiceHashAPI({ apiKey: CFG.apiKey, apiSecret: CFG.apiSecret, orgId: CFG.orgId });
    return nh;
  }

  async function ensurePoolId(state) {
    if (poolId) return poolId;
    const client = await ensureNh();
    if (!client) return null;
    if (!CFG.rentalAddr) {
      log("ERROR: RENTAL_LTC_ADDR not set — cannot configure NiceHash pool.");
      return null;
    }
    const username = `${CFG.rentalAddr}.nh`;
    try {
      poolId = await client.ensurePool({
        name: "honest-rental",
        algorithm: "SCRYPT",
        host: CFG.poolHost,
        username,
        password: "x",
        coin: "LTC",
        location: 0,
        type: "PROP",
        fee: 0.0,
      });
      state.pool_id = poolId;
      log("NiceHash pool ready", { poolId, username, host: CFG.poolHost });
    } catch (e) {
      log("ERROR ensuring NiceHash pool:", { error: String(e.message) });
    }
    return poolId;
  }

  async function syncActiveOrders(state) {
    const client = await ensureNh();
    if (!client) return state.active_orders;
    try {
      const data = await client.getActiveOrders("SCRYPT", "BTC");
      // Response shape: { list: [...] } per NiceHash myOrders
      const live = (data && data.list) || [];
      const liveIds = new Set(live.map((o) => o.id));
      // Drop tracked orders that NiceHash no longer reports as active.
      const dropped = state.active_orders.filter((o) => !liveIds.has(o.id));
      if (dropped.length)
        log("Orders no longer active (expired/cancelled):", {
          ids: dropped.map((o) => o.id),
        });
      state.active_orders = state.active_orders.filter((o) => liveIds.has(o.id));
      return live;
    } catch (e) {
      log("WARN: getActiveOrders failed:", { error: String(e.message) });
      return state.active_orders;
    }
  }

  async function alert(state, key, text) {
    if (!tg.isEnabled()) return;
    state.alerts = state.alerts || {};
    const now = Date.now();
    const last = state.alerts[key] || 0;
    if (now - last < CFG.alertCooldownMin * 60000) return;
    state.alerts[key] = now;
    await tg.send(text, log);
  }

  async function tick() {
    const state = loadState();
    resetDailySpendIfNewDay(state);

    // 1. read pool hashrate
    let actual;
    try {
      actual = await pool.currentHashrateThs("scrypt");
    } catch (e) {
      log("ERROR reading pool hashrate — skipping cycle:", { error: String(e.message) });
      return;
    }
    state.last_pool_hashrate = round8(actual);

    // 2. refresh target (max(7d avg, min)) every ~15 min
    const now = Date.now();
    if (!state.target_updated_at || now - state.target_updated_at > 900000) {
      try {
        const avg7 = await pool.avg7dHashrateThs("scrypt");
        const target = Math.max(avg7 || 0, CFG.minTargetThs);
        state.target_ths = round8(target);
        state.target_updated_at = now;
        log("Target refreshed", { avg7d: round8(avg7), target: state.target_ths });
      } catch (e) {
        log("WARN: 7d avg fetch failed, using last target:", { error: String(e.message), target: state.target_ths });
      }
    }
    const target = state.target_ths || CFG.minTargetThs;
    const deficit = round8(Math.max(0, target - actual));
    const triggerThreshold = target * CFG.triggerFraction;

    log("cycle", {
      actual_ths: round8(actual),
      target_ths: target,
      deficit_ths: deficit,
      trigger_below: round8(triggerThreshold),
      active_orders: state.active_orders.length,
      spend_today: state.spend_today.btc,
    });

    // 2b. Telegram alerting on the 75%-of-target threshold
    if (actual < triggerThreshold) {
      const pct = target > 0 ? (actual / target) * 100 : 0;
      if (!state.below_trigger) {
        state.below_trigger = true;
        state.alerts = state.alerts || {};
        delete state.alerts["below"];
      }
      await alert(
        state,
        "below",
        `\u26a0\ufe0f <b>Pool hashrate low</b>\n` +
          `Current: <b>${round8(actual)} TH/s</b>\n` +
          `Target (7d avg, min ${CFG.minTargetThs}): <b>${round8(target)} TH/s</b>\n` +
          `That's <b>${pct.toFixed(1)}%</b> of target (alert below ${(CFG.triggerFraction * 100).toFixed(0)}%).\n` +
          `Deficit: ${deficit} TH/s — NiceHash rental will be used to cover it.`
      );
    } else if (state.below_trigger && actual >= target) {
      state.below_trigger = false;
      state.alerts = state.alerts || {};
      delete state.alerts["below"];
      await tg.send(
        `\u2705 <b>Pool hashrate recovered</b>\n` +
          `Current: <b>${round8(actual)} TH/s</b> (target ${round8(target)} TH/s)`,
        log
      );
    }

    // 3. sync active orders with NiceHash reality
    await syncActiveOrders(state);

    // 4. recovery handling — once actual >= target for N cycles, cancel & refund
    if (actual >= target) {
      state.recover_count = (state.recover_count || 0) + 1;
      if (state.recover_count >= CFG.recoverConfirmations && state.active_orders.length) {
        log("Pool recovered above target — cancelling rental orders:", { ids: state.active_orders.map((o) => o.id) });
        await cancelAll(state);
        state.recover_count = 0;
      }
    } else {
      state.recover_count = 0;
    }

    // 5. need rental?
    const belowTrigger = actual < triggerThreshold;
    const needRent = deficit > 0.1 && belowTrigger;

    if (needRent) {
      if (dailyCapReached(state)) {
        log("DAILY_BTC_CAP reached — not renting:", { cap: CFG.dailyBtcCap, spent: state.spend_today.btc });
      } else if (state.active_orders.length >= CFG.maxConcurrentOrders) {
        log("MAX_CONCURRENT_ORDERS reached — managing existing orders:", { count: state.active_orders.length });
        await manageOrders(state, actual, target);
      } else {
        await createOrder(state, deficit);
      }
    } else if (state.active_orders.length > 0 && deficit > 0.1) {
      // Below target but above trigger: keep existing orders topped up.
      await manageOrders(state, actual, target);
    }

    saveState(state);
  }

  async function createOrder(state, deficit) {
    const client = await ensureNh();
    if (!client) return;
    const pid = await ensurePoolId(state);
    if (!pid) return;

    let orderBook;
    try {
      orderBook = await client.getOrderBook("SCRYPT", "BTC");
    } catch (e) {
      log("ERROR fetching order book:", { error: String(e.message) });
      return;
    }
    const { bid, top, capped } = computeBid(orderBook);
    const limit = round8(Math.min(deficit, CFG.rentCapThs));
    if (limit < 0.5) {
      log("Deficit too small to open an order:", { deficit, limit });
      return;
    }
    const amount = round8(CFG.orderAmountBtc);
    const body = {
      market: "BTC",
      algorithm: "SCRYPT",
      type: "STANDARD",
      amount,
      price: bid,
      limit,
      poolId: pid,
    };
    log("Creating rental order:", { bid, top, limit, amount, capped, poolId: pid, dryRun: CFG.dryRun });
    if (CFG.dryRun) {
      log("[DRY_RUN] would POST /main/api/v2/hashpower/order", body);
      return;
    }
    try {
      const created = await client.createOrder(body);
      const id = created && created.id;
      if (id) {
        state.active_orders.push({ id, created_at: Date.now(), amount, limit, price: bid });
        state.spend_today.btc = round8(state.spend_today.btc + amount);
        state.last_action = `created ${id}`;
        log("Order created:", { id, bid, limit, amount });
        await tg.send(
          `\ud83d\uded2 <b>NiceHash order placed</b>\n` +
            `Id: <code>${id}</code>\nSpeed limit: ${limit} TH/s\n` +
            `Price: ${bid} BTC/TH/day\nBudget: ${amount} BTC`,
          log
        );
      } else {
        log("Order create returned no id:", { created });
      }
    } catch (e) {
      log("ERROR creating order:", { error: String(e.message), status: e.status, body: e.body });
      await alert(state, "order-error", `\u274c <b>NiceHash order failed</b>\n${String(e.message)}`);
    }
  }

  async function manageOrders(state, actual, target) {
    const client = await ensureNh();
    if (!client) return;
    for (const ao of state.active_orders) {
      let order;
      try {
        order = await client.getOrder(ao.id);
      } catch (e) {
        log("WARN: getOrder failed:", { id: ao.id, error: String(e.message) });
        continue;
      }
      const remaining = orderRemainingBtc(order);
      const alive = order && order.alive !== false;
      const acceptedThs = Number((order.acceptedSpeed || 0));
      log("order status:", { id: ao.id, alive, acceptedSpeed: acceptedThs, limit: order.limit, remaining });

      // refill if budget low and still needed
      const stillNeeded = actual < target;
      if (stillNeeded && alive) {
        let doRefill = false;
        if (remaining != null) {
          if (remaining < CFG.refillThresholdBtc) doRefill = true;
        } else {
          // unknown remaining — log raw once and fall back to a guarded refill
          log("Order detail (raw, please verify remaining-amount field):", order);
          doRefill = false;
        }
        if (doRefill) {
          await refill(state, ao.id);
        }
      }

      // scale up: if this order is saturated at its limit and we still need more,
      // and we have room for another concurrent order, create a second order.
      // (handled by the maxConcurrent branch in tick.)
    }
  }

  async function refill(state, orderId) {
    if (dailyCapReached(state)) {
      log("DAILY_BTC_CAP reached — skipping refill:", { orderId });
      return;
    }
    const amount = round8(CFG.refillAmountBtc);
    log("Refilling order:", { orderId, amount, dryRun: CFG.dryRun });
    if (CFG.dryRun) {
      log("[DRY_RUN] would refill", { orderId, amount });
      return;
    }
    const client = await ensureNh();
    if (!client) return;
    try {
      await client.refillOrder(orderId, amount);
      state.spend_today.btc = round8(state.spend_today.btc + amount);
      state.last_action = `refilled ${orderId}`;
      log("Order refilled:", { orderId, amount });
    } catch (e) {
      log("ERROR refilling order:", { orderId, error: String(e.message), status: e.status });
    }
  }

  async function cancelAll(state) {
    const client = await ensureNh();
    if (!client) return;
    for (const ao of [...state.active_orders]) {
      if (CFG.dryRun) {
        log("[DRY_RUN] would cancel", { id: ao.id });
        continue;
      }
      try {
        await client.cancelOrder(ao.id);
        log("Order cancelled (refunded unused):", { id: ao.id });
        await tg.send(`\ud83e\uddfe <b>NiceHash order cancelled</b> (unused BTC refunded)\nId: <code>${ao.id}</code>`, log);
      } catch (e) {
        log("ERROR cancelling order:", { id: ao.id, error: String(e.message), status: e.status });
      }
    }
    state.active_orders = [];
    state.last_action = "cancelled all";
  }

  // run forever
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await tick();
    } catch (e) {
      log("ERROR in tick (non-fatal):", { error: String(e && e.stack || e.message) });
    }
    await sleep(CFG.pollIntervalSec * 1000);
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((e) => {
  log("FATAL:", { error: String(e && e.stack || e.message) });
  process.exit(1);
});
