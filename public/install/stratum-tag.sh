#!/usr/bin/env bash
# stratum-tag.sh -- put our name in every block we find.
#
# Replaces the default yiimp coinbase tag "PoolMine.xyz" with "/honest.money/"
# (the text that block explorers read to say who mined a block).
#
# Steps, each a separate run, each safe to stop after:
#   1. CHECK    (default) read-only. Finds the source tree, shows where the old
#               tag lives, and decodes a LIVE mining job to prove today's tag
#               and that the coinbase layout is internally consistent.
#   2. BUILD    compiles a PATCHED COPY in /root/stratum-tag-<ts>/. Touches
#               nothing live. Saves a source archive.
#   3. INSTALL CONFIRM   full pool snapshot, keeps current binary as
#               /var/stratum/stratum.pre-tag, swaps, ONE restart, health check,
#               then decodes a live job to prove the new tag is in place.
#   4. VERIFY   read-only. Decodes a live job (tag + layout check).
#   5. ROLLBACK CONFIRM  puts stratum.pre-tag back + one restart.
#
#   curl -fsSL "https://pool.honest.money/install/stratum-tag.sh?v=$(date +%s)" | sudo bash
#   ... | sudo bash -s BUILD
#   ... | sudo bash -s INSTALL CONFIRM
#   ... | sudo bash -s VERIFY
#   ... | sudo bash -s ROLLBACK CONFIRM
#
# VERSION LOG
#   v1  2026-10-03  First cut. Builds on the socket-fix tree (SOCKETFIX-20261001).
VER="v1"
set -uo pipefail
MODE="${1:-CHECK}"; CONF="${2:-}"
LIVE=/var/stratum/stratum
BACKUP=/var/stratum/stratum.pre-tag
UNIT=stratum-aws-scrypt
WORK_ROOT=/root
ARCHIVE_DIR=/var/backups/stratum-source
OLD_TXT="PoolMine.xyz"; NEW_TXT="/honest.money/"
OLD_HEX="506f6f6c4d696e652e78797a"; NEW_HEX="2f686f6e6573742e6d6f6e65792f"
PAYOUT=LdSHVgxVWbP5kGKzmZMm8aEXe2wprwwr32

