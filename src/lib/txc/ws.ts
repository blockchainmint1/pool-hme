// Live feed for the explorer.
//
// Tries the mempool.space-style WebSocket at wss://mempool.texitcoin.org/api/v1/ws.
// If it fails / closes / never opens, transparently falls back to polling the
// REST endpoints every 10s. Either way, downstream subscribers see the same
// `MempoolFeedSnapshot` shape and re-render via TanStack Query invalidation.

import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { esplora } from "./esplora";
import { TXC_WS_URL } from "./network";
import type { BlockSummary, FeeRecommendations, MempoolBlock, MempoolInfo } from "./esplora";

export type FeedStatus = "connecting" | "live" | "polling" | "offline";

export interface MempoolFeedSnapshot {
  tipHeight: number | null;
  blocks: BlockSummary[];
  mempool: MempoolInfo | null;
  mempoolBlocks: MempoolBlock[];
  fees: FeeRecommendations | null;
  status: FeedStatus;
  lastTick: number;
}

const EMPTY: MempoolFeedSnapshot = {
  tipHeight: null,
  blocks: [],
  mempool: null,
  mempoolBlocks: [],
  fees: null,
  status: "connecting",
  lastTick: 0,
};

export function useMempoolFeed(): MempoolFeedSnapshot {
  const [snap, setSnap] = useState<MempoolFeedSnapshot>(EMPTY);
  const qc = useQueryClient();
  const wsRef = useRef<WebSocket | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    let cancelled = false;
    let wsAlive = false;

    async function pullAll(): Promise<Partial<MempoolFeedSnapshot>> {
      const [tip, blocks, mempool, mempoolBlocks, fees] = await Promise.allSettled([
        esplora.tipHeight(),
        // v1 includes extras.medianFee / totalFees / pool — needed by the
        // confirmed-blocks strip. Fall back to the plain endpoint if 404.
        esplora.blocksV1().catch(() => esplora.recentBlocks()),
        esplora.mempool(),
        esplora.mempoolBlocks(),
        esplora.feesRecommended(),
      ]);
      return {
        tipHeight: tip.status === "fulfilled" ? tip.value : null,
        blocks: blocks.status === "fulfilled" ? blocks.value : [],
        mempool: mempool.status === "fulfilled" ? mempool.value : null,
        mempoolBlocks:
          mempoolBlocks.status === "fulfilled" ? mempoolBlocks.value : [],
        fees: fees.status === "fulfilled" ? fees.value : null,
        lastTick: Date.now(),
      };
    }

    async function poll() {
      const next = await pullAll();
      if (cancelled) return;
      setSnap((prev) => ({ ...prev, ...next, status: wsAlive ? "live" : "polling" }));
      // Bump any tx/address queries that may have flipped on new block.
      qc.invalidateQueries({ queryKey: ["mempool"], exact: false });
    }

    function startPolling() {
      if (pollRef.current) return;
      poll();
      pollRef.current = setInterval(poll, 10_000);
    }

    function stopPolling() {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    }

    function tryWs() {
      try {
        const ws = new WebSocket(TXC_WS_URL);
        wsRef.current = ws;
        const openTimer = setTimeout(() => {
          if (!wsAlive) {
            try { ws.close(); } catch { /* ignore */ }
            startPolling();
          }
        }, 4000);

        ws.addEventListener("open", () => {
          wsAlive = true;
          clearTimeout(openTimer);
          // Subscribe to all the things mempool.space frontend subscribes to.
          ws.send(JSON.stringify({
            action: "want",
            data: ["blocks", "stats", "mempool-blocks", "live-2h-chart"],
          }));
          setSnap((p) => ({ ...p, status: "live" }));
          // Still seed from REST so we have a full initial snapshot.
          poll();
        });

        ws.addEventListener("message", (ev) => {
          try {
            const m = JSON.parse(typeof ev.data === "string" ? ev.data : "");
            setSnap((prev) => {
              const next = { ...prev, lastTick: Date.now(), status: "live" as FeedStatus };
              if (m.block) {
                next.blocks = [m.block, ...prev.blocks].slice(0, 15);
                next.tipHeight = m.block.height ?? prev.tipHeight;
                qc.invalidateQueries({ queryKey: ["mempool"], exact: false });
              }
              if (m.blocks && Array.isArray(m.blocks)) {
                next.blocks = m.blocks;
                next.tipHeight = m.blocks[0]?.height ?? prev.tipHeight;
              }
              if (m["mempool-blocks"]) next.mempoolBlocks = m["mempool-blocks"];
              if (m["mempoolInfo"]) {
                next.mempool = {
                  count: m.mempoolInfo.size ?? 0,
                  vsize: m.mempoolInfo.bytes ?? 0,
                  total_fee: m.mempoolInfo.total_fee ?? 0,
                  fee_histogram: m.mempoolInfo.histogram ?? [],
                };
              }
              if (m.fees) next.fees = m.fees;
              return next;
            });
          } catch { /* ignore */ }
        });

        ws.addEventListener("close", () => {
          wsAlive = false;
          setSnap((p) => ({ ...p, status: "polling" }));
          startPolling();
        });
        ws.addEventListener("error", () => {
          // Let close handler trigger fallback.
          try { ws.close(); } catch { /* ignore */ }
        });
      } catch {
        startPolling();
      }
    }

    tryWs();

    return () => {
      cancelled = true;
      stopPolling();
      if (wsRef.current) {
        try { wsRef.current.close(); } catch { /* ignore */ }
      }
    };
  }, [qc]);

  return snap;
}
