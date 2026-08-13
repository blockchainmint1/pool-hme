#!/usr/bin/env bash
# zcu-restore-plan.sh -- READ ONLY. Quantify exactly what we would gain (ZCU)
# and what we would lose (15-20 Jul fixes) by restoring the ZCU-capable stratum.
#
#   curl -fsSL "https://pool.honest.money/install/zcu-restore-plan.sh?v=$(date +%s)" | sudo bash
#
# BACKGROUND (from zcu-archaeology, 13 Aug 2026):
#   * a9cde1777ae8  4 Jun 08:35  new=14 aux=48 zcu=18  <- LAST ZCU-CAPABLE BUILD
#       live copy kept at /var/stratum/stratum.bak.20260715-050518
#       source at /root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src
#   * ZCU's last block was 13 Jul 04:21 -- TWO DAYS BEFORE that binary was
#     swapped out on 15 Jul 05:05. So ZCU died from environment (log/disk/CPU),
#     not from code. Every binary from 15 Jul on has zcu=0.
#
# This script does NOT stop, start, install or modify anything. It only diffs.
#
# VERSION LOG -- bump on every change, newest first.
#   v1  2026-08-13  First cut.
PLAN_VERSION="v1"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n=== %s ===\n' "$*"; }

ZCU_SRC=${ZCU_SRC:-$(ls -d /root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src 2>/dev/null | head -1)}
LIVE_SRC=${LIVE_SRC:-/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum}
ZCU_BIN=${ZCU_BIN:-/var/stratum/stratum.bak.20260715-050518}
LIVE_BIN=${LIVE_BIN:-/var/stratum/stratum}

echo "zcu-restore-plan $PLAN_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"
echo "READ ONLY -- nothing is modified."
echo "  ZCU source : $ZCU_SRC"
echo "  LIVE source: $LIVE_SRC"

hr "1. confirm the two binaries are what we think"
for b in "$ZCU_BIN" "$LIVE_BIN"; do
  [ -f "$b" ] || { echo "   MISSING: $b"; continue; }
  printf '   %-46s %s  %s  zcu=%s new=%s\n' "$b" \
    "$(date -r "$b" '+%Y-%m-%d %H:%M')" "$(sha256sum "$b" | cut -c1-12)" \
    "$(strings -a "$b" | grep -cE 'Zero Chill|ZCU')" \
    "$(strings -a "$b" | grep -cEi 'scrypt_submitAuxBlock|ZCUAUXCOMMIT|zcu_submit_from_ltc_parent')"
done

hr "2. WHAT WE WOULD LOSE -- files changed in LIVE since the ZCU build"
# NOTE: GNU diff has NO --include option (only --exclude). v1 used --include and
# silently produced nothing. We enumerate the source files ourselves instead.
if [ ! -d "$ZCU_SRC" ] || [ ! -d "$LIVE_SRC" ]; then
  echo "   one of the trees is missing; set ZCU_SRC= / LIVE_SRC= and re-run"
else
  WORK=$(mktemp)
  ( cd "$ZCU_SRC" && find . -maxdepth 1 \( -name '*.cpp' -o -name '*.h' \) -printf '%f\n' ) | sort -u \
  | while read -r n; do
      a="$ZCU_SRC/$n"; b="$LIVE_SRC/$n"
      if [ ! -f "$b" ]; then echo "MISSING-IN-LIVE $n"; continue; fi
      c=$(diff "$a" "$b" 2>/dev/null | grep -c '^[<>]')
      [ "$c" -gt 0 ] && echo "$c $n"
    done > "$WORK"
  ( cd "$LIVE_SRC" && find . -maxdepth 1 \( -name '*.cpp' -o -name '*.h' \) -printf '%f\n' ) \
  | while read -r n; do
      [ -f "$ZCU_SRC/$n" ] || echo "NEW-IN-LIVE $n"
    done >> "$WORK"
  echo "   -- files present only on one side:"
  grep -E '^(MISSING-IN-LIVE|NEW-IN-LIVE)' "$WORK" | sed 's/^/      /' || true
  echo "   -- files that DIFFER, by lines changed (biggest first). THIS is the worklist:"
  grep -E '^[0-9]+ ' "$WORK" | sort -rn | awk '{printf "      %6s  %s\n", $1, $2}'
  echo "   -- total differing files: $(grep -cE '^[0-9]+ ' "$WORK")"
fi

hr "3. the actual diffs, per file (forward-port worklist)"
if [ -d "$ZCU_SRC" ] && [ -d "$LIVE_SRC" ] && [ -f "${WORK:-/nonexistent}" ]; then
  grep -E '^[0-9]+ ' "$WORK" | sort -rn | awk '{print $2}' | while read -r n; do
    echo "   ---------- $n  ($(grep -E "^[0-9]+ $n\$" "$WORK" | awk '{print $1}') lines) ----------"
    diff -u "$ZCU_SRC/$n" "$LIVE_SRC/$n" 2>/dev/null | sed -n '3,140p' | sed 's/^/      /'
  done
  rm -f "$WORK"
