import { useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Search } from "lucide-react";
import { classifySearch } from "@/lib/txc/format";
import { esplora } from "@/lib/txc/esplora";

interface Props {
  variant?: "header" | "hero";
  autoFocus?: boolean;
}

export function SearchBar({ variant = "header", autoFocus = false }: Props) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const navigate = useNavigate();

  async function handle(e: React.FormEvent) {
    e.preventDefault();
    const q = value.trim();
    if (!q || busy) return;
    setErr(null);
    setBusy(true);
    try {
      const kind = classifySearch(q);
      if (kind === "height") {
        const hash = await esplora.blockByHeight(Number(q));
        navigate({ to: "/block/$hash", params: { hash } });
      } else if (kind === "address") {
        // bech32 addresses are canonically lowercase
        const addr = /^txc1/i.test(q) ? q.toLowerCase() : q;
        navigate({ to: "/address/$addr", params: { addr } });
      } else if (kind === "hash") {
        navigate({ to: "/block/$hash", params: { hash: q.toLowerCase() } });
      } else if (kind === "txid") {
        // Try tx first; fall back to block lookup if it 404s.
        try {
          await esplora.txStatus(q.toLowerCase());
          navigate({ to: "/tx/$txid", params: { txid: q.toLowerCase() } });
        } catch {
          try {
            await esplora.blockByHash(q.toLowerCase());
            navigate({ to: "/block/$hash", params: { hash: q.toLowerCase() } });
          } catch {
            setErr("Not found as transaction or block.");
          }
        }
      } else {
        setErr("Enter a block height, hash, txid, or TXC address.");
      }
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : "Lookup failed.");
    } finally {
      setBusy(false);
    }
  }

  const isHero = variant === "hero";
  return (
    <form onSubmit={handle} className={isHero ? "w-full max-w-3xl mx-auto" : "w-full max-w-xl"}>
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-muted-foreground" />
        <input
          autoFocus={autoFocus}
          value={value}
          onChange={(e) => { setValue(e.target.value); setErr(null); }}
          placeholder="Search block height, hash, txid, or address (T… or txc1…)"
          className={
            isHero
              ? "w-full pl-10 pr-28 py-3.5 rounded-md surface-2 border border-border focus:border-primary focus:outline-none font-mono text-sm"
              : "w-full pl-9 pr-24 py-2 rounded-md surface-2 border border-border focus:border-primary focus:outline-none font-mono text-xs"
          }
          aria-label="Search the chain"
        />
        <button
          type="submit"
          disabled={busy || !value}
          className={
            isHero
              ? "absolute right-2 top-1/2 -translate-y-1/2 px-4 py-2 rounded-sm bg-primary text-primary-foreground text-sm font-semibold disabled:opacity-50"
              : "absolute right-1.5 top-1/2 -translate-y-1/2 px-3 py-1 rounded-sm bg-primary text-primary-foreground text-xs font-semibold disabled:opacity-50"
          }
        >
          {busy ? "…" : "Search"}
        </button>
      </div>
      {err && (
        <div className="mt-2 text-xs text-destructive font-mono">{err}</div>
      )}
    </form>
  );
}
