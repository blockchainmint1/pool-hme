import { createFileRoute, Link } from "@tanstack/react-router";
import { SearchBar } from "@/components/explorer/SearchBar";

export const Route = createFileRoute("/$")({
  component: CatchAll,
});

function CatchAll() {
  return (
    <div className="max-w-2xl mx-auto px-4 py-16 text-center">
      <h1 className="font-display text-5xl text-primary">404</h1>
      <h2 className="font-display text-xl mt-2">Not on the chain</h2>
      <p className="text-sm text-muted-foreground mt-2">
        That URL doesn't match a known route. Search for a block, transaction, or address instead.
      </p>
      <div className="mt-6">
        <SearchBar variant="hero" autoFocus />
      </div>
      <div className="mt-4">
        <Link to="/" className="text-sm text-accent hover:underline">← back to the dashboard</Link>
      </div>
    </div>
  );
}
