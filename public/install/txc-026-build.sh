#!/usr/bin/env bash
# txc-026-build.sh -- build and test a MINING-CAPABLE TXC Core v0.26.0 candidate.
#
# Builds in its own folder. Never touches the live TXC node, its data, its
# service, /usr/local/bin, or the stratum. The only system-wide change is that
# BUILD may install missing build tools with apt (compilers, autotools).
#
# What the candidate is:
#   public TEXITcoin code tag v0.25.2 (commit 3d10743)
#   + smoother difficulty (LWMA)     from core.honest.money/patches
#   + Send To Many                   from core.honest.money/patches
#   built with NO --enable-feature flag, so getblocktemplate / submitblock /
#   createauxblock / submitauxblock ARE compiled in (the pool needs them).
#   Checkpoint security is a one-line table entry; height + hash are not chosen
#   yet, so it is NOT in this build.
#   Mainnet switch-on heights in both patches are the placeholder 999999999, so
#   on mainnet this binary behaves exactly like 0.25.2 until a height is announced.
#
# Steps, each a separate run:
#   1. CHECK   (default) read-only. Is the box ready? Can it reach the code and patches?
#   2. BUILD   fetch, patch, then compile IN THE BACKGROUND (safe if your SSH drops).
#   3. STATUS  read-only. Shows how far the build is.
#   4. TEST    runs the new binary on a private test chain (own ports, own folder).
#              Proves mining commands exist and the smoother difficulty switches on.
#
#   curl -fsSL "https://pool.honest.money/install/txc-026-build.sh?v=$(date +%s)" | sudo bash
#   ... | sudo bash -s BUILD
#   ... | sudo bash -s STATUS
#   ... | sudo bash -s TEST
#
# VERSION LOG
#   v1  2026-10-03  First cut.
VER="v1"
set -uo pipefail
MODE="${1:-CHECK}"
WORK_ROOT=/root
POINTER=/root/txc026.latest
ARCHIVE_DIR=/var/backups/txc-source
REPO=https://github.com/blockchainmint1/texitcoin
TAG=v0.25.2
TAG_COMMIT=3d10743f2c7b462f5e5ba2ca662e25bc30091a5a
PATCH_BASE=https://core.honest.money/patches
PATCHES="lwma-difficulty send-to-many"
LIVE_CLI=/home/ubuntu/Fork-Upgrade/binaries/txc/texitcoin-cli

say(){ echo; echo "===== $*"; }
die(){ echo; echo "STOPPED: $*"; echo "Nothing live was changed."; exit 1; }
ok(){ echo "  OK    $*"; }
warn(){ echo "  WARN  $*"; }
bad(){ echo "  FAIL  $*"; }
[ "$(id -u)" = 0 ] || die "run with sudo"
echo "txc-026-build $VER  mode=$MODE  $(date -u +%FT%TZ)"

mem_avail_gb(){ awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo; }
disk_free_gb(){ df -BG --output=avail "$WORK_ROOT" | tail -1 | tr -dc '0-9'; }
pick_jobs(){
  local c m j; c=$(nproc); m=$(mem_avail_gb)
  j=$(( c / 2 )); [ "$j" -gt $(( m * 2 / 5 )) ] && j=$(( m * 2 / 5 ))
  [ "$j" -lt 1 ] && j=1; [ "$j" -gt 8 ] && j=8
  echo "$j"
}
latest_work(){ [ -f "$POINTER" ] && cat "$POINTER" || echo ""; }

