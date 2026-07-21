/**
 * Session-by-site rollup, derived from live TCP sockets on the stratum
 * host. Runs `ss -Htn state established sport = :3433` and aggregates
 * peer IPs into site labels.
 *
 * We never expose raw peer IPs in the public API — only site labels +
 * session counts. The site map matches
 * .lovable/memory/infra/site-wan-ips.md; keep them in sync.
 *
 * yiimp-api runs unprivileged (`User=yiimp-api`), but `ss` doesn't need
 * root to list established sockets (it just reads /proc/net/tcp*, which
 * is world-readable). If the exec fails for any reason we degrade to an
 * empty rollup rather than 500 the whole diagnostics response.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

// Known site egress IPs. Values must stay in sync with
// .lovable/memory/infra/site-wan-ips.md.
const SITE_MAP: Record<string, string> = {
  "209.34.50.105": "Conroe",
  "97.154.36.156": "Mansfield",
  "99.107.246.68": "McKinney",
  "13.217.211.175": "Conroe (haproxy)",
};

export interface SiteSession {
  site: string;
  sessions: number;
  is_known_site: boolean;
}

const STRATUM_PORT = process.env.STRATUM_PORT ?? "3433";

let cache: { at: number; body: SiteSession[] } | null = null;
const TTL_MS = 15_000;

export async function getSessionsBySite(): Promise<SiteSession[]> {
  const now = Date.now();
  if (cache && now - cache.at < TTL_MS) return cache.body;

  const body = await runOnce();
  cache = { at: now, body };
  return body;
}

async function runOnce(): Promise<SiteSession[]> {
  try {
    const { stdout } = await execFileP(
      "ss",
      ["-Htn", "state", "established", "sport", "=", `:${STRATUM_PORT}`],
      { timeout: 3_000 },
    );

    const perIp = new Map<string, number>();
    for (const line of stdout.split("\n")) {
      const parts = line.trim().split(/\s+/);
      // ss -Htn columns: Recv-Q Send-Q Local Peer
      const peer = parts[3];
      if (!peer) continue;
      // strip port; also strip IPv6 brackets. IPv4-mapped-in-v6 (::ffff:1.2.3.4)
      // shows up as "[::ffff:1.2.3.4]:12345" — normalize.
      const ip = peer
        .replace(/^\[|\]$/g, "")
        .replace(/^::ffff:/, "")
        .replace(/:\d+$/, "");
      if (!ip || !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) continue;
      perIp.set(ip, (perIp.get(ip) ?? 0) + 1);
    }

    const bySite = new Map<string, number>();
    for (const [ip, count] of perIp) {
      const site = SITE_MAP[ip] ?? "external / one-off";
      bySite.set(site, (bySite.get(site) ?? 0) + count);
    }

    return [...bySite.entries()]
      .map(([site, sessions]) => ({
        site,
        sessions,
        is_known_site: site !== "external / one-off",
      }))
      .sort((a, b) => b.sessions - a.sessions);
  } catch {
    return [];
  }
}
