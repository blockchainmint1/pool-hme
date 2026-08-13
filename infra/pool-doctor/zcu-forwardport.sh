#!/usr/bin/env bash
# zcu-forwardport.sh -- port the 15-20 Jul LIVE fixes INTO the ZCU source tree,
# build the result OFF TO THE SIDE, and verify it. Nothing live is touched.
#
#   curl -fsSL "https://pool.honest.money/install/zcu-forwardport.sh?v=$(date +%s)" | sudo bash            # PLAN (read only)
#   curl -fsSL "https://pool.honest.money/install/zcu-forwardport.sh?v=$(date +%s)" | sudo bash -s BUILD   # patch + compile in a scratch tree
#
# WHY THIS DIRECTION
#   zcu-restore-plan v2 listed 10 differing files. Reading them, only THREE are
#   real LIVE-side improvements. The rest are either ZCU code LIVE deleted, or
#   places where the ZCU tree is actually the NEWER/safer one:
#
#     LIVE is ahead (must port):
#       client.cpp   diff clamp to g_stratum_min_diff / g_stratum_max_diff  (NiceHash)
#       db.cpp       auxpow_rpc_mode allowlist EXCLUDES DOGE (that omission IS
#                    the DOGE fix) and includes ZCU -> ISK || TXC || ZCU
#       coind.cpp    generic is_evm_address() -- superseded, ZCU tree already
#                    has coind_validate_zcu_address_string(), same behaviour
#
#     ZCU tree is ahead (do NOT take LIVE's version):
#       util.cpp     has the pthread mutex around reopen_logs_if_needed().
#                    LIVE lost it -- that is a log-corruption race.
#       coind_aux.cpp takes a malloc'd SNAPSHOT of coind->aux under the coind
#                    mutex. LIVE stores a raw &coind->aux pointer into the
#                    template -- a use-after-free / torn-read across threads.
#       job.h/coind.h/coind_template.cpp/coinbase.cpp/coind_submit.cpp
#                    = the ZCU feature itself, plus whitespace churn.
#
#   So the merge is: ZCU tree + 2 small edits. Not a rewrite.
#
# SAFETY
#   * Never writes to /var/stratum, never restarts anything.
#   * Copies the ZCU tree to a fresh /root/ZCU-FWDPORT-<ts>/ and works there.
#   * Build output is left at that path for a later maintenance window.
#
# VERSION LOG -- bump on every change, newest first.
#   v3  2026-08-13  Fix two BUILD-mode faults found on the first real run:
#                   (a) db.cpp allowlist regex assumed three closing parens and
#                       silently skipped -- now a line-oriented rewrite that
#                       ASSERTS the result (build aborts if DOGE survives).
#                   (b) the archived ZCU tree is missing algos/ar2 sources
#                       ("No rule to make target 'ar2/core.c'"). Missing algo
#                       sources are now backfilled from the LIVE tree, add-only,
#                       never overwriting a file the ZCU tree already has.
#   v2  2026-08-13  CORRECTION: DOGE must be OUT of the auxpow_rpc_mode=1
#                   allowlist. mode 1 broke DOGE (~20% accept); removing DOGE
#                   gave 100%. Target allowlist = ISK || TXC || ZCU.
#   v1  2026-08-13  First cut.
FP_VERSION="v3"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-PLAN}"
hr() { printf '\n=== %s ===\n' "$*"; }
ok(){ echo "   OK   $*"; }
warn(){ echo "   WARN $*"; }
bad(){ echo "   FAIL $*"; }

ZCU_SRC=${ZCU_SRC:-$(ls -d /root/ZCU-PROD-YIIMP-PROD4B-*/work/stratum-build-src 2>/dev/null | head -1)}
LIVE_SRC=${LIVE_SRC:-/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum}

echo "zcu-forwardport $FP_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"
echo "  ZCU source : $ZCU_SRC"
echo "  LIVE source: $LIVE_SRC"
[ -d "$ZCU_SRC" ]  || { bad "ZCU source tree not found"; exit 1; }
[ -d "$LIVE_SRC" ] || { bad "LIVE source tree not found"; exit 1; }

################################################################################
hr "1. how much of the diff is real code vs whitespace"
################################################################################
printf '   %-24s %8s %8s\n' file all-lines ignoring-ws
for f in job.h coind_template.cpp coinbase.cpp coind_submit.cpp util.cpp \
         coind.cpp coind_aux.cpp client.cpp coind.h db.cpp; do
  [ -f "$ZCU_SRC/$f" ] && [ -f "$LIVE_SRC/$f" ] || continue
  a=$(diff -u "$ZCU_SRC/$f" "$LIVE_SRC/$f" 2>/dev/null | grep -c '^[+-][^+-]')
  b=$(diff -u -w -B "$ZCU_SRC/$f" "$LIVE_SRC/$f" 2>/dev/null | grep -c '^[+-][^+-]')
  printf '   %-24s %8s %8s\n' "$f" "$a" "$b"
done
echo "   (a big drop in the right-hand column = tabs/spaces churn, not logic)"

