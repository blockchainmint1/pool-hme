#!/usr/bin/env bash
# pool-snapshot.sh -- take a complete, restorable snapshot of the pool's
# mutable state BEFORE any maintenance window, and restore it in one command.
#
#   curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | sudo bash -s SAVE
#   curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | sudo bash -s LIST
#   curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | sudo bash -s VERIFY <dir>
#   curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | sudo bash -s RESTORE <dir>
#
# WHAT IT CAPTURES
#   1. /var/stratum        binaries (stratum + every stratum.bak.*), *.conf,
#                          adapter python, run scripts.  NOT the logs.
#   2. systemd             unit files for stratum-aws-scrypt, yiimp-api,
#                          zcu-* , nicehash-*, plus `systemctl is-enabled`.
#   3. crontabs            root + ubuntu + /etc/cron.d.
#   4. wallet config       /etc/pool-wallets/*  (mode-preserved, root-only).
#   5. yiimp web config    keys.php / serverconfig.php if present.
#   6. MySQL               FULL mysqldump of `yiimpfrontend` (schema+data),
#                          plus a separate small dump of just the config-ish
#                          tables (coins, settings) for fast surgical restore.
#   7. state manifest      running binary sha256 + mtime, coins table snapshot,
#                          miner/socket count, latest block per coin, service
#                          NRestarts -- the "before" numbers to compare against.
#
# WHAT RESTORE DOES
#   Files: restored in place, with the CURRENT files first copied aside to
#   <dir>/pre-restore/ so even the restore is reversible.
#   Service: restarted ONLY if you pass RESTORE ... --restart.
#   Database: NOT auto-restored. It prints the exact mysql command, because
#   rolling the DB back also rolls back real earnings/payout rows since the
#   snapshot. You almost never want that -- binaries are the thing to revert.
#
# SAFETY
#   SAVE and VERIFY change nothing. SAVE never stops or restarts a service, so
#   it is safe to run right now with 1700 miners connected.
#
# VERSION LOG -- bump on every change, newest first.
#   v1  2026-08-13  First cut, ahead of the ZCU binary swap.
SNAP_VERSION="v1"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-SAVE}"
ARG2="${2:-}"
ROOT=/var/backups/pool-snapshots
hr(){ printf '\n=== %s ===\n' "$*"; }
ok(){ echo "   OK   $*"; }
warn(){ echo "   WARN $*"; }
bad(){ echo "   FAIL $*"; }

echo "pool-snapshot $SNAP_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

