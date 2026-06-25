import { useMemo } from "react";
import type { Tx } from "@/lib/txc/esplora";
import { isOpReturn } from "@/lib/txc/omni";
import { satsToTxc } from "@/lib/txc/format";

function scrollToId(id: string) {
  const el = document.getElementById(id);
  if (!el) return;
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  el.classList.add("ring-2", "ring-primary");
  window.setTimeout(() => el.classList.remove("ring-2", "ring-primary"), 1400);
}

/**
 * Banner-style transaction flow.
 *
 * Left flag = inputs (one clickable slice per input). Right stubs = outputs
 * (one clickable stub per output). Clicking a region scrolls to the
 * corresponding row below and briefly highlights it.
 */
export function TxFlowDiagram({ tx }: { tx: Tx }) {
  const W = 1200;
  const H = 260;
  const PAD_Y = 18;
  const NOTCH = 26;
  const SPLIT_X = W * 0.62;
  const RIGHT_X = W - 6;
  const GAP = 6;

  const { ins, outs, totalOut, isCoinbase } = useMemo(() => {
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

  // Output stub heights on the right side
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

  // Left flag spans almost the full height
  const flagTop = PAD_Y;
  const flagBot = H - PAD_Y;
  const flagH = flagBot - flagTop;

  // Ribbons per output: slice the flag's right edge proportionally
  let acc = 0;
  const slices = outStubs.map((r) => {
    const share = r.value === 0 ? 0.001 : r.value / totalOut;
    const sliceH = share * flagH;
    const y0a = flagTop + acc;
    const y0b = y0a + sliceH;
    acc += sliceH;
    return { o: r, y0a, y0b };
  });

  // Input slices on the left flag (stacked vertically, proportional to value)
  const insTotal = ins.reduce((s, x) => s + x.value, 0) || 1;
  let accIn = 0;
  const inputSlices = ins.map((v) => {
    const share = v.value === 0 ? 0.001 : v.value / insTotal;
    const sliceH = share * flagH;
    const y0 = flagTop + accIn;
    accIn += sliceH;
    return { v, y0, h: sliceH };
  });

  return (
    <div className="surface-2 border border-border rounded-lg p-4 overflow-hidden">
      <div className="flex items-center justify-between mb-3">
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Flow</div>
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

        {/* Output ribbons (clickable per output) */}
        <g filter="url(#bannerGlow)">
          {slices.map((s) => {
            const x0 = NOTCH;
            const xSplit = SPLIT_X;
            const x1 = RIGHT_X;
            const d = `
              M ${x0} ${s.y0a}
              L ${0} ${s.y0a}
              L ${NOTCH} ${(s.y0a + s.y0b) / 2}
              L ${0} ${s.y0b}
              L ${x0} ${s.y0b}
              C ${xSplit} ${s.y0b}, ${xSplit} ${s.o.y + s.o.h}, ${x1} ${s.o.y + s.o.h}
              L ${x1} ${s.o.y}
              C ${xSplit} ${s.o.y}, ${xSplit} ${s.y0a}, ${x0} ${s.y0a}
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

        {/* Clickable output stubs (transparent hit-target on right side) */}
        {outStubs.map((o) => (
          <rect
            key={`hit-${o.key}`}
            x={SPLIT_X}
            y={o.y}
            width={RIGHT_X - SPLIT_X}
            height={o.h}
            fill="transparent"
            style={{ cursor: "pointer" }}
            onClick={() => scrollToId(`vout-${o.idx}`)}
          >
            <title>{`Output #${o.idx} — ${satsToTxc(o.value)} TXC`}</title>
          </rect>
        ))}

        {/* Clickable input slices (left flag region) */}
        {inputSlices.map(({ v, y0, h }) => (
          <rect
            key={`hit-${v.key}`}
            x={0}
            y={y0}
            width={SPLIT_X * 0.4}
            height={h}
            fill="transparent"
            style={{ cursor: "pointer" }}
            onClick={() => scrollToId(`vin-${v.idx}`)}
          >
            <title>{`Input #${v.idx}${v.coinbase ? " — coinbase" : ` — ${satsToTxc(v.value)} TXC`}`}</title>
          </rect>
        ))}

        {/* Label hints */}
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
