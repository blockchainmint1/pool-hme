#!/usr/bin/env bash
# stratum-backtrace.sh -- reads saved stratum crash snapshots and prints WHERE it crashed.
#
#   run:  curl -fsSL "https://pool.honest.money/install/stratum-backtrace.sh?v=$(date +%s)" | sudo bash
#
# The ONLY change it makes: installs the read-only debugger "gdb" (apt) if missing.
# It does NOT touch stratum, its config, the database, coins, or any service.
# Unpacked snapshots go to /root/crash-evidence-backtrace/ (outside the pool).
set -u
H() { echo; echo "===== $*"; }
BIN=/var/stratum/stratum
OUT=/root/crash-evidence-backtrace
mkdir -p "$OUT"
echo "stratum-backtrace v1  $(date -u '+%F %T') UTC"

H "1. debugger"
if ! command -v gdb >/dev/null; then
  echo "  installing gdb (read-only debugger, does not affect mining)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gdb >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gdb >/dev/null 2>&1; }
fi
command -v gdb >/dev/null && echo "  gdb: $(gdb --version | head -1)" || { echo "  FAIL could not install gdb"; exit 1; }

H "2. the stratum binary (are function names inside it?)"
file "$BIN" | sed 's/^/  /'
md5sum "$BIN" | sed 's/^/  /'

H "3. find saved crash snapshots"
CORES=()
for c in /var/crash/*stratum*.crash; do
  [ -f "$c" ] || continue
  echo "  apport report: $c ($(du -h "$c" | cut -f1), $(date -u -r "$c" '+%F %T'))"
  d="$OUT/$(basename "$c" .crash)-$(date -u -r "$c" +%Y%m%dT%H%M%S)"
  if [ ! -f "$d/CoreDump" ] && command -v apport-unpack >/dev/null; then
    rm -rf "$d"; apport-unpack "$c" "$d" >/dev/null 2>&1
  fi
  [ -f "$d/CoreDump" ] && CORES+=("$d/CoreDump")
done
for c in /var/lib/apport/coredump/core.*stratum* /var/stratum/core* /root/crash-evidence-*/core* /root/crash-evidence-*/*.crash; do
  [ -f "$c" ] || continue
  case "$c" in *.crash) continue;; esac
  echo "  core file: $c ($(du -h "$c" | cut -f1), $(date -u -r "$c" '+%F %T'))"; CORES+=("$c")
done
[ ${#CORES[@]} -eq 0 ] && { echo "  no crash snapshots found on the box."; ls -la /var/crash /var/lib/apport/coredump 2>/dev/null | sed 's/^/    /'; }

H "4. where it crashed (backtrace per snapshot, newest first)"
for c in $(ls -t "${CORES[@]}" 2>/dev/null); do
  echo; echo "--- $c"
  timeout 120 gdb -q -batch -nx \
    -ex 'set pagination off' -ex 'set print thread-events off' \
    -ex 'echo \n[signal]\n' -ex 'info signal' -ex 'p $_siginfo._sifields._sigfault.si_addr' \
    -ex 'echo \n[crashing thread]\n' -ex 'bt 30' \
    -ex 'echo \n[locals of top frames]\n' -ex 'frame 1' -ex 'info locals' -ex 'frame 2' -ex 'info locals' -ex 'frame 3' -ex 'info locals' \
    -ex 'echo \n[all threads, top 8 frames]\n' -ex 'thread apply all bt 8' \
    "$BIN" "$c" 2>&1 | grep -avE '^\[New LWP|^warning: (Can.t|Could not)|^$' | cut -c1-220 | head -400
done

echo; echo "DONE. Paste everything above back to the chat. (stratum was not touched)"
