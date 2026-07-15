import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Terms of Service — TEXITcoin Pool" },
      {
        name: "description",
        content:
          "Terms of service for the TEXITcoin merged mining pool. Draft — plain-language rules for using the pool.",
      },
      { property: "og:title", content: "Terms — TEXITcoin Pool" },
      { property: "og:description", content: "Plain-language terms for using the TEXITcoin pool." },
    ],
  }),
  component: TermsPage,
});

function TermsPage() {
  return (
    <div className="font-pool-body pool-grid-bg">
      <div className="max-w-3xl mx-auto px-4 py-16 space-y-8">
        <header>
          <div className="text-[10px] uppercase tracking-[0.2em] text-pool-steel font-mono">
            Draft · v0
          </div>
          <h1 className="font-pool-display text-4xl md:text-5xl text-pool-steel-hi mt-2">
            Terms of Service
          </h1>
          <p className="mt-3 text-pool-steel text-sm">
            Plain-language rules for using pool.texitcoin.org. This is a working draft —
            it will be replaced with a lawyer-reviewed version before the pool exits preview.
          </p>
        </header>

        <Clause n={1} title="No warranty">
          The pool is provided as-is. Mining is inherently variable — hashrate, block luck,
          coin price and difficulty all fluctuate. We make no promise of revenue, uptime,
          or specific behavior.
        </Clause>
        <Clause n={2} title="You control your funds">
          The pool pays out directly to the LTC and DOGE addresses you register. We do not
          custody your coins. If you lose access to those wallets, we cannot recover funds.
        </Clause>
        <Clause n={3} title="No support obligation">
          Support is best-effort. There is no SLA. The pool is run by individuals, not a
          company. See the{" "}
          <Link to="/manifesto" className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint">
            manifesto
          </Link>{" "}
          for the philosophy.
        </Clause>
        <Clause n={4} title="Acceptable use">
          Don't abuse the pool: no DoS, no share-withholding attacks, no attempts to
          extract or interfere with other miners' data. We may block workers that harm the
          pool or the network.
        </Clause>
        <Clause n={5} title="Jurisdiction">
          You are responsible for complying with the laws of your own jurisdiction,
          including tax reporting on any coins you receive.
        </Clause>
        <Clause n={6} title="Changes">
          These terms may change. Material changes will be announced on the homepage. Your
          continued use of the pool means you accept the current version.
        </Clause>

        <div className="pt-6 border-t border-pool-hairline text-[11px] font-mono text-pool-steel">
          Questions? See{" "}
          <a
            href="https://texitcoin.org/build"
            className="text-pool-steel-hi underline decoration-dotted underline-offset-2 hover:text-pool-mint"
            target="_blank"
            rel="noreferrer"
          >
            texitcoin.org/build
          </a>
          .
        </div>
      </div>
    </div>
  );
}

function Clause({ n, title, children }: { n: number; title: string; children: React.ReactNode }) {
  return (
    <section className="pool-kpi-panel rounded-md p-5">
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-pool-mint">{String(n).padStart(2, "0")}</span>
        <h2 className="font-pool-display text-lg text-pool-steel-hi">{title}</h2>
      </div>
      <p className="mt-2 text-sm text-pool-steel leading-relaxed">{children}</p>
    </section>
  );
}
