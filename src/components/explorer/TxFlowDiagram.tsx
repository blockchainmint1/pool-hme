import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import type { Tx } from "@/lib/txc/esplora";
import { isOpReturn } from "@/lib/txc/omni";
import { satsToTxc, shortHash } from "@/lib/txc/format";

/**
 * Sankey-ish flow diagram: inputs on the left funnel into outputs on the right
 * via smooth cubic-bezier ribbons whose thickness is proportional to value.
 *
 * Design notes:
 * - Side bars are slim (so the ribbons dominate, not the bars).
 * - Segments have visible gaps so you can count inputs/outputs at a glance.
 * - Zero-value entries (e.g. OP_RETURN markers) are rendered as a thin tick,
 *   not a min-height slab, and contribute no ribbon mass.
 */
export function TxFlowDiagram({ tx }: { tx: Tx }) {
  const W = 1000;
  const H = 220;
  const PAD_Y = 8;
  const BAR_W = 14;
  const LEFT_X = 0;
  const RIGHT_X = W;
  const RIBBON_LEFT = BAR_W;
  const RIBBON_RIGHT = W - BAR_W;
  const GAP = 3; // px gap between stacked segments

  const data = useMemo(() => {
    const isCoinbase = !!tx.vin[0]?.is_coinbase;
    const txTotalOut = tx.vout.reduce((s, o) => s + o.value, 0);

    const inputs = tx.vin.map((v, i) => ({
      key: `in-${i}`,
      value: isCoinbase ? txTotalOut : (v.prevout?.value ?? 0),
      addr: v.prevout?.scriptpubkey_address,
      label: v.is_coinbase
        ? "Coinbase"
        : v.prevout?.scriptpubkey_address ?? v.prevout?.scriptpubkey_type ?? "unknown",
      coinbase: !!v.is_coinbase,
      txid: v.txid,
      vout: v.vout,
      idx: i,
    }));
    const outputs = tx.vout.map((o, i) => ({
      key: `out-${i}`,
      value: o.value,
      addr: o.scriptpubkey_address,
      label: isOpReturn(o)
        ? "OP_RETURN"
        : o.scriptpubkey_address ?? o.scriptpubkey_type ?? "unknown",
      opReturn: isOpReturn(o),
      idx: i,
    }));

    const totalIn = inputs.reduce((s, x) => s + x.value, 0) || 1;
    const totalOut = outputs.reduce((s, x) => s + x.value, 0) || 1;

    // Reserve gap space, then distribute remaining height proportionally.
    // Zero-value entries get a fixed 3px tick and consume no proportional area.
    function layout<T extends { value: number }>(items: T[], total: number) {
      const gapTotal = Math.max(0, items.length - 1) * GAP;
      const zeroCount = items.filter((it) => it.value === 0).length;
      const tickH = 3;
      const usable = H - PAD_Y * 2 - gapTotal - zeroCount * tickH;
      let y = PAD_Y;
      return items.map((it) => {
        const h = it.value === 0 ? tickH : Math.max(2, (it.value / total) * usable);
        const seg = { ...it, y, h };
        y += h + GAP;
        return seg;
      });
    }

    return {
      ins: layout(inputs, totalIn),
      outs: layout(outputs, totalOut),
      totalIn,
      totalOut,
    };
  }, [tx]);

  // Build ribbons: distribute each input proportionally across non-zero outputs.
  // Zero-value outputs (OP_RETURN markers) get no ribbon — they'd just add noise.
  const ribbons: Array<{ d: string; key: string }> = [];
  const nonZeroOut = data.outs.filter((o) => o.value > 0);
  const valuedOutTotal = nonZeroOut.reduce((s, o) => s + o.value, 0) || 1;

  // Running offsets *within* each segment's height
  const inOffsets = new Map<string, number>();
  const outOffsets = new Map<string, number>();

  data.ins.forEach((inp) => {
    if (inp.value === 0) return;
    nonZeroOut.forEach((out) => {
      const flow = (inp.value / data.totalIn) * out.value; // proportional fan-out
      const hIn = (flow / inp.value) * inp.h;
      const hOut = (flow / valuedOutTotal) * out.h * (valuedOutTotal / out.value) * (out.value / valuedOutTotal);
      // simpler: ribbon thickness at the output edge proportional to share of that output
      const hOutSimple = (flow / out.value) * out.h;
      const offIn = inOffsets.get(inp.key) ?? 0;
      const offOut = outOffsets.get(out.key) ?? 0;
      const y0a = inp.y + offIn;
      const y0b = y0a + hIn;
      const y1a = out.y + offOut;
      const y1b = y1a + hOutSimple;
      inOffsets.set(inp.key, offIn + hIn);
      outOffsets.set(out.key, offOut + hOutSimple);
      void hOut;

      const x0 = RIBBON_LEFT;
      const x1 = RIBBON_RIGHT;
      const cx0 = x0 + (x1 - x0) * 0.5;
      const cx1 = cx0;
      const d = `M ${x0} ${y0a} C ${cx0} ${y0a}, ${cx1} ${y1a}, ${x1} ${y1a} L ${x1} ${y1b} C ${cx1} ${y1b}, ${cx0} ${y0b}, ${x0} ${y0b} Z`;
      ribbons.push({ d, key: `r-${inp.key}-${out.key}` });
    });
  });

  return (
    <div className="surface-2 border border-border rounded-lg p-4">
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground mb-2">
        Flow
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="w-full h-[160px] md:h-[200px]"
      >
        <defs>
          <linearGradient id="flowGrad" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="hsl(280 80% 60%)" stopOpacity="0.55" />
            <stop offset="50%" stopColor="hsl(220 90% 60%)" stopOpacity="0.45" />
            <stop offset="100%" stopColor="hsl(190 90% 55%)" stopOpacity="0.55" />
          </linearGradient>
          <linearGradient id="inBar" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="hsl(280 85% 65%)" />
            <stop offset="100%" stopColor="hsl(260 80% 50%)" />
          </linearGradient>
          <linearGradient id="outBar" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="hsl(200 90% 60%)" />
            <stop offset="100%" stopColor="hsl(190 90% 45%)" />
          </linearGradient>
        </defs>

        <g style={{ mixBlendMode: "screen" }}>
          {ribbons.map((r) => (
            <path key={r.key} d={r.d} fill="url(#flowGrad)" />
          ))}
        </g>

        {data.ins.map((it) => (
          <rect
            key={it.key}
            x={LEFT_X}
            y={it.y}
            width={BAR_W}
            height={it.h}
            fill="url(#inBar)"
            rx={3}
          >
            <title>{`${it.label}\n${satsToTxc(it.value)} TXC`}</title>
          </rect>
        ))}

        {data.outs.map((it) => (
          <rect
            key={it.key}
            x={RIGHT_X - BAR_W}
            y={it.y}
            width={BAR_W}
            height={it.h}
            fill={it.opReturn ? "hsl(45 90% 55%)" : "url(#outBar)"}
            rx={3}
          >
            <title>{`${it.label}\n${satsToTxc(it.value)} TXC`}</title>
          </rect>
        ))}
      </svg>

      <div className="mt-3 grid md:grid-cols-2 gap-4 text-[11px]">
        <div className="space-y-1">
          <div className="text-muted-foreground uppercase tracking-widest text-[10px]">
            Inputs ({data.ins.length})
          </div>
          {data.ins.map((it) => (
            <div key={it.key} className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-2 min-w-0">
                <span className="w-2 h-2 rounded-sm bg-[hsl(270_80%_55%)] flex-shrink-0" />
                {it.coinbase ? (
                  <span className="text-warning font-mono">coinbase</span>
                ) : it.addr ? (
                  <Link
                    to="/address/$addr"
                    params={{ addr: it.addr }}
                    className="font-mono truncate hover:text-primary"
                  >
                    {shortHash(it.addr, 8, 8)}
                  </Link>
                ) : (
                  <span className="font-mono text-muted-foreground truncate">{it.label}</span>
                )}
              </div>
              <span className="font-mono flex-shrink-0">{satsToTxc(it.value)}</span>
            </div>
          ))}
        </div>
        <div className="space-y-1">
          <div className="text-muted-foreground uppercase tracking-widest text-[10px]">
            Outputs ({data.outs.length})
          </div>
          {data.outs.map((it) => (
            <div key={it.key} className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-2 min-w-0">
                <span
                  className={`w-2 h-2 rounded-sm flex-shrink-0 ${
                    it.opReturn ? "bg-[hsl(45_90%_55%)]" : "bg-[hsl(195_90%_52%)]"
                  }`}
                />
                {it.opReturn ? (
                  <span className="text-accent font-mono">OP_RETURN</span>
                ) : it.addr ? (
                  <Link
                    to="/address/$addr"
                    params={{ addr: it.addr }}
                    className="font-mono truncate hover:text-primary"
                  >
                    {shortHash(it.addr, 8, 8)}
                  </Link>
                ) : (
                  <span className="font-mono text-muted-foreground truncate">{it.label}</span>
                )}
              </div>
              <span className="font-mono flex-shrink-0">{satsToTxc(it.value)}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
