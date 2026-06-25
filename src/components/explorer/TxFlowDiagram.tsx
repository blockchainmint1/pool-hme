import { useMemo } from "react";
import type { Tx } from "@/lib/txc/esplora";
import { isOpReturn } from "@/lib/txc/omni";
import { satsToTxc } from "@/lib/txc/format";

/**
 * Banner-style transaction flow.
 *
 * Inputs render as a left "flag" with a chevron notch on the left edge.
 * The flag flows rightward as a single value-weighted ribbon, then splits
 * into one stub per output on the right. Stub thickness is proportional
 * to that output's share of the total value; zero-value outputs (OP_RETURN
 * markers) render as a thin tick so they're visible without dominating.
 */
export function TxFlowDiagram({ tx }: { tx: Tx }) {
  const W = 1200;
  const H = 260;
  const PAD_Y = 18;
  const NOTCH = 26; // chevron depth on the left
  const SPLIT_X = W * 0.62; // where outputs begin to fan out
  const RIGHT_X = W - 6;
  const GAP = 6;

  const { ins, outs, totalIn, totalOut, isCoinbase } = useMemo(() => {
    const cb = !!tx.vin[0]?.is_coinbase;
    const txTotalOut = tx.vout.reduce((s, o) => s + o.value, 0);
    const inputs = tx.vin.map((v, i) => ({
      key: `in-${i}`,
      value: cb ? txTotalOut : v.prevout?.value ?? 0,
      addr: v.prevout?.scriptpubkey_address,
      coinbase: !!v.is_coinbase,
      idx: i,
    }));
    const outputs = tx.vout.map((o, i) => ({
      key: `out-${i}`,
      value: o.value,
      addr: o.scriptpubkey_address,
      opReturn: isOpReturn(o),
      idx: i,
    }));
    return {
      ins: inputs,
      outs: outputs,
      totalIn: inputs.reduce((s, x) => s + x.value, 0) || 1,
      totalOut: outputs.reduce((s, x) => s + x.value, 0) || 1,
      isCoinbase: cb,
    };
  }, [tx]);

  // Lay out output stub heights on the right side, with gaps.
  const usable = H - PAD_Y * 2;
  const gapTotal = Math.max(0, outs.length - 1) * GAP;
  const tickH = 4;
  const zeroCount = outs.filter((o) => o.value === 0).length;
  const propUsable = usable - gapTotal - zeroCount * tickH;
  let yOut = PAD_Y;
  const outStubs = outs.map((o) => {
    const h = o.value === 0 ? tickH : Math.max(4, (o.value / totalOut) * propUsable);
    const stub = { ...o, y: yOut, h };
    yOut += h + GAP;
    return stub;
  });

  // Left flag spans almost the full height.
  const flagTop = PAD_Y;
  const flagBot = H - PAD_Y;

  // Build one ribbon per output: flag right-edge midpoint → output stub.
  const ribbons = outStubs.map((o) => {
    // Slice of the flag right-edge proportional to this output's share.
    const share = o.value === 0 ? 0.001 : o.value / totalOut;
    return { o, share };
  });

  // Distribute slices vertically along the flag's right edge proportional to share.
  let acc = 0;
  const flagH = flagBot - flagTop;
  const slices = ribbons.map((r) => {
    const sliceH = r.share * flagH;
    const y0a = flagTop + acc;
    const y0b = y0a + sliceH;
    acc += sliceH;
    return { ...r, y0a, y0b };
  });

  return (
    <div className="surface-2 border border-border rounded-lg p-4 overflow-hidden">
      <div className="flex items-center justify-between mb-3">
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">
          Flow
        </div>
        <div className="text-[10px] font-mono text-muted-foreground">
          {ins.length} in → {outs.length} out · {satsToTxc(totalOut)} TXC
        </div>
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="w-full h-[180px] md:h-[220px]"
      >
        <defs>
          <linearGradient id="bannerGrad" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="hsl(280 85% 62%)" />
            <stop offset="55%" stopColor="hsl(225 90% 60%)" />
            <stop offset="100%" stopColor="hsl(190 90% 55%)" />
          </linearGradient>
          <linearGradient id="bannerEdge" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="hsl(280 90% 70%)" stopOpacity="0.6" />
            <stop offset="100%" stopColor="hsl(190 90% 55%)" stopOpacity="0.6" />
          </linearGradient>
          <filter id="bannerGlow" x="-5%" y="-20%" width="110%" height="140%">
            <feGaussianBlur stdDeviation="6" result="b" />
            <feMerge>
              <feMergeNode in="b" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* Outer banner: left flag with chevron notch → split into per-output stubs */}
        <g filter="url(#bannerGlow)">
          {slices.map((s) => {
            const x0 = NOTCH; // start past the notch
            const xSplit = SPLIT_X;
            const x1 = RIGHT_X;
            // Top edge: from flag-top to output-top, via two bezier handles
            const cTopA = xSplit;
            const cTopB = xSplit;
            // Bottom edge mirrors
            const d = `
              M ${x0} ${s.y0a}
              L ${0} ${s.y0a}
              L ${NOTCH} ${(s.y0a + s.y0b) / 2}
              L ${0} ${s.y0b}
              L ${x0} ${s.y0b}
              C ${cTopB} ${s.y0b}, ${cTopA} ${s.o.y + s.o.h}, ${x1} ${s.o.y + s.o.h}
              L ${x1} ${s.o.y}
              C ${cTopA} ${s.o.y}, ${cTopB} ${s.y0a}, ${x0} ${s.y0a}
              Z
            `;
            return (
              <path
                key={s.o.key}
                d={d}
                fill={s.o.opReturn ? "hsl(45 90% 55%)" : "url(#bannerGrad)"}
                opacity={s.o.opReturn ? 0.85 : 0.92}
                stroke="url(#bannerEdge)"
                strokeWidth={1}
              />
            );
          })}
        </g>

        {/* Tiny label hints */}
        <g className="font-mono" fontSize="11" fill="hsl(0 0% 100% / 0.6)">
          <text x={NOTCH + 8} y={flagTop - 4}>
            {isCoinbase ? "coinbase" : `${ins.length} input${ins.length > 1 ? "s" : ""}`}
          </text>
          <text x={RIGHT_X} y={flagTop - 4} textAnchor="end">
            {satsToTxc(totalOut)} TXC
          </text>
        </g>
      </svg>
    </div>
  );
}
