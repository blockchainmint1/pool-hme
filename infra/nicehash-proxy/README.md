# nicehash-proxy

Stratum shim on port **3533** that fronts the real scrypt stratum on
**3433** so rental services (NiceHash, MiningRigRentals) pass pool
verification. The live pool config is never touched.

## The two failures it fixes

Measured against `stratum.pool.honest.money:3433`:

| symptom | cause | fix |
|---|---|---|
| `Pool difficulty too low (provided=16, minimum=50000)` | the **subscribe reply** advertises `["mining.set_difficulty","16"]`; NiceHash parses that string and ignores the later `set_difficulty` notification | proxy rewrites it to `MIN_DIFF` |
| `Unknown message` / timeout | first real `mining.notify` lands 6–11s after connect | proxy replies with `set_difficulty` + a cached job in ~0.3s |

It also appends `d=65536` to any authorize password that doesn't already
set a difficulty, and raises any upstream `set_difficulty` below `MIN_DIFF`
(raising is safe — a share meeting a harder target also meets the easier
one the pool validates against).

The cached job comes from one persistent "sentinel" upstream connection.
`mining.notify` carries no extranonce1 and yiimp job ids are pool-global,
so a sentinel job is valid work for any connection; the client's own job
supersedes it within seconds.

## Deploy

```bash
bash infra/nicehash-proxy/build-bundle.sh   # regenerate the installer
# publish the site, then on the stratum host:
curl -fsSL https://pool.honest.money/install/nicehash-proxy.sh | sudo bash
```

Then open **TCP 3533** in the AWS security group (and `ufw` if enabled).

## Rental service settings

```
Host: stratum.pool.honest.money:3533
User: ltc1qfvefpfgmznsvzwkczk47hq2mt5d07qwqyh05de.nh
Pass: x
Algo: Scrypt
```

## Ops

```bash
systemctl status nicehash-proxy
journalctl -u nicehash-proxy -f
ss -tn '( sport = :3533 )' | wc -l     # rental sessions
```

Tune `MIN_DIFF` in `/etc/nicehash-proxy/env` and restart if you rent more
than a few TH/s.
