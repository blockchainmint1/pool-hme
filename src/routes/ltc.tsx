import { createFileRoute } from "@tanstack/react-router";
import { CoinPage, coinPageQuery } from "@/components/pool/CoinPage";

export const Route = createFileRoute("/ltc")({
  head: () => ({
    meta: [
      { title: "Litecoin blocks — TEXITcoin Pool" },
      {
        name: "description",
        content:
          "Every LTC block found by the pool: rewards, confirmation status, daily cadence, coinbase destination, and how payouts were distributed to miners.",
      },
      { property: "og:title", content: "Litecoin blocks — TEXITcoin Pool" },
      {
        property: "og:description",
        content:
          "Every LTC block found by the pool: rewards, confirmation status, daily cadence, coinbase destination, and payout distribution.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  loader: ({ context }) => context.queryClient.ensureQueryData(coinPageQuery("LTC")),
  component: () => <CoinPage symbol="LTC" />,
});
