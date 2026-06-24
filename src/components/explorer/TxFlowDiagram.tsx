import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import type { Tx } from "@/lib/txc/esplora";
import { isOpReturn } from "@/lib/txc/omni";
import { satsToTxc, shortHash } from "@/lib/txc/format";

/**
 * Sankey-ish flow diagram: inputs on the left funnel into outputs on the right
 * via smooth cubic-bezier ribbons whose thickness is proportional to value.
 * Inspired by the classic block explorer flow visualization.
 */
export function TxFlowDiagram({ tx }: { tx: Tx }) {
  const W = 1000;
  const H = 360;
  const PAD_Y = 12;
  const LEFT_X = 0;
  const RIGHT_X = W;
  const RIBBON_LEFT = 180;
  const RIBBON_RIGHT = W - 180;

  const data = useMemo(() => {
    const isCoinbase = tx.vin[0]?.is_coinbase;
    const inputs = tx.vin.map((v, i) => ({
      key: `in-${i}`,
      value: isCoinbase ? tx.vout.reduce((s, o) => s + o.value, 0) : (v.prevout?.value ?? 0),
      label: v.is_coinbase
        ? "Coinbase (newly minted)"
        : v.prevout?.scriptpubkey_address ?? v.prevout?.scriptpubkey_type ?? "unknown",
      addr: v.prevout?.scriptpubkey_address,
      txid: v.txid,
      vout: v.vout,
      coinbase: !!v.is_coinbase,
    }));
    const outputs = tx.vout.map((o, i) => ({
      key: `out-${i}`,
      value: o.value,
      label: isOpReturn(o)
        ? "OP_RETURN"
        : o.scriptpubkey_address ?? o.scriptpubkey_type ?? "unknown",
      addr: o.scriptpubkey_address,
      opReturn: isOpReturn(o),
      index: i,
    }));
    const totalIn = inputs.reduce((s, x) => s + x.value, 0) || 1;
    const totalOut = outputs.reduce((s, x) => s + x.value, 0) || 1;

    const usableH = H - PAD_Y * 2;
    let yIn = PAD_Y;
    const ins = inputs.map((it) => {
      const h = Math.max(2, (it.value / totalIn) * usableH);
      const seg = { ...it, y: yIn, h };
      yIn += h;
      return seg;
    });
    let yOut = PAD_Y;
    const outs = outputs.map((it) => {
      const h = Math.max(2, (it.value / totalOut) * usableH);
      const seg = { ...it, y: yOut, h };
      yOut += h;
      return seg;
    });
    return { ins, outs };
  }, [tx]);

  // Build ribbons: distribute each input proportionally across all outputs
  // (Bitcoin has no per-input→per-output mapping; the classic viz fans out).
  const ribbons: Array<{ d: string; key: string; opacity: number }> = [];
  const totalIn = data.ins.reduce((s, x) => s + x.value, 0) || 1;
  const totalOut = data.outs.reduce((s, x) => s + x.value, 0) || 1;

  // Track running offsets within each input/output band
  const inOffsets = data.ins.map(() => 0);
  const outOffsets = data.outs.map(() => 0);

  data.ins.forEach((inp, i) => {
    data.outs.forEach((out, j) => {
      const flow = (inp.value / totalIn) * out.value; // proportional share
      const hIn = (flow / totalIn) * (H - PAD_Y * 2);
      const hOut = (flow / totalOut) * (H - PAD_Y * 2);
      const y0a = inp.y + inOffsets[i];
      const y0b = y0a + hIn;
      const y1a = out.y + outOffsets[j];
      const y1b = y1a + hOut;
      inOffsets[i] += hIn;
      outOffsets[j] += hOut;

      const x0 = RIBBON_LEFT;
      const x1 = RIBBON_RIGHT;
      const cx0 = x0 + (x1 - x0) * 0.5;
      const cx1 = x0 + (x1 - x0) * 0.5;
      const d = `
        M ${x0} ${y0a}
        C ${cx0} ${y0a}, ${cx1} ${y1a}, ${x1} ${y1a}
        L ${x1} ${y1b}
        C ${cx1} ${y1b}, ${cx0} ${y0b}, ${x0} ${y0b}
        Z
      `;
      ribbons.push({ d, key: `r-${i}-${j}`, opacity: 0.55 });
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
        className="w-full h-[260px] md:h-[340px]"
      >
        <defs>
          <linearGradient id="flowGrad" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="hsl(280 80% 60%)" />
            <stop offset="50%" stopColor="hsl(220 90% 60%)" />
            <stop offset="100%" stopColor="hsl(190 90% 55%)" />
          </linearGradient>
          <linearGradient id="inBar" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="hsl(280 80% 55%)" />
            <stop offset="100%" stopColor="hsl(260 80% 55%)" />
          </linearGradient>
          <linearGradient id="outBar" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="hsl(200 90% 55%)" />
            <stop offset="100%" stopColor="hsl(190 90% 50%)" />
          </linearGradient>
        </defs>

        {/* Ribbons */}
        <g style={{ mixBlendMode: "screen" }}>
          {ribbons.map((r) => (
            <path
              key={r.key}
              d={r.d}
              fill="url(#flowGrad)"
              opacity={r.opacity}
            >
              <title />
            </path>
          ))}
        </g>

        {/* Input bars */}
        {data.ins.map((it) => (
          <g key={it.key}>
            <rect
              x={LEFT_X}
              y={it.y}
              width={RIBBON_LEFT - 4}
              height={it.h}
              fill="url(#inBar)"
              rx={2}
            >
              <title>
                {it.label}
                {"\n"}
                {satsToTxc(it.value)} TXC
              </title>
            </rect>
          </g>
        ))}

        {/* Output bars */}
        {data.outs.map((it) => (
          <g key={it.key}>
            <rect
              x={RIBBON_RIGHT + 4}
              y={it.y}
              width={RIGHT_X - RIBBON_RIGHT - 4}
              height={it.h}
              fill={it.opReturn ? "hsl(45 90% 55%)" : "url(#outBar)"}
              rx={2}
            >
              <title>
                {it.label}
                {"\n"}
                {satsToTxc(it.value)} TXC
              </title>
            </rect>
          </g>
        ))}
      </svg>

      {/* Legend rows under the diagram */}
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