################################################################################
hr "2. the three LIVE-side changes we care about -- present in ZCU tree?"
################################################################################
NEED_CLIENT=1; NEED_DB=1
if grep -q 'g_stratum_min_diff' "$ZCU_SRC/client.cpp" 2>/dev/null; then
  ok "client.cpp diff clamp already present"; NEED_CLIENT=0
else
  warn "client.cpp diff clamp MISSING -- will port"
fi
if grep -q '"ZCU"' "$ZCU_SRC/db.cpp" && ! grep -q '"DOGE"' "$ZCU_SRC/db.cpp"; then
  ok "db.cpp allowlist is already ISK/TXC/ZCU with DOGE excluded"; NEED_DB=0
else
  warn "db.cpp allowlist must become ISK || TXC || ZCU (DOGE REMOVED) -- will port"
  grep -q '"DOGE"' "$ZCU_SRC/db.cpp" && warn "  ZCU tree still has DOGE at mode 1 -- that is the ~20% DOGE accept bug"
fi
echo "   -- current allowlist line in each tree:"
grep -n 'auxpow_rpc_mode = 1' -B1 "$ZCU_SRC/db.cpp"  | sed 's/^/      ZCU : /'
grep -n 'auxpow_rpc_mode = 1' -B1 "$LIVE_SRC/db.cpp" | sed 's/^/      LIVE: /'

echo
echo "   -- do the clamp globals even exist in the ZCU tree?"
for sym in g_stratum_min_diff g_stratum_max_diff client_normalize_difficulty; do
  n=$(grep -rl "$sym" "$ZCU_SRC" --include='*.cpp' --include='*.h' 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && ok "$sym found in $n file(s)" || bad "$sym NOT in ZCU tree -- clamp cannot be ported as-is"
done

################################################################################
hr "3. confirm the ZCU tree is the safer one where it differs"
################################################################################
grep -q 'pthread_mutex_t g_log_reopen_mutex' "$ZCU_SRC/util.cpp" \
  && ok "util.cpp: ZCU tree HAS the log-reopen mutex (LIVE lost it)" \
  || warn "util.cpp: ZCU tree has no log mutex either"
grep -q 'aux_copy' "$ZCU_SRC/coind_aux.cpp" \
  && ok "coind_aux.cpp: ZCU tree snapshots aux under lock (LIVE stores a raw pointer)" \
  || warn "coind_aux.cpp: no snapshot in ZCU tree"
grep -q 'ZCUAUXCOMMIT\|5a4355415558434f4d4d4954' "$ZCU_SRC/coinbase.cpp" \
  && ok "coinbase.cpp: ZCU commitment output present" \
  || bad "coinbase.cpp: no ZCU commitment -- wrong tree?"

if [ "$MODE" != "BUILD" ]; then
  cat <<EOF

=== 4. verdict ===
   The forward-port is 2 small edits into the ZCU tree, not a rewrite.
   Nothing has been changed. To patch + compile in a scratch dir (still
   installs nothing):

     curl -fsSL "https://pool.honest.money/install/zcu-forwardport.sh?v=\$(date +%s)" | sudo bash -s BUILD

zcu-forwardport $FP_VERSION done -- read only.
EOF
  exit 0
fi

################################################################################
hr "4. BUILD -- copy tree, patch, compile (nothing installed)"
################################################################################
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK=/root/ZCU-FWDPORT-$TS
echo "   scratch tree: $WORK"
mkdir -p "$WORK"
cp -a "$ZCU_SRC/." "$WORK/" || { bad "copy failed"; exit 1; }
cd "$WORK" || exit 1

# ---- patch 1: db.cpp allowlist = ISK, TXC, ZCU (no DOGE) -------------------------
# v3: rewrite the whole line that guards auxpow_rpc_mode=1, preserving its
# indentation, instead of matching a paren count that varies between trees.
if [ "$NEED_DB" = 1 ]; then
  python3 - "$WORK/db.cpp" <<'PY' || { echo "   db.cpp patch FAILED"; exit 1; }
import sys
p=sys.argv[1]; L=open(p).read().splitlines(True)
tgt='if(!strcmp(coind->symbol, "ISK") || !strcmp(coind->symbol, "TXC") || !strcmp(coind->symbol, "ZCU"))\n'
hits=[i for i,l in enumerate(L)
      if 'auxpow_rpc_mode = 1' in l and i>0 and 'coind->symbol' in L[i-1] and L[i-1].lstrip().startswith('if(')]
if not hits:
    print("   db.cpp: allowlist guard line not found -- ABORT (do not ship a DOGE regression)")
    sys.exit(1)
for i in hits:
    g=i-1
    indent=L[g][:len(L[g])-len(L[g].lstrip())]
    L[g]=indent+tgt
open(p,'w').writelines(L)
s=open(p).read()
if '"DOGE"' in s and 'auxpow_rpc_mode' in s.split('"DOGE"')[0][-400:]:
    print("   db.cpp: DOGE STILL in the allowlist after patch -- ABORT"); sys.exit(1)
print("   db.cpp allowlist patched -> ISK || TXC || ZCU  (%d site(s))" % len(hits))
PY
fi

# ---- patch 2: client.cpp diff clamp ------------------------------------------
if [ "$NEED_CLIENT" = 1 ]; then
  python3 - "$WORK/client.cpp" <<'PY'
import sys
p=sys.argv[1]; L=open(p).read().splitlines(True)
anchor=next((i for i,l in enumerate(L) if 'client_normalize_difficulty(' in l and 'double diff' in l), None)
if anchor is None:
    print("   client.cpp: anchor not found -- clamp NOT applied")
else:
    L.insert(anchor+1,
"""
\t\t// Clamp to runtime pool config so firmware/proxy suggestions can't
\t\t// bypass diff_min / diff_max from the algo .conf.
\t\tif(g_stratum_min_diff > 0 && diff < g_stratum_min_diff)
\t\t\tdiff = g_stratum_min_diff;
\t\tif(g_stratum_max_diff > 0 && diff > g_stratum_max_diff)
\t\t\tdiff = g_stratum_max_diff;
""")
    open(p,'w').writelines(L)
    print("   client.cpp diff clamp applied")
PY
fi

hr "4b. backfill algo sources the archived ZCU tree is missing"
# The 3 Jun archive was taken after a `make clean` that also removed some algo
# sources (algos/ar2/* first offender: "No rule to make target 'ar2/core.c'").
# Those files are pure hashing code, identical in both trees, and are NOT part
# of the ZCU feature -- so taking LIVE's copy is safe. ADD ONLY: any file the
# ZCU tree already has is left exactly as it is.
added=0
if [ -d "$LIVE_SRC/algos" ]; then
  while IFS= read -r rel; do
    if [ ! -e "$WORK/algos/$rel" ]; then
      mkdir -p "$WORK/algos/$(dirname "$rel")"
      cp -a "$LIVE_SRC/algos/$rel" "$WORK/algos/$rel" && added=$((added+1))
      [ "$added" -le 12 ] && echo "   + algos/$rel"
    fi
  done < <(cd "$LIVE_SRC/algos" && find . \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name 'Makefile' \) | sed 's|^\./||')
