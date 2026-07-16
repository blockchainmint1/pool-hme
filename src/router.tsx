import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { routerWithQueryClient } from "@tanstack/react-router-with-query";
import { routeTree } from "./routeTree.gen";

export const getRouter = () => {
  const queryClient = new QueryClient();

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    defaultPreloadStaleTime: 0,
  });

  // Dehydrates the QueryClient on the server and rehydrates on the client so
  // useSuspenseQuery returns the same data on first paint that SSR rendered.
  // Without this, the client re-runs loader queryFns and any drift (new block,
  // ticker) causes a hydration mismatch.
  return routerWithQueryClient(router, queryClient);
};

