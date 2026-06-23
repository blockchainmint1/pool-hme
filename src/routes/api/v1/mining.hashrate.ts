// Network hashrate / difficulty time series, computed locally from block
// headers. No upstream `/mining/hashrate/*` dependency — we walk
// `/api/v1/blocks/{height}` ourselves and apply the standard formula:
//
//     hashrate = difficulty * 2^32 / avg_block_time
//
// Anyone consuming this can do the same math from `/api/v1/blocks` if
// they don't want to call us. See src/lib/txc/hashrate.ts.

import { createFileRoute } from "@tanstack/react-router";
import { CORS_HEADERS, errorResponse, optionsHandler } from "@/lib/api/cors";
import {
  difficultyFromChunks,
  hashrateFromBlocks,
  sampleHeights,
  seriesFromChunks,
  type BlockHeaderLite,
  type Window,
} from "@/lib/txc/hashrate";

const BACKEND = "https://api.mempool.texitcoin.org/api";
const VALID_WINDOWS: Window[] = ["1d", "1w", "1m", "3m", "1y"];

interface ApiBlock {
  height: number;
  timestamp: number;
  difficulty: number;
}

async function fetchBlocksAt(height: number): Promise<BlockHeaderLite[]> {
  const url = `${BACKEND}/v1/blocks/${height}`;
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) return [];
  const arr = (await res.json()) as ApiBlock[];
  return arr.map((b) => ({
    height: b.height,
    timestamp: b.timestamp,
    difficulty: b.difficulty,
  }));
}

async function fetchTipHeight(): Promise<number> {
  const res = await fetch(`${BACKEND}/v1/blocks/tip/height`);
  if (!res.ok) throw new Error(`tip ${res.status}`);
  return Number(await res.text());
}

// Run promises with limited concurrency to be polite to the backend.
async function mapWithConcurrency<T, U>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<U>,
): Promise<U[]> {
  const out: U[] = new Array(items.length);
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const idx = i++;
      if (idx >= items.length) return;
      out[idx] = await fn(items[idx]);
    }
  });
  await Promise.all(workers);
  return out;
}

export const Route = createFileRoute("/api/v1/mining/hashrate")({
  server: {
    handlers: {
      OPTIONS: optionsHandler,
      GET: async ({ request }) => {
        const url = new URL(request.url);
        const windowParam = (url.searchParams.get("window") ?? "1w") as Window;
        if (!VALID_WINDOWS.includes(windowParam)) {
          return errorResponse(
            `invalid window — use one of ${VALID_WINDOWS.join(", ")}`,
            400,
          );
        }

        let tip: number;
        try {
          tip = await fetchTipHeight();
        } catch (e) {
          return errorResponse(`tip lookup failed: ${(e as Error).message}`, 502);
        }

        const heights = sampleHeights(tip, windowParam);
        const chunks = await mapWithConcurrency(heights, 8, fetchBlocksAt);
        const populated = chunks.filter((c) => c.length > 0);

        if (populated.length === 0) {
          return errorResponse("no block data returned from backend", 502);
        }

        // Current = average over the most recent populated chunk.
        const newestChunk = populated.reduce((a, b) =>
          Math.max(...a.map((x) => x.height)) > Math.max(...b.map((x) => x.height)) ? a : b,
        );
        const currentHashrate = hashrateFromBlocks(newestChunk);
        const currentDifficulty = newestChunk[0]?.difficulty ?? 0;

        const body = {
          window: windowParam,
          tipHeight: tip,
          computedAt: Math.floor(Date.now() / 1000),
          currentHashrate,
          currentDifficulty,
          hashrates: seriesFromChunks(populated),
          difficulty: difficultyFromChunks(populated),
          formula: "hashrate = difficulty * 2^32 / avg_block_time_sec",
          sampleSizePerPoint: 15,
        };

        // Edge-cache: 1d window churns; 1y is basically static.
        const cacheSeconds = windowParam === "1d" ? 60 : windowParam === "1w" ? 300 : 1800;

        return new Response(JSON.stringify(body), {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": `public, max-age=${cacheSeconds}, s-maxage=${cacheSeconds}`,
            ...CORS_HEADERS,
          },
        });
      },
    },
  },
});
