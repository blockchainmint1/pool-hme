#!/usr/bin/env bash
# stratum-socket-fix.sh -- MAJOR UPDATE 2026-10-01: fix the disconnect-race
# crash (stratum reads a miner connection that was already closed -> SEGV in
# socket_nextjson -> all miners dropped).
#
# Steps, each a separate run, each safe to stop after:
#   1. CHECK    (default) read-only. Finds the source tree that matches the
#               running binary and shows exactly what the patch would change.
#   2. BUILD    compiles a PATCHED COPY in /root/stratum-fix-<ts>/. Touches
#               nothing live. Also saves a full source archive (for new boxes).
#   3. INSTALL CONFIRM   full pool snapshot, keeps the current binary as
#               /var/stratum/stratum.pre-socketfix, swaps in the new one,
#               ONE restart, then health-checks.
#   4. ROLLBACK CONFIRM  puts stratum.pre-socketfix back + one restart.
#
#   curl -fsSL "https://pool.honest.money/install/stratum-socket-fix.sh?v=$(date +%s)" | sudo bash
#   ... | sudo bash -s BUILD
#   ... | sudo bash -s INSTALL CONFIRM
#   ... | sudo bash -s ROLLBACK CONFIRM
#
# VERSION LOG
#   v1  2026-10-01  First cut.
#   v2  2026-10-01  Also searches /root/ZCU-FWDPORT-* and every built
#                   stratum binary under /root /home/ubuntu /opt for the match.
VER="v2"
set -uo pipefail
MODE="${1:-CHECK}"; CONF="${2:-}"
LIVE=/var/stratum/stratum
BACKUP=/var/stratum/stratum.pre-socketfix
UNIT=stratum-aws-scrypt
WORK_ROOT=/root
ARCHIVE_DIR=/var/backups/stratum-source
TREES="/home/ubuntu/aws/LIVE/LIVE-FINAL /home/ubuntu/aws/LIVE/yiimp/live-aux-issue-doge /home/ubuntu/aws/LIVE/live-aux-issue-doge /home/ubuntu/aws/LIVE/perfect1"
for d in /root/ZCU-FWDPORT-* /root/ZCU-FWDPORT-*/* /root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src; do [ -d "$d" ] && TREES="$TREES $d"; done

say(){ echo; echo "===== $*"; }
die(){ echo; echo "STOPPED: $*"; echo "Nothing live was changed."; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
echo "stratum-socket-fix $VER  mode=$MODE  $(date -u +%FT%TZ)"

stratum_dir(){ # tree -> dir containing socket.cpp
  local t="$1"
  [ -f "$t/stratum/socket.cpp" ] && { echo "$t/stratum"; return; }
  [ -f "$t/socket.cpp" ] && { echo "$t"; return; }
}

find_tree(){
  LIVE_SHA=$(sha256sum "$LIVE" | cut -c1-12)
  MATCH=""; CANDS=""
  for t in $TREES; do
    d=$(stratum_dir "$t"); [ -n "$d" ] || continue
    CANDS="$CANDS $d"
    if [ -f "$d/stratum" ] && [ "$(sha256sum "$d/stratum" | cut -c1-12)" = "$LIVE_SHA" ]; then MATCH="$d"; fi
  done
  if [ -z "$MATCH" ]; then # wide search: any built stratum binary with same size+sha
    SZ=$(stat -c %s "$LIVE")
    while IFS= read -r b; do
      [ "$b" = "$LIVE" ] && continue
      [ "$(sha256sum "$b" | cut -c1-12)" = "$LIVE_SHA" ] || continue
      echo "  identical binary found: $b"
      dd=$(dirname "$b"); [ -f "$dd/socket.cpp" ] && [ -z "$MATCH" ] && MATCH="$dd"
    done < <(find /root /home/ubuntu /opt /tmp -xdev -type f -name 'stratum*' -size ${SZ}c 2>/dev/null)
  fi
}

PATCH_MARK="SOCKETFIX-20261001"
apply_patch(){ # dir
  local f="$1/socket.cpp"
  grep -q "$PATCH_MARK" "$f" && { echo "already patched"; return 0; }
  python3 - "$f" "$PATCH_MARK" <<'PY'
import re,sys
p,mark=sys.argv[1],sys.argv[2]
s=open(p).read()
m=re.search(r'json_value\s*\*\s*socket_nextjson\s*\(\s*YAAMP_SOCKET\s*\*\s*(\w+)[^)]*\)\s*\{',s)
if not m: sys.exit("socket_nextjson not found")
v=m.group(1)
guard=f"\n\t// {mark}: connection may already be closed by another thread\n\tif(!{v} || {v}->sock <= 0) return NULL;\n"
s=s[:m.end()]+guard+s[m.end():]
open(p,'w').write(s)
print("patched socket_nextjson (var=%s)"%v)
PY
}

case "$MODE" in
CHECK)
  say "1. running binary"
  ls -l "$LIVE"; sha256sum "$LIVE"
  systemctl show $UNIT -p ActiveEnterTimestamp -p NRestarts
  say "2. source trees"
  find_tree
  for d in $CANDS; do
    s="(no built binary)"; [ -f "$d/stratum" ] && s="$(sha256sum "$d/stratum"|cut -c1-12)  $(date -r "$d/stratum" +%F\ %T)"
    echo "  $d  -> $s"
  done
  if [ -n "$MATCH" ]; then echo "MATCH: $MATCH built the running binary exactly."
  else echo "NO EXACT MATCH: no tree's built binary equals the running one ($LIVE_SHA). BUILD will refuse until we pick a tree together."; fi
  say "3. the crash spot today"
  [ -n "$MATCH" ] && grep -n -A8 "socket_nextjson" "$MATCH/socket.cpp" | head -20
  say "4. what the patch adds (2 lines, at the top of socket_nextjson)"
  echo "    if(!s || s->sock <= 0) return NULL;   // miner already disconnected -> skip, don't crash"
  echo; echo "CHECK done. Nothing changed. Next: ... | sudo bash -s BUILD"
  ;;
BUILD)
  find_tree
  [ -n "$MATCH" ] || die "no source tree matches the running binary -- paste CHECK output to Lovable"
  TS=$(date -u +%Y%m%d-%H%M%S); W="$WORK_ROOT/stratum-fix-$TS"
  say "copying $MATCH -> $W (original tree untouched)"
  mkdir -p "$W"; cp -a "$MATCH/." "$W/" || die "copy failed"
  mkdir -p "$ARCHIVE_DIR"
  tar czf "$ARCHIVE_DIR/stratum-source-asrunning-$TS.tgz" -C "$(dirname "$MATCH")" "$(basename "$MATCH")" \
    && echo "source archive (exact running version): $ARCHIVE_DIR/stratum-source-asrunning-$TS.tgz"
  say "patching the copy"
  apply_patch "$W" || die "patch failed"
  grep -n -A3 "$PATCH_MARK" "$W/socket.cpp"
  say "building (in order, to avoid the link race)"
  cd "$W" || die "cd"
  rm -f stratum
  for sub in iniparser secp256k1; do [ -d $sub ] && { make -C $sub >/tmp/sfix-$sub.log 2>&1 || die "make $sub failed (see /tmp/sfix-$sub.log)"; }; done
  for sub in algos sha3; do [ -d $sub ] && { make -C $sub -j"$(nproc)" >/tmp/sfix-$sub.log 2>&1 || die "make $sub failed (see /tmp/sfix-$sub.log)"; }; done
  make -j1 >/tmp/sfix-main.log 2>&1 || { tail -20 /tmp/sfix-main.log; die "main build failed"; }
  [ -x stratum ] || die "no binary produced"
  [ "$(find stratum -mmin -10)" ] || die "binary is stale"
  tar czf "$ARCHIVE_DIR/stratum-source-socketfix-$TS.tgz" --exclude='*.o' --exclude='*.a' -C "$WORK_ROOT" "stratum-fix-$TS" \
    && echo "source archive (patched): $ARCHIVE_DIR/stratum-source-socketfix-$TS.tgz"
  echo "$W" > /root/stratum-fix.latest
  ls -l stratum; sha256sum stratum
  echo; echo "BUILD OK. Live mining untouched. Next (planned ~20s miner reconnect): ... | sudo bash -s INSTALL CONFIRM"
  ;;
INSTALL)
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  W=$(cat /root/stratum-fix.latest 2>/dev/null); [ -x "$W/stratum" ] || die "run BUILD first"
  grep -q "$PATCH_MARK" "$W/socket.cpp" || die "built tree is not patched"
  say "full pool snapshot first"
  curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | bash -s SAVE || die "snapshot failed"
  [ -f "$BACKUP" ] || cp -a "$LIVE" "$BACKUP" || die "backup copy failed"
  cmp -s "$LIVE" "$BACKUP" || echo "note: $BACKUP already existed from an earlier install; kept it (it is the original)."
  echo "undo copy: $BACKUP  $(sha256sum "$BACKUP"|cut -c1-12)"
  say "swap + one restart"
  install -m755 "$W/stratum" "$LIVE.new" && mv -f "$LIVE.new" "$LIVE" || die "swap failed"
  systemctl restart $UNIT
  echo "waiting 60s for miners to reconnect..."; sleep 60
  say "health"
  systemctl is-active $UNIT; systemctl show $UNIT -p NRestarts -p ActiveEnterTimestamp
  echo "connections on 3433: $(ss -Htn state established '( sport = :3433 )' | wc -l)"
  tail -5 /var/stratum/scrypt.log 2>/dev/null
  echo; echo "INSTALLED ($(sha256sum "$LIVE"|cut -c1-12)). If anything looks wrong:"
  echo '  curl -fsSL "https://pool.honest.money/install/stratum-socket-fix.sh?v=$(date +%s)" | sudo bash -s ROLLBACK CONFIRM'
  ;;
ROLLBACK)
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  [ -x "$BACKUP" ] || die "no $BACKUP found"
  cp -a "$LIVE" "$LIVE.socketfix-rolledback" 2>/dev/null
  install -m755 "$BACKUP" "$LIVE.new" && mv -f "$LIVE.new" "$LIVE" || die "restore failed"
  systemctl restart $UNIT; sleep 30
  systemctl is-active $UNIT; sha256sum "$LIVE"
  echo "ROLLED BACK to the pre-fix binary."
  ;;
*) die "unknown mode $MODE" ;;
esac
