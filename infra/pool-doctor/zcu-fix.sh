#!/usr/bin/env bash
# zcu-fix.sh v2 -- fixes the two confirmed ZCU blockers. DRY RUN by default.
#
#   inspect:  curl -fsSL https://pool.honest.money/install/zcu-fix.sh | sudo bash
#   apply:    curl -fsSL https://pool.honest.money/install/zcu-fix.sh | sudo bash -s CONFIRM_FIX
#
# Blocker A (why ZCU has ZERO aux submits):
#   stratum's coin-refresh loop calls getblocktemplate on the ZCU coind every ~22s.
#   The adapter has no handler for it, so it passes it through to geth, which is an
#   EVM node and answers -32601. yiimp logs "Zero Chill Units error getblocktemplate
#   result" and drops ZCU from the aux chain list -> no work, no submits, no blocks
#   since height 16300 (8 Jul). Meanwhile getauxblock/createauxblock work perfectly.
#   Fix: teach the adapter to synthesize a bitcoind-shaped getblocktemplate from
#   scrypt_createAuxBlock + the real geth head. Adapter-only: stratum is NOT touched
#   and NOT restarted, so LTC/DOGE/TXC/ISK cannot be affected.
#
# Blocker B (crash-loop every 60s):
#   zcu-mainnet-sync-blocks-to-yiimp.py requires  rpcencoding='GETH'  but the coins
#   row says 'POW' -> rows=0 -> ZCU_ROW_NOT_EXACTLY_ONE_OR_NOT_ENABLED.
#   Fix: relax the script's predicate. We deliberately do NOT edit the coins row --
#   stratum reads that same row and we are not risking a live coin definition.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
MODE="${1:-DRYRUN}"
TS=$(date -u '+%Y%m%d-%H%M%S')
ADAPTER=/opt/zcu-adapter/adapter.py
SYNC=/opt/zcu-pool-tools/zcu-mainnet-sync-blocks-to-yiimp.py
WORK=$(mktemp -d /tmp/zcu-fix.XXXXXX)
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-fix v2  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

##############################################################################
# A. adapter: add getblocktemplate (+ listsinceblock, getblockchaininfo)
##############################################################################
hr "A. adapter patch -- synthesize getblocktemplate from scrypt_createAuxBlock"
[ -f "$ADAPTER" ] || { echo "  MISSING $ADAPTER"; exit 1; }
cp "$ADAPTER" "$WORK/adapter.py.orig"
cp "$ADAPTER" "$WORK/adapter.py.new"

if grep -q 'ZCU_GBT_SHIM' "$ADAPTER"; then
  echo "  already patched (ZCU_GBT_SHIM present) -- adapter left alone"
  ADAPTER_NEEDS=0
else
  ADAPTER_NEEDS=1
  python3 - "$WORK/adapter.py.new" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p).read()

shim = '''
# ---- ZCU_GBT_SHIM ---------------------------------------------------------
# yiimp's coin-refresh loop insists on getblocktemplate even for an aux child.
# geth has no such method, so we build a bitcoind-shaped template out of the
# real chain head plus scrypt_createAuxBlock. Only the fields yiimp reads
# (height / target / bits / coinbasevalue / previousblockhash) need to be sane;
# actual merged-mining work still flows through createauxblock/submitauxblock.

def _target_to_bits(target_hex: str) -> str:
    t = int(target_hex, 16)
    if t <= 0:
        return "1d00ffff"
    b = t.to_bytes(32, "big").lstrip(b"\\x00")
    if not b:
        return "1d00ffff"
    if b[0] & 0x80:
        b = b"\\x00" + b
    size = len(b)
    head = (b + b"\\x00\\x00\\x00")[:3]
    return "%02x%s" % (size, head.hex())

async def m_getblocktemplate(rid, p):
    addr = os.environ.get("POOL_ADDR", "zcu-pool")
    aux = await geth_call("scrypt_createAuxBlock", [addr])
    if aux.get("error") or not aux.get("result"):
        return err(rid, -32603, "createAuxBlock: %s" % (aux.get("error"),))
    a = aux["result"]
    target = (a.get("target") or a.get("_target") or "").lower().replace("0x", "")
    target = target.rjust(64, "0")

    hb = await geth_call("eth_getBlockByNumber", ["latest", False])
    head = hb.get("result") or {}
    prev = (head.get("hash") or "0x" + "00" * 32)[2:]
    height = int(head.get("number", "0x0"), 16) + 1

    return ok(rid, {
        "version": 536870912,
        "previousblockhash": prev,
        "transactions": [],
        "coinbaseaux": {"flags": ""},
        "coinbasevalue": 0,
        "target": target,
        "mintime": int(time.time()) - 600,
        "mutable": ["time", "transactions", "prevblock"],
        "noncerange": "00000000ffffffff",
        "sigoplimit": 20000,
        "sizelimit": 1000000,
        "curtime": int(time.time()),
        "bits": _target_to_bits(target),
        "height": height,
        "chainid": a.get("chainid"),
        "auxhash": a.get("hash"),
        "coinbasetxn": {"data": ""},
    })

async def m_listsinceblock(rid, p):
    # payout scanner probe -- EVM payouts are handled by the block-sync job
    hb = await geth_call("eth_getBlockByNumber", ["latest", False])
    head = (hb.get("result") or {}).get("hash", "0x" + "00" * 32)[2:]
    return ok(rid, {"transactions": [], "lastblock": head})

async def m_getblockchaininfo(rid, p):
    r = await geth_call("eth_blockNumber")
    h = int(r["result"], 16) if r.get("result") else 0
    return ok(rid, {"chain": "main", "blocks": h, "headers": h,
                    "difficulty": 1, "verificationprogress": 1,
                    "initialblockdownload": False, "warnings": ""})
# ---- end ZCU_GBT_SHIM -----------------------------------------------------

'''

