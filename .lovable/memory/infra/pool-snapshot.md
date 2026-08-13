---
name: Pool snapshot / rollback tool
description: pool-snapshot.sh SAVE/LIST/VERIFY/RESTORE — full pre-maintenance snapshot of /var/stratum binaries+configs, systemd units, crontabs, wallet config, and a mysqldump; one-command file rollback.
type: feature
---
`infra/pool-doctor/pool-snapshot.sh` (published to `/install/pool-snapshot.sh`).

Always run `SAVE` then `VERIFY` before any stratum binary swap or config change.

- `SAVE` — writes `/var/backups/pool-snapshots/<ts>/`: `/var/stratum` binaries
  (incl. every `stratum.bak.*`) + `*.conf` + adapter `.py`, systemd units and
  enable-state, root/ubuntu crontabs + `/etc/cron.d`, `/etc/pool-wallets`,
  yiimp `keys.php`/`serverconfig.php`, full gzip `mysqldump` of `yiimpfrontend`
  plus a coins/settings-only dump, a `MANIFEST.txt` of "before" numbers
  (binary sha256 + ZCU strings counts, service NRestarts, port 3433/3533
  socket counts, coins table, latest block per coin), and `SHA256SUMS`.
  Excludes logs. Never stops or restarts anything — safe with miners connected.
- `VERIFY [dir]` — checksum-verifies, gzip-tests the dumps, prints the manifest.
- `RESTORE [dir] [--restart]` — copies current files to `pre-restore-<ts>/`
  inside the snapshot first (restore is itself reversible), then restores.
  Restart only with `--restart`.
- DB is deliberately NOT auto-restored: rolling it back erases shares/earnings/
  payouts since the snapshot. It prints the `zcat | mysql` command instead.

Rule: a `BUILD`-mode doctor script (e.g. zcu-forwardport BUILD) touches nothing
live — it only compiles in `/root/<scratch>`. The risk is the later
`install -m755 ... /var/stratum/stratum` + `systemctl restart`. Snapshot before
that step, and also take an EBS/AMI snapshot for true off-box recovery.
