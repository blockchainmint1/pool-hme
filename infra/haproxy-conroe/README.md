# haproxy-conroe

On-site stratum proxy for the Conroe, TX site. Terminates ~200 miner TCP
sessions per container on a local Beelink so the landlord's ISP CPE only
sees a handful of long-lived upstream flows. See `docs/infrastructure.md`
§9 for the incident that made this necessary.

## Topology: one Beelink per container

The site has 6 containers × ~200 Antminer L9s each. Rather than one
central edge box carrying 1200 sessions (a single point of failure), we
run **an identical Beelink in every container** — each one is its own
NAT + DHCP + HAProxy island.

```
              Landlord CPE
                        │
                     SG2218           (dumb L2 uplink to the internet)
                        │
        ┌────────┬──────┼──────┬────────┬────────┐
    Beelink-1  BL-2   BL-3   BL-4    BL-5    BL-6     (WAN: DHCP from landlord)
    (each: WAN NIC + LAN 10.0.0.10/24)                (LAN: 10.0.0.10/24)
        │        │       │       │       │       │
     Cont-1   Cont-2  Cont-3  Cont-4  Cont-5   Cont-6
     ~200 L9s ~200    ~200    ~200    ~200    ~200
```

**Every container uses the same LAN subnet `10.0.0.0/24`.** The subnets
are physically separated and hidden behind NAT, so they don't collide.
Admin access is by Tailscale hostname (`beelink-c1` … `beelink-c6`), not
LAN IP.

### Why 6 boxes instead of 1

- **HA by default.** One Beelink down = one container offline. The other
  five keep mining.
- **Conntrack pressure divided by 6.** ~200 sessions/box is trivial for
  an N100; 1200 on one box was what killed the ER605s.
- **Blast radius per container.** An attacker on the landlord's shared
  network cannot reach any L9 — miners are RFC1918 behind 6 separate NATs.
- **Identical config across all 6.** Same `restore.sh`, no snowflakes.

### Why an EC2-first build

Operator is in Singapore. Site is in Conroe, TX. We build and burn in on
EC2 (Ubuntu 24.04, `us-east-2`), prove HAProxy works against the real
upstream stratum, then ship **just the config** to fresh Ubuntu installs
on the on-site mini-PCs.

```
laptop (SG) ──ssh──► EC2 t3.small (us-east-2)        burn-in target
                     │
                     │  restore.sh --skip-netplan    (EC2: no dual-NIC, no NAT)
                     ▼
                     Beelink #1..#6 (Conroe, TX)     production
                     │  restore.sh --with-tailscale
```

## Files

```
infra/haproxy-conroe/
├── README.md
├── build-on-ec2.sh          # spin up EC2, install haproxy, apply config, tail logs
├── restore.sh               # run on any fresh Ubuntu 24.04 → identical box
├── config/
│   ├── haproxy.cfg          # frontend :3433 → upstream stratum
│   ├── 99-haproxy.yaml      # netplan template: WAN=dhcp, LAN=10.0.0.10/24
│   ├── 99-haproxy.conf      # sysctl: conntrack + keepalives + ephemeral ports
│   ├── 99-forward.conf      # sysctl: net.ipv4.ip_forward=1 (NAT)
│   ├── haproxy.limits.conf  # systemd override: LimitNOFILE=1048576
│   └── kea-dhcp4.conf       # DHCP scope 10.0.0.100-.254 for the container
└── scripts/
    ├── smoke-test.sh        # verify :3433 accepts, upstream reachable
    └── watch-sessions.sh    # live count of miner→proxy and proxy→upstream flows
```

Everything under `config/` is the source of truth. Never hand-edit the
running box — edit here, commit, re-run `restore.sh`.

## What restore.sh does on-site

1. Installs `haproxy`, `kea-dhcp4-server`, `iptables-persistent`, tooling.
2. Detects the two NICs — WAN = whichever holds the default route (DHCP
   from landlord), LAN = the other one — and writes a netplan config
   giving LAN a static `10.0.0.10/24`.
3. Enables `ip_forward` and installs `iptables` MASQUERADE for
   `10.0.0.0/24 → WAN`. Persisted via `netfilter-persistent`.
