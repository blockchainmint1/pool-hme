import { runIndexerLoop } from "./indexer.js";
import { startHttp } from "./esplora.js";

async function main(): Promise<void> {
  console.log("[indexer] starting txc address indexer");
  await startHttp();
  await runIndexerLoop();
}

main().catch((err) => {
  console.error("[indexer] fatal:", err);
  process.exit(1);
});
