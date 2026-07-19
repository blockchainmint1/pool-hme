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
        │        │       │       │       │       │
     Cont-1   Cont-2  Cont-3  Cont-4  Cont-5   Cont-6
     ~200 L9s ~200    ~200    ~200    ~200    ~200
```

### Why 6 boxes instead of 1

- **HA by default.** One Beelink down = one container offline. The other
  five keep mining.
- **Conntrack pressure divided by 6.** ~200 sessions/box is trivial for
  an N100; 1200 on one box was what killed the ER605s.
- **Blast radius per container.** An attacker on the landlord's shared
  network cannot reach any L9 — miners are RFC1918 behind 6 separate NATs.
- **Identical script, one flag apart.** `restore.sh --container N`.

## Addressing plan

Each container is its own island behind NAT, so the LAN subnets don't
*have to* be unique. But making them unique means `ssh 10.3.0.10`
unambiguously means "container 3" — no "which 10.0.0.10 am I on?"
mistakes.

| Container | Beelink LAN   | Miner range           |
| --------- | ------------- | --------------------- |
| 1         | 10.1.0.10/24  | 10.1.0.20 – .254      |
| 2         | 10.2.0.10/24  | 10.2.0.20 – .254      |
| 3         | 10.3.0.10/24  | 10.3.0.20 – .254      |
| 4         | 10.4.0.10/24  | 10.4.0.20 – .254      |
| 5         | 10.5.0.10/24  | 10.5.0.20 – .254      |
| 6         | 10.6.0.10/24  | 10.6.0.20 – .254      |

Miners for container N are configured with pool
`stratum+tcp://10.N.0.10:3433`.

### Why an EC2-first build

Operator is in Singapore. Site is in Conroe, TX. We build and burn in on
EC2 (Ubuntu 24.04, `us-east-2`), prove HAProxy works against the real
upstream stratum, then ship **just the config** to fresh Ubuntu installs
on the on-site mini-PCs.

```
laptop (SG) ──ssh──► EC2 t3.small (us-east-2)        burn-in target
                     │
                     │  restore.sh --skip-netplan     (EC2: no dual-NIC, no NAT)
                     ▼
                     Beelink #1..#6 (Conroe, TX)     production
                     │  restore.sh --container N
```

## Files

```
infra/haproxy-conroe/
├── README.md
├── build-on-ec2.sh          # spin up EC2, install haproxy, apply config, tail logs
├── restore.sh               # run on any fresh Ubuntu 24.04 → identical box
├── config/
│   ├── haproxy.cfg          # frontend :3433 → upstream stratum
│   ├── 99-haproxy.yaml      # netplan template: WAN=dhcp, LAN=10.N.0.10/24
│   ├── 99-haproxy.conf      # sysctl: conntrack + keepalives + ephemeral ports
│   ├── 99-forward.conf      # sysctl: net.ipv4.ip_forward=1 (NAT)
│   ├── haproxy.limits.conf  # systemd override: LimitNOFILE=1048576
│   └── kea-dhcp4.conf       # DHCP scope 10.N.0.100-.254 for the container
└── scripts/
    ├── smoke-test.sh        # verify :3433 accepts, upstream reachable
    └── watch-sessions.sh    # live count of miner→proxy and proxy→upstream flows
```

Everything under `config/` is the source of truth. Never hand-edit the
running box — edit here, commit, re-run `restore.sh`.

## What restore.sh does on-site

Invoked as `sudo bash restore.sh --container N` (N = 1..6):

1. Installs `haproxy`, `kea-dhcp4-server`, `iptables-persistent`, tooling.
2. Detects the two NICs — WAN = whichever holds the default route (DHCP
   from landlord), LAN = the other one — and writes a netplan config
   giving LAN a static `10.N.0.10/24`.
3. Enables `ip_forward` and installs `iptables` MASQUERADE for
   `10.N.0.0/24 → WAN`. Persisted via `netfilter-persistent`.
