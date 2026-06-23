# TXC self-hosted mempool stack

Everything this explorer needs to run on its own infrastructure — node,
address indexer, mempool backend, TLS — with no third-party dependencies in
the data path. Spin this up on a VPS, point the frontend at it, done.

## What runs

| Service       | Image / source                                  | Purpose                                   | Port |
|---------------|--------------------------------------------------|-------------------------------------------|------|
| `texitcoind`  | host install (node-spinner)                      | Full TXC node — source of truth           | 8332 (RPC, internal only) |
| `indexer`     | `./indexer/` (custom, TypeScript)                | Esplora-compatible address index over RPC | 3001 (internal) |
| `mempool-api` | `mempool/backend:latest` (MEMPOOL_BACKEND=none)  | mempool.space REST + WS (everything except address) | 8999 (internal) |
| `mempool-db`  | `mariadb:11`                                     | mempool backend's stats DB                | internal |
| `nginx`       | `nginx:alpine`                                   | TLS termination + `/api` routing          | 80 / 443 |

There is **no electrs** in this stack — we replaced it with our own
`txc-indexer` (see `./indexer/README.md`) because stock electrs doesn't
support TXC's network parameters. Nginx routes `/api/address/*` straight to
the indexer and everything else to `mempool-api`.

The frontend (this Lovable project) talks to **nginx only**, at the same
domain (`/api`, `/api/v1/ws`). It's a single constant to switch:
`TXC_API_BASE` in `src/lib/txc/network.ts`.

## Hardware

Minimum: 4 vCPU, 8 GB RAM, 200 GB NVMe SSD. The chain itself is small;
RAM matters during initial sync + indexer warmup. Hetzner CCX13 / DO 4 GB /
Vultr HF work fine.

## Quick start

```bash
# On a fresh Ubuntu 22.04 / 24.04 box, as root or with sudo.
git clone https://github.com/YOUR_USER/YOUR_REPO.git
cd YOUR_REPO/infra/txc-stack

cp .env.example .env
nano .env                      # set DOMAIN, LETSENCRYPT_EMAIL, RPC_PASSWORD, MYSQL_*
sudo ./scripts/bootstrap.sh    # installs docker, opens firewall, issues TLS cert
docker compose up -d --build   # starts the stack (builds indexer image)
./scripts/wait-for-sync.sh     # polls until node + indexer + mempool are up
```

Don't have the repo on GitHub? Just copy the folder up directly:

```bash
# from your laptop, in the project root:
scp -r infra/txc-stack root@your-vps:/opt/txc-stack
ssh root@your-vps
cd /opt/txc-stack
# ...then continue from `cp .env.example .env` above
```

Initial block download is ~30–60 min on a decent box (TXC chain is small).
The custom indexer walks from genesis on first start and is usable once
its `/address/_status` reports a tip — usually finishes well before the
node does on a fresh sync.

## Pointing the frontend at your stack

In `src/lib/txc/network.ts`:

```ts
export const TXC_API_BASE      = "https://your.domain/api";
export const TXC_WS_URL        = "wss://your.domain/api/v1/ws";
export const TXC_EXPLORER_BASE = "https://your.domain";
```

That's it. No other code changes — the explorer was built against the
mempool.space API shape, which `mempool/backend` serves natively, and the
custom indexer serves the Esplora address routes mempool/backend skips when
`MEMPOOL_BACKEND=none`.

## Files in this directory

```
docker-compose.yml         # the whole stack
.env.example               # config — copy to .env and edit
indexer/                   # custom Esplora-compatible address indexer
texitcoind/Dockerfile      # optional dockerized node (host install is preferred)
texitcoind/texitcoin.conf  # node config (RPC on, txindex on)
nginx/nginx.conf           # reverse proxy w/ TLS + WS upgrade
scripts/bootstrap.sh       # one-shot host setup
scripts/wait-for-sync.sh   # polls until the node + indexer are caught up
scripts/backup.sh          # dumps chainstate + mempool DB to /var/backups
```

## Operating notes

- **Logs**: `docker compose logs -f mempool-api indexer` is where you'll
  spend most of your time. `texitcoind` writes to
  `./data/texitcoin/debug.log`.
- **Upgrading texitcoind**: handled by `node-spinner` on the host.
- **Backups**: chainstate can be re-synced; what's irreplaceable is
  `wallet.dat` (if you ever enable a wallet), the mempool MariaDB
  (historical stats), and the indexer SQLite at
  `./data/indexer/indexer.sqlite`. `scripts/backup.sh` handles the DB.
- **Monitoring**: nginx access log + a simple uptime check on
  `/api/blocks/tip/height` returning a number, and `/api/address/_status`
  returning `{ok:true}`, covers 95% of what you need.

## Why nginx and not Caddy?

Either works. Nginx is here because mempool.space's reference deployment
uses it and the WS upgrade headers are copy-paste from their docs. If you
prefer Caddy, swap the `nginx` service for `caddy:2` and use a short
Caddyfile — the rest of the stack is identical.
