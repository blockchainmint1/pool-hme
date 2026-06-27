import { CORS_HEADERS, errorResponse } from "./cors";

// Our self-hosted TXC backend (mempool-api + custom indexer + nginx)
// running on EC2. Same infrastructure that serves the WebSocket and the
// raw mempool REST API. We proxy through here so the public /api/v1
// surface gets consistent CORS, edge caching, and a stable URL even if
// the backend hostname ever changes.
const BACKEND_URL = "https://api.mempool.texitcoin.org/api";

/**
 * Proxy a GET to the TXC backend and forward the body back to the client
 * with our public CORS headers + a short edge cache. Passes through
 * Content-Type so numeric endpoints (e.g. tip/height) stay plain-text.
 */
export async function proxy(
  path: string,
  opts: { cacheSeconds?: number } = {},
): Promise<Response> {
  const url = `${BACKEND_URL}${path}`;
  let res: Response;
  try {
    res = await fetch(url, { headers: { Accept: "application/json, text/plain, */*" } });
  } catch (e) {
    console.error("Backend fetch failed", { path, error: e });
    return errorResponse("Upstream unavailable", 502);
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

/**
 * Proxy a POST to the TXC backend. Used for Esplora-compatible transaction
 * broadcast aliases on the frontend domain.
 */
export async function proxyPost(path: string, request: Request): Promise<Response> {
  const url = `${BACKEND_URL}${path}`;
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": request.headers.get("content-type") || "text/plain",
        Accept: "application/json, text/plain, */*",
      },
      body: await request.text(),
    });
  } catch (e) {
    console.error("Backend POST failed", { path, error: e });
    return errorResponse("Upstream unavailable", 502);
  }

  const ct = res.headers.get("content-type") || "text/plain";
  const body = await res.arrayBuffer();
  return new Response(body, {
    status: res.status,
    headers: {
      "Content-Type": ct,
      ...CORS_HEADERS,
    },
  });
}
