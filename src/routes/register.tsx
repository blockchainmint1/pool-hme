import { useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  getCaptcha,
  getRegistrationStatus,
  submitRegistration,
  type RegisterSuccess,
} from "@/lib/pool/register.functions";
import {
  AlertTriangle,
  ChevronLeft,
  Check,
  Copy,
  Loader2,
  RefreshCw,
  ShieldCheck,
} from "lucide-react";

export const Route = createFileRoute("/register")({
  head: () => ({
    meta: [
      { title: "Register LTC + DOGE payouts · honest.money pool" },
      {
        name: "description",
        content:
          "Link your Litecoin mining address to a Dogecoin payout address and get the permanent dogelink token your miners need. Zero-fee merged mining.",
      },
      { property: "og:title", content: "Register LTC + DOGE payouts" },
      {
        property: "og:description",
        content:
          "Link your LTC mining address to a DOGE payout address and get your permanent dogelink token.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: RegisterPage,
});

function Field({
  label,
  hint,
  error,
  ...props
}: {
  label: string;
  hint: string;
  error?: string;
} & React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="block">
      <span className="text-[10px] uppercase tracking-[0.2em] font-mono text-pool-steel">
        {label}
      </span>
      <input
        {...props}
        spellCheck={false}
        autoComplete="off"
        className={`mt-2 w-full rounded-md border bg-transparent px-3 py-2.5 font-mono text-sm text-pool-steel-hi outline-none transition-colors placeholder:text-pool-steel/50 focus:border-pool-mint ${
          error ? "border-destructive" : "border-pool-hairline"
        }`}
      />
      <span className="mt-1.5 block text-xs text-pool-steel">{error ?? hint}</span>
    </label>
  );
}

function RegisterPage() {
  const status = useQuery({
    queryKey: ["pool", "register", "status"],
    queryFn: () => getRegistrationStatus(),
    staleTime: 60_000,
  });

  const captcha = useQuery({
    queryKey: ["pool", "register", "captcha"],
    queryFn: () => getCaptcha(),
    staleTime: 0,
    gcTime: 0,
    enabled: status.data?.enabled === true,
  });

  const submit = useServerFn(submitRegistration);

  const [ltc, setLtc] = useState("");
  const [doge, setDoge] = useState("");
  const [answer, setAnswer] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errorField, setErrorField] = useState<string | undefined>();
  const [result, setResult] = useState<RegisterSuccess | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const enabled = status.data?.enabled === true;

  async function copy(text: string, key: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(key);
      setTimeout(() => setCopied(null), 1600);
    } catch {
      /* clipboard unavailable */
    }
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (busy || !captcha.data) return;
    setBusy(true);
    setError(null);
    setErrorField(undefined);
    try {
      const res = await submit({
        data: {
          ltc_address: ltc,
          doge_address: doge,
          captcha: {
            nonce: captcha.data.nonce,
            expires: captcha.data.expires,
            sig: captcha.data.sig,
            answer,
          },
        },
      });
      if (res.ok) {
        setResult(res);
      } else {
        setError(res.error);
        setErrorField(res.field);
        setAnswer("");
        captcha.refetch();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Registration failed.");
      setAnswer("");
      captcha.refetch();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen bg-pool-ink text-pool-steel-hi">
      <div className="mx-auto max-w-3xl px-4 py-10 space-y-8">
        <Link
          to="/"
          className="inline-flex items-center gap-1.5 text-xs font-mono text-pool-steel hover:text-pool-steel-hi"
        >
          <ChevronLeft className="size-3.5" /> back to pool
        </Link>

        <header>
          <div className="flex items-center gap-2 text-[11px] font-mono uppercase tracking-[0.2em] text-pool-steel">
            <span className="size-1.5 rounded-full bg-pool-mint animate-pulse-dot" />
            merged mining · zero fee
          </div>
          <h1 className="mt-3 font-pool-display text-3xl md:text-4xl text-pool-steel-hi">
            Register LTC + DOGE payouts
          </h1>
          <p className="mt-3 text-sm text-pool-steel leading-relaxed max-w-2xl">
            You mine with your <span className="text-pool-steel-hi">LTC address</span> as
            the stratum username. To also get paid in DOGE, link a Dogecoin payout
            address here. You'll receive a permanent{" "}
            <span className="font-mono text-pool-steel-hi">dogelink</span> token to put in
            your miner's password field.
          </p>
        </header>

        {result ? (
          <TokenPanel result={result} copied={copied} copy={copy} />
        ) : !enabled ? (
          <div className="rounded-lg border border-pool-hairline p-6 pool-graphite">
            <div className="flex items-start gap-3">
              <AlertTriangle className="size-4 mt-0.5 text-pool-amber shrink-0" />
              <div className="space-y-2">
                <div className="text-sm text-pool-steel-hi">
                  Registration isn't open on this server yet
                </div>
                <p className="text-xs text-pool-steel leading-relaxed">
                  The new registration path is deployed but still switched off while we
                  verify it against the live payout pipeline. In the meantime use the
                  existing form:
                </p>
                <a
                  href="https://pool.texitcoin.org/site/dogeRegister"
                  target="_blank"
                  rel="noreferrer"
                  className="inline-block text-xs font-mono text-pool-mint hover:underline"
                >
                  pool.texitcoin.org/site/dogeRegister →
                </a>
              </div>
            </div>
          </div>
        ) : (
          <form
            onSubmit={onSubmit}
            className="rounded-lg border border-pool-hairline p-6 pool-graphite space-y-5"
          >
            <Field
              label="LTC mining address"
              hint="This becomes your stratum username. Mainnet only: ltc1… or L / M / 3…"
              error={errorField === "ltc_address" ? error ?? undefined : undefined}
              value={ltc}
              onChange={(e) => setLtc(e.target.value)}
              placeholder="ltc1q…"
              maxLength={120}
              required
            />
            <Field
              label="DOGE payout address"
              hint="Where your merged-mined DOGE is sent. Mainnet only: D…, A… or 9…"
              error={errorField === "doge_address" ? error ?? undefined : undefined}
              value={doge}
              onChange={(e) => setDoge(e.target.value)}
              placeholder="D…"
              maxLength={120}
              required
            />

            <div className="flex items-end gap-3">
              <div className="flex-1">
                <Field
                  label="Human check"
                  hint={captcha.data?.question ?? "Loading challenge…"}
                  error={errorField === "captcha" ? error ?? undefined : undefined}
                  value={answer}
                  onChange={(e) => setAnswer(e.target.value)}
                  placeholder="answer"
                  inputMode="numeric"
                  maxLength={6}
                  required
                />
              </div>
              <button
                type="button"
                onClick={() => captcha.refetch()}
                className="mb-6 rounded-md border border-pool-hairline p-2.5 text-pool-steel hover:text-pool-steel-hi"
                aria-label="New challenge"
              >
                <RefreshCw className="size-4" />
              </button>
            </div>

            {error && !errorField && (
              <div className="flex items-start gap-2 rounded-md border border-destructive/40 px-3 py-2.5 text-xs text-destructive">
                <AlertTriangle className="size-3.5 mt-0.5 shrink-0" />
                <span>{error}</span>
              </div>
            )}

            <button
              type="submit"
              disabled={busy || !captcha.data}
              className="inline-flex w-full items-center justify-center gap-2 rounded-md bg-pool-mint px-4 py-3 text-sm font-medium text-pool-ink transition-opacity disabled:opacity-50"
            >
              {busy ? <Loader2 className="size-4 animate-spin" /> : <ShieldCheck className="size-4" />}
              {busy ? "Registering…" : "Create registration"}
            </button>

            <p className="text-[11px] text-pool-steel leading-relaxed">
              We store only the two addresses and the token. Both are verified against the
              live LTC and DOGE daemons before anything is written. Registration is
              additive — an address that's already linked can't be re-registered here.
            </p>
          </form>
        )}

        <section className="rounded-lg border border-pool-hairline p-6 space-y-3">
          <h2 className="font-pool-display text-lg text-pool-steel-hi">
            How the token is used
          </h2>
          <ol className="space-y-2 text-xs text-pool-steel leading-relaxed list-decimal pl-4">
            <li>
              Set your miner's <span className="font-mono text-pool-steel-hi">username</span>{" "}
              to your LTC address — never your DOGE address.
            </li>
            <li>
              Set the <span className="font-mono text-pool-steel-hi">password</span> to{" "}
              <span className="font-mono text-pool-steel-hi">dogelink=YOUR_TOKEN</span>.
            </li>
            <li>
              The pool sees the token on your shares and routes DOGE rewards to the linked
              payout address. If the token stops appearing, DOGE payouts pause until it's
              back.
            </li>
          </ol>
        </section>
      </div>
    </div>
  );
}

function TokenPanel({
  result,
  copied,
  copy,
}: {
  result: RegisterSuccess;
  copied: string | null;
  copy: (text: string, key: string) => void;
}) {
  const cmd = `-o stratum+tcp://stratum.pool.honest.money:3433 -u ${result.ltc_address} -p ${result.stratum_password}`;
  return (
    <div className="space-y-5">
      <div className="rounded-lg border border-pool-mint/50 p-6 pool-graphite space-y-4">
        <div className="flex items-center gap-2 text-xs font-mono uppercase tracking-[0.2em] text-pool-mint">
          <Check className="size-4" /> registration created
        </div>

        <div>
          <div className="text-[10px] uppercase tracking-[0.2em] font-mono text-pool-steel">
            Permanent token
          </div>
          <div className="mt-2 flex items-center gap-2">
            <code className="flex-1 break-all rounded-md border border-pool-hairline px-3 py-3 font-mono text-base text-pool-steel-hi">
              {result.permanent_token}
            </code>
            <button
              onClick={() => copy(result.permanent_token, "token")}
              className="rounded-md border border-pool-hairline p-3 text-pool-steel hover:text-pool-steel-hi"
              aria-label="Copy token"
            >
              {copied === "token" ? <Check className="size-4" /> : <Copy className="size-4" />}
            </button>
          </div>
        </div>

        <div className="flex items-start gap-2 rounded-md border border-pool-amber/40 px-3 py-2.5 text-xs text-pool-amber">
          <AlertTriangle className="size-3.5 mt-0.5 shrink-0" />
          <span>
            This token is shown once and can never be reissued. Copy it somewhere safe
            before leaving this page.
          </span>
        </div>
      </div>

      <div className="rounded-lg border border-pool-hairline p-6 space-y-3">
        <div className="text-[10px] uppercase tracking-[0.2em] font-mono text-pool-steel">
          Miner configuration
        </div>
        <div className="flex items-start gap-2">
          <code className="flex-1 break-all rounded-md border border-pool-hairline px-3 py-3 font-mono text-xs text-pool-steel-hi">
            {cmd}
          </code>
          <button
            onClick={() => copy(cmd, "cmd")}
            className="rounded-md border border-pool-hairline p-3 text-pool-steel hover:text-pool-steel-hi"
            aria-label="Copy miner config"
          >
            {copied === "cmd" ? <Check className="size-4" /> : <Copy className="size-4" />}
          </button>
        </div>
        <dl className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs pt-2">
          <div>
            <dt className="text-pool-steel">LTC mining address</dt>
            <dd className="font-mono text-pool-steel-hi break-all">{result.ltc_address}</dd>
          </div>
          <div>
            <dt className="text-pool-steel">DOGE payout address</dt>
            <dd className="font-mono text-pool-steel-hi break-all">{result.doge_address}</dd>
          </div>
        </dl>
      </div>
    </div>
  );
}
