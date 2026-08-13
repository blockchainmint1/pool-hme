#!/usr/bin/env bash
# zcu-lab.sh -- ZCU merged-mining research bench. TOUCHES NOTHING LIVE.
#
#   curl -fsSL https://pool.honest.money/install/zcu-lab.sh | sudo bash
#   curl -fsSL https://pool.honest.money/install/zcu-lab.sh | sudo bash -s GRIND
#
# Hard guarantees:
#   * talks ONLY to geth on 127.0.0.1:8747, never to the adapter, never to stratum
#   * REFUSES to run if the ZCU adapter is listening (that is the 13 Aug crash path)
#   * writes no files outside /tmp, restarts no services, edits no config, no DB writes
#
# Goal: answer the one question that blocks ZCU --
#   what exactly does scrypt_submitAuxBlock want, and why does it say
#   "invalid auxpow parent work"?
#
# The 13 Aug outage happened because we let stratum discover the answer for us,
# in production, with 1200 rigs attached. We do it here instead.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-PROBE}"
GETH=${GETH_PORT:-8747}
ADAPTER_PORT=${ADAPTER_PORT:-8749}
UNIT=stratum-aws-scrypt
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-lab v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

##############################################################################
hr "0. safety interlock"
##############################################################################
if ss -ltn 2>/dev/null | grep -q ":$ADAPTER_PORT"; then
  echo "  REFUSING TO RUN: the ZCU adapter is listening on :$ADAPTER_PORT."
  echo "  While it answers RPC, stratum keeps ZCU in the live aux rotation and a"
  echo "  failed aux submit deadlocks the WHOLE scrypt stratum (13 Aug 2026)."
  echo "  Disarm first:   sudo pkill -f '/opt/zcu-adapter/adapter.py'"
  exit 1
fi
echo "  adapter down, ZCU out of the aux rotation -- safe to experiment"
R0=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts at start = $R0  (must be unchanged when we finish)"

G() { # G <method> [params-json]
  curl -s -m 15 -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" \
    "http://127.0.0.1:$GETH/" 2>&1
}
SHOW() { printf '  %-28s %s\n' "$1" "$(G "$1" "${2:-[]}" | tr -d '\n' | head -c 320)"; }

##############################################################################
hr "1. what chain are we actually talking to?"
##############################################################################
SHOW eth_blockNumber
SHOW eth_chainId
SHOW net_version
SHOW eth_mining
SHOW eth_coinbase
SHOW eth_getWork

