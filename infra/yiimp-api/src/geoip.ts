/**
 * GeoIP wrapper. Wraps `geoip-lite` (MaxMind GeoLite2 country/city snapshot,
 * embedded in the npm package, refreshed monthly by `npm run updatedb` in a
 * cron job on the host).
 *
 * We never expose raw IPs in public API responses — only aggregated
 * country/region rollups. If GEOIP_ENABLED=false or the module isn't
 * installed, everything degrades to "unknown".
 */
type Lookup = {
  country: string;
  region: string;
  city: string;
} | null;

let geoip: { lookup: (ip: string) => Lookup } | null = null;
try {
  // Dynamic require so a missing binary doesn't crash boot in dev.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  geoip = (await import("geoip-lite")).default as unknown as {
    lookup: (ip: string) => Lookup;
  };
} catch {
  geoip = null;
}

export interface GeoRow {
  country: string; // ISO 3166-1 alpha-2, e.g. "US"
  region: string; // ISO 3166-2 subdivision code, e.g. "TX"
}

export function lookupGeo(ip: string | null | undefined): GeoRow {
  if (!geoip || !ip) return { country: "??", region: "??" };
  // Some yiimp rows store the IP with a trailing port or "::ffff:" IPv4-mapped
  // IPv6 prefix. Normalize.
  const clean = String(ip)
    .replace(/^::ffff:/, "")
    .replace(/[[\]]/g, "")
    .split(":")[0]
    .trim();
  const rec = geoip.lookup(clean);
  return {
    country: rec?.country || "??",
    region: rec?.region || "??",
  };
}

/**
 * Aggregate a list of IPs into a country+region rollup. Never returns
 * per-IP data.
 */
export function aggregateGeo<T extends { ip: string | null | undefined; hashrate: number }>(
  rows: T[],
): { country: string; region: string; miner_count: number; hashrate: number }[] {
  const bucket = new Map<
    string,
    { country: string; region: string; miner_count: number; hashrate: number }
  >();
  for (const r of rows) {
    const { country, region } = lookupGeo(r.ip);
    const key = `${country}/${region}`;
    const b = bucket.get(key);
    if (b) {
      b.miner_count += 1;
      b.hashrate += Number(r.hashrate ?? 0);
    } else {
      bucket.set(key, { country, region, miner_count: 1, hashrate: Number(r.hashrate ?? 0) });
    }
  }
  return [...bucket.values()].sort((a, b) => b.hashrate - a.hashrate);
}
