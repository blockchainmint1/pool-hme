#!/usr/bin/env bash
# txc-swap-0261.sh -- swap the live TXC node on the pool box to the PRIVATE
# MINING build of v0.26.1 (/root/txc-MINING-PRIVATE-amd-ubuntu22-v0.26.1.zip).
#
# Never touches the stratum, LTC, DOGE, ISK or ZCU. Only the TXC node program.
#
#   1. CHECK            read-only. Unpacks the zip into a staging folder, proves the
#                       new program runs on this box, has the mining commands, and
#                       finds how the live TXC node is started.
#   2. SWAP CONFIRM     backs up the old programs, stops the TXC node, puts the new
#                       programs in the same place, starts it, checks mining works.
#   3. VERIFY           read-only. Version, height, peers, mining commands.
#   4. ROLLBACK CONFIRM puts the old programs back. Refused after block 364,100.
#
#   curl -fsSL "https://pool.honest.money/install/txc-swap-0261.sh?v=$(date +%s)" | sudo bash
#   ... | sudo bash -s SWAP CONFIRM
#
# VERSION LOG
#   v1  2026-10-05  First cut.
VER="v2"
set -uo pipefail
MODE="${1:-CHECK}"; CONF="${2:-}"
ZIP=/root/txc-MINING-PRIVATE-amd-ubuntu22-v0.26.1.zip
ZIP_SHA=7b339bacf9780e6eb15a8118b6b152094f637f6ac990099ec3d5fd0513f7d2fe
STAGE=/root/txc0261-stage
STATE=/root/txc0261.state
BK_ROOT=/var/backups/txc-binaries
GOLIVE=364100
CHECKPOINT_H=362494
BINS="texitcoind texitcoin-cli texitcoin-tx texitcoin-wallet"

say(){ echo; echo "===== $*"; }
ok(){ echo "  OK    $*"; }
warn(){ echo "  WARN  $*"; }
bad(){ echo "  FAIL  $*"; FAILS=$((FAILS+1)); }
die(){ echo; echo "STOPPED: $*"; exit 1; }
FAILS=0
[ "$(id -u)" = 0 ] || die "run with sudo"
echo "txc-swap-0261 $VER  mode=$MODE  $(date -u +%FT%TZ)"

# ---------- find the live node
find_live(){
  PID=$(pgrep -x texitcoind | head -1)
  [ -n "$PID" ] || return 1
  EXE=$(readlink -f /proc/$PID/exe | sed 's/ (deleted)$//')
  BINDIR=$(dirname "$EXE")
  RUNUSER=$(ps -o user= -p "$PID" | tr -d ' ')
  mapfile -d '' ARGS < /proc/$PID/cmdline
  CLIARGS=()
  for a in "${ARGS[@]:1}"; do
    case "$a" in -datadir=*|-conf=*|-rpcport=*|-rpcuser=*|-rpcpassword=*|-rpccookiefile=*) CLIARGS+=("$a");; esac
  done
  UNIT=$(grep -o '[^/]*\.service' /proc/$PID/cgroup 2>/dev/null | head -1)
  case "$UNIT" in session-*|user@*|"") UNIT="";; esac
  return 0
}
LC(){ sudo -u "$RUNUSER" "$BINDIR/texitcoin-cli" "${CLIARGS[@]}" "$@"; }

show_live(){
  echo "  pid:      $PID   user: $RUNUSER"
  echo "  program:  $EXE"
  echo "  started:  ${ARGS[*]}"
  echo "  service:  ${UNIT:-none (started by hand / script)}"
  echo "  version:  $("$EXE" --version 2>/dev/null | head -1)"
  echo "  height:   $(LC getblockcount 2>&1 | head -1)   peers: $(LC getconnectioncount 2>&1 | head -1)"
}

mining_ok(){ # $1 = label ; uses LC
  local r; r=$(LC getblocktemplate '{"rules":["mweb","segwit"]}' 2>&1 | head -c 300)
  case "$r" in *'"height"'*) ok "$1: getblocktemplate gives a job"; return 0;; *) bad "$1: getblocktemplate -> $(echo "$r"|head -1)"; return 1;; esac
}

