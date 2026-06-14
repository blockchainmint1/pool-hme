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
          {error.message}
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
      { title: "TXC Mempool — TEXITcoin Block Explorer" },
      { name: "description", content: "Real-time TEXITcoin (TXC) block explorer, mempool visualization, fee estimator, Omni-Layer token decoder, and mining stats." },
      { name: "author", content: "TEXITcoin" },
      { property: "og:title", content: "TXC Mempool — TEXITcoin Block Explorer" },
      { property: "og:description", content: "Real-time TEXITcoin (TXC) block explorer, mempool visualization, fee estimator, Omni-Layer token decoder, and mining stats." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: "TXC Mempool — TEXITcoin Block Explorer" },
      { name: "twitter:description", content: "Real-time TEXITcoin (TXC) block explorer, mempool visualization, fee estimator, Omni-Layer token decoder, and mining stats." },
      { property: "og:image", content: "https://pub-bb2e103a32db4e198524a2e9ed8f35b4.r2.dev/0e23c0e1-ae81-4e85-8c9c-5b9c9a47003f/id-preview-f9d7e95b--a356bfa6-5f63-4466-b99d-f11202767549.lovable.app-1779994450550.png" },
      { name: "twitter:image", content: "https://pub-bb2e103a32db4e198524a2e9ed8f35b4.r2.dev/0e23c0e1-ae81-4e85-8c9c-5b9c9a47003f/id-preview-f9d7e95b--a356bfa6-5f63-4466-b99d-f11202767549.lovable.app-1779994450550.png" },
    ],
    links: [{ rel: "stylesheet", href: appCss }],
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
            TXC<span className="text-primary">.</span>MEMPOOL
          </div>
        </Link>
        <nav className="hidden md:flex items-center gap-1 text-sm font-medium">
          {[
            { to: "/", label: "Dashboard" },
            { to: "/mempool", label: "Mempool" },
            { to: "/blocks", label: "Blocks" },
            { to: "/mining", label: "Mining" },
            { to: "/graphs", label: "Graphs" },
            { to: "/docs", label: "API" },
            { to: "/about", label: "About" },
          ].map((l) => (
            <Link
              key={l.to}
              to={l.to}
              activeOptions={{ exact: l.to === "/" }}
              className="px-3 py-1.5 rounded-sm text-muted-foreground hover:text-foreground hover:surface-2 transition-colors"
              activeProps={{ className: "px-3 py-1.5 rounded-sm text-foreground bg-surface-2" }}
            >
              {l.label}
            </Link>
          ))}
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
          <div className="font-display tracking-wide mb-2">TXC.MEMPOOL</div>
          <div className="text-xs text-muted-foreground">
            Live block explorer for the TEXITcoin chain. Built on the upstream
            mempool/Esplora API at <span className="font-mono">mempool.texitcoin.org</span>.
          </div>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Explore</div>
          <ul className="space-y-1">
            <li><Link to="/" className="hover:text-primary">Dashboard</Link></li>
            <li><Link to="/mempool" className="hover:text-primary">Mempool</Link></li>
            <li><Link to="/blocks" className="hover:text-primary">Blocks</Link></li>
            <li><Link to="/mining" className="hover:text-primary">Mining</Link></li>
            <li><Link to="/graphs" className="hover:text-primary">Graphs</Link></li>
          </ul>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Ecosystem</div>
          <ul className="space-y-1">
            <li><a href="https://texitcoin.org" className="hover:text-primary" target="_blank" rel="noreferrer">texitcoin.org</a></li>
            <li><a href="https://honest.money" className="hover:text-primary" target="_blank" rel="noreferrer">honest.money</a></li>
            <li><a href="https://cryptopop.asia/api" className="hover:text-primary" target="_blank" rel="noreferrer">L2 docs (POP)</a></li>
            <li><a href="https://imaginenation.com/api" className="hover:text-primary" target="_blank" rel="noreferrer">ImagineNation API</a></li>
          </ul>
        </div>
        <div>
          <div className="font-display text-xs uppercase mb-2 text-muted-foreground">Network</div>
          <ul className="space-y-1 font-mono text-xs">
            <li>P2PKH prefix: <span className="text-foreground">0x42 (T…)</span></li>
            <li>Block time: <span className="text-foreground">~3 min</span></li>
            <li>L2: <span className="text-foreground">Omni Layer</span></li>
          </ul>
        </div>
      </div>
      <div className="border-t border-border py-3 text-center text-[11px] text-muted-foreground">
        TEXITcoin · Mined in Texas, by individuals.
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
