import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronDown } from "lucide-react";
import { satsToTxc, shortHash } from "@/lib/txc/format";
import { decodeOpReturn, omniLabel, isOpReturn, type OmniMessage } from "@/lib/txc/omni";
import type { Tx, TxVin, TxVout } from "@/lib/txc/esplora";

function DetailRow({ label, value, mono = true }: { label: string; value: React.ReactNode; mono?: boolean }) {
  return (
    <div className="grid grid-cols-[110px_1fr] gap-2 items-start py-1 border-b border-border/40 last:border-0">
      <div className="text-[10px] uppercase tracking-wide text-muted-foreground pt-0.5">{label}</div>
      <div className={`text-[11px] ${mono ? "font-mono" : ""} break-all`}>{value}</div>
    </div>
  );
}

function ScriptAsm({ asm }: { asm?: string }) {
  if (!asm) return <span className="text-muted-foreground">—</span>;
  const tokens = asm.split(/\s+/);
  return (
    <div className="leading-5">
      {tokens.map((t, i) => {
        const isOp = t.startsWith("OP_");
        return (
          <span key={i} className={isOp ? "text-warning" : "text-foreground/80"}>
            {t}
            {i < tokens.length - 1 ? " " : ""}
          </span>
        );
      })}
    </div>
  );
}

function VinRow({ v, index }: { v: TxVin; index: number }) {
  const [open, setOpen] = useState(false);
  const isCb = v.is_coinbase;
  const addr = v.prevout?.scriptpubkey_address;

  return (
    <div id={`vin-${index}`} className="surface-2 rounded border border-border overflow-hidden scroll-mt-24 transition-shadow">
      <div className="px-3 py-2 flex items-center justify-between gap-3">
        <div className="min-w-0 flex-1">
          {isCb ? (
            <>
              <span className="text-[10px] uppercase font-semibold text-warning">Coinbase</span>
              <span className="ml-2 font-mono text-xs text-muted-foreground">newly minted</span>
            </>
          ) : addr ? (
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
          {!isCb && (
            <Link
              to="/tx/$txid"
              params={{ txid: v.txid }}
              className="font-mono text-[10px] text-muted-foreground hover:text-accent"
            >
              ← {shortHash(v.txid, 6, 6)}:{v.vout}
            </Link>
          )}
        </div>
        <div className="font-mono text-xs flex-shrink-0">
          {satsToTxc(v.prevout?.value ?? 0)} TXC
        </div>
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="text-[10px] uppercase tracking-wide text-accent hover:text-primary flex items-center gap-1 flex-shrink-0"
          aria-expanded={open}
        >
          Details
          <ChevronDown
            className={`w-3 h-3 transition-transform ${open ? "rotate-180" : ""}`}
          />
        </button>
      </div>
      {open && (
        <div className="px-3 py-2 border-t border-border/60 bg-background/40">
          <DetailRow label="Index" value={`#${index}`} />
          {!isCb && v.prevout?.scriptpubkey_type && (
            <DetailRow label="Type" value={v.prevout.scriptpubkey_type} />
          )}
          <DetailRow label="ScriptSig (ASM)" value={<ScriptAsm asm={v.scriptsig_asm} />} />
          <DetailRow
            label="ScriptSig (HEX)"
            value={v.scriptsig ? v.scriptsig : <span className="text-muted-foreground">—</span>}
          />
          <DetailRow
            label="Witness"
            value={
              v.witness && v.witness.length > 0 ? (
                <div className="space-y-0.5">
                  {v.witness.map((w, i) => (
                    <div key={i}>{w || <span className="text-muted-foreground">∅</span>}</div>
                  ))}
                </div>
              ) : (
                <span className="text-muted-foreground">—</span>
              )
            }
          />
          <DetailRow
            label="nSequence"
            value={
              v.sequence != null
                ? `0x${v.sequence.toString(16).padStart(8, "0")}`
                : "—"
            }
          />
        </div>
      )}
    </div>
  );
}

function VoutRow({ o, index }: { o: TxVout; index: number }) {
  const [open, setOpen] = useState(false);
  const opReturn = isOpReturn(o);
  const decoded = opReturn ? decodeOpReturn(o.scriptpubkey) : null;
  const addr = o.scriptpubkey_address;

  return (
    <div id={`vout-${index}`} className="surface-2 rounded border border-border overflow-hidden scroll-mt-24 transition-shadow">
      <div className="px-3 py-2 flex items-center justify-between gap-3">
        <div className="min-w-0 flex-1">
          {opReturn ? (
            <>
              <span className="text-[10px] uppercase font-semibold text-accent">OP_RETURN</span>
              {decoded?.kind === "omni" && (
                <span className="ml-2 font-mono text-[11px] text-accent">{omniLabel(decoded.message)}</span>
              )}
              {decoded?.kind === "text" && (
                <span className="ml-2 font-mono text-[11px] text-muted-foreground truncate">"{decoded.text}"</span>
              )}
            </>
          ) : addr ? (
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
        <button
          type="button"
          onClick={() => setOpen((s) => !s)}
          className="text-[10px] uppercase tracking-wide text-accent hover:text-primary flex items-center gap-1 flex-shrink-0"
          aria-expanded={open}
        >
          Details
          <ChevronDown
            className={`w-3 h-3 transition-transform ${open ? "rotate-180" : ""}`}
          />
        </button>
      </div>
      {open && (
        <div className="px-3 py-2 border-t border-border/60 bg-background/40">
          <DetailRow label="Index" value={`#${index}`} />
          <DetailRow label="Type" value={o.scriptpubkey_type ?? "—"} />
          <DetailRow label="Value" value={`${satsToTxc(o.value)} TXC`} />
          <DetailRow label="ScriptPubKey (ASM)" value={<ScriptAsm asm={o.scriptpubkey_asm} />} />
          <DetailRow label="ScriptPubKey (HEX)" value={o.scriptpubkey} />
          {opReturn && decoded?.kind === "omni" && (
            <DetailRow label="Omni" value={<OmniDetail msg={decoded.message} />} mono={false} />
          )}
          {opReturn && decoded?.kind === "text" && (
            <DetailRow label="UTF-8" value={<>"{decoded.text}"</>} />
          )}
        </div>
      )}
    </div>
  );
}

function OmniDetail({ msg }: { msg: OmniMessage }) {
  switch (msg.kind) {
    case "simple-send":
      return (
        <div className="space-y-0.5 font-mono text-[11px]">
          <div>Property: <span className="text-foreground">#{msg.propertyId}</span></div>
          <div>Amount: <span className="text-foreground">{msg.amount.toString()}</span></div>
        </div>
      );
    case "grant":
    case "revoke":
      return (
        <div className="space-y-0.5 font-mono text-[11px]">
          <div>Property: <span className="text-foreground">#{msg.propertyId}</span></div>
          <div>Amount: <span className="text-foreground">{msg.amount.toString()}</span></div>
          {msg.note && <div>Note: <span className="text-foreground">{msg.note}</span></div>}
        </div>
      );
    case "create-fixed":
    case "create-managed":
      return (
        <div className="space-y-0.5 font-mono text-[11px]">
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
        <div className="font-mono text-[11px]">
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
          {tx.vin.map((v, i) => <VinRow key={i} v={v} index={i} />)}
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
