# @honestmoney/pool-sdk

TypeScript client for the [honest.money pool API](https://api.stratum.pool.honest.money). Works in Node 18+ and browsers.

```bash
npm i @honestmoney/pool-sdk
```

```ts
import { PoolClient } from "@honestmoney/pool-sdk";
const pool = new PoolClient();

const summary = await pool.getSummary();
const count = await pool.getMinerCount();
const rounds = await pool.getMergedMiningRounds("24h");

const stop = pool.stream({
  onBlockFound: (b) => console.log("block!", b.symbol, b.height),
  onHashrateTick: (t) => console.log("tick", t.algo, t.clients),
});
// stop() to unsubscribe
```

Point at a different base URL:

```ts
new PoolClient("https://api.stratum.pool.honest.money");
```

Full API reference: [docs/api.md](https://github.com/honestmoney/honest.money-pool/blob/main/docs/api.md).

## What this SDK is for

- Building third-party pool dashboards without polling
- Wiring pool state into Grafana / Home Assistant / miner monitors
- Analytics over pool-found blocks + merged-mining rounds
- Miner-facing tools that need per-address hashrate + payout history

## Not published to npm yet

This package lives in `infra/pool-sdk/` inside the honest.money-pool repo. Publish is on the roadmap; for now, copy the file or install directly from the git URL.
