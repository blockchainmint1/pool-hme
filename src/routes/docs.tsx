import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Copy, Globe, Radio } from "lucide-react";
import { REST_GROUPS, WS_GROUPS, type EndpointGroup } from "@/lib/docs/api-spec";

export const Route = createFileRoute("/docs")({
  head: () => ({
    meta: [
      { title: "API Docs — TXC Mempool" },
      { name: "description", content: "Public REST and WebSocket API for the TEXITcoin block explorer. Drop-in compatible with mempool.space patterns." },
      { property: "og:title", content: "TXC Mempool — Public API" },
      { property: "og:description", content: "REST + WebSocket endpoints for chain tip, blocks, transactions, addresses, mempool, fees, mining, and TXC-only extras (price, supply, Omni decoding)." },
    ],
  }),
  component: DocsPage,
});

const ORIGIN = "https://mempool2.texitcoin.org";

function DocsPage() {
  const [tab, setTab] = useState<"rest" | "ws">("rest");
  const groups = tab === "rest" ? REST_GROUPS : WS_GROUPS;
  return (
    <div className="max-w-7xl mx-auto px-4 py-6">
      <div className="mb-6">
        <div className="text-[10px] uppercase tracking-widest text-muted-foreground">Developers</div>
        <h1 className="font-display text-3xl md:text-4xl font-semibold mt-1">TXC Mempool API</h1>
        <p className="mt-2 text-sm text-muted-foreground max-w-3xl">
          Free, open, no API key required. Drop-in compatible with{" "}
          <a href="https://mempool.space/docs/api" target="_blank" rel="noreferrer" className="text-accent hover:underline">
            mempool.space
          </a>{" "}
          patterns — point your client at <span className="font-mono text-foreground">{ORIGIN}</span> and you're done.
          Rate-limited per IP at the edge; please cache aggressively. Need higher limits or want to mirror the data?{" "}
          <a href="mailto:hello@texitcoin.org" className="text-accent hover:underline">Get in touch</a>.
        </p>
        <div className="mt-4 inline-flex rounded-md border border-border surface-2 p-1 text-xs">
          <button
            onClick={() => setTab("rest")}
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-sm font-medium transition-colors ${
              tab === "rest" ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Globe className="size-3.5" /> REST
          </button>
          <button
            onClick={() => setTab("ws")}
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-sm font-medium transition-colors ${
              tab === "ws" ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Radio className="size-3.5" /> WebSocket
          </button>
        </div>
      </div>

      <div className="grid lg:grid-cols-[200px_1fr] gap-6">
        <nav className="space-y-1 text-xs lg:sticky lg:top-20 lg:self-start">
          {groups.map((g) => (
            <a key={g.id} href={`#${g.id}`} className="block px-2 py-1.5 rounded-sm text-muted-foreground hover:text-foreground hover:surface-2">
              {g.title}
            </a>
          ))}
        </nav>
        <div className="space-y-8 min-w-0">
          {groups.map((g) => (
            <GroupBlock key={g.id} group={g} kind={tab} />
          ))}
        </div>
      </div>
    </div>
  );
}

function GroupBlock({ group, kind }: { group: EndpointGroup; kind: "rest" | "ws" }) {
  return (
    <section id={group.id} className="scroll-mt-20">
      <h2 className="font-display text-xl font-semibold">{group.title}</h2>
      <p className="text-sm text-muted-foreground mt-1">{group.description}</p>
      <div className="mt-4 space-y-3">
        {group.endpoints.map((e, i) => (
          <EndpointRow key={i} method={e.method} path={e.path} summary={e.summary} example={e.example} kind={kind} />
        ))}
      </div>
    </section>
  );
}

function EndpointRow({
  method, path, summary, example, kind,
}: { method: "GET" | "WS"; path: string; summary: string; example?: string; kind: "rest" | "ws" }) {
  const [copied, setCopied] = useState(false);
  const fullUrl = kind === "rest" ? `${ORIGIN}${path}` : path;
  const curl = kind === "rest"
    ? `curl -s ${fullUrl.replace(/:(\w+)/g, "<$1>")}`
    : path;
  return (
    <div className="surface-2 border border-border rounded-md overflow-hidden">
      <div className="flex flex-wrap items-center gap-2 px-3 py-2 border-b border-border">
        <span className={`font-mono text-[10px] uppercase font-semibold px-1.5 py-0.5 rounded-sm ${
          method === "GET" ? "bg-success/20 text-success" : "bg-accent/20 text-accent"
        }`}>
          {method}
        </span>
        <code className="font-mono text-xs flex-1 break-all">{path}</code>
        <button
          onClick={async () => { await navigator.clipboard.writeText(curl); setCopied(true); setTimeout(() => setCopied(false), 1200); }}
          className="text-[11px] inline-flex items-center gap-1 px-2 py-0.5 rounded-sm border border-border hover:border-primary"
          title="Copy curl"
        >
          <Copy className="size-3" /> {copied ? "copied" : "copy"}
        </button>
      </div>
      <div className="px-3 py-2 text-sm text-muted-foreground">{summary}</div>
      {example && (
        <pre className="px-3 py-2 bg-background/40 border-t border-border text-[11px] font-mono overflow-x-auto whitespace-pre">
{example}
        </pre>
      )}
    </div>
  );
}
