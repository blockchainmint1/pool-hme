# haproxy-conroe

On-site stratum proxy for the Conroe, TX site. Terminates ~1000 miner TCP
sessions on the LAN so the landlord's ISP CPE only sees a handful of
long-lived upstream flows. See `docs/infrastructure.md` §9 for the
incident that made this necessary.

## Why an EC2-first build

Operator is in Singapore. Site is in Conroe, TX. We build and burn in on
EC2 (Ubuntu 24.04, `us-east-2`), prove HAProxy works against the real
upstream stratum, then ship **just the config** to a fresh Ubuntu install
on the on-site mini-PC. No AMI export, no USB-of-a-disk-image, no cross-
region snapshot dance. The box is disposable — the config is not.

```
laptop (SG)  ──ssh──►  EC2 t3.small (us-east-2)          burn-in target
                       │
                       │  restore.sh                     (same script)
                       ▼
                       Beelink N100 (Conroe, TX)         production
```

## Files

```
infra/haproxy-conroe/
├── README.md
├── build-on-ec2.sh          # spin up EC2, install haproxy, apply config, tail logs
├── restore.sh               # run on any fresh Ubuntu 24.04 → identical box
├── config/
│   ├── haproxy.cfg          # frontend :3433 → upstream stratum
│   ├── 99-haproxy.yaml      # netplan: static 10.0.0.10/24
│   ├── 99-haproxy.conf      # sysctl: conntrack + keepalives + ephemeral ports
│   └── haproxy.limits.conf  # systemd override: LimitNOFILE=1048576
└── scripts/
    ├── smoke-test.sh        # verify :3433 accepts, upstream reachable
    └── watch-sessions.sh    # live count of miner→proxy and proxy→upstream flows
```

Everything under `config/` is the source of truth. Never hand-edit the
running box — edit here, commit, re-run `restore.sh`.

## Burn-in on EC2

```bash
# from your laptop
cd infra/haproxy-conroe

# one-time: aws configure  (us-east-2, key with EC2 permissions)
./build-on-ec2.sh
# → prints the EC2 public IP and SSH command
# → HAProxy is already running, pointed at the real upstream stratum
```

Point **one** test miner (not all 1200) at the EC2 public IP on :3433 for
30 minutes. Watch:

```bash
ssh ubuntu@<ec2-ip> 'sudo tail -f /var/log/haproxy.log'
ssh ubuntu@<ec2-ip> 'sudo /opt/haproxy-conroe/watch-sessions.sh'
```

You should see the miner establish, submit shares, and Yiimp credit them
to the normal wallet. If that works, the config is good — the on-site
box will behave the same because it's the same script.

Tear down when done:

```bash
./build-on-ec2.sh --destroy
```

## Restore onto the on-site mini-PC

Hand this to whoever is at the Conroe site:

1. Install Ubuntu Server 24.04 LTS on the Beelink N100 (defaults, enable
   OpenSSH, no snaps).
2. Plug it into the SG2218 on any access port.
3. From your laptop:

   ```bash
   scp -r infra/haproxy-conroe ubuntu@<box-lan-ip>:/tmp/
   ssh ubuntu@<box-lan-ip> 'sudo bash /tmp/haproxy-conroe/restore.sh'
   ```

That's it. Same config as the EC2 burn-in box, no drift.

## Rollback

HAProxy is a sidecar, not a shared resource. If it dies, flip miners
back to `stratum.pool.honest.money:3433` and the fleet keeps mining —
you're just back to the double-NAT problem, not offline.

## Frontend

The mining frontend / dashboard lives at `pool.honest.money`. This box
only proxies stratum traffic; it does not serve the web frontend.

## Change management

Same rules as `infra/stratum-stack/`:

1. Edit files under `config/` in this repo.
2. Commit.
3. Re-run `restore.sh` against the box (idempotent).
4. Never `sed` on the live box.
