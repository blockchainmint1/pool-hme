import { CORS_HEADERS, errorResponse } from "./cors";

const UPSTREAM = "https://api.mempool.texitcoin.org/api";

/**
 * Proxy a GET to the upstream mempool backend and forward the body back to the
 * client with our public CORS headers + a short edge cache. Passes through
 * Content-Type so numeric endpoints (e.g. tip/height) stay plain-text.
 */
export async function proxy(
  upstreamPath: string,
  opts: { cacheSeconds?: number } = {},
): Promise<Response> {
  const url = `${UPSTREAM}${upstreamPath}`;
  let res: Response;
  try {
    res = await fetch(url, { headers: { Accept: "application/json, text/plain, */*" } });
  } catch (e) {
    return errorResponse(
      `Upstream fetch failed: ${(e as Error).message}`,
      502,
    );
  }
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    return new Response(body || res.statusText, {
      status: res.status,
      headers: {
        "Content-Type": res.headers.get("content-type") || "text/plain",
        ...CORS_HEADERS,
      },
    });
  }
  const ct = res.headers.get("content-type") || "application/json";
  const cache = `public, max-age=${opts.cacheSeconds ?? 10}, s-maxage=${opts.cacheSeconds ?? 10}`;
  const body = await res.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": ct,
      "Cache-Control": cache,
      ...CORS_HEADERS,
    },
  });
}