# ---------------------------------------------------------------- CHECK
do_check(){
  say "this box"
  . /etc/os-release 2>/dev/null; echo "  OS: ${PRETTY_NAME:-unknown}   cpu cores: $(nproc)   arch: $(uname -m)"
  echo "  memory available: $(mem_avail_gb) GB   swap: $(free -g | awk '/Swap/{print $2}') GB"
  echo "  disk free under $WORK_ROOT: $(disk_free_gb) GB (need 15)"
  [ "$(mem_avail_gb)" -ge 4 ] && ok "memory is enough" || bad "less than 4 GB free memory: a build could starve the live pool"
  [ "$(disk_free_gb)" -ge 15 ] && ok "disk is enough" || bad "less than 15 GB free disk"
  [ "$(uname -m)" = x86_64 ] && ok "x86_64" || warn "not x86_64: depends triple will differ"
  echo "  build will use $(pick_jobs) parallel job(s), at lowest CPU priority"

  say "tools"
  local miss=""
  for t in git make g++ gcc autoconf automake libtool pkg-config python3 patch curl; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || { bad "$t missing"; miss="$miss $t"; }
  done
  [ -n "$miss" ] && echo "  (BUILD will install the missing ones with apt:$miss)"

  say "can we reach the code and the patches?"
  if git ls-remote --tags "$REPO" "$TAG" 2>/dev/null | grep -q "$TAG"; then ok "$REPO tag $TAG"; else bad "cannot read $REPO"; fi
  for p in $PATCHES; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$PATCH_BASE/$p.patch")
    [ "$code" = 200 ] && ok "$PATCH_BASE/$p.patch" || bad "$PATCH_BASE/$p.patch  HTTP $code"
  done

  say "the live TXC node (read-only look)"
  if [ -x "$LIVE_CLI" ]; then
    echo "  blocks: $(sudo -u ubuntu "$LIVE_CLI" getblockcount 2>&1 | head -1)"
    for m in getblocktemplate createauxblock; do
      r=$(sudo -u ubuntu "$LIVE_CLI" help "$m" 2>&1 | head -1)
      case "$r" in *"not found"*|*"nknown command"*|*error*) bad "live node: $m -> $r" ;; *) ok "live node has $m" ;; esac
    done
  else
    warn "live cli not at $LIVE_CLI"
  fi
  echo "  live node process:"; pgrep -a texitcoind | sed 's/^/    /' || true

  say "earlier 0.26 build folders"
  ls -d /root/txc026-* 2>/dev/null | sed 's/^/  /' || echo "  none"
  echo
  echo "CHECK done. Nothing was changed. Next: ... | sudo bash -s BUILD"
}