# ---------------------------------------------------------------- CHECK
do_check(){
  say "the downloaded file"
  [ -f "$ZIP" ] || die "$ZIP not found"
  S=$(sha256sum "$ZIP" | cut -d' ' -f1)
  [ "$S" = "$ZIP_SHA" ] && ok "fingerprint matches ($S)" || bad "fingerprint is $S, expected $ZIP_SHA"
  command -v unzip >/dev/null || { apt-get install -y -qq unzip >/dev/null 2>&1; }
  rm -rf "$STAGE"; mkdir -p "$STAGE"; unzip -q "$ZIP" -d "$STAGE" || die "unzip failed"
  NB=$(dirname "$(find "$STAGE" -type f -name texitcoind | head -1)")
  [ -x "$NB/texitcoind" ] || die "no texitcoind inside the zip"
  for b in $BINS; do [ -f "$NB/$b" ] && { chmod 755 "$NB/$b"; ok "$b  $(sha256sum "$NB/$b"|cut -c1-16)"; } || warn "$b not in zip"; done

  say "does the new program run on this box?"
  . /etc/os-release; echo "  box OS: $PRETTY_NAME"
  M=$(ldd "$NB/texitcoind" 2>&1 | grep -i "not found")
  [ -z "$M" ] && ok "all system libraries present" || bad "missing libraries: $M"
  V=$("$NB/texitcoind" --version 2>&1 | head -1); echo "  $V"
  case "$V" in *0.26.1*) ok "version 0.26.1";; *GLIBC*|*error*) bad "program will not start here";; *) warn "version line does not say 0.26.1";; esac

  say "private test chain with the NEW program (own ports, own folder)"
  D="$STAGE/regtest"; P=38997; R=38996; mkdir -p "$D"
  T(){ "$NB/texitcoin-cli" -regtest -datadir="$D" -rpcport=$R -rpcuser=t -rpcpassword=t "$@"; }
  "$NB/texitcoind" -regtest -datadir="$D" -port=$P -rpcport=$R -rpcuser=t -rpcpassword=t -rpcbind=127.0.0.1 \
     -rpcallowip=127.0.0.1 -listen=0 -dnsseed=0 -connect=0 -fallbackfee=0.0001 -daemon >/dev/null 2>&1
  up=0; for i in $(seq 1 60); do T getblockcount >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
  if [ $up = 1 ]; then
    ok "test node started"
    for m in getblocktemplate submitblock createauxblock submitauxblock omni_sendtomany; do
      r=$(T help $m 2>&1 | head -1)
      case "$r" in *"not found"*|*"nknown command"*|*"error code"*) bad "$m missing";; *) ok "$m present";; esac
    done
    T createwallet t >/dev/null 2>&1; A=$(T -rpcwallet=t getnewaddress 2>/dev/null)
    T generatetoaddress 5 "$A" >/dev/null 2>&1
    r=$(T createauxblock "$A" 2>&1 | head -c 200)
    case "$r" in *'"hash"'*) ok "createauxblock returns a merged-mining job";; *) bad "createauxblock: $r";; esac
    T stop >/dev/null 2>&1; sleep 3
  else
    bad "test node did not start"; tail -10 "$D/regtest/debug.log" 2>/dev/null | sed 's/^/    /'
  fi

  say "the live TXC node (read-only)"
  find_live || die "no running texitcoind found"
  show_live
  H=$(LC getblockcount 2>/dev/null)
  echo "  checkpoint block $CHECKPOINT_H on our chain: $(LC getblockhash $CHECKPOINT_H 2>&1 | head -1)"
  [ -n "$H" ] && echo "  blocks until go-live $GOLIVE: $((GOLIVE - H))  (~$(( (GOLIVE - H) * 3 / 60 )) hours)"
  r=$(LC getblocktemplate '{"rules":["mweb","segwit"]}' 2>&1 | head -c 120)
  case "$r" in *'"height"'*) echo "  live node mining commands: working";; *) echo "  live node mining commands: $(echo "$r"|head -1)";; esac
  for b in $BINS; do [ -e "$BINDIR/$b" ] && echo "  will replace $BINDIR/$b" || warn "$BINDIR/$b does not exist (will be added)"; done
  ls -l /usr/local/bin/texitcoin* 2>/dev/null | sed 's/^/  /'

  say "result"
  if [ "$FAILS" = 0 ]; then
    echo "$NB" > "$STATE"
    echo "  CHECK PASSED. Nothing was changed."
    echo "  Next (stops TXC for about a minute; stratum keeps running):"
    echo "    curl -fsSL \"https://pool.honest.money/install/txc-swap-0261.sh?v=\$(date +%s)\" | sudo bash -s SWAP CONFIRM"
  else
    rm -f "$STATE"; echo "  $FAILS problem(s). Do NOT swap. Paste this output to me."
  fi
}

