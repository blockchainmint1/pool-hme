# yiimp-api

Small read-only JSON API that runs on the yiimp box
(`stratum.pool.honest.money`) and exposes just enough of the
`yiimpfrontend` MySQL schema for the pool front-end (pool.honest.money)
to render:

- Pool dashboard (per-algo hashrate, miners, workers, last block)
- Miner page by wallet address (workers, hashrate, shares, pending)
- Blocks found (LTC / DOGE / TXC / ISK / ZCU)
- Payouts / earnings per address

No auth. Public by address, like nicehash/f2pool. All state comes from
the DB — the service is stateless and safe to restart at any time.

## Why a separate service (not yiimp's api.php)

- yiimp's PHP web tier is old and not something I want to maintain.
- The front-end already lives on Lovable / TanStack Start with a clean
  proxy layer (`src/lib/api/backend.ts`). One more upstream = one more
  file (`src/lib/api/yiimp.ts`).
- Read-only + short cache = trivial to reason about and to firewall.
- If yiimp itself gets rewritten later, the front-end contract is
  stable — we just re-implement these ~10 endpoints.

## Topology

```
   pool.honest.money  (Lovable / Cloudflare)
           │
           │  fetch()  →  src/routes/api/v1/pool/*   (thin proxy + CORS + cache)
           ▼
   api.stratum.pool.honest.money    (this service, nginx TLS in front)

           │
           │  mysql localhost:3306
           ▼
   yiimpfrontend  DB on stratum.pool.honest.money
```

The service listens on `127.0.0.1:8787` only. nginx on the yiimp box
terminates TLS on `api.stratum.pool.honest.money` and proxies to it. No
direct internet exposure of Node or MySQL.


## Endpoints (v0.2.0)

All JSON. All GET (plus one SSE stream). The `/api/v1/*` namespace is the stable surface; `/api/*` paths remain as legacy aliases for one release.

Full reference: [`docs/api.md`](../../docs/api.md).

| Path                                        | Notes |
| ------------------------------------------- | ----- |
| `/api/v1/health`                            | `{ok, db, uptime, version}` |
| `/api/v1/coins`                             | Visible coins |
| `/api/v1/coins/:symbol`                     | One coin incl. price / difficulty / network_hash / reward / fees |
| `/api/v1/coins/:symbol/blocks`              | Pool-found blocks for one coin |
| `/api/v1/pool/summary`                      | One-shot dashboard payload (algos, live stratum, last blocks, effort, blocks 24h) |
| `/api/v1/pool/hashrate?window=1h\|24h\|7d\|30d` | Bucketed hashrate series from `hashstats` |
| `/api/v1/pool/effort`                       | Shares since last block ÷ network difficulty |
| `/api/v1/pool/blocks/luck?window=…`         | Actual blocks over window |
| `/api/v1/blocks?coin=&algo=&limit=`         | Recent blocks |
| `/api/v1/mergedmining/summary?window=…`     | Per-round: primary + auxpow chains credited |
| `/api/v1/mergedmining/credits?limit=`       | Flat credit feed tagged `solo` / `auxpow` |
| `/api/v1/miners/count`                      | **Real** active-miner count from stratum diag (not the stale `workers` table) |
| `/api/v1/miners/top?limit=`                 | Leaderboard, addresses truncated |
| `/api/v1/miners/locations`                  | GeoIP country/region rollup — **no IPs ever returned** |
| `/api/v1/miner/:address`                    | Summary |
| `/api/v1/miner/:address/workers`            | Per-worker rows with country/region |
| `/api/v1/miner/:address/hashrate?window=…`  | Per-miner time-series |
| `/api/v1/miner/:address/payouts?limit=`     | Payout history |
| `/api/v1/miner/:address/earnings?limit=`    | Per-block credits |
| `/api/v1/stream` (SSE)                      | `block-found`, `hashrate-tick`, `ping` |
| `/api/v1/openapi.json`                      | OpenAPI 3.1 index for client generation |

### Fixing the miner count

`/api/v1/miners/count` reads the last `SCRYPT summary diag clients=…` line
from each `${STRATUM_LOG_DIR}/${algo}.log`. This is the truth — the yiimp
`workers` MySQL table keeps stale rows for hours after miner disconnects,
which is why every previous number was wrong.

Address validation regex: `/^[A-Za-z0-9]{20,80}$/`. Rejected with 400 before
hitting SQL.

### GeoIP

Server-side lookups via `geoip-lite` (embedded MaxMind Lite DB). The DB
refreshes monthly — add a cron entry on the host:

```
0 3 1 * * cd /opt/yiimp-api && npx geoip-lite-update
```

Raw IPs are never returned in any public response.


## Files

```
infra/yiimp-api/
├── README.md
├── install.sh              # one-shot installer for a fresh yiimp box
├── package.json
├── tsconfig.json
├── src/
│   └── server.ts           # entire service (~350 lines)
├── systemd/
│   └── yiimp-api.service   # systemd unit
├── nginx/
│   └── yiimp-api.conf      # server block for api.stratum.pool.honest.money

└── .env.example            # DB creds — copy to /etc/yiimp-api/env
```

## Install on the yiimp box

```bash
# on your laptop
cd infra/yiimp-api
scp -r . ubuntu@stratum.pool.honest.money:/tmp/yiimp-api/
ssh ubuntu@stratum.pool.honest.money "sudo bash /tmp/yiimp-api/install.sh"
```

`install.sh` does:

1. Installs Node 20 (nvm-free, from NodeSource) and nginx + certbot if
   missing.
2. Copies the source to `/opt/yiimp-api/`, runs `npm ci && npm run build`.
3. Creates `yiimp-api` system user, `/etc/yiimp-api/env` (chmod 600).
4. Installs `systemd/yiimp-api.service`, enables + starts.
    5. Drops `nginx/yiimp-api.conf` in `/etc/nginx/sites-available/`,
    symlinks, and runs `certbot --nginx -d api.stratum.pool.honest.money`.


Idempotent — safe to re-run after edits.

## Configuration

Environment (from `/etc/yiimp-api/env`, read by systemd):

```
YIIMP_API_PORT=8787
YIIMP_API_BIND=127.0.0.1
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_DATABASE=yiimpfrontend
MYSQL_USER=yiimp_ro
MYSQL_PASSWORD=REPLACE_ME
STRATUM_LOG_DIR=/var/stratum         # optional; enables scraping SCRYPT summary diag lines
CORS_ORIGIN=https://pool.honest.money
```

Create a read-only MySQL user first — the service must never be able
to write:

```sql
CREATE USER 'yiimp_ro'@'localhost' IDENTIFIED BY '<strong-password>';
GRANT SELECT ON yiimpfrontend.* TO 'yiimp_ro'@'localhost';
FLUSH PRIVILEGES;
```

## Change management

1. Edit `src/server.ts` in this repo.
2. Commit.
3. Re-run `install.sh` (or just `git pull && npm run build &&
   systemctl restart yiimp-api` on the box).

Never edit the running box's `/opt/yiimp-api/` directly.

## Front-end integration

The Lovable front-end exposes a thin proxy at
`/api/v1/pool/*` that forwards to `https://api.stratum.pool.honest.money`
with CORS and edge caching. See `src/lib/api/yiimp.ts` and
`src/routes/api/v1/pool.*.ts`.