4. Serves DHCP on the LAN NIC: `10.0.0.100 – 10.0.0.254`, gateway
   `10.0.0.10`, DNS `1.1.1.1 / 9.9.9.9`.
5. UFW: WAN side default-deny; LAN side allows SSH + stratum (:3433) +
   stats (:8404) + DHCP (:67). Tailscale interface allowed for SSH.
6. Starts HAProxy on `:3433`, backend `stratum.pool.honest.money:3433`.

The Beelink is the **entire edge for its container**: firewall, NAT,
DHCP server, and stratum proxy in one box.

## Burn-in on EC2

Same as before — EC2 has a single NIC so `restore.sh` is invoked with
`--skip-netplan` (skips dual-NIC, NAT, DHCP; opens :22/:3433/:8404 to
the world for burn-in only).

### Prerequisites

```bash
# AWS CLI configured for us-east-2
aws configure

# EC2 Instance Connect CLI (for easy reconnect)
# macOS:   brew install ec2-instance-connect-cli
# Ubuntu:  sudo apt install ec2-instance-connect-cli
```

Required IAM permissions: `ec2:RunInstances`, `ec2:DescribeImages`,
`ec2:DescribeSecurityGroups`, `ec2:CreateSecurityGroup`,
`ec2:AuthorizeSecurityGroupIngress`, `ec2:DescribeInstances`,
`ec2:TerminateInstances`, `ec2-instance-connect:SendSSHPublicKey`.

### Spin it up

```bash
cd infra/haproxy-conroe
./build-on-ec2.sh
# → prints the EC2 public IP and SSH command
# → HAProxy is running against the real upstream stratum
```

Point **one** test miner at the EC2 public IP on :3433 for 30 minutes.
Watch:

```bash
mssh ubuntu@<instance-id> --region us-east-2 --command 'sudo tail -f /var/log/haproxy.log'
mssh ubuntu@<instance-id> --region us-east-2 --command 'sudo /opt/haproxy-conroe/watch-sessions.sh'
```

Tear down:

```bash
./build-on-ec2.sh --destroy
```

## Deploy to one container

For each of the 6 Beelinks:

1. Install Ubuntu Server 24.04 LTS (defaults, OpenSSH enabled, no snaps).
2. Plug **WAN NIC** into the SG2218 (landlord uplink). Plug **LAN NIC**
   into the container's miner switch.
3. On first boot the WAN NIC will get an internet lease from the
   landlord. Find its temporary IP on the landlord subnet (label the
   Beelink's MAC ahead of time so you can identify it on the CPE lease
   table), then:

   ```bash
   scp -r infra/haproxy-conroe ubuntu@<wan-ip>:/tmp/
   ssh ubuntu@<wan-ip> 'sudo bash /tmp/haproxy-conroe/restore.sh --with-tailscale'
   ssh ubuntu@<wan-ip> 'sudo tailscale up --ssh --hostname=beelink-cN'
   # visit the URL tailscaled prints, approve the node
   ```

4. From then on, ssh in over Tailscale:

   ```bash
   ssh ubuntu@beelink-c1
   ```

5. Power on the container's L9s. They'll DHCP from the Beelink into
   `10.0.0.100+`, and their existing pool config (`stratum+tcp://10.0.0.10:3433`)
   points at the local Beelink.

Same script, run 6 times. No per-container variables.

## Rollback

HAProxy is a sidecar per container, not a shared resource:

- One Beelink down → point that container's miners at
  `stratum.pool.honest.money:3433` directly (or swap the Beelink out
  with a spare). Other 5 containers unaffected.
- All 6 down → back to the double-NAT problem (miners direct to
  upstream through landlord CPE), not offline.

## Frontend

The mining frontend / dashboard lives at `pool.honest.money`. These
boxes only proxy stratum traffic; they don't serve the web frontend.

## Change management

Same rules as `infra/stratum-stack/`:

1. Edit files under `config/` in this repo.
2. Commit.
3. Re-run `restore.sh` against every Beelink (idempotent). A single
   Ansible loop over `beelink-c1..c6` handles the fan-out.
4. Never `sed` on a live box.
