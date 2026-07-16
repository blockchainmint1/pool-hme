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
   yiimp-api.pool.honest.money      (this service, nginx TLS in front)
           │
           │  mysql localhost:3306
           ▼
   yiimpfrontend  DB on stratum.pool.honest.money
```

The service listens on `127.0.0.1:8787` only. nginx on the yiimp box
terminates TLS on `yiimp-api.pool.honest.money` and proxies to it. No
direct internet exposure of Node or MySQL.

## Endpoints

All JSON. All GET. All cached at the edge for 5–30s depending on
volatility.

| Path                                 | Cache | Notes |
| ------------------------------------ | ----- | ----- |
| `/api/health`                        | 0s    | `{ok:true, db:true, uptime}` |
| `/api/pool/stats`                    | 10s   | Per-algo: hashrate, workers, miners, last_block, network_diff |
| `/api/pool/algos`                    | 60s   | Active algos + upstream ports |
| `/api/coins`                         | 60s   | Coins yiimp knows about, `enabled`, `visible` |
| `/api/blocks?coin=&algo=&limit=`     | 15s   | Recent blocks. `coin=` matches `symbol` (LTC/DOGE/TXC/ISK/ZCU). Default limit 50, max 500. |
| `/api/miner/:address`                | 5s    | Address summary: hashrate, workers online, pending balance, total paid, last share |
| `/api/miner/:address/workers`        | 5s    | One row per worker: name, hashrate, last_share, diff, valid/invalid shares |
| `/api/miner/:address/payouts?limit=` | 30s   | Payout history rows. Default 50, max 500. |
| `/api/miner/:address/earnings?limit=`| 30s   | Per-block credits — matched-block share of reward. |

Address validation regex: `/^[A-Za-z0-9]{20,80}$/`. Rejects anything
else with 400 before hitting SQL.

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
│   └── yiimp-api.conf      # server block for yiimp-api.pool.honest.money
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
   symlinks, and runs `certbot --nginx -d yiimp-api.pool.honest.money`.

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
`/api/v1/pool/*` that forwards to `https://yiimp-api.pool.honest.money`
with CORS and edge caching. See `src/lib/api/yiimp.ts` and
`src/routes/api/v1/pool.*.ts`.