fi
[ "$added" -gt 12 ] && echo "   ... and $((added-12)) more"
if [ "$added" -gt 0 ]; then
  ok "backfilled $added missing algo source file(s) from the LIVE tree"
else
  ok "algos tree already complete -- nothing backfilled"
fi
if [ ! -f "$WORK/algos/ar2/core.c" ]; then
  bad "algos/ar2/core.c is missing from BOTH trees -- cannot build"
  echo "   find another copy:  sudo find /root /home/ubuntu -path '*algos/ar2/core.c' 2>/dev/null"
  exit 1
fi
ok "algos/ar2/core.c present"

hr "5. compile (dependency order -- parallel make races on these subdirs)"
LOG=$WORK/build.log
{
  make -C iniparser && make -C secp256k1 \
  && make -C algos -j"$(nproc)" && make -C sha3 -j"$(nproc)" \
  && make -j"$(nproc)"
} >"$LOG" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  bad "build failed (rc=$RC). last 40 lines:"
  tail -40 "$LOG" | sed 's/^/      /'
  echo "   full log: $LOG"
  exit 1
fi
ok "build succeeded"

hr "6. verify the fresh binary BEFORE anyone installs it"
NEW=$WORK/stratum
if [ ! -f "$NEW" ]; then bad "no stratum binary produced"; exit 1; fi
echo "   $(ls -l --time-style='+%Y-%m-%d %H:%M' "$NEW" | awk '{print $6,$7,$5" bytes"}')"
grep -n 'auxpow_rpc_mode = 1' -B1 "$WORK/db.cpp" | sed 's/^/      NEW : /'
grep -q '"DOGE"' "$WORK/db.cpp" && bad "DOGE still in allowlist -- DOGE would regress to ~20% accept" || ok "DOGE correctly excluded from auxpow_rpc_mode=1"
for sym in ZCUAUXCOMMIT scrypt_submitAuxBlock scrypt_createAuxBlock auxpow_rpc_mode; do
  n=$(strings -a "$NEW" | grep -c "$sym")
  [ "$n" -gt 0 ] && ok "$sym x$n" || bad "$sym MISSING"
done
live_keys=$(strings -a /var/stratum/stratum 2>/dev/null | grep -c 'auxpow_rpc_mode')
ok "live binary auxpow_rpc_mode count = $live_keys (must be non-zero too)"

cat <<EOF

=== 7. staged, NOT installed ===
   new binary : $NEW
   build log  : $LOG

   Next, in a maintenance window ONLY, and with ZCU still disabled:
     sudo cp -a /var/stratum/stratum /var/stratum/stratum.rollback
     sudo install -m755 $NEW /var/stratum/stratum
     sudo systemctl restart stratum-aws-scrypt
     curl -fsSL "https://pool.honest.money/install/mining-canary.sh?v=\$(date +%s)" | sudo bash -s CHECK

   Rollback, always:
     sudo install -m755 /var/stratum/stratum.rollback /var/stratum/stratum
     sudo systemctl restart stratum-aws-scrypt

zcu-forwardport $FP_VERSION done.
EOF