# ---- locate MySQL creds the same way the other doctors do --------------------
find_db_creds() {
  DBU=""; DBP=""; DBN="yiimpfrontend"
  for f in /var/stratum/scrypt.conf /var/stratum/*.conf; do
    [ -f "$f" ] || continue
    u=$(grep -oP '^\s*username\s*=\s*\K\S+' "$f" 2>/dev/null | head -1)
    p=$(grep -oP '^\s*password\s*=\s*\K\S+' "$f" 2>/dev/null | head -1)
    n=$(grep -oP '^\s*database\s*=\s*\K\S+' "$f" 2>/dev/null | head -1)
    [ -n "${u:-}" ] && { DBU=$u; DBP=${p:-}; DBN=${n:-yiimpfrontend}; break; }
  done
  if [ -z "$DBU" ]; then
    for f in /var/web/serverconfig.php /var/web/keys.php; do
      [ -f "$f" ] || continue
      u=$(grep -oP "YIIMP_DB_USER'\s*,\s*'\K[^']+" "$f" 2>/dev/null | head -1)
      p=$(grep -oP "YIIMP_DB_PASS'\s*,\s*'\K[^']+" "$f" 2>/dev/null | head -1)
      [ -n "${u:-}" ] && { DBU=$u; DBP=${p:-}; break; }
    done
  fi
  [ -n "$DBU" ]
}
myq(){ mysql -u"$DBU" -p"$DBP" "$DBN" -N -B -e "$1" 2>/dev/null; }

################################################################################
if [ "$MODE" = "LIST" ]; then
  hr "snapshots on this box"
  [ -d "$ROOT" ] || { warn "none yet ($ROOT does not exist)"; exit 0; }
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    printf '   %-52s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
    [ -f "$d/MANIFEST.txt" ] && sed -n '1,3p' "$d/MANIFEST.txt" | sed 's/^/        /'
  done
  exit 0
fi

################################################################################
if [ "$MODE" = "VERIFY" ] || [ "$MODE" = "RESTORE" ]; then
  SNAP="$ARG2"
  [ -n "$SNAP" ] || SNAP=$(ls -1dt "$ROOT"/*/ 2>/dev/null | head -1)
  SNAP="${SNAP%/}"
  [ -d "$SNAP" ] || { bad "snapshot dir not found: '$SNAP'"; exit 1; }
  echo "  snapshot: $SNAP"

  hr "1. integrity"
  if [ -f "$SNAP/SHA256SUMS" ]; then
    ( cd "$SNAP" && sha256sum -c SHA256SUMS 2>&1 | grep -v ': OK$' | sed 's/^/      /' )
    n_bad=$( cd "$SNAP" && sha256sum -c SHA256SUMS 2>/dev/null | grep -c ': FAILED' )
    [ "$n_bad" -eq 0 ] && ok "all files match their checksums" || bad "$n_bad file(s) corrupt"
  else
    warn "no SHA256SUMS in this snapshot"
  fi
  for must in files/var/stratum/stratum MANIFEST.txt; do
    [ -e "$SNAP/$must" ] && ok "present: $must" || bad "MISSING: $must"
  done
  sz=$(du -sh "$SNAP" 2>/dev/null | awk '{print $1}'); ok "total size $sz"
  if ls "$SNAP"/db/*.sql.gz >/dev/null 2>&1; then
    for f in "$SNAP"/db/*.sql.gz; do
      gzip -t "$f" 2>/dev/null && ok "db dump OK: $(basename "$f") ($(du -h "$f"|awk '{print $1}'))" \
                               || bad "db dump CORRUPT: $(basename "$f")"
    done
  else
    warn "no database dump in this snapshot"
  fi

  hr "2. what the box looked like when it was taken"
  sed 's/^/   /' "$SNAP/MANIFEST.txt" 2>/dev/null | head -50

  if [ "$MODE" = "VERIFY" ]; then
    echo
    ok "VERIFY only -- nothing was changed."
    echo "   To roll the FILES back to this snapshot:"
    echo "     curl -fsSL \"https://pool.honest.money/install/pool-snapshot.sh?v=\$(date +%s)\" | sudo bash -s RESTORE $SNAP --restart"
    exit 0
  fi

  ################################################################################
  hr "3. RESTORE -- current files copied aside first"
  PRE="$SNAP/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$PRE"
  RESTART=0; [ "${3:-}" = "--restart" ] && RESTART=1

  restored=0
  while IFS= read -r rel; do
    src="$SNAP/files/$rel"; dst="/$rel"
    [ -f "$src" ] || continue
    if [ -f "$dst" ]; then
      mkdir -p "$PRE/$(dirname "$rel")"
      cp -a "$dst" "$PRE/$rel"
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst" && restored=$((restored+1))
  done < <(cd "$SNAP/files" && find . -type f | sed 's|^\./||')
  ok "restored $restored file(s); previous versions saved to $PRE"

  if [ -f "$SNAP/files/var/stratum/stratum" ]; then
    chmod 755 /var/stratum/stratum
    ok "stratum binary restored, sha256 $(sha256sum /var/stratum/stratum | cut -c1-16)"
  fi

  systemctl daemon-reload 2>/dev/null
  if [ "$RESTART" = 1 ]; then
    warn "restarting stratum-aws-scrypt -- miners will reconnect"
    systemctl restart stratum-aws-scrypt
    sleep 5
    systemctl is-active --quiet stratum-aux-scrypt 2>/dev/null
    systemctl is-active --quiet stratum-aws-scrypt \
      && ok "stratum-aws-scrypt is active" || bad "stratum-aws-scrypt NOT active -- check journalctl"
  else
    warn "service NOT restarted (pass --restart to restart it)"
  fi

  cat <<EOF

=== 4. database ===
   NOT restored automatically, on purpose: rolling the DB back would also
   erase every share, earning and payout row recorded since the snapshot.
   Only do this if the DB itself is what broke:

     zcat $SNAP/db/yiimpfrontend-full.sql.gz | mysql -u<user> -p<pass> yiimpfrontend

   Surgical config-only restore (coins + settings tables):

     zcat $SNAP/db/config-tables.sql.gz | mysql -u<user> -p<pass> yiimpfrontend

=== 5. undo the restore ===
     sudo cp -a $PRE/var/stratum/stratum /var/stratum/stratum
     sudo systemctl restart stratum-aws-scrypt

pool-snapshot $SNAP_VERSION restore done.
EOF
  exit 0
fi

################################################################################
# SAVE
################################################################################
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP="$ROOT/$TS"
mkdir -p "$SNAP/files" "$SNAP/db"
echo "  target: $SNAP"

hr "1. disk space check"
avail=$(df -BG --output=avail /var/backups | tail -1 | tr -dc '0-9')
echo "   free on /var/backups: ${avail}G"
if [ "${avail:-0}" -lt 5 ]; then
  bad "under 5G free -- snapshot may not fit. Free space first."; exit 1
fi
ok "enough space"

copy_in(){ # copy_in <abs-path>
  local p="$1"
  [ -e "$p" ] || return 0
  mkdir -p "$SNAP/files$(dirname "$p")"
  cp -a "$p" "$SNAP/files$p" 2>/dev/null && echo "   + $p"
}

hr "2. /var/stratum (binaries + configs, no logs)"
for f in /var/stratum/stratum /var/stratum/stratum.bak.* /var/stratum/stratum.rollback \
         /var/stratum/*.conf /var/stratum/*.py /var/stratum/*.sh; do
  [ -e "$f" ] && copy_in "$f"
done
[ -d /var/stratum/config ] && { mkdir -p "$SNAP/files/var/stratum"; cp -a /var/stratum/config "$SNAP/files/var/stratum/" 2>/dev/null; echo "   + /var/stratum/config/"; }
for d in /var/stratum/config.UNUSED-*; do [ -d "$d" ] && { cp -a "$d" "$SNAP/files/var/stratum/" 2>/dev/null; echo "   + $d"; }; done

hr "3. systemd units + enable state"
for u in stratum-aws-scrypt yiimp-api zcu-mainnet-yiimp-block-sync nicehash-proxy nicehash-watcher pool-watchdog ltc-unlock; do
  for p in /etc/systemd/system/$u.service /etc/systemd/system/$u.timer; do
    [ -f "$p" ] && copy_in "$p"
  done
  printf '%-40s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo n/a)" >> "$SNAP/systemd-enabled.txt"
done
ok "unit enable-state -> systemd-enabled.txt"

hr "4. crontabs and wallet config"
crontab -l -u root    > "$SNAP/crontab-root.txt"   2>/dev/null && ok "root crontab"
crontab -l -u ubuntu  > "$SNAP/crontab-ubuntu.txt" 2>/dev/null && ok "ubuntu crontab"
[ -d /etc/cron.d ] && { cp -a /etc/cron.d "$SNAP/files/etc/" 2>/dev/null || mkdir -p "$SNAP/files/etc" && cp -a /etc/cron.d "$SNAP/files/etc/"; ok "/etc/cron.d"; }
[ -d /etc/pool-wallets ] && { mkdir -p "$SNAP/files/etc"; cp -a /etc/pool-wallets "$SNAP/files/etc/"; chmod -R go-rwx "$SNAP/files/etc/pool-wallets"; ok "/etc/pool-wallets (mode-locked to root)"; }
for f in /var/web/serverconfig.php /var/web/keys.php; do copy_in "$f"; done

hr "5. database dump"
if find_db_creds; then
  ok "creds found for user '$DBU' db '$DBN'"
  if mysqldump --single-transaction --quick --routines --events \
       -u"$DBU" -p"$DBP" "$DBN" 2>"$SNAP/db/mysqldump.err" | gzip -1 > "$SNAP/db/yiimpfrontend-full.sql.gz"; then
    ok "full dump $(du -h "$SNAP/db/yiimpfrontend-full.sql.gz" | awk '{print $1}')"
  else
    bad "full dump failed -- see $SNAP/db/mysqldump.err"
  fi
  if mysqldump --single-transaction -u"$DBU" -p"$DBP" "$DBN" coins settings 2>/dev/null | gzip -1 > "$SNAP/db/config-tables.sql.gz"; then
    ok "config-tables dump (coins, settings)"
  else
    warn "config-tables dump skipped (table names may differ)"
  fi
else
  bad "could not find MySQL creds -- NO DB DUMP TAKEN"
  warn "see mem: yiimp DB creds; rerun with DBU/DBP exported if needed"
fi

hr "6. state manifest (the 'before' numbers)"
{
  echo "snapshot   : $TS"
  echo "host       : $(hostname)"
  echo "kernel     : $(uname -r)"
  echo
  echo "-- running stratum binary --"
  ls -l --time-style='+%Y-%m-%d %H:%M' /var/stratum/stratum 2>/dev/null
  echo "sha256     : $(sha256sum /var/stratum/stratum 2>/dev/null | awk '{print $1}')"
  for sym in ZCUAUXCOMMIT scrypt_submitAuxBlock scrypt_createAuxBlock auxpow_rpc_mode submitauxblock; do
    echo "strings $sym = $(strings -a /var/stratum/stratum 2>/dev/null | grep -c "$sym")"
  done
  echo
  echo "-- services --"
  for u in stratum-aws-scrypt yiimp-api; do
    echo "$u active=$(systemctl is-active $u 2>/dev/null) NRestarts=$(systemctl show -p NRestarts --value $u 2>/dev/null) since=$(systemctl show -p ActiveEnterTimestamp --value $u 2>/dev/null)"
  done
  echo
  echo "-- connections on stratum ports --"
  for p in 3433 3533; do
    echo "port $p ESTABLISHED = $(ss -tn state established "( sport = :$p )" 2>/dev/null | tail -n +2 | wc -l)"
  done
  echo
  if find_db_creds; then
    echo "-- coins table --"
    myq "SELECT id,symbol,enable,auxpow,IFNULL(rpcencoding,'') FROM coins ORDER BY id;" | sed 's/\t/  /g'
    echo
    echo "-- latest block per coin --"
    myq "SELECT c.symbol, MAX(b.height), FROM_UNIXTIME(MAX(b.time)) FROM blocks b JOIN coins c ON c.id=b.coin_id GROUP BY c.symbol ORDER BY c.symbol;" | sed 's/\t/  /g'
    echo
    echo "-- workers --"
    myq "SELECT COUNT(*) FROM workers;" | sed 's/^/workers rows: /'
  fi
} > "$SNAP/MANIFEST.txt" 2>/dev/null
sed 's/^/   /' "$SNAP/MANIFEST.txt" | head -40

hr "7. checksum everything"
( cd "$SNAP" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS )
chmod -R go-rwx "$SNAP"
ok "$(wc -l < "$SNAP/SHA256SUMS") files checksummed"
ok "snapshot size $(du -sh "$SNAP" | awk '{print $1}')"

cat <<EOF

=== 8. done -- nothing on this box was changed ===
   snapshot : $SNAP

   Verify it is complete and readable (do this NOW, before the window):
     curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=\$(date +%s)" | sudo bash -s VERIFY $SNAP

   One-command rollback of every file, with restart:
     curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=\$(date +%s)" | sudo bash -s RESTORE $SNAP --restart

   Belt and braces for the binary specifically:
     sudo cp -a /var/stratum/stratum /var/stratum/stratum.rollback

   Off-box copy (recommended -- an EBS/AMI snapshot beats any of this):
     aws ec2 create-snapshot --volume-id <vol-id> --description "pre-ZCU-swap $TS"

pool-snapshot $SNAP_VERSION done.
EOF