4. Serves DHCP on the LAN NIC: `10.N.0.100 – 10.N.0.254`, gateway
   `10.N.0.10`, DNS `1.1.1.1 / 9.9.9.9`.
5. UFW: WAN side default-deny; LAN side allows SSH + stratum (:3433) +
   stats (:8404) + DHCP (:67). WAN gets no inbound ports at all.
6. Starts HAProxy on `:3433`, backend `stratum.pool.honest.money:3433`.
7. Writes `/opt/haproxy-conroe/CONTAINER` with the container number so
   ops scripts know which island they're on.

The Beelink is the **entire edge for its container**: firewall, NAT,
DHCP server, and stratum proxy in one box.

## Burn-in on EC2

Same as before — EC2 has a single NIC so `restore.sh` is invoked with
`--skip-netplan` (skips dual-NIC, NAT, DHCP; opens :22/:3433/:8404 to
the world for burn-in only). Already validated on EC2 `13.217.211.175`.

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

For each Beelink, on-site:

1. Install Ubuntu Server 24.04 LTS (defaults, OpenSSH enabled, no snaps).
   Label the Beelink with its container number (1–6).
2. Plug **WAN NIC** into the SG2218 (landlord uplink). Plug **LAN NIC**
   into the container's miner switch.
3. Boot. The WAN NIC pulls a DHCP lease from the landlord and the box
   has internet. Log in at the console (keyboard + monitor, or the
   Beelink's HDMI) and run **one line**:

   ```bash
   curl -fsSL https://pool.honest.money/install/haproxy-conroe.sh \
     | sudo bash -s -- --container N
   ```

   Replace `N` with this Beelink's container number (1–6). The installer
   bundles the config from this repo, runs `restore.sh`, and prints the
   Beelink's LAN IP + smoke-test commands when it's done.

   No scp, no laptop-on-site, no landlord DHCP lease lookup required.
   The Beelink pulls everything from `pool.honest.money` over its WAN.

4. After it finishes, ssh to the Beelink from inside the container at
   its LAN IP:

   ```bash
   ssh ubuntu@10.1.0.10        # container 1
   ssh ubuntu@10.6.0.10        # container 6
   ```

5. Power on the container's L9s. They'll DHCP from the Beelink into
   `10.N.0.20+`. Configure their pool as
   `stratum+tcp://10.N.0.10:3433`.

Same one-liner per Beelink, only `--container N` changes. No hand-editing.



### Remote admin from your laptop

Without Tailscale, ssh from your laptop to a Beelink only works when
you're on a network that can route to it — physically on-site, or via
the landlord CPE's WAN IP if the CPE forwards a port to that Beelink.
Two practical options:

- **On-site laptop plugged into any miner switch** — you're on
  `10.N.0.0/24` and `ssh ubuntu@10.N.0.10` works directly.
- **Landlord CPE port forward** to one Beelink (say container 1). SSH
  to that one over the public IP, then from container-1's Beelink
  `ssh ubuntu@10.2.0.10` etc. — but only if the containers share a
  routable mgmt path (they don't today; each Beelink's WAN is a
  separate NAT hop). Simplest is: forward a different public port to
  each Beelink's WAN IP.

If remote admin becomes painful, revisit Tailscale later — one command
per box, `sudo tailscale up`, and you're done. Not required today.

## Rollback

HAProxy is a sidecar per container, not a shared resource:

- One Beelink down → point that container's miners at
  `stratum.pool.honest.money:3433` directly (or swap the Beelink out
  with a spare configured for the same container number). Other 5
  containers unaffected.
- All 6 down → back to the double-NAT problem (miners direct to
  upstream through landlord CPE), not offline.

## Frontend

The mining frontend / dashboard lives at `pool.honest.money`. These
boxes only proxy stratum traffic; they don't serve the web frontend.

## Change management

Same rules as `infra/stratum-stack/`:

1. Edit files under `config/` in this repo.
2. Commit.
3. Re-run `restore.sh --container N` against every Beelink (idempotent).
4. Never `sed` on a live box.
