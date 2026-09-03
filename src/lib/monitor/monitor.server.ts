/**
 * Pool watchdog — app-side health evaluation + Telegram alerting.
 *
 * This complements the on-box nicehash-watcher: the box watches its own
 * hashrate and rents when short; this watchdog watches the box from the
 * outside (so it also catches "the box/API is gone") and pings Telegram.
 *
 * State (last heartbeat, alert cooldowns) lives in module memory. Worker
 * isolates are recycled, so treat it as best-effort de-duplication, not a
 * durable store — every alert re-fires at most once per cooldown window per
 * isolate, which is fine for a low-volume ops channel.
 */

const POOL_API = "https://api.stratum.pool.honest.money";

import type {
  Severity,
  CheckResult,
  WatcherHeartbeat,
  MonitorReport,
} from "./types";

export type { Severity, CheckResult, WatcherHeartbeat, MonitorReport } from "./types";

interface SummaryShape {
  algos?: Array<{
    algo: string;
    live_clients?: number;
    hashrate_hs?: number;
    hashrate_updated_at?: number;
    hashrate_live_hs?: number;
    hashrate_source?: string;
  }>;
  last_blocks?: Array<{ symbol: string; time: number }>;
  active_miners_10m?: number;
  fetched_at?: number;
}

const state: {
  heartbeat: WatcherHeartbeat | null;
  cooldown: Map<string, number>;
} = { heartbeat: null, cooldown: new Map() };

export function recordHeartbeat(hb: WatcherHeartbeat) {
  state.heartbeat = hb;
}

export function getHeartbeat(): WatcherHeartbeat | null {
  return state.heartbeat;
}

const MIN_TARGET_THS = 19;
const TRIGGER_RATIO = 0.75;
const COOLDOWN_MS = 30 * 60 * 1000;

