# stratum-stack

Ansible-managed deployment of the yiimp-style stratum server that fronts the
Iskandercoin / TEXITcoin merge-mine pool (`pool2.iskandercoin.com`).

This directory is the source of truth for:

- `stratum` binary build (from source, per algo)
- Per-algo config files (`scrypt.conf`, `pawelhash.conf`, ...) with all the
  vardiff / TTF / lock-contention tuning baked in
- systemd unit files + drop-in overrides (`LimitNOFILE=1048576`, etc.)
- Ops scripts (health check, vardiff report, share-rate audit)

## What lives where

```
infra/stratum-stack/
├── README.md
├── .env.example               # non-secret vars (host, ports)
├── .gitignore                 # blocks vault.yml, .env, *.bak
├── ansible/
│   ├── inventory.example.ini  # copy → inventory.ini and fill in
│   ├── playbook.yml           # top-level: build + deploy + restart
│   ├── group_vars/
│   │   ├── all.example.yml    # copy → all.yml (non-secret)
│   │   └── vault.example.yml  # copy → vault.yml, encrypt with ansible-vault
│   └── roles/stratum/
│       ├── defaults/main.yml
│       ├── tasks/
│       │   ├── main.yml
│       │   ├── build.yml      # clones + compiles the stratum source
│       │   ├── config.yml     # renders *.conf from templates
│       │   └── systemd.yml    # installs .service + override.conf
│       └── templates/
│           ├── scrypt.conf.j2
│           ├── pawelhash.conf.j2
│           ├── stratum-aws.service.j2
│           └── override.conf.j2
└── scripts/
    ├── health-check.sh
    ├── vardiff-report.sh
    └── share-audit.sh
```

## First-time setup

```bash
cd infra/stratum-stack
cp .env.example .env
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
cp ansible/group_vars/vault.example.yml ansible/group_vars/vault.yml

# put real passwords in vault.yml, then encrypt:
ansible-vault encrypt ansible/group_vars/vault.yml

# edit inventory.ini with your EC2 host + ssh user
```

## Deploy

```bash
# full deploy (build + configs + systemd + restart)
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --ask-vault-pass

# configs only (skip rebuild) — the common case for a tuning change
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml \
  --tags config,systemd --ask-vault-pass

# dry run
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --check --diff
```

Changing a value in `group_vars/all.yml` (e.g. `scrypt_diff_max: 16777216`) and
re-running with `--tags config,systemd` is the sanctioned way to make tuning
changes — never `sed` on the box directly. The box's live `/var/stratum/config/`
is authoritative *only until the next playbook run*.

## Ops scripts

Run against the box over SSH:

```bash
./scripts/health-check.sh    ubuntu@pool2.iskandercoin.com
./scripts/vardiff-report.sh  ubuntu@pool2.iskandercoin.com
./scripts/share-audit.sh     ubuntu@pool2.iskandercoin.com scrypt
```

## Tuning decisions captured here

| Setting | Value | Why |
|---|---|---|
| `difficulty` (start) | 0.25 | Legacy default, vardiff ramps from here |
| `diff_min` | 65536 | Was 15000 — caused 82% futex contention w/ 1200 L9s |
| `diff_max` | 16777216 | Was 4194304 — 30% of L9s were pegged at ceiling |
| `max_ttf` | 40000 | ~40s target time-to-find per share (observed ~65s on L9s at avg 1.7M diff — vardiff behaving correctly) |
| `LimitNOFILE` | 1048576 | Default 1024 exhausted at ~900 connections |

Change history lives in git; do not edit these values on the box.
