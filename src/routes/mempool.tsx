import { createFileRoute, Outlet } from "@tanstack/react-router";

export const Route = createFileRoute("/mempool")({
  component: MempoolLayout,
});

function MempoolLayout() {
  return <Outlet />;
}