anchor = "# aliases yiimp/stratum sometimes uses"
assert anchor in s, "handler-table anchor not found"
s = s.replace(anchor, shim + anchor, 1)

entry = '    "submitauxblock":       m_submitauxblock,'
assert entry in s, "HANDLERS entry anchor not found"
s = s.replace(entry, entry + '''
    "getblocktemplate":     m_getblocktemplate,   # ZCU_GBT_SHIM
    "getblockchaininfo":    m_getblockchaininfo,  # ZCU_GBT_SHIM
    "listsinceblock":       m_listsinceblock,     # ZCU_GBT_SHIM''', 1)

open(p, "w").write(s)
print("  shim inserted")
PYEOF
  [ $? -eq 0 ] || { echo "  PATCH FAILED -- aborting, nothing written"; exit 1; }
  python3 -m py_compile "$WORK/adapter.py.new" || { echo "  SYNTAX ERROR -- aborting"; exit 1; }
  echo "  python syntax OK"
  diff -u "$WORK/adapter.py.orig" "$WORK/adapter.py.new" | head -90
fi

##############################################################################
# B. block-sync predicate
##############################################################################
hr "B. block-sync patch -- drop the rpcencoding='GETH' predicate"
if [ -f "$SYNC" ]; then
  cp "$SYNC" "$WORK/sync.orig"; cp "$SYNC" "$WORK/sync.new"
  sed -i "s/ and rpcencoding='GETH'//g" "$WORK/sync.new"
  if diff -q "$WORK/sync.orig" "$WORK/sync.new" >/dev/null; then
    echo "  no change needed (predicate already absent)"; SYNC_NEEDS=0
  else
    SYNC_NEEDS=1
    diff -u "$WORK/sync.orig" "$WORK/sync.new"
    python3 -m py_compile "$WORK/sync.new" && echo "  python syntax OK"
  fi
else
  SYNC_NEEDS=0; echo "  $SYNC missing"
fi

##############################################################################
if [ "$MODE" != "CONFIRM_FIX" ]; then
  echo
  echo "DRY RUN -- nothing written."
  echo "Re-run with:  curl -fsSL https://pool.honest.money/install/zcu-fix.sh | sudo bash -s CONFIRM_FIX"
  exit 0
fi

hr "APPLYING"
if [ "${ADAPTER_NEEDS:-0}" = "1" ]; then
  cp "$ADAPTER" "/var/backups/zcu-adapter.py.$TS"
  install -m 0755 "$WORK/adapter.py.new" "$ADAPTER"
  systemctl restart zcu-adapter
  echo "  adapter patched (backup /var/backups/zcu-adapter.py.$TS) + restarted"
fi
if [ "${SYNC_NEEDS:-0}" = "1" ]; then
  cp "$SYNC" "/var/backups/zcu-sync-blocks.py.$TS"
  install -m 0755 "$WORK/sync.new" "$SYNC"
  echo "  block-sync patched (backup /var/backups/zcu-sync-blocks.py.$TS)"
fi

sleep 3
hr "verify: adapter now answers getblocktemplate"
curl -s -m 10 -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getblocktemplate","params":[{}]}' \
  http://127.0.0.1:8749/ | head -c 700; echo

hr "verify: block-sync"
systemctl start zcu-mainnet-yiimp-block-sync 2>/dev/null
journalctl -u zcu-mainnet-yiimp-block-sync -n 8 --no-pager | sed 's/^/   /'

hr "next"
cat <<'EOT'
  stratum re-polls ZCU every ~22s -- within a minute the log should stop saying
  "Zero Chill Units error getblocktemplate result" and ZCU should start appearing
  in aux submits:

    tail -f /var/log/stratum/debug.log | grep -i 'zero chill\|ZCU'
    tail -n 20000 /var/stratum/scrypt.log | grep -i 'aux submit' \
      | grep -oiE '\b(doge|txc|isk|zcu)\b' | sort | uniq -c

  ZCU targets ~180s block spacing, so first block should land within a few minutes.
EOT
echo "done."
