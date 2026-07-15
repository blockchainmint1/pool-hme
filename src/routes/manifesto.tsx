import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/manifesto")({
  head: () => ({
    meta: [
      { title: "Manifesto — TEXITcoin Pool" },
      {
        name: "description",
        content:
          "Why the TEXITcoin pool exists: sound money as a right, mining without a middleman, and infrastructure built by individuals for individuals.",
      },
      { property: "og:title", content: "Manifesto — TEXITcoin Pool" },
      {
        property: "og:description",
        content:
          "Sound money is a right. This pool exists so anyone with a rig can secure it.",
      },
    ],
  }),
  component: ManifestoPage,
});

function ManifestoPage() {
  return (
    <div className="font-pool-body pool-grid-bg">
      <div className="max-w-3xl mx-auto px-4 py-16 md:py-24 space-y-10">
        <div>
          <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
            honest.money · TEXITcoin
          </div>
          <h1 className="font-pool-display text-4xl md:text-6xl text-pool-steel-hi mt-3 leading-[1.02] text-balance">
            Sound money is a <span className="text-pool-mint">right</span>.
          </h1>
          <p className="mt-6 text-pool-steel text-lg leading-relaxed">
            The TEXITcoin pool exists because a currency you cannot participate in producing
            is not really yours. If mining is only for corporations, the money is only for
            them too. So we run a pool that anyone with a rig — one ASIC, ten ASICs, or a
            garage full of them — can plug into and help secure.
          </p>
        </div>

        <Section title="One hash, five chains, no middleman.">
          Merged mining means every scrypt hash your rig produces contributes to LTC, DOGE,
          ISK, TXC and ZCU at the same time. You mine LTC and DOGE for revenue. You mine
          TXC and ISK for the chains you want to exist. The pool takes 0%.
        </Section>

        <Section title="Custody-free by construction.">
          The pool never holds your coins beyond the ~30-minute payout cycle. You register
          your own LTC address, your own DOGE payout address, and the pool routes to them
          directly. There is nothing to hack that would let anyone take your funds.
        </Section>

        <Section title="Built by individuals, for individuals.">
          Every layer of this stack — the node, the pool, the indexer, the explorer, the L2 —
          is open, self-hostable, and independently verifiable. If we go away tomorrow,
          the network continues. That's the point.
        </Section>

        <Section title="No permission required.">
          We don't KYC miners. We don't rate-limit hobbyists. We don't sell hashrate to the
          highest bidder. If you can point a stratum client at us, you can mine.
        </Section>

        <div className="pt-6 border-t border-pool-hairline">
          <div className="text-[11px] font-mono text-pool-steel">
            Part of the{" "}
            <a
              href="https://honest.money"
              target="_blank"
              rel="noreferrer"
              className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            >
              honest.money
            </a>{" "}
            ecosystem. Learn more at{" "}
            <a
              href="https://texitcoin.org/build"
              target="_blank"
              rel="noreferrer"
              className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            >
              texitcoin.org/build
            </a>
            .
          </div>
          <div className="mt-4">
            <Link
              to="/"
              className="inline-flex items-center gap-2 rounded-md bg-pool-mint text-pool-obsidian px-4 py-2.5 text-sm font-semibold hover:opacity-90"
            >
              Back to the pool
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="font-pool-display text-2xl md:text-3xl text-pool-steel-hi text-balance">
        {title}
      </h2>
      <p className="mt-3 text-pool-steel leading-relaxed">{children}</p>
    </section>
  );
}