say(){ echo; echo "===== $*"; }
die(){ echo; echo "STOPPED: $*"; echo "Nothing live was changed."; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
echo "stratum-tag $VER  mode=$MODE  $(date -u +%FT%TZ)"

find_tree(){ # tree whose built binary == running binary
  LIVE_SHA=$(sha256sum "$LIVE" | cut -c1-12); MATCH=""
  local cands=""
  [ -f /root/stratum-fix.latest ] && cands="$(cat /root/stratum-fix.latest)"
  for d in $cands /root/stratum-fix-*; do
    [ -f "$d/stratum" ] && [ -f "$d/socket.cpp" ] || continue
    [ "$(sha256sum "$d/stratum" | cut -c1-12)" = "$LIVE_SHA" ] && { MATCH="$d"; break; }
  done
}

# Decode one live mining job: tag + full coinbase layout check.
live_job(){
python3 - "$PAYOUT" "$OLD_HEX" "$NEW_HEX" <<'PY'
import socket,json,sys,time
user,old,new=sys.argv[1:4]
def varint(b,i):
    n=b[i]
    if n<0xfd: return n,i+1
    if n==0xfd: return int.from_bytes(b[i+1:i+3],'little'),i+3
    if n==0xfe: return int.from_bytes(b[i+1:i+5],'little'),i+5
    return int.from_bytes(b[i+1:i+9],'little'),i+9
try:
    s=socket.create_connection(("127.0.0.1",3433),timeout=5)
except Exception as e:
    print("  could not connect to 127.0.0.1:3433:",e); sys.exit(2)
s.settimeout(3)
s.sendall(b'{"id":1,"method":"mining.subscribe","params":["tagcheck/1"]}\n')
s.sendall(('{"id":2,"method":"mining.authorize","params":["%s.tagcheck","x"]}\n'%user).encode())
buf=b""; end=time.time()+45; en1=None; en2=None; notify=None
while time.time()<end and notify is None:
    try: d=s.recv(65536)
    except socket.timeout: continue
    if not d: break
    buf+=d
    for line in buf.split(b"\n"):
        try: j=json.loads(line)
        except Exception: continue
        if j.get("id")==1 and j.get("result"): en1=j["result"][1]; en2=j["result"][2]
        if j.get("method")=="mining.notify": notify=j["params"]
s.close()
if not notify or en1 is None:
    print("  no mining.notify received within 45s. What the stratum did say:")
    for line in buf.split(b"\n")[:6]: print("   ", line[:300].decode(errors="replace"))
    if not buf: print("    (nothing at all)")
    sys.exit(2)
coinb1,coinb2=notify[2],notify[3]
tx=bytes.fromhex(coinb1+en1+"00"*int(en2)+coinb2)
ok=True
try:
    i=4; n,i=varint(tx,i); assert n==1,"vin count %d"%n
    i+=36; sl,i=varint(tx,i); script=tx[i:i+sl]; i+=sl
    i+=4; vo,i=varint(tx,i)
    for _ in range(vo):
        i+=8; l,i=varint(tx,i); i+=l
    i+=4
    ok=(i==len(tx))
    print("  coinbase: scriptSig %d bytes (limit 100), %d outputs, layout consumes %d of %d bytes -> %s"%(sl,vo,i,len(tx),"CONSISTENT" if ok else "BROKEN"))
except Exception as e:
    ok=False; script=b""; print("  coinbase layout check failed:",e)
h=script.hex()
tag="NEW (/honest.money/)" if new in h else ("OLD (PoolMine.xyz)" if old in h else "none found")
print("  scriptSig text:", "".join(chr(c) if 32<=c<127 else "." for c in script))
print("  tag in live job:", tag)
sys.exit(0 if ok else 3)
PY
}

case "$MODE" in
CHECK)
  say "1. running binary"
  ls -l "$LIVE"; sha256sum "$LIVE"
  systemctl show $UNIT -p ActiveEnterTimestamp -p NRestarts
  say "2. source tree that built it"
  find_tree
  [ -n "$MATCH" ] && echo "MATCH: $MATCH" || echo "NO MATCH among /root/stratum-fix-* (BUILD will refuse)"
  if [ -n "$MATCH" ]; then
    say "3. where the old tag lives in the source"
    grep -rnI --include='*.cpp' --include='*.h' -iE "$OLD_TXT|$OLD_HEX" "$MATCH" | cut -c1-200 || true
    say "4. how the coinbase length is worked out (should be computed, not fixed)"
    grep -nE "script_len|script1|script2" "$MATCH/coinbase.cpp" | head -25 | cut -c1-200
  fi
  say "5. a LIVE mining job right now (what miners are told to build blocks from)"
  live_job
  echo; echo "CHECK done. Nothing changed. Next: ... | sudo bash -s BUILD"
  ;;
BUILD)
  find_tree
  [ -n "$MATCH" ] || die "no source tree matches the running binary -- paste CHECK output to Lovable"
  TS=$(date -u +%Y%m%d-%H%M%S); W="$WORK_ROOT/stratum-tag-$TS"
  say "copying $MATCH -> $W (original tree untouched)"
  mkdir -p "$W"; cp -a "$MATCH/." "$W/" || die "copy failed"
  mkdir -p "$ARCHIVE_DIR"
  say "patching the copy"
  python3 - "$W" "$OLD_TXT" "$NEW_TXT" "$OLD_HEX" "$NEW_HEX" <<'PY' || die "patch failed"
import re,sys,os
root,ot,nt,oh,nh=sys.argv[1:6]
hits=0
for dp,dn,fn in os.walk(root):
    if any(x in dp for x in ("/secp256k1","/.git")): continue
    for f in fn:
        if not f.endswith((".cpp",".h")): continue
        p=os.path.join(dp,f)
        try: s=open(p,errors="surrogateescape").read()
        except Exception: continue
        out=[]; ch=False
        for line in s.split("\n"):
            new=line
            if re.search(re.escape(oh),line,re.I):
                new=re.sub(re.escape(oh),nh,new,flags=re.I)
                m=re.search(r'\[(\d+)\]\s*=\s*"',new)
                if m and int(m.group(1))<len(nh)+2: new=new.replace("[%s]"%m.group(1),"[64]",1)
            elif ot in line:
                new=line.replace(ot,nt)
            if new!=line: ch=True; hits+=1; print("  %s:\n     was: %s\n     now: %s"%(p,line.strip()[:150],new.strip()[:150]))
            out.append(new)
        if ch: open(p,"w",errors="surrogateescape").write("\n".join(out))