stop_node(){
  if [ -n "$UNIT" ]; then systemctl stop "$UNIT"
  else LC stop >/dev/null 2>&1; fi
  for i in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || return 0; sleep 1; done
  return 1
}
start_node(){
  if [ -n "$UNIT" ]; then systemctl start "$UNIT"
  else
    local daemon=0; for a in "${ARGS[@]}"; do [ "$a" = "-daemon" ] || [ "$a" = "-daemon=1" ] && daemon=1; done
    if [ $daemon = 1 ]; then sudo -u "$RUNUSER" "$BINDIR/texitcoind" "${ARGS[@]:1}"
    else sudo -u "$RUNUSER" nohup "$BINDIR/texitcoind" "${ARGS[@]:1}" >/dev/null 2>&1 < /dev/null & fi
  fi
  for i in $(seq 1 180); do LC getblockcount >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

# ---------------------------------------------------------------- SWAP
do_swap(){
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  # Quick path (v2): the private test chain was already run elsewhere, so skip it.
  # Still checks the file fingerprint, unpacks it, and proves the program starts on this box.
  say "quick check of the downloaded file (no test chain)"
  [ -f "$ZIP" ] || die "$ZIP not found"
  S=$(sha256sum "$ZIP" | cut -d' ' -f1)
  [ "$S" = "$ZIP_SHA" ] || die "fingerprint is $S, expected $ZIP_SHA. Nothing changed."
  ok "fingerprint matches"
  command -v unzip >/dev/null || { apt-get install -y -qq unzip >/dev/null 2>&1; }
  rm -rf "$STAGE"; mkdir -p "$STAGE"; unzip -q "$ZIP" -d "$STAGE" || die "unzip failed. Nothing changed."
  NB=$(dirname "$(find "$STAGE" -type f -name texitcoind | head -1)")
  [ -f "$NB/texitcoind" ] || die "no texitcoind inside the zip. Nothing changed."
  for b in $BINS; do [ -f "$NB/$b" ] && chmod 755 "$NB/$b"; done
  M=$(ldd "$NB/texitcoind" 2>&1 | grep -i "not found")
  [ -z "$M" ] || die "missing system libraries: $M. Nothing changed."
  V=$("$NB/texitcoind" --version 2>&1 | head -1); echo "  $V"
  case "$V" in *0.26.1*) ok "version 0.26.1";; *) die "new program does not report 0.26.1 here. Nothing changed.";; esac
  find_live || die "no running texitcoind found"
  say "before"; show_live
  TS=$(date -u +%Y%m%dT%H%M%SZ); BK="$BK_ROOT/pre-0261-$TS"; mkdir -p "$BK"
  for b in $BINS; do [ -e "$BINDIR/$b" ] && cp -a "$(readlink -f "$BINDIR/$b")" "$BK/$b"; done
  { echo "BINDIR=$BINDIR"; echo "UNIT=$UNIT"; echo "RUNUSER=$RUNUSER"; printf 'ARGS=%q\n' "${ARGS[*]}"; } > "$BK/RESTORE-INFO"
  [ -n "$UNIT" ] && cp -a "/etc/systemd/system/$UNIT" "$BK/" 2>/dev/null
  (cd "$BK" && sha256sum * > SHA256SUMS 2>/dev/null)
  echo "$BK" > "$BK_ROOT/latest-pre-0261"
  ok "old programs saved in $BK"

  say "stopping TXC node"
  stop_node || die "TXC node did not stop within 5 minutes; nothing replaced. Paste this to me."
  ok "stopped"
  for b in $BINS; do [ -f "$NB/$b" ] && install -m755 "$NB/$b" "$BINDIR/$b"; done
  ok "new programs in $BINDIR"
  say "starting TXC node"
  if ! start_node; then
    bad "new node did not answer within 6 minutes -- putting the old one back"
    stop_node; for b in $BINS; do [ -f "$BK/$b" ] && install -m755 "$BK/$b" "$BINDIR/$b"; done
    start_node && echo "  old program running again." ; die "swap undone. Paste this output to me."
  fi
  find_live; show_live
  FAILS=0; mm=0
  for i in 1 2 3 4 5 6; do FAILS=0; mining_ok "new live node" >/tmp/txc0261.mining 2>&1 && { mm=1; break; }; sleep 10; done
  cat /tmp/txc0261.mining
  [ $mm = 1 ] || echo "  Mining commands did NOT answer. Paste this to me before doing anything else."
  echo; echo "  Stratum was NOT restarted; it picks the node back up by itself."
  echo "  Undo (only before block $GOLIVE):"
  echo "    curl -fsSL \"https://pool.honest.money/install/txc-swap-0261.sh?v=\$(date +%s)\" | sudo bash -s ROLLBACK CONFIRM"
  echo "  In 10 minutes run the canary and paste both outputs to me."
}

# ---------------------------------------------------------------- VERIFY
do_verify(){
  find_live || die "no running texitcoind found"; show_live; mining_ok "live node"
  r=$(LC help omni_sendtomany 2>&1 | head -1); case "$r" in *"not found"*|*"nknown"*) bad "omni_sendtomany missing";; *) ok "omni_sendtomany present";; esac
  echo "  checkpoint $CHECKPOINT_H: $(LC getblockhash $CHECKPOINT_H 2>&1|head -1)"
}

# ---------------------------------------------------------------- ROLLBACK
do_rollback(){
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  BK=$(cat "$BK_ROOT/latest-pre-0261" 2>/dev/null); [ -d "$BK" ] || die "no backup found"
  find_live || die "no running texitcoind found"
  H=$(LC getblockcount 2>/dev/null || echo 0)
  [ "$H" -ge "$GOLIVE" ] && die "chain is at $H, past go-live $GOLIVE. The old program would split off the network. Not rolling back."
  stop_node || die "node did not stop"
  for b in $BINS; do [ -f "$BK/$b" ] && install -m755 "$BK/$b" "$BINDIR/$b"; done
  start_node || die "old node did not answer. Paste this to me."
  show_live; echo "  rolled back from $BK"
}

case "$MODE" in
  CHECK) do_check;; SWAP) do_swap;; VERIFY) do_verify;; ROLLBACK) do_rollback;;
  *) die "use CHECK, SWAP CONFIRM, VERIFY or ROLLBACK CONFIRM";;
esac