# ---------------------------------------------------------------- BUILD
do_build(){
  pgrep -f "txc026-run-build" >/dev/null && die "a build is already running. Use STATUS."
  [ "$(mem_avail_gb)" -ge 4 ] || die "less than 4 GB free memory; a build could starve the live pool"
  [ "$(disk_free_gb)" -ge 15 ] || die "less than 15 GB free disk"

  say "build tools"
  local need=""
  for t in git make g++ autoconf automake libtool pkg-config python3 patch curl; do command -v "$t" >/dev/null 2>&1 || need="$need $t"; done
  if [ -n "$need" ]; then
    echo "  installing missing:$need"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    for pk in build-essential autoconf automake autotools-dev libtool pkg-config python3 git patch curl bsdmainutils; do
      apt-get install -y -qq "$pk" >/dev/null 2>&1 || echo "  (could not install $pk, continuing)"
    done
    for t in git make g++ autoconf automake libtool pkg-config python3 patch curl; do command -v "$t" >/dev/null 2>&1 || die "$t still missing after install"; done
  fi
  ok "all tools present"

  TS=$(date -u +%Y%m%d-%H%M%S); WORK="$WORK_ROOT/txc026-$TS"; SRC="$WORK/src"
  mkdir -p "$WORK/patches" || die "cannot create $WORK"

  say "fetching the code ($TAG)"
  git clone -q --branch "$TAG" "$REPO" "$SRC" 2>&1 | tail -2
  HEADC=$(git -C "$SRC" rev-parse HEAD 2>/dev/null)
  [ "$HEADC" = "$TAG_COMMIT" ] || die "tag $TAG is $HEADC, expected $TAG_COMMIT"
  ok "commit ${HEADC:0:7}"

  say "fetching and checking the patches"
  cat > "$WORK/recount.py" <<'PY'
#!/usr/bin/env python3
"""Rewrite each hunk header's line counts from the hunk body. Never changes patch content."""
import re,sys
L=open(sys.argv[1]).read().split("\n")
if L and L[-1]=="": L.pop()
out=[];i=0;fixed=0
while i<len(L):
    m=re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$",L[i])
    if not m: out.append(L[i]); i+=1; continue
    j=i+1;o=n=0;body=[]
    while j<len(L) and not L[j].startswith("@@ ") and not L[j].startswith("diff --git"):
        l=L[j]
        if l=="": l=" "
        c=l[0]
        if c=="+": n+=1
        elif c=="-": o+=1
        elif c==" ": o+=1;n+=1
        body.append(l); j+=1
    h="@@ -%s,%d +%s,%d @@%s"%(m.group(1),o,m.group(2),n,m.group(3))
    if h!=L[i]: fixed+=1
    out.append(h); out+=body; i=j
open(sys.argv[2],"w").write("\n".join(out)+"\n")
print("hunk line-counts corrected:",fixed)
PY
  for p in $PATCHES; do
    curl -fsSL "$PATCH_BASE/$p.patch" -o "$WORK/patches/$p.orig.patch" || die "download of $p.patch failed"
    head -1 "$WORK/patches/$p.orig.patch" | grep -q '^diff --git' || die "$p.patch does not look like a patch"
    echo "  $p: sha256 $(sha256sum "$WORK/patches/$p.orig.patch" | cut -c1-16)"
    echo -n "  $p: "; python3 "$WORK/recount.py" "$WORK/patches/$p.orig.patch" "$WORK/patches/$p.patch" || die "recount failed"
  done
  echo "  (the published Send To Many patch has two wrong line counts in its headers; correcting them changes no code)"
  for p in $PATCHES; do
    ( cd "$SRC" && patch -p1 --dry-run -s < "$WORK/patches/$p.patch" ) || die "$p.patch does not apply cleanly to $TAG"
    ( cd "$SRC" && patch -p1 -s < "$WORK/patches/$p.patch" ) || die "$p.patch failed while applying"
    ok "applied $p"
  done
  ( cd "$SRC" && git add -A && git -c user.name=pool -c user.email=pool@honest.money commit -q -m "TXC 0.26 pool candidate: $TAG + $PATCHES (no block-all-mining)" && git tag "txc026-pool-$TS" )
  echo "  files changed vs $TAG: $(git -C "$SRC" diff --name-only "$TAG" | wc -l)"

  mkdir -p "$ARCHIVE_DIR"
  tar -C "$WORK" -czf "$ARCHIVE_DIR/txc026-source-$TS.tgz" src patches recount.py && ok "source archive: $ARCHIVE_DIR/txc026-source-$TS.tgz"

  J=$(pick_jobs)
  cat > "$WORK/build.env" <<ENV
WORK=$WORK
SRC=$SRC
J=$J
ENV
  cat > "$WORK/txc026-run-build.sh" <<'INNER'
#!/usr/bin/env bash
# txc026-run-build  (background worker)
set -uo pipefail
. "$1/build.env"
cd "$SRC"
rm -f "$WORK/BUILD-DONE" "$WORK/BUILD-FAILED"
stamp(){ echo "[$(date -u +%T)] $*"; }
fail(){ stamp "FAILED: $*"; echo "$*" > "$WORK/BUILD-FAILED"; exit 1; }
RUN="nice -n 19 ionice -c3"
stamp "step 1/4: dependencies (the longest step, 20-60 minutes)"
$RUN make -C depends NO_QT=1 -j"$J" || fail "dependencies did not build"
SITE=$(ls -d "$SRC"/depends/*/share/config.site 2>/dev/null | head -1)
[ -n "$SITE" ] || fail "dependencies built but config.site not found"
stamp "step 2/4: autogen"
./autogen.sh || fail "autogen"
stamp "step 3/4: configure (NO --enable-feature flag: mining stays ON)"
CONFIG_SITE="$SITE" ./configure --enable-wallet --with-gui=no --disable-tests --disable-bench --disable-man || fail "configure"
stamp "step 4/4: compile"
$RUN make -j"$J" || fail "compile"
[ -x src/texitcoind ] && [ -x src/texitcoin-cli ] || fail "binaries missing after compile"
{
  echo "built:   $(date -u +%FT%TZ)"
  echo "commit:  $(git rev-parse HEAD)  tag $(git describe --tags --abbrev=0 2>/dev/null)"
  echo "daemon:  $(sha256sum src/texitcoind | cut -d' ' -f1)"
  echo "cli:     $(sha256sum src/texitcoin-cli | cut -d' ' -f1)"
} > "$WORK/BUILD-DONE"
stamp "BUILD DONE"
INNER
  chmod +x "$WORK/txc026-run-build.sh"
  echo "$WORK" > "$POINTER"
  nohup "$WORK/txc026-run-build.sh" "$WORK" > "$WORK/build.log" 2>&1 < /dev/null &
  sleep 2
  say "build started in the background"
  echo "  folder:  $WORK"
  echo "  jobs:    $J (lowest CPU priority, so the pool keeps priority)"
  echo "  log:     $WORK/build.log"
  echo "  The live node and stratum are untouched. It is safe to close this window."
  echo "  Check progress any time (read-only):"
  echo "    curl -fsSL \"https://pool.honest.money/install/txc-026-build.sh?v=\$(date +%s)\" | sudo bash -s STATUS"
}

# ---------------------------------------------------------------- STATUS
do_status(){
  WORK=$(latest_work); [ -n "$WORK" ] && [ -d "$WORK" ] || die "no build folder found. Run BUILD first."
  echo "  folder: $WORK"
  if [ -f "$WORK/BUILD-DONE" ]; then
    say "BUILD FINISHED"; cat "$WORK/BUILD-DONE"
    echo; echo "Next: ... | sudo bash -s TEST"
  elif [ -f "$WORK/BUILD-FAILED" ]; then
    say "BUILD FAILED: $(cat "$WORK/BUILD-FAILED")"
    echo "  last 25 log lines:"; tail -25 "$WORK/build.log" | cut -c1-200 | sed 's/^/    /'
    echo; echo "Paste this output to me."
  elif pgrep -f "txc026-run-build" >/dev/null; then
    say "STILL BUILDING"
    grep -E '^\[[0-9:]+\] step' "$WORK/build.log" | tail -1
    echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)   memory free: $(mem_avail_gb) GB"
    echo "  last log line: $(tail -1 "$WORK/build.log" | cut -c1-160)"
  else
    say "NOT RUNNING and no result file"
    echo "  last 15 log lines:"; tail -15 "$WORK/build.log" | cut -c1-200 | sed 's/^/    /'
  fi
}

# ---------------------------------------------------------------- TEST
do_test(){
  WORK=$(latest_work); [ -n "$WORK" ] && [ -f "$WORK/BUILD-DONE" ] || die "no finished build. Run STATUS."
  SRC="$WORK/src"; BIN="$SRC/src/texitcoind"; CLI="$SRC/src/texitcoin-cli"
  D="$WORK/regtest-data"; RPCP=38999; P2PP=38998
  C(){ "$CLI" -regtest -datadir="$D" -rpcport=$RPCP -rpcuser=t -rpcpassword=t "$@"; }
  for p in $RPCP $P2PP; do ss -ltn 2>/dev/null | grep -q ":$p " && die "port $p already in use"; done
  FAILS=0
  chk(){ if [ "$1" = ok ]; then ok "$2"; else bad "$2"; FAILS=$((FAILS+1)); fi; }

  say "new program"
  "$BIN" --version 2>&1 | head -2 | sed 's/^/  /'
  sha256sum "$BIN" | cut -c1-16 | sed 's/^/  sha256 /'

  say "starting a PRIVATE test chain (own ports $P2PP/$RPCP, own folder, no network)"
  rm -rf "$D"; mkdir -p "$D"
  "$BIN" -regtest -datadir="$D" -port=$P2PP -rpcport=$RPCP -rpcuser=t -rpcpassword=t -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
    -listen=0 -dnsseed=0 -discover=0 -connect=0 -fallbackfee=0.0001 -daemon >/dev/null 2>&1
  trap 'C stop >/dev/null 2>&1' EXIT
  up=0; for i in $(seq 1 60); do C getblockcount >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
  [ $up = 1 ] && chk ok "test node started" || { chk bad "test node did not start"; tail -15 "$D/regtest/debug.log" 2>/dev/null | sed 's/^/    /'; exit 1; }

  say "mining commands exist (the check we missed on 3 Oct)"
  for m in getblocktemplate submitblock createauxblock submitauxblock; do
    r=$(C help "$m" 2>&1 | head -1)
    case "$r" in *"not found"*|*"nknown command"*|*"error code"*) chk bad "$m -> $r" ;; *) chk ok "$m present" ;; esac
  done
  r=$(C help omni_sendtomany 2>&1 | head -1)
  case "$r" in *"not found"*|*"nknown command"*|*"error code"*) chk bad "omni_sendtomany -> $r" ;; *) chk ok "omni_sendtomany present (Send To Many)" ;; esac

  say "mining 220 test blocks"
  C createwallet t >/dev/null 2>&1
  ADDR=$(C -rpcwallet=t getnewaddress 2>/dev/null || C getnewaddress 2>/dev/null)
  [ -n "$ADDR" ] && chk ok "test address $ADDR" || chk bad "could not get a test address"
  GEN=$(C generatetoaddress 220 "$ADDR" 2>&1 | head -c 300)
  H=$(C getblockcount 2>&1)
  [ "$H" = 220 ] && chk ok "chain height $H" || { chk bad "height is '$H' after generate: $GEN"; }

  say "smoother difficulty switches on at test height 150"
  python3 - "$CLI" "$D" "$RPCP" <<'PY'
import subprocess,sys,json
cli,d,port=sys.argv[1:4]
def c(*a): return subprocess.run([cli,"-regtest","-datadir="+d,"-rpcport="+port,"-rpcuser=t","-rpcpassword=t",*a],capture_output=True,text=True).stdout.strip()
diffs={}
for h in range(1,221):
    try: diffs[h]=json.loads(c("getblock",c("getblockhash",str(h))))["difficulty"]
    except Exception: pass
for h in (1,100,149,150,151,152,175,200,220):
    print("  height %3d  difficulty %s"%(h,diffs.get(h)))
before=set(diffs[h] for h in range(1,150) if h in diffs)
after=set(diffs[h] for h in range(151,221) if h in diffs)
print("  distinct difficulties, heights 1-149 (old rule, no retarget on test chain): %d"%len(before))
print("  distinct difficulties, heights 151-220 (smoother rule, every block):        %d"%len(after))
sys.exit(0 if (len(before)==1 and len(after)>=5) else 3)
PY
  [ $? = 0 ] && chk ok "difficulty flat before 150, changing every block after" || chk bad "difficulty did not behave as expected"

  say "pool-style work requests"
  r=$(C getblocktemplate '{"rules":["segwit"]}' 2>&1 | head -c 200)
  case "$r" in *"not found"*) chk bad "getblocktemplate: $r" ;; *'"height"'*|*'"version"'*) chk ok "getblocktemplate returns a job" ;; *) warn "getblocktemplate said: $r" ;; esac
  r=$(C createauxblock "$ADDR" 2>&1 | head -c 300)
  case "$r" in *'"hash"'*) chk ok "createauxblock returns a merged-mining job" ;; *"not found"*) chk bad "createauxblock: $r" ;; *) chk bad "createauxblock said: $r" ;; esac

  say "result"
  C stop >/dev/null 2>&1; trap - EXIT
  if [ "$FAILS" = 0 ]; then
    echo "  ALL TESTS PASSED. The live node and pool were not touched."
    echo "  Candidate: $BIN"
    cat "$WORK/BUILD-DONE" | sed 's/^/  /'
  else
    echo "  $FAILS TEST(S) FAILED. Paste this output to me. Nothing live was changed."
  fi
}

case "$MODE" in
  CHECK)  do_check ;;
  BUILD)  do_build ;;
  STATUS) do_status ;;
  TEST)   do_test ;;
  *) die "unknown mode $MODE (use CHECK, BUILD, STATUS or TEST)" ;;
esac
