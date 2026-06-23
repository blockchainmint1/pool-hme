import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/about")({
  head: () => ({
    meta: [
      { title: "About — TXC Mempool Explorer" },
      { name: "description", content: "What TXC Mempool is, how it works, and the data sources behind it." },
      { property: "og:title", content: "About TXC Mempool" },
      { property: "og:description", content: "How the TEXITcoin block explorer works." },
    ],
  }),
  component: AboutPage,
});

function AboutPage() {
  return (
    <div className="max-w-3xl mx-auto px-4 py-10 prose-invert">
      <h1 className="font-display text-4xl mb-4">About TXC Mempool</h1>
      <p className="text-muted-foreground leading-relaxed">
        TXC Mempool is a real-time block explorer for the{" "}
        <a href="https://texitcoin.org" target="_blank" rel="noreferrer" className="text-primary hover:underline">TEXITcoin</a>{" "}
        chain. It mirrors the look and feel of mempool.space — fee bucket
        visualizations, projected next blocks, fee gauges, mining pool stats —
        and adds <strong className="text-foreground">first-class decoding for Omni-Layer L2 token activity</strong>{" "}
        carried in TXC OP_RETURN outputs.
      </p>

      <h2 className="font-display text-2xl mt-8 mb-3">Where the data comes from</h2>
      <p className="text-muted-foreground leading-relaxed">
        Everything is read live from our own infrastructure at{" "}
        <code className="font-mono text-foreground">api.mempool.texitcoin.org</code>:
        a fully-synced TXC node (Litecoin-fork, Scrypt PoW, 3-min target), a
        custom Esplora-compatible address indexer, and the mempool backend on
        top — all self-hosted, no third parties in the path. When available,
        this UI subscribes to the WebSocket at{" "}
        <code className="font-mono text-foreground">wss://api.mempool.texitcoin.org/api/v1/ws</code>{" "}
        for live updates; otherwise it polls every 10 seconds. The status pill
        in the dashboard hero tells you which mode you're in.
      </p>

      <h2 className="font-display text-2xl mt-8 mb-3">OP_RETURN & Omni-Layer</h2>
      <p className="text-muted-foreground leading-relaxed">
        TXC carries token activity through the Omni-Layer protocol: regular TXC
        transactions whose first OP_RETURN output begins with the ASCII magic{" "}
        <code className="font-mono text-foreground">"omni"</code> (0x6f 0x6d 0x6e 0x69),
        followed by a binary version + type + payload. This explorer decodes:
      </p>
      <ul className="list-disc pl-6 space-y-1 text-muted-foreground text-sm mt-2">
        <li>Simple Send (type 0)</li>
        <li>Send All (type 4)</li>
        <li>Create Property Fixed (type 50) and Managed (type 54)</li>
        <li>Grant (55), Revoke (56), Close Crowdsale (53), Change Issuer (70)</li>
      </ul>
      <p className="text-muted-foreground leading-relaxed mt-3">
        For the canonical L2 spec see{" "}
        <a href="https://cryptopop.asia/api" target="_blank" rel="noreferrer" className="text-primary hover:underline">cryptopop.asia/api</a>{" "}
        and{" "}
        <a href="https://imaginenation.com/api" target="_blank" rel="noreferrer" className="text-primary hover:underline">imaginenation.com/api</a>.
        Unknown payload types are displayed as raw hex so you can still see
        them.
      </p>

      <h2 className="font-display text-2xl mt-8 mb-3">The ecosystem</h2>
      <ul className="list-disc pl-6 space-y-1 text-muted-foreground text-sm">
        <li><a href="https://texitcoin.org" className="text-primary hover:underline" target="_blank" rel="noreferrer">texitcoin.org</a> — chain home</li>
        <li><a href="https://honest.money" className="text-primary hover:underline" target="_blank" rel="noreferrer">honest.money</a> — the umbrella ecosystem</li>
        <li><a href="https://api.mempool.texitcoin.org" className="text-primary hover:underline" target="_blank" rel="noreferrer">api.mempool.texitcoin.org</a> — public REST + WebSocket API</li>
        <li><a href="https://explorer.texitcoin.org" className="text-primary hover:underline" target="_blank" rel="noreferrer">explorer.texitcoin.org</a> — classic block explorer</li>
      </ul>

      <div className="mt-10">
        <Link
          to="/"
          className="inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:opacity-90"
        >
          ← Back to dashboard
        </Link>
      </div>
    </div>
  );
}
