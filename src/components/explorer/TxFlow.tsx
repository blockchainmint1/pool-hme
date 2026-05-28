import { Link } from "@tanstack/react-router";
import { satsToTxc, shortHash } from "@/lib/txc/format";
import { decodeOpReturn, omniLabel, isOpReturn, type OmniMessage } from "@/lib/txc/omni";
import type { Tx, TxVin, TxVout } from "@/lib/txc/esplora";

function VinRow({ v }: { v: TxVin }) {
  if (v.is_coinbase) {
    return (
      <div className="px-3 py-2 surface-2 rounded border border-border">
        <span className="text-[10px] uppercase font-semibold text-warning">Coinbase</span>
        <span className="ml-2 font-mono text-xs text-muted-foreground">newly minted</span>
      </div>
    );
  }
  const addr = v.prevout?.scriptpubkey_address;
  return (
    <div className="px-3 py-2 surface-2 rounded border border-border flex items-center justify-between gap-3">
      <div className="min-w-0 flex-1">
        {addr ? (
          <Link
            to="/address/$addr"
            params={{ addr }}
            className="font-mono text-xs hover:text-primary truncate block"
          >
            {addr}
          </Link>
        ) : (
          <span className="font-mono text-xs text-muted-foreground">
            {v.prevout?.scriptpubkey_type ?? "unknown script"}
          </span>
        )}
        <Link
          to="/tx/$txid"
          params={{ txid: v.txid }}
          className="font-mono text-[10px] text-muted-foreground hover:text-accent"
        >
          ← {shortHash(v.txid, 6, 6)}:{v.vout}
        </Link>
      </div>
      <div className="font-mono text-xs flex-shrink-0">
        {satsToTxc(v.prevout?.value ?? 0)} TXC
      </div>
    </div>
  );
}

function VoutRow({ o, index }: { o: TxVout; index: number }) {
  const opReturn = isOpReturn(o);
  if (opReturn) {
    const decoded = decodeOpReturn(o.scriptpubkey);
    return (
      <div className="px-3 py-2 surface-2 rounded border border-border">
        <div className="flex items-center justify-between gap-3">
          <span className="text-[10px] uppercase font-semibold text-accent">OP_RETURN</span>
          <span className="font-mono text-xs text-muted-foreground">#{index}</span>
        </div>
        {decoded.kind === "omni" && (
          <div className="mt-1 text-xs font-mono">
            <div className="text-accent font-semibold">{omniLabel(decoded.message)}</div>
            <OmniDetail msg={decoded.message} />
          </div>
        )}
        {decoded.kind === "text" && (
          <div className="mt-1 text-xs font-mono break-all">
            <span className="text-muted-foreground">UTF-8: </span>
            "{decoded.text}"
          </div>
        )}
        {decoded.kind === "raw" && (
          <div className="mt-1 text-[10px] font-mono break-all text-muted-foreground">
            {decoded.rawHex}
          </div>
        )}
      </div>
    );
  }
  const addr = o.scriptpubkey_address;
  return (
    <div className="px-3 py-2 surface-2 rounded border border-border flex items-center justify-between gap-3">
      <div className="min-w-0 flex-1">
        {addr ? (
          <Link
            to="/address/$addr"
            params={{ addr }}
            className="font-mono text-xs hover:text-primary truncate block"
          >
            {addr}
          </Link>
        ) : (
          <span className="font-mono text-xs text-muted-foreground">
            {o.scriptpubkey_type ?? "unknown script"}
          </span>
        )}
        <span className="text-[10px] text-muted-foreground">#{index}</span>
      </div>
      <div className="font-mono text-xs flex-shrink-0">{satsToTxc(o.value)} TXC</div>
    </div>
  );
}

function OmniDetail({ msg }: { msg: OmniMessage }) {
  switch (msg.kind) {
    case "simple-send":
      return (
        <div className="mt-1 text-muted-foreground space-y-0.5">
          <div>Property: <span className="text-foreground">#{msg.propertyId}</span></div>
          <div>Amount: <span className="text-foreground">{msg.amount.toString()}</span></div>
        </div>
      );
    case "grant":
    case "revoke":
      return (
        <div className="mt-1 text-muted-foreground space-y-0.5">
          <div>Property: <span className="text-foreground">#{msg.propertyId}</span></div>
          <div>Amount: <span className="text-foreground">{msg.amount.toString()}</span></div>
          {msg.note && <div>Note: <span className="text-foreground">{msg.note}</span></div>}
        </div>
      );
    case "create-fixed":
    case "create-managed":
      return (
        <div className="mt-1 text-muted-foreground space-y-0.5">
          <div>Name: <span className="text-foreground">{msg.name || "—"}</span></div>
          {msg.category && <div>Category: <span className="text-foreground">{msg.category}/{msg.subcategory}</span></div>}
          {msg.url && <div>URL: <span className="text-foreground break-all">{msg.url}</span></div>}
          {"amount" in msg && (
            <div>Initial supply: <span className="text-foreground">{msg.amount.toString()}</span></div>
          )}
        </div>
      );
    case "close-crowdsale":
    case "change-issuer":
      return (
        <div className="mt-1 text-muted-foreground">
          Property: <span className="text-foreground">#{msg.propertyId}</span>
        </div>
      );
    default:
      return null;
  }
}

export function TxFlow({ tx }: { tx: Tx }) {
  return (
    <div className="grid md:grid-cols-2 gap-4">
      <div>
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground mb-2">
          Inputs ({tx.vin.length})
        </div>
        <div className="space-y-2">
          {tx.vin.map((v, i) => <VinRow key={i} v={v} />)}
        </div>
      </div>
      <div>
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground mb-2">
          Outputs ({tx.vout.length})
        </div>
        <div className="space-y-2">
          {tx.vout.map((o, i) => <VoutRow key={i} o={o} index={i} />)}
        </div>
      </div>
    </div>
  );
}