##############################################################################
hr "2. the merged-mining RPC surface"
##############################################################################
COINBASE=$(G eth_coinbase | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
COINBASE=${COINBASE:-0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe}
echo "  using coinbase $COINBASE"
SHOW scrypt_createAuxBlock "[\"$COINBASE\"]"
SHOW scrypt_getAuxBlock    "[\"$COINBASE\"]"
SHOW getAuxBlock           "[\"$COINBASE\"]"
SHOW scrypt_getWork
SHOW rpc_modules

##############################################################################
hr "3. characterise the VALIDATOR -- deliberately bad submits, one at a time"
##############################################################################
echo "  Each of these is expected to FAIL. We are cataloguing the exact error"
echo "  string for each failure class so we can tell which one production hit."
AUX=$(G scrypt_createAuxBlock "[\"$COINBASE\"]")
AUXHASH=$(echo "$AUX" | sed -n 's/.*"hash": *"\([0-9a-fx]*\)".*/\1/p')
echo "  live aux hash = ${AUXHASH:-<none>}"
probe() { printf '  %-34s -> %s\n' "$1" \
  "$(G scrypt_submitAuxBlock "$2" | tr -d '\n' | head -c 260)"; }
probe "empty params"            '[]'
probe "hash only"               "[\"${AUXHASH:-0x00}\"]"
probe "hash + empty auxpow"     "[\"${AUXHASH:-0x00}\",\"\"]"
probe "hash + junk auxpow"      "[\"${AUXHASH:-0x00}\",\"deadbeef\"]"
probe "unknown hash + junk"     '["0x0000000000000000000000000000000000000000000000000000000000000001","deadbeef"]'
echo
echo "  >> Compare these strings with the production failure:"
echo "     'ERROR Zero Chill Units scrypt: invalid auxpow parent work'"
echo "     Whichever probe reproduces it tells us WHICH field stratum got wrong."

##############################################################################
hr "4. the target -- can a valid parent even be produced?"
##############################################################################
python3 - "$AUX" <<'PY'
import sys, json, re
raw = sys.argv[1]
try:
    d = json.loads(raw).get("result") or {}
except Exception:
    m = re.search(r'"target":\s*"([0-9a-fx]+)"', raw)
    d = {"target": m.group(1)} if m else {}
t = (d.get("target") or "").replace("0x", "")
if not t:
    print("  could not read target from createAuxBlock"); sys.exit(0)
tgt = int(t, 16)
print(f"  target        0x{t}")
print(f"  chainid       {d.get('chainid')}")
print(f"  height        {d.get('height')}")
print(f"  coinbasevalue {d.get('coinbasevalue')}")
if tgt <= 0:
    print("  target is zero -- unmineable"); sys.exit(0)
diff1 = 0x00000000FFFF0000000000000000000000000000000000000000000000000000
print(f"  difficulty    ~{diff1/tgt:,.0f}")
hashes = (1 << 256) / tgt
print(f"  expected hashes/block ~{hashes:,.0f}")
print(f"  a single CPU core (~40 kH/s scrypt) would need ~{hashes/40000/86400:,.1f} days")
print(f"  the live fleet (~19 TH/s) needs ~{hashes/19e12:,.2f} s")
print()
print("  => If the CPU figure is days, we CANNOT grind a real parent here; we must")
print("     validate the auxpow BLOB FORMAT instead (section 3) and only then let")
print("     the fleet produce the work.")
PY

##############################################################################
hr "5. how does geth validate the parent? (source / config on disk)"
##############################################################################
for d in /opt/zcu-mainnet /opt/zcu-pool-tools /opt/zcu-adapter; do
  [ -d "$d" ] && echo "  -- $d" && ls -la "$d" 2>/dev/null | head -12 | sed 's/^/     /'
done
grep -rl 'invalid auxpow parent work' /opt /usr/local 2>/dev/null | head -5 | sed 's/^/  match: /'
echo "  (a match above is the exact validator -- read it and we have the answer)"

##############################################################################
if [ "$MODE" = "GRIND" ]; then
hr "6. GRIND -- try to mine one real ZCU aux block on this CPU"
python3 - "$AUX" <<'PY'
import sys, json, re, hashlib, struct, time, os
raw = sys.argv[1]
try: d = json.loads(raw).get("result") or {}
except Exception: d = {}
t = (d.get("target") or "").replace("0x","")
if not t:
    print("  no target -- cannot grind"); sys.exit(0)
tgt = int(t,16)
auxhash = (d.get("hash") or "").replace("0x","")
if not auxhash:
    print("  no aux hash -- cannot grind"); sys.exit(0)

# Litecoin-style parent header: 80 bytes, scrypt(N=1024,r=1,p=1) as PoW.
# hashlib.scrypt with those parameters IS litecoin's PoW function.
def scrypt_pow(header: bytes) -> int:
    h = hashlib.scrypt(header, salt=header, n=1024, r=1, p=1, dklen=32,
                       maxmem=256*1024*1024)
    return int.from_bytes(h, "little")

merkle = bytes.fromhex(auxhash)[::-1]
prev   = os.urandom(32)
ver, bits, ts = 0x20000000, 0x1e0ffff0, int(time.time())
start, tries = time.time(), 0
found = None
while time.time() - start < 30:
    for nonce in range(tries, tries + 20000):
        hdr = struct.pack("<I32s32sIII", ver, prev, merkle, ts, bits, nonce)
        if scrypt_pow(hdr) < tgt:
            found = (nonce, hdr.hex()); break
    tries += 20000
    if found: break
rate = tries / max(time.time()-start, 0.001)
print(f"  tried {tries:,} nonces at ~{rate:,.0f} H/s over 30s")
if found:
    print(f"  FOUND a qualifying parent header, nonce={found[0]}")
    print(f"  header={found[1]}")
    print("  -> build the auxpow blob from this and submit manually")
else:
    need = (1<<256)/tgt
    print(f"  no luck -- need ~{need:,.0f} hashes, i.e. ~{need/max(rate,1)/86400:,.1f} CPU-days")
    print("  CONFIRMED: we cannot produce parent work here. Format validation only.")
PY
fi

##############################################################################
hr "7. did we disturb production?"
##############################################################################
R1=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts start=$R0 now=$R1"
if [ "$R0" = "$R1" ]; then
  echo "  CLEAN -- stratum never noticed. LTC/DOGE/TXC/ISK untouched."
else
  echo "  !! stratum restarted during this run -- investigate immediately"
fi
echo
echo "  Now run the canary to confirm mining is still healthy:"
echo "    curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash"