async function getJson<T>(path: string, timeoutMs = 8000): Promise<T | null> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${POOL_API}${path}`, {
      signal: ctl.signal,
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

function worst(a: Severity, b: Severity): Severity {
  const rank = { ok: 0, warn: 1, critical: 2 } as const;
  return rank[a] >= rank[b] ? a : b;
}

function fmtTh(n: number) {
  return `${n.toFixed(2)} TH/s`;
}

function fmtAge(sec: number | null) {
  if (sec == null) return "unknown";
  if (sec < 60) return `${Math.round(sec)}s`;
  if (sec < 3600) return `${Math.round(sec / 60)}m`;
  return `${(sec / 3600).toFixed(1)}h`;
}

/** Run every health check against the live pool API. Never throws. */
export async function evaluatePool(): Promise<Omit<MonitorReport, "alerts_sent">> {
  const now = Math.floor(Date.now() / 1000);
  const [health, summary, series] = await Promise.all([
    getJson<{ ok: boolean; db: boolean }>("/api/v1/health"),
    getJson<SummaryShape>("/api/v1/pool/summary"),
    getJson<{ points?: Array<{ hashrate?: number }> }>(
      "/api/v1/pool/hashrate?window=7d&algo=scrypt",
    ),
  ]);

  const checks: CheckResult[] = [];

  // 1 — upstream reachability
  if (!health || !summary) {
    checks.push({
      key: "api",
      label: "Pool API",
      severity: "critical",
      detail: "yiimp-api on the stratum host is unreachable or returned an error.",
    });
  } else if (!health.ok || !health.db) {
    checks.push({
      key: "api",
      label: "Pool API",
      severity: "critical",
      detail: `Degraded — api=${health.ok} db=${health.db}.`,
    });
  } else {
    checks.push({ key: "api", label: "Pool API", severity: "ok", detail: "Reachable, DB up." });
  }

  const scrypt = (summary?.algos ?? []).find(
    (a) => String(a.algo).toLowerCase() === "scrypt",
  );
  const scryptThs = Number(scrypt?.hashrate_hs ?? 0) / 1e12;
  const liveClients = Number(scrypt?.live_clients ?? 0);
  const pts = series?.points ?? [];
  const avg7d = pts.length
    ? pts.reduce((acc, p) => acc + Number(p.hashrate ?? 0), 0) / pts.length / 1e12
    : 0;
  const target = Math.max(avg7d, MIN_TARGET_THS);

  // 2 — hashrate vs target
  if (summary) {
    if (scryptThs < target * TRIGGER_RATIO) {
      checks.push({
        key: "hashrate",
        label: "Scrypt hashrate",
        severity: "critical",
        detail: `${fmtTh(scryptThs)} is ${((scryptThs / target) * 100).toFixed(0)}% of target ${fmtTh(target)} (7d avg ${fmtTh(avg7d)}). Short ${fmtTh(Math.max(0, target - scryptThs))}.`,
      });
    } else if (scryptThs < target * 0.9) {
      checks.push({
        key: "hashrate",
        label: "Scrypt hashrate",
        severity: "warn",
        detail: `${fmtTh(scryptThs)} vs target ${fmtTh(target)} — soft dip, above the 75% rent trigger.`,
      });
    } else {
      checks.push({
        key: "hashrate",
        label: "Scrypt hashrate",
        severity: "ok",
        detail: `${fmtTh(scryptThs)} vs target ${fmtTh(target)}.`,
      });
    }

    // 3 — miners connected at all
    checks.push(
      liveClients === 0
        ? {
            key: "miners",
            label: "Connected miners",
            severity: "critical",
            detail: "Zero live stratum sessions on scrypt — the pool is taking no work.",
          }
        : {
            key: "miners",
            label: "Connected miners",
            severity: "ok",
            detail: `${liveClients.toLocaleString()} live sessions · ${Number(summary.active_miners_10m ?? 0).toLocaleString()} hashing in 10m.`,
          },
    );

    // 4 — stale hashrate feed
    const feedAge = scrypt?.hashrate_updated_at ? now - Number(scrypt.hashrate_updated_at) : null;
    if (feedAge != null && feedAge > 900) {
      checks.push({
        key: "feed",
        label: "Hashrate feed",
        severity: "warn",
        detail: `Last update ${fmtAge(feedAge)} ago — the stats collector may be stuck.`,
      });
    }
  }

  // 5 — block find rate on the chains we are the only pool for
  const blockAge = (sym: string): number | null => {
    const b = (summary?.last_blocks ?? []).find(
      (x) => String(x.symbol).toUpperCase() === sym,
    );
    return b ? now - Number(b.time) : null;
  };
  const txcAge = blockAge("TXC");
  const iskAge = blockAge("ISK");
  for (const [sym, age] of [
    ["TXC", txcAge],
    ["ISK", iskAge],
  ] as const) {
    if (age == null) continue;
    if (age > 1800) {
      checks.push({
        key: `blocks_${sym.toLowerCase()}`,
        label: `${sym} block find`,
        severity: "critical",
        detail: `No ${sym} block for ${fmtAge(age)} — we are the only pool on that chain, so this is a stall, not variance.`,
      });
    } else if (age > 900) {
      checks.push({
        key: `blocks_${sym.toLowerCase()}`,
        label: `${sym} block find`,
        severity: "warn",
        detail: `Last ${sym} block ${fmtAge(age)} ago (healthy is ~3m).`,
      });
    } else {
      checks.push({
        key: `blocks_${sym.toLowerCase()}`,
        label: `${sym} block find`,
        severity: "ok",
        detail: `Last block ${fmtAge(age)} ago.`,
      });
    }
  }

  // 6 — rental watcher heartbeat (only meaningful once we've seen one)
  const hb = state.heartbeat;
  if (hb) {
    const age = now - hb.received_at;
    checks.push(
      age > 600
        ? {
            key: "watcher",
            label: "Rental watcher",
            severity: "warn",
            detail: `No heartbeat for ${fmtAge(age)} — nicehash-watcher may be stopped on the box.`,
          }
        : {
            key: "watcher",
            label: "Rental watcher",
            severity: "ok",
            detail: `Alive ${fmtAge(age)} ago · ${hb.active_orders} order(s) · ${hb.spend_today_btc.toFixed(5)} BTC today${hb.dry_run ? " · DRY RUN" : ""}.`,
          },
    );
  }

  const overall = checks.reduce<Severity>((acc, c) => worst(acc, c.severity), "ok");

  return {
    checked_at: now,
    overall,
    checks,
    metrics: {
      scrypt_ths: scryptThs,
      avg7d_ths: avg7d,
      target_ths: target,
      live_clients: liveClients,
      active_miners_10m: Number(summary?.active_miners_10m ?? 0),
      last_txc_block_age: txcAge,
      last_isk_block_age: iskAge,
    },
    watcher: hb,
  };
}

async function telegram(text: string): Promise<boolean> {
  const token = process.env["TELEGRAM_BOT_TOKEN"] ?? "";
  const chat = process.env["TELEGRAM_CHAT_ID"] ?? "";
  if (!token || !chat) return false;
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        chat_id: chat,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

const ICON: Record<Severity, string> = { ok: "✅", warn: "⚠️", critical: "🚨" };

/**
 * Evaluate + alert. Problems fire at most once per cooldown window per check;
 * a check that recovers sends a single all-clear.
 */
export async function runWatchdog(opts: { silent?: boolean } = {}): Promise<MonitorReport> {
  const report = await evaluatePool();
  const sent: string[] = [];
  if (opts.silent) return { ...report, alerts_sent: sent };

  const nowMs = Date.now();
  for (const c of report.checks) {
    const last = state.cooldown.get(c.key) ?? 0;
    if (c.severity === "ok") {
      if (last) {
        state.cooldown.delete(c.key);
        if (await telegram(`✅ <b>Recovered — ${c.label}</b>\n${c.detail}\n<i>pool.honest.money watchdog</i>`)) {
          sent.push(`${c.key}:recovered`);
        }
      }
      continue;
    }
    if (nowMs - last < COOLDOWN_MS) continue;
    state.cooldown.set(c.key, nowMs);
    const m = report.metrics;
    const body =
      `${ICON[c.severity]} <b>${c.severity === "critical" ? "ALERT" : "Warning"} — ${c.label}</b>\n` +
      `${c.detail}\n\n` +
      `Scrypt: <b>${fmtTh(m.scrypt_ths)}</b> · target ${fmtTh(m.target_ths)} (7d ${fmtTh(m.avg7d_ths)})\n` +
      `Sessions: ${m.live_clients.toLocaleString()} · hashing 10m: ${m.active_miners_10m.toLocaleString()}\n` +
      `https://pool.honest.money/diagnostics`;
    if (await telegram(body)) sent.push(c.key);
  }

  return { ...report, alerts_sent: sent };
}

/** Constant-time-ish shared-secret check for the public monitor route. */
export function tokenOk(supplied: string): boolean {
  const expected = process.env["MONITOR_TOKEN"] ?? "";
  if (!expected || supplied.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= supplied.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}
