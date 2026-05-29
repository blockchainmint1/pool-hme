# TXC self-hosted mempool stack

Everything this explorer needs to stop depending on `mempool.texitcoin.org`.
Spin this up on a VPS, point the frontend at it, done.

## What runs

| Service       | Image / source                                  | Purpose                                   | Port |
|---------------|--------------------------------------------------|-------------------------------------------|------|
| `texitcoind`  | built from https://github.com/texitcoin/texitcoin| Full TXC node (the source of truth)       | 8332 (RPC, internal only) |
| `electrs`     | `getumbrel/electrs` (works for any Bitcoin-fork)| Address/tx index over the node            | 50001 (internal) |
| `mempool-api` | `mempool/backend:latest`                         | mempool.space backend — REST + WS         | 8999 (internal) |
| `mempool-db`  | `mariadb:11`                                     | mempool backend's stats DB                | internal |
| `nginx`       | `nginx:alpine`                                   | TLS termination + `/api` + `/api/v1/ws`   | 80 / 443 |

The frontend (this Lovable project) talks to **nginx only**, on the same
hostnames the upstream uses (`/api`, `/api/v1/ws`). Switching is one
constant: `TXC_API_BASE` in `src/lib/txc/network.ts`.

## Hardware

Minimum: 4 vCPU, 8 GB RAM, 200 GB NVMe SSD. The chain is small but electrs
likes RAM during initial sync. Hetzner CCX13 / DO 4 GB / Vultr HF work fine.

## Quick start

```bash
# On a fresh Ubuntu 22.04 / 24.04 box, as root or with sudo:
git clone <this repo> && cd infra/txc-stack
cp .env.example .env
# Edit .env — at minimum set DOMAIN and RPC_PASSWORD
./scripts/bootstrap.sh        # installs docker, opens firewall, certbot
docker compose up -d          # builds texitcoind, starts the stack
./scripts/wait-for-sync.sh    # tails logs until node is in sync
```

Initial block download is ~30–60 min on a decent box (TXC chain is small).
Electrs indexing adds another 30–60 min after the node is synced. The
mempool backend is usable as soon as electrs finishes indexing — check
`https://your.domain/api/blocks/tip/height`.

## Pointing the frontend at your stack

In `src/lib/txc/network.ts`:

```ts
export const TXC_API_BASE      = "https://your.domain/api";
export const TXC_WS_URL        = "wss://your.domain/api/v1/ws";
export const TXC_EXPLORER_BASE = "https://your.domain";
```

That's it. No other code changes — the explorer was built against the
mempool.space API shape, which `mempool/backend` serves natively.

## Files in this directory

```
docker-compose.yml         # the whole stack
.env.example               # config — copy to .env and edit
texitcoind/Dockerfile      # builds texitcoind from source
texitcoind/texitcoin.conf  # node config (RPC on, txindex on)
electrs/electrs.toml       # electrs config for TXC
mempool/mempool-config.json# mempool/backend config
nginx/nginx.conf           # reverse proxy w/ TLS + WS upgrade
scripts/bootstrap.sh       # one-shot host setup
scripts/wait-for-sync.sh   # polls until the node is caught up
scripts/backup.sh          # dumps chainstate + mempool DB to /var/backups
```

## Operating notes

- **Logs**: `docker compose logs -f mempool-api` is where you'll spend most
  of your time. `texitcoind` writes to `./data/texitcoin/debug.log`.
- **Upgrading texitcoind**: bump the git ref in `texitcoind/Dockerfile`,
  `docker compose build texitcoind && docker compose up -d texitcoind`.
- **Backups**: chainstate can be re-synced; what's irreplaceable is
  `wallet.dat` (if you ever enable a wallet) and the mempool MariaDB
  (historical stats). `scripts/backup.sh` handles the DB.
- **Monitoring**: nginx access log + a simple uptime check on
  `/api/blocks/tip/height` returning a number is 95% of what you need.

## Why nginx and not Caddy?

Either works. Nginx is here because mempool.space's reference deployment
uses it and the WS upgrade headers are copy-paste from their docs. If you
prefer Caddy, swap the `nginx` service for `caddy:2` and use a 6-line
Caddyfile — the rest of the stack is identical.
