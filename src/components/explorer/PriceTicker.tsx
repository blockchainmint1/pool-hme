import { TrendingDown, TrendingUp } from "lucide-react";
import { useTxcPrice } from "@/hooks/use-txc-price";

export function PriceTicker() {
  const q = useTxcPrice();
  const p = q.data;
  if (!p) return null;
  const up = p.change24h >= 0;
  return (
    <div className="hidden lg:flex items-center gap-2 px-2.5 py-1 rounded-sm surface-2 border border-border text-xs">
      <span className="text-muted-foreground font-mono">TXC</span>
      <span className="font-mono font-semibold">
        ${p.usd.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 6 })}
      </span>
      <span
        className={`inline-flex items-center gap-0.5 font-mono ${up ? "text-success" : "text-primary"}`}
      >
        {up ? <TrendingUp className="size-3" /> : <TrendingDown className="size-3" />}
        {up ? "+" : ""}
        {p.change24h.toFixed(2)}%
      </span>
    </div>
  );
}