if hits==0: sys.exit("old tag not found in source")
print("  %d line(s) changed"%hits)
PY
  echo "TAG-20261003 $OLD_TXT -> $NEW_TXT" > "$W/TAG-PATCH.txt"
  say "building (in order, to avoid the link race)"
  cd "$W" || die "cd"
  rm -f stratum
  for sub in iniparser secp256k1; do [ -d $sub ] && { make -C $sub >/tmp/stag-$sub.log 2>&1 || die "make $sub failed (see /tmp/stag-$sub.log)"; }; done
  for sub in algos sha3; do [ -d $sub ] && { make -C $sub -j"$(nproc)" >/tmp/stag-$sub.log 2>&1 || die "make $sub failed (see /tmp/stag-$sub.log)"; }; done
  touch coinbase.cpp
  make -j1 >/tmp/stag-main.log 2>&1 || { tail -20 /tmp/stag-main.log; die "main build failed"; }
  [ -x stratum ] || die "no binary produced"
  [ "$(find stratum -mmin -10)" ] || die "binary is stale"
  C_NEW=$(grep -ac -e "$NEW_TXT" -e "$NEW_HEX" stratum); C_OLD=$(grep -ac -e "$OLD_TXT" -e "$OLD_HEX" stratum)
  echo "new binary contains new tag: $C_NEW   old tag: $C_OLD"
  [ "$C_NEW" -ge 1 ] || die "new tag not found inside the built binary"
  tar czf "$ARCHIVE_DIR/stratum-source-tag-$TS.tgz" --exclude='*.o' --exclude='*.a' -C "$WORK_ROOT" "stratum-tag-$TS" \
    && echo "source archive: $ARCHIVE_DIR/stratum-source-tag-$TS.tgz"
  echo "$W" > /root/stratum-tag.latest
  ls -l stratum; sha256sum stratum
  echo; echo "BUILD OK. Live mining untouched. Next (planned ~20s miner reconnect): ... | sudo bash -s INSTALL CONFIRM"
  ;;
INSTALL)
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  W=$(cat /root/stratum-tag.latest 2>/dev/null); [ -x "$W/stratum" ] || die "run BUILD first"
  [ -f "$W/TAG-PATCH.txt" ] || die "built tree is not the tag build"
  say "full pool snapshot first"
  curl -fsSL "https://pool.honest.money/install/pool-snapshot.sh?v=$(date +%s)" | bash -s SAVE || die "snapshot failed"
  [ -f "$BACKUP" ] || cp -a "$LIVE" "$BACKUP" || die "backup copy failed"
  echo "undo copy: $BACKUP  $(sha256sum "$BACKUP"|cut -c1-12)"
  say "swap + one restart"
  install -m755 "$W/stratum" "$LIVE.new" && mv -f "$LIVE.new" "$LIVE" || die "swap failed"
  systemctl restart $UNIT
  echo "waiting 60s for miners to reconnect..."; sleep 60
  say "health"
  systemctl is-active $UNIT; systemctl show $UNIT -p NRestarts -p ActiveEnterTimestamp
  echo "connections on 3433: $(ss -Htn state established '( sport = :3433 )' | wc -l)"
  say "live job: new tag + layout check"
  live_job; RC=$?
  echo
  if [ $RC -eq 0 ]; then echo "INSTALLED ($(sha256sum "$LIVE"|cut -c1-12)) and the live job looks right."
  else echo "WARNING: the live job check did not pass. Safest is to undo now:"; fi
  echo '  undo: curl -fsSL "https://pool.honest.money/install/stratum-tag.sh?v=$(date +%s)" | sudo bash -s ROLLBACK CONFIRM'
  ;;
VERIFY)
  say "live job"
  live_job
  ;;
ROLLBACK)
  [ "$CONF" = CONFIRM ] || die "add CONFIRM"
  [ -x "$BACKUP" ] || die "no $BACKUP found"
  cp -a "$LIVE" "$LIVE.tag-rolledback" 2>/dev/null
  install -m755 "$BACKUP" "$LIVE.new" && mv -f "$LIVE.new" "$LIVE" || die "restore failed"
  systemctl restart $UNIT; sleep 30
  systemctl is-active $UNIT; sha256sum "$LIVE"
  echo "ROLLED BACK to the pre-tag binary (still has the socket fix)."
  ;;
*) die "unknown mode $MODE" ;;
esac
