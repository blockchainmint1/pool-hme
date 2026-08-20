import { createFileRoute } from "@tanstack/react-router";
import { CoinPage, coinPageQuery } from "@/components/pool/CoinPage";

export const Route = createFileRoute("/doge")({
  head: () => ({
    meta: [
      { title: "Dogecoin blocks — TEXITcoin Pool" },
      {
        name: "description",
        content:
          "Every DOGE block merge-mined by the pool: rewards, confirmation status, daily cadence, coinbase destination, and how payouts were distributed to miners.",
      },
      { property: "og:title", content: "Dogecoin blocks — TEXITcoin Pool" },
      {
        property: "og:description",
        content:
          "Every DOGE block merge-mined by the pool: rewards, confirmation status, daily cadence, coinbase destination, and payout distribution.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  loader: ({ context }) => context.queryClient.ensureQueryData(coinPageQuery("DOGE")),
  component: () => <CoinPage symbol="DOGE" />,
});
