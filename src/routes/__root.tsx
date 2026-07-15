import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";

import appCss from "../styles.css?url";
import { SearchBar } from "@/components/explorer/SearchBar";
import { PriceTicker } from "@/components/explorer/PriceTicker";

function NotFoundComponent() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="font-display text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">Off the chain</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          The block, transaction, or address you're looking for doesn't exist on TXC.
        </p>
        <div className="mt-6 flex gap-2 justify-center">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:opacity-90"
          >
            Dashboard
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="font-display text-xl font-semibold tracking-tight text-foreground">
          Couldn't fetch from the chain
        </h1>
        <p className="mt-2 text-sm text-muted-foreground font-mono break-all">
          {import.meta.env.DEV ? error.message : "Something went wrong. Please try again."}
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => { router.invalidate(); reset(); }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground hover:opacity-90"
          >
            Retry
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-border bg-surface px-4 py-2 text-sm font-medium text-foreground hover:bg-surface-2"
          >
            Dashboard
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "TEXITcoin Pool — Sound-money mining, made simple" },
      { name: "description", content: "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem." },
      { name: "author", content: "TEXITcoin" },
      { property: "og:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      { property: "og:description", content: "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "TEXITcoin Pool — Sound-money mining, made simple" },
      { name: "twitter:description", content: "TXC merged mining pool. Live hashrate, active miners, merged-mining across LTC / DOGE / ISK / TXC / ZCU, and 30-minute payouts. Part of the honest.money ecosystem." },
      { property: "og:image", content: "https://pub-bb2e103a32db4e198524a2e9ed8f35b4.r2.dev/0e23c0e1-ae81-4e85-8c9c-5b9c9a47003f/id-preview-f9d7e95b--a356bfa6-5f63-4466-b99d-f11202767549.lovable.app-1779994450550.png" },
      { name: "twitter:image", content: "https://pub-bb2e103a32db4e198524a2e9ed8f35b4.r2.dev/0e23c0e1-ae81-4e85-8c9c-5b9c9a47003f/id-preview-f9d7e95b--a356bfa6-5f63-4466-b99d-f11202767549.lovable.app-1779994450550.png" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      { rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Oswald:wght@500;600;700&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@400;500;600;700&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700&display=swap" },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function Header() {
  return (
    <header className="border-b border-border surface/80 backdrop-blur sticky top-0 z-30">
      <div className="max-w-7xl mx-auto px-4 py-3 flex items-center gap-4">
        <Link to="/" className="flex items-center gap-2 flex-shrink-0">
          <div className="size-7 rounded-sm bg-primary flex items-center justify-center font-display font-bold text-primary-foreground shadow-glow-red">
            T
          </div>
          <div className="font-display tracking-wide text-base hidden sm:block">
            HME POOL
          </div>
        </Link>
        <nav className="hidden md:flex items-center gap-1 text-sm font-medium">
          <Link
            to="/"
            activeOptions={{ exact: true }}
            className="px-3 py-1.5 rounded-sm text-muted-foreground hover:text-foreground hover:surface-2 transition-colors"
            activeProps={{ className: "px-3 py-1.5 rounded-sm text-foreground bg-surface-2" }}
          >
            Pool
          </Link>
        </nav>
        <div className="flex-1 flex justify-end items-center gap-2">
          <PriceTicker />
          <SearchBar variant="header" />
        </div>
      </div>
    </header>
  );
}

function Footer() {
  return (
    <footer className="border-t border-border mt-16 surface/50">
      <div className="max-w-7xl mx-auto px-4 py-8 grid grid-cols-2 md:grid-cols-4 gap-6 text-sm">
        <div>
          <div className="font-display tracking-wide mb-2">HME POOL</div>
          <div className="text-xs text-muted-foreground leading-relaxed">
            Part of the{" "}
            <a
              href="https://honest.money"
              className="text-foreground underline decoration-dotted underline-offset-2 hover:text-primary"
              target="_blank"
              rel="noreferrer"
            >
              honest.money
            </a>{" "}
            ecosystem — sound-money infrastructure built by individuals, for individuals.
          </div>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Explore</div>
          <ul className="space-y-1">
            <li><Link to="/" className="hover:text-primary">Pool</Link></li>
            <li><a href="#workers" className="hover:text-primary">Workers</a></li>
            <li><a href="#blocks" className="hover:text-primary">Found blocks</a></li>
            <li><a href="#connect" className="hover:text-primary">Connect a miner</a></li>
          </ul>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Ecosystem</div>
          <ul className="space-y-1">
            <li><a href="https://honest.money" className="hover:text-primary" target="_blank" rel="noreferrer">honest.money</a></li>
            <li><a href="https://texitcoin.org" className="hover:text-primary" target="_blank" rel="noreferrer">texitcoin.org</a></li>
            <li><a href="https://texitcoin.org/build" className="hover:text-primary" target="_blank" rel="noreferrer">Build on TXC</a></li>
            <li><Link to="/manifesto" className="hover:text-primary">Manifesto</Link></li>
          </ul>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Legal</div>
          <ul className="space-y-1">
            <li><Link to="/terms" className="hover:text-primary">Terms</Link></li>
            <li><Link to="/privacy" className="hover:text-primary">Privacy</Link></li>
            <li><Link to="/manifesto" className="hover:text-primary">Manifesto</Link></li>
            <li><a href="https://texitcoin.org/build" className="hover:text-primary" target="_blank" rel="noreferrer">Build docs</a></li>
          </ul>
        </div>
      </div>
      <div className="border-t border-border py-3 text-center text-[11px] text-muted-foreground">
        HME Pool · Mined in Texas, by individuals. Part of the{" "}
        <a href="https://honest.money" className="underline decoration-dotted underline-offset-2 hover:text-primary" target="_blank" rel="noreferrer">honest.money</a>{" "}
        ecosystem.
      </div>
    </footer>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();
  return (
    <QueryClientProvider client={queryClient}>
      <div className="min-h-screen flex flex-col">
        <Header />
        <main className="flex-1">
          <Outlet />
        </main>
        <Footer />
      </div>
    </QueryClientProvider>
  );
}
