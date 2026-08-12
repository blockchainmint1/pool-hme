# nicehash-watcher

Auto-purchases NiceHash scrypt hashpower to keep the pool's hashrate at its
7-day average (floor 19 TH/s) — "at any cost." When the live scrypt hashrate
drops below **75%** of the target, it rents, bidding top-of-market + 10%, and
refills orders until the pool fully recovers, then cancels (refunding unused
budget).

## Strategy (live)

- **Target** = `max(7-day average, 19 TH/s)` — refreshes every 15 min.
- **Trigger** = actual < `0.75 × target` opens the first order.
- **Maintain** = existing orders are refilled/kept until `actual ≥ target` for 3
  consecutive cycles, then all orders are cancelled (unused BTC refunded).
- **Bid** = `max(top-of-market × 1.10, 0.0088)`, capped at `0.05` BTC/TH/day.
- **Cap** = up to 2 concurrent orders, each limited to the deficit (≤19 TH/s).
  `DAILY_BTC_CAP=0` disables the hard spend guard (honours "at any cost"); set
  a number to enforce an emergency ceiling.

Cost reference: at ~0.0088 BTC/TH/day, holding 19 TH/s costs ~0.17 BTC/day.

## Files

- `src/nicehash-api.cjs` — NiceHash API v2 client (null-byte HMAC-SHA256 auth).
- `src/pool-api.cjs` — reads `/api/v1/pool/summary` + `/api/v1/pool/hashrate?window=7d`.
- `src/watcher.cjs` — main state machine + state file.
- `build-bundle.sh` — packs to a single `bundle.cjs` and publishes to `public/install/`.
- `install.sh` — systemd installer (env file + unit).

## Deploy

```bash
# 1. publish bundle (run from dev-server)
bash infra/nicehash-watcher/build-bundle.sh

# 2. on the stratum box (ubuntu@stratum.pool.honest.money)
curl -fsSL https://pool.honest.money/install/nicehash-watcher.sh | sudo bash

# 3. add credentials (https://www.nicehash.com/my/api/v2)
sudo nano /etc/nicehash-watcher.env   # fill the 4 REQUIRED values
sudo systemctl restart nicehash-watcher
sudo journalctl -u nicehash-watcher -f
```

## Verifying without spending

Set `DRY_RUN=true` in `/etc/nicehash-watcher.env` and restart. The watcher logs
every decision ("would POST …", "would refill …") without spending. The live
test showed correct signing — NiceHash accepted the request and only rejected
on a fake orgId, confirming the auth chain works.

## State

`/var/lib/nicehash-watcher/state.json` tracks active order ids, daily spend,
the computed target, and recovery confirmations. Safe to delete to reset.
