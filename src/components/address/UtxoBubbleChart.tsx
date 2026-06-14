import { useMemo, useState } from "react";
import { hierarchy, pack } from "d3-hierarchy";
import { useNavigate } from "@tanstack/react-router";
import type { Utxo } from "@/lib/txc/esplora";
import { satsToTxc } from "@/lib/txc/format";

interface Props { utxos: Utxo[]; tipHeight?: number }

const SIZE = 480;

export function UtxoBubbleChart({ utxos, tipHeight }: Props) {
  const navigate = useNavigate();
  const [hover, setHover] = useState<Utxo | null>(null);

  const nodes = useMemo(() => {
    if (!utxos.length) return [];
    const root = hierarchy<{ children: Array<{ utxo: Utxo; value: number }> }>(
      { children: utxos.map((u) => ({ utxo: u, value: u.value })) },
    ).sum((d) => (d as { value?: number }).value ?? 0);
    const layout = pack<typeof root.data>().size([SIZE, SIZE]).padding(2);
    const packed = layout(root);
    return packed.leaves().map((l) => ({
      utxo: (l.data as unknown as { utxo: Utxo }).utxo,
      x: l.x, y: l.y, r: l.r,
    }));
  }, [utxos]);

  if (!utxos.length) {
    return (
      <div className="surface-2 border border-border rounded-md p-6 text-sm text-muted-foreground">
        No unspent outputs at this address.
      </div>
    );
  }

  const ageColor = (u: Utxo) => {
    if (!u.status.confirmed || !u.status.block_height || !tipHeight) return "var(--color-accent)";
    const confs = tipHeight - u.status.block_height + 1;
    // Fresh (red) -> aged (cyan) gradient via fee buckets
    if (confs < 144) return "var(--color-fee-6)";
    if (confs < 1008) return "var(--color-fee-5)";
    if (confs < 4320) return "var(--color-fee-4)";
    if (confs < 30000) return "var(--color-fee-3)";
    return "var(--color-fee-2)";
  };

  return (
    <div className="surface border border-border rounded-md p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
          Unspent outputs · {utxos.length}
        </h3>
        <div className="text-[10px] text-muted-foreground flex items-center gap-2">
          <span className="inline-flex items-center gap-1"><span className="size-2 rounded-full" style={{ background: "var(--color-fee-6)" }} /> fresh</span>
          <span className="inline-flex items-center gap-1"><span className="size-2 rounded-full" style={{ background: "var(--color-fee-2)" }} /> aged</span>
        </div>
      </div>
      <div className="relative">
        <svg viewBox={`0 0 ${SIZE} ${SIZE}`} className="w-full h-auto max-h-[480px]">
          {nodes.map(({ utxo, x, y, r }, i) => (
            <g
              key={`${utxo.txid}:${utxo.vout}:${i}`}
              transform={`translate(${x},${y})`}
              className="cursor-pointer"
              onMouseEnter={() => setHover(utxo)}
              onMouseLeave={() => setHover(null)}
              onClick={() => navigate({ to: "/tx/$txid", params: { txid: utxo.txid } })}
            >
              <circle
                r={r}
                fill={ageColor(utxo)}
                fillOpacity={0.85}
                stroke="var(--color-background)"
                strokeWidth={1}
              />
              {r > 28 && (
                <text textAnchor="middle" dy="0.35em" fontSize={Math.min(r / 3, 14)} fill="var(--color-background)" fontWeight={600}>
                  {Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(utxo.value / 1e8)}
                </text>
              )}
            </g>
          ))}
        </svg>
        <div className="mt-2 text-xs font-mono min-h-[1.5em] text-muted-foreground">
          {hover ? (
            <>
              <span className="text-foreground">{satsToTxc(hover.value)} TXC</span>
              {" · "}
              {hover.status.block_height ? `block #${hover.status.block_height.toLocaleString()}` : "mempool"}
              {" · "}
              click to view funding tx
            </>
          ) : (
            <>Hover any circle for details · click to view the funding transaction</>
          )}
        </div>
      </div>
    </div>
  );
}