fi

hr "4. is the DOGE fix in the CODE or the CONFIG?"
echo "   (if auxpow_rpc_mode only appears in scrypt.conf, restoring the old binary costs nothing on DOGE)"
grep -rn 'auxpow_rpc_mode' /var/stratum/scrypt.conf 2>/dev/null | sed 's/^/      conf: /'
echo "   -- SOURCE files only (v1 wrongly matched .o object files):"
grep -rln 'auxpow_rpc_mode' "$LIVE_SRC" "$ZCU_SRC" \
  --include='*.cpp' --include='*.h' 2>/dev/null | sed 's/^/      src:  /'
echo "   -- where DOGE auxpow mode is set (DB coins row wins over conf):"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e \
  "SELECT id,symbol,enable,auxpow,rpcencoding,rpcport FROM coins WHERE symbol IN ('DOGE','TXC','ISK','ZCU','LTC')" 2>&1 \
  | grep -v '^mysql:' | sed 's/^/      /'
echo "   -- does the ZCU-era binary understand auxpow_rpc_mode at all?"
for b in "$ZCU_BIN" "$LIVE_BIN"; do
  [ -f "$b" ] && printf '      %-46s auxpow_rpc_mode=%s\n' "$(basename "$b")" \
    "$(strings -a "$b" | grep -c 'auxpow_rpc_mode')"
done


hr "5. config compatibility -- would scrypt.conf still parse?"
echo "   -- coin sections currently configured:"
grep -nE '^\[|^[[:space:]]*(name|symbol|algo|auxpow|enable)' /var/stratum/scrypt.conf 2>/dev/null \
  | sed -E 's/(password|rpcpassword|rpcuser)([[:space:]]*=).*/\1\2 ***MASKED***/I' | head -60 | sed 's/^/      /'
echo "   -- config keys the LIVE binary knows but the ZCU binary does not:"
comm -23 \
  <(strings -a "$LIVE_BIN" 2>/dev/null | grep -oE '^[a-z_]{4,24}$' | sort -u) \
  <(strings -a "$ZCU_BIN"  2>/dev/null | grep -oE '^[a-z_]{4,24}$' | sort -u) \
  | head -40 | sed 's/^/      /'

hr "6. current health -- the baseline we must not regress"
systemctl is-active stratum-aws-scrypt 2>/dev/null | sed 's/^/      service: /'
systemctl show stratum-aws-scrypt -p NRestarts -p ActiveEnterTimestamp --no-pager 2>/dev/null | sed 's/^/      /'
ss -tn state established '( sport = :3433 )' 2>/dev/null | tail -n +2 | wc -l | sed 's/^/      miner sockets: /'
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e \
  "SELECT c.symbol, COUNT(*) n, FROM_UNIXTIME(MAX(b.time)) last FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE b.time > UNIX_TIMESTAMP()-86400 GROUP BY c.symbol ORDER BY n DESC" 2>&1 \
  | grep -v '^mysql:' | sed 's/^/      /'

hr "7. proposed restore procedure (NOT executed)"
cat <<'PLAN' | sed 's/^/   /'
Only if sections 2-3 show the diffs are small / config-only:

  1. Baseline:  mining-canary.sh BASELINE          (must be green first)
  2. Forward-port the section-3 diffs INTO the ZCU tree:
       $ZCU_SRC   <-- apply the 15-20 Jul fixes here
  3. Build in that tree, in dependency order (parallel make races):
       make -C iniparser && make -C secp256k1
       make -C algos -j"$(nproc)" && make -C sha3 -j"$(nproc)"
       make -j"$(nproc)"
       ls -l stratum      # MUST have a fresh mtime, or nothing was rebuilt
  4. Verify the new binary BEFORE installing:
       strings -a stratum | grep -c ZCUAUXCOMMIT     # must be > 0
       strings -a stratum | grep -c auxpow_rpc_mode  # must match live
  5. Keep ZCU DISABLED on first boot (coins.enable=0 AND out of scrypt.conf).
     Prove LTC/DOGE/TXC/ISK are unchanged for a full hour with the canary.
  6. Only then re-arm ZCU, with the full-256 gate doing the filtering, and
     watch journalctl -u stratum-aws-scrypt for the deadlock signature.

Rollback at any point:
  sudo install -m755 /var/stratum/stratum.rollback /var/stratum/stratum
  sudo systemctl restart stratum-aws-scrypt
PLAN

echo
echo "zcu-restore-plan $PLAN_VERSION done -- nothing was modified."
