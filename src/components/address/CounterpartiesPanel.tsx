import { useMemo } from "react";
import { Link } from "@tanstack/react-router";
import type { Tx } from "@/lib/txc/esplora";
import { satsToTxc, shortHash } from "@/lib/txc/format";

interface Stats {
  received: number;
  sent: number;
  firstSeen?: number;
  lastSeen?: number;
  topSenders: Array<{ addr: string; amount: number }>;
  topReceivers: Array<{ addr: string; amount: number }>;
}

function compute(txs: Tx[], me: string): Stats {
  let received = 0;
  let sent = 0;
  let firstSeen: number | undefined;
  let lastSeen: number | undefined;
  const senders = new Map<string, number>();
  const receivers = new Map<string, number>();

  for (const tx of txs) {
    const t = tx.status.block_time;
    if (t) {
      if (firstSeen === undefined || t < firstSeen) firstSeen = t;
      if (lastSeen === undefined || t > lastSeen) lastSeen = t;
    }
    const inFromMe = tx.vin.reduce((s, v) => s + (v.prevout?.scriptpubkey_address === me ? v.prevout.value : 0), 0);
    const outToMe = tx.vout.reduce((s, v) => s + (v.scriptpubkey_address === me ? v.value : 0), 0);

    if (inFromMe > 0) {
      // we sent — credit each non-self recipient
      sent += Math.max(0, inFromMe - outToMe);
      for (const v of tx.vout) {
        const a = v.scriptpubkey_address;
        if (!a || a === me) continue;
        receivers.set(a, (receivers.get(a) ?? 0) + v.value);
      }
    } else if (outToMe > 0) {
      // we received — credit each non-self sender
      received += outToMe;
      for (const i of tx.vin) {
        const a = i.prevout?.scriptpubkey_address;
        const val = i.prevout?.value ?? 0;
        if (!a || a === me) continue;
        senders.set(a, (senders.get(a) ?? 0) + val);
      }
    }
  }

  const top = (m: Map<string, number>) =>
    [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([addr, amount]) => ({ addr, amount }));

  return { received, sent, firstSeen, lastSeen, topSenders: top(senders), topReceivers: top(receivers) };
}

export function CounterpartiesPanel({ txs, address }: { txs: Tx[]; address: string }) {
  const s = useMemo(() => compute(txs, address), [txs, address]);

  return (
    <div className="grid md:grid-cols-2 gap-4">
      <div className="surface border border-border rounded-md p-4">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
          Flow summary
        </h3>
        <div className="mt-3 grid grid-cols-2 gap-3 text-sm">
          <div className="surface-2 border border-border rounded-md p-3">
            <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Received</div>
            <div className="font-display text-lg text-success">+{satsToTxc(s.received)} TXC</div>
          </div>
          <div className="surface-2 border border-border rounded-md p-3">
            <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Sent</div>
            <div className="font-display text-lg text-primary">−{satsToTxc(s.sent)} TXC</div>
          </div>
          <div className="surface-2 border border-border rounded-md p-3 col-span-2">
            <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Active window</div>
            <div className="font-mono text-xs mt-1">
              {s.firstSeen ? new Date(s.firstSeen * 1000).toLocaleDateString() : "—"}
              {" → "}
              {s.lastSeen ? new Date(s.lastSeen * 1000).toLocaleDateString() : "—"}
            </div>
          </div>
        </div>
      </div>

      <div className="surface border border-border rounded-md p-4">
        <h3 className="font-display text-sm uppercase tracking-widest text-muted-foreground">
          Top counterparties
        </h3>
        <div className="mt-3 grid grid-cols-1 gap-3 text-xs">
          <CpList title="Received from" rows={s.topSenders} accent="text-success" />
          <CpList title="Sent to" rows={s.topReceivers} accent="text-primary" />
        </div>
      </div>
    </div>
  );
}

function CpList({ title, rows, accent }: { title: string; rows: Array<{ addr: string; amount: number }>; accent: string }) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-widest text-muted-foreground mb-1">{title}</div>
      {rows.length === 0 && <div className="text-muted-foreground text-xs">— none in loaded history —</div>}
      <div className="space-y-1">
        {rows.map((r) => (
          <Link
            key={r.addr}
            to="/address/$addr"
            params={{ addr: r.addr }}
            className="flex items-center justify-between gap-3 surface-2 border border-border rounded-sm px-2 py-1 hover:border-primary/60"
          >
            <span className="font-mono truncate">{shortHash(r.addr, 10, 8)}</span>
            <span className={`font-mono font-semibold ${accent}`}>{satsToTxc(r.amount)} TXC</span>
          </Link>
        ))}
      </div>
    </div>
  );
}
