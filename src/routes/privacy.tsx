import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy — TEXITcoin Pool" },
      {
        name: "description",
        content:
          "What data the TEXITcoin pool collects (and doesn't). Draft — plain-language privacy notice.",
      },
      { property: "og:title", content: "Privacy — TEXITcoin Pool" },
      {
        property: "og:description",
        content: "Plain-language privacy notice for the TEXITcoin pool.",
      },
    ],
  }),
  component: PrivacyPage,
});

function PrivacyPage() {
  return (
    <div className="font-pool-body pool-grid-bg">
      <div className="max-w-3xl mx-auto px-4 py-16 space-y-8">
        <header>
          <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
            Draft · v0
          </div>
          <h1 className="font-pool-display text-4xl md:text-5xl text-pool-steel-hi mt-2">
            Privacy
          </h1>
          <p className="mt-3 text-pool-steel text-sm">
            The short version: we collect the minimum needed to run a mining pool. No
            marketing analytics, no third-party trackers, no ad networks.
          </p>
        </header>

        <Row title="What we do collect">
          <ul className="mt-2 space-y-1 list-disc list-inside">
            <li>The LTC and DOGE addresses you register (they're literally how we pay you).</li>
            <li>Stratum share submissions — worker name, timestamp, difficulty.</li>
            <li>The IP address your miner connects from, kept only for abuse-prevention.</li>
            <li>Standard web server logs on this site (IP, path, user-agent) retained briefly.</li>
          </ul>
        </Row>

        <Row title="What we don't collect">
          <ul className="mt-2 space-y-1 list-disc list-inside">
            <li>No KYC. No name, no email, no phone.</li>
            <li>No third-party analytics, no ad SDKs, no cross-site tracking.</li>
            <li>No cookies beyond what's strictly needed to make the site work.</li>
          </ul>
        </Row>

        <Row title="On-chain data">
          Payouts happen on public blockchains. Anyone can see amounts and addresses. Use a
          fresh receiving address if you want stronger unlinkability.
        </Row>

        <Row title="Contact">
          For privacy requests, reach the maintainers via the channels listed at{" "}
          <a
            href="https://texitcoin.org/build"
            className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            target="_blank"
            rel="noreferrer"
          >
            texitcoin.org/build
          </a>
          .
        </Row>
      </div>
    </div>
  );
}

function Row({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="pool-kpi-panel rounded-md p-5">
      <h2 className="font-pool-display text-lg text-pool-steel-hi">{title}</h2>
      <div className="text-sm text-pool-steel leading-relaxed">{children}</div>
    </section>
  );
}
