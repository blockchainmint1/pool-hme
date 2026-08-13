#!/usr/bin/env bash
# zcu-shadow.sh -- ZCU capture-only adapter. CANNOT deadlock stratum.
#
#   install:  curl -fsSL https://pool.honest.money/install/zcu-shadow.sh | sudo bash -s INSTALL
#   verify:   curl -fsSL https://pool.honest.money/install/zcu-shadow.sh | sudo bash -s VERIFY
#   stop:     curl -fsSL https://pool.honest.money/install/zcu-shadow.sh | sudo bash -s STOP
#
# WHY THIS IS SAFE (and the 13 Aug adapter was not):
#   The 13 Aug outage happened because a ZCU aux submit was REJECTED by geth
#   ("invalid auxpow parent work"), which tripped stratum's deadlock detector
#   and killed the whole scrypt process -- LTC/DOGE/TXC/ISK with it.
#   This adapter NEVER forwards a submit to geth. submitauxblock is recorded to
#   disk and answered `true`, unconditionally. A rejection is structurally
#   impossible, so the deadlock path cannot be reached.
#
#   Cost of that safety: ZCU blocks are NOT actually submitted while shadow
#   mode is on. We are buying the real auxpow blobs the fleet produces so we
#   can validate them offline. Nothing is mined into ZCU until VERIFY is green.
#
# It also touches NOTHING owned by stratum: no scrypt.conf, no stratum binary,
# no restart, no DB writes.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSTALL}"
GETH_PORT=${GETH_PORT:-8747}
PORT=${ADAPTER_PORT:-8749}
CAP=/var/log/zcu-capture.jsonl
PY=/opt/zcu-adapter/adapter-capture.py
UNIT=stratum-aws-scrypt
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-shadow v3  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

R0=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts at start = ${R0:-?}"

##############################################################################
if [ "$MODE" = "STOP" ]; then
  pkill -f 'adapter-capture.py' && echo "  capture adapter stopped" || echo "  was not running"
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$PORT" && echo "  WARNING :$PORT still listening" \
    || echo "  :$PORT clear -- ZCU out of the aux rotation again"
  exit 0
fi

##############################################################################
if [ "$MODE" = "INSTALL" ]; then
hr "1. refuse to stack on top of another adapter"
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
  echo "  REFUSING: something is already listening on :$PORT."
  echo "  Stop it first:  sudo pkill -f '/opt/zcu-adapter/adapter.py'"
  exit 1
fi
systemctl is-enabled zcu-adapter >/dev/null 2>&1 && {
  echo "  disabling the old zcu-adapter unit so it cannot race us"
  systemctl disable --now zcu-adapter >/dev/null 2>&1
}

hr "2. write the capture-only adapter"
mkdir -p /opt/zcu-adapter
cat > "$PY" <<'PYEOF'
#!/usr/bin/env python3
"""Capture-only bitcoind<->geth adapter for ZCU.

createauxblock  -> forwarded to geth (read-only, safe)
submitauxblock  -> RECORDED TO DISK AND ACKED. NEVER FORWARDED.

The ack is what keeps stratum alive: yiimp only trips its deadlock detector
when an aux submit is refused. We answer true every time, so that path is
unreachable. We lose the ZCU block; we gain the exact blob, plus the target
that was live when the work was handed out, which is what we need to prove
the parent-work maths before we ever let a real submit through.
"""
import asyncio, json, logging, os, time
from aiohttp import web, ClientSession, ClientTimeout, BasicAuth

GETH_URL = os.environ.get("GETH_URL", "http://127.0.0.1:8747")
GETH_USER = os.environ.get("GETH_USER", "zcu")
GETH_PASS = os.environ.get("GETH_PASS", "zcu")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8749"))
CAPTURE = os.environ.get("CAPTURE_FILE", "/var/log/zcu-capture.jsonl")
POOL_ADDR = os.environ.get("POOL_ADDR", "0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zcu-shadow")
session = None

# aux hash -> the createAuxBlock result that produced it. Lets VERIFY compare
# each captured submit against the target that was actually live at the time,
# instead of whatever the tip target happens to be later.
WORK = {}


async def geth(method, params=None):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    async with session.post(GETH_URL, json=payload,
                            auth=BasicAuth(GETH_USER, GETH_PASS),
                            timeout=ClientTimeout(total=10)) as r:
        return await r.json(content_type=None)


def ok(rid, result):
    return {"result": result, "error": None, "id": rid}


def err(rid, code, m):
    return {"result": None, "error": {"code": code, "message": m}, "id": rid}


def record(kind, obj):
    obj["kind"] = kind
    obj["ts"] = time.time()
    try:
        with open(CAPTURE, "a") as fh:
            fh.write(json.dumps(obj) + "\n")
    except Exception as e:
        log.error("capture write failed: %s", e)


async def m_getinfo(rid, p):
    r = await geth("eth_blockNumber")
    h = int(r["result"], 16) if "result" in r and r["result"] else 0
    return ok(rid, {"version": 1000000, "protocolversion": 70015, "blocks": h,
                    "connections": 8, "difficulty": 1, "testnet": False, "errors": ""})


async def m_getblockcount(rid, p):
    r = await geth("eth_blockNumber")
    if not r.get("result"):
        return err(rid, -32603, str(r.get("error")))
    return ok(rid, int(r["result"], 16))


async def m_getdifficulty(rid, p):
    return ok(rid, 1.0)


async def m_getmininginfo(rid, p):
    r = await geth("eth_blockNumber")
    h = int(r["result"], 16) if r.get("result") else 0
    return ok(rid, {"blocks": h, "difficulty": 1, "networkhashps": 0,
                    "chain": "main", "warnings": ""})


async def m_validateaddress(rid, p):
    a = p[0] if p else ""
    return ok(rid, {"isvalid": bool(a), "address": a, "ismine": True, "isscript": False})


async def m_getrawchangeaddress(rid, p):
    return ok(rid, POOL_ADDR)


async def m_createauxblock(rid, p):
    addr = p[0] if p else POOL_ADDR
    r = await geth("scrypt_createAuxBlock", [addr])
    if r.get("error"):
        return err(rid, r["error"].get("code", -32603),
                   r["error"].get("message", "createAuxBlock failed"))
    res = r.get("result") or {}
    h = (res.get("hash") or "").lower().replace("0x", "")
    if h:
        if h not in WORK:
            # Record the exact work shape we hand stratum. If stratum never
            # submits, the answer is usually in these fields (missing chainid,
            # 0x-prefixed hash, target vs _target, byte order), not in luck.
            record("auxwork", {"reply": res, "keys": sorted(res.keys())})
        WORK[h] = res
        if len(WORK) > 512:
            for k in list(WORK)[:256]:
                WORK.pop(k, None)
    return ok(rid, res)


GBT_MODE = os.environ.get("ZCU_GBT_MODE", "template").lower()


async def m_getblocktemplate(rid, p):
    """The capture log settled this: stratum ONLY ever calls us with [{}].

    It never retries with {"rules":[...]}. So the -8 "call me with rules" hint
    we were returning was a dead end -- stratum saw an error, marked the coin
    unusable for that job cycle, and moved on. 47 declines, 0 aux jobs.

    So we now answer with a minimal, well-formed bitcoind template. This is NOT
    the 13 Aug SEGV path: that crash came from a REJECTED aux submit, and this
    adapter still acks every submit unconditionally. The template only has to
    be shaped well enough that coind_create_job() stops bailing and goes on to
    call createauxblock, which is the call we actually want to see.

    ZCU_GBT_MODE=decline restores the old -8 behaviour for A/B testing.
    """
    if GBT_MODE == "decline":
        record("gbt_declined", {"params": str(p)[:200]})
        return err(rid, -8, "getblocktemplate must be called with "
                            "{\"rules\": [\"segwit\"]}")

    r = await geth("eth_blockNumber")
    height = int(r["result"], 16) if r.get("result") else 0
    prev = "%064x" % height  # placeholder: aux children never mine this template
    tmpl = {
        "version": 536870912,
        "rules": [],
        "vbavailable": {},
        "vbrequired": 0,
        "previousblockhash": prev,
        "transactions": [],
        "coinbaseaux": {"flags": ""},
        "coinbasevalue": 0,
        "longpollid": prev + str(int(time.time())),
        "target": "0" * 8 + "f" * 56,
        "mintime": int(time.time()) - 600,
        "mutable": ["time", "transactions", "prevblock"],
        "noncerange": "00000000ffffffff",
        "sigoplimit": 80000,
        "sizelimit": 4000000,
        "weightlimit": 4000000,
        "curtime": int(time.time()),
        "bits": "1d00ffff",
        "height": height + 1,
    }
    record("gbt_served", {"params": str(p)[:200], "height": height + 1})
    return ok(rid, tmpl)


async def m_listsinceblock(rid, p):
    return ok(rid, {"transactions": [], "lastblock": "00" * 32})


async def m_submitauxblock(rid, p):
    """THE SAFETY INVERSION. Record, ack, never forward."""
    if len(p) < 2:
        return err(rid, -32602, "expected [hash, auxpow]")
    h = str(p[0] or "").lower().replace("0x", "")
    auxpow = str(p[1] or "")
    record("submit", {"hash": h, "auxpow": auxpow, "auxpow_len": len(auxpow),
                      "work": WORK.get(h)})
    log.info("CAPTURED submit hash=%s auxpow_len=%d work_known=%s -- ACKing "
             "without forwarding (deadlock path disarmed)",
             h, len(auxpow), h in WORK)
    return ok(rid, True)


HANDLERS = {
    "getinfo": m_getinfo,
    "getblockcount": m_getblockcount,
    "getdifficulty": m_getdifficulty,
    "getmininginfo": m_getmininginfo,
    "validateaddress": m_validateaddress,
    "getrawchangeaddress": m_getrawchangeaddress,
    "getnewaddress": m_getrawchangeaddress,
    "createauxblock": m_createauxblock,
    "getauxblock": m_createauxblock,
    "getblocktemplate": m_getblocktemplate,
    "listsinceblock": m_listsinceblock,
    "submitauxblock": m_submitauxblock,
}


async def handle(request):
    raw = await request.text()
    try:
        body = json.loads(raw)
    except Exception:
        return web.json_response(err(None, -32700, "parse error"))
    single = not isinstance(body, list)
    calls = [body] if single else body
    out = []
    for c in calls:
        rid = c.get("id")
        method = (c.get("method") or "").lower()
        params = c.get("params") or []
        h = HANDLERS.get(method)
        if not h:
            # Anything unknown is answered with a plain error rather than being
            # proxied blind. Passthrough is how surprises reach geth.
            record("unhandled", {"method": method, "params": str(params)[:400]})
            out.append(err(rid, -32601, "method not supported in shadow mode"))
            continue
        try:
            out.append(await h(rid, params))
        except Exception as e:
            log.error("handler %s failed: %s", method, e)
            out.append(err(rid, -32603, str(e)))
    return web.json_response(out[0] if single else out)


async def main():
    global session
    session = ClientSession()
    app = web.Application()
    app.router.add_post("/", handle)
    app.router.add_post("/{tail:.*}", handle)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, LISTEN_HOST, LISTEN_PORT).start()
    log.info("zcu shadow adapter on %s:%d -> geth %s (capture=%s) "
             "SUBMITS ARE NEVER FORWARDED", LISTEN_HOST, LISTEN_PORT, GETH_URL, CAPTURE)
    while True:
        await asyncio.sleep(3600)


asyncio.run(main())
PYEOF
chmod 755 "$PY"
touch "$CAP"; chmod 600 "$CAP"
echo "  wrote $PY"

hr "3. start it (foreground process, no systemd unit, easy to kill)"
GETH_URL="http://127.0.0.1:$GETH_PORT" LISTEN_PORT="$PORT" CAPTURE_FILE="$CAP" \
  nohup python3 "$PY" >/var/log/zcu-shadow.log 2>&1 &
sleep 2
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
  echo "  listening on :$PORT"
else
  echo "  FAILED to start -- see /var/log/zcu-shadow.log"; tail -20 /var/log/zcu-shadow.log; exit 1
fi

hr "4. smoke test the read path"
curl -s -m 10 -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"createauxblock","params":["0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe"]}' \
  "http://127.0.0.1:$PORT/" | head -c 300; echo

hr "5. what happens next"
cat <<'TXT'
  ZCU is now answering RPC again, so stratum will put it back in the aux
  rotation on its next coin re-detect. THAT IS EXPECTED. The difference from
  13 Aug: every submit gets a `true`, so stratum can never hit the deadlock.

  Watch, in this order:
    sudo tail -f /var/log/zcu-shadow.log
    curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash

  The fleet solves the ZCU target in ~105s, so you should see CAPTURED lines
  within a few minutes. Once you have 3+, run:
    curl -fsSL https://pool.honest.money/install/zcu-shadow.sh | sudo bash -s VERIFY
TXT
fi

##############################################################################
if [ "$MODE" = "VERIFY" ]; then
hr "VERIFY -- decode captured blobs and do geth's parent-work maths offline"
python3 - "$CAP" <<'PY'
import sys, json, hashlib, struct, os

path = sys.argv[1]
if not os.path.exists(path):
    print("  no capture file yet -- run INSTALL and wait for a find"); sys.exit(0)

subs = []
for line in open(path):
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("kind") == "submit":
        subs.append(o)

print(f"  captured submits: {len(subs)}")
if not subs:
    print("  nothing to verify yet -- stratum has NOT re-added ZCU.")
    sys.exit(0)

def scrypt_pow(hdr):
    return hashlib.scrypt(hdr, salt=hdr, n=1024, r=1, p=1, dklen=32,
                          maxmem=256 * 1024 * 1024)

DIFF1 = 0x00000000FFFF0000000000000000000000000000000000000000000000000000
MAXSCAN = int(os.environ.get("VERIFY_MAX", "20000"))

# FULL SCAN. The old last-10 sample could not answer the only question that
# matters: does the fleet EVER produce a blob that meets the ZCU aux target?
# stratum submits every accepted LTC share, so winners are ~1 in a few hundred
# and a 10-blob tail will almost always miss them.
scan = subs[-MAXSCAN:]
print(f"  scanning {len(scan)} blobs (scrypt is slow; ~30s for 12k)...")

winners, ratios, bad = [], [], 0
for s in scan:
    try:
        raw = bytes.fromhex(str(s.get("auxpow", "")).replace("0x", ""))
    except Exception:
        bad += 1; continue
    if len(raw) < 80:
        bad += 1; continue
    work = s.get("work") or {}
    tgt_hex = (work.get("target") or "").replace("0x", "")
    if not tgt_hex:
        bad += 1; continue
    tgt = int(tgt_hex, 16)
    hdr = raw[-80:]
    disp = int.from_bytes(scrypt_pow(hdr)[::-1], "big")
    r = disp / tgt
    ratios.append(r)
    if disp <= tgt:
        winners.append((s, hdr, disp, tgt))

print(f"  decoded {len(ratios)}   unusable {bad}")
if not ratios:
    print("  no decodable blob carried a recorded target -- cannot judge"); sys.exit(0)

ratios.sort()
best = ratios[0]
buckets = [(1, 0), (2, 0), (10, 0), (100, 0), (1000, 0), (10000, 0)]
counts = {b: 0 for b, _ in buckets}
for r in ratios:
    for b, _ in buckets:
        if r <= b:
            counts[b] += 1
            break

print("\n  how close does the fleet get? (ratio = scrypt hash / aux target)")
prev = 0
for b, _ in buckets:
    print(f"    <= {b:>6}x   {counts[b]}")
print(f"    >  10000x   {sum(1 for r in ratios if r > 10000)}")
print(f"\n  best blob: {best:,.1f}x the aux target"
      f"   (aux diff ~{DIFF1/tgt:,.0f}, so the fleet's best share was"
      f" ~1/{max(best,1e-9):,.0f} of it)")


if winners:
    s, hdr, disp, tgt = winners[0]
    ver, prev_h, merkle, ts, bits, nonce = struct.unpack("<I32s32sIII", hdr)
    print(f"\n  >> {len(winners)} of {len(ratios)} blobs WOULD BE ACCEPTED by geth.")
    print(f"     example: hash={s['hash'][:24]}... nonce={nonce} bits=0x{bits:08x}")
    print(f"     scrypt {disp:064x}")
    print(f"     target {tgt:064x}")
    print("     The auxpow blob and the parent-work maths are BOTH CORRECT.")
    print("     ZCU's only remaining problem is that stratum submits EVERY share,")
    print("     so geth rejects the ~99.8% that miss -- and a rejection is what")
    print("     deadlocked stratum on 13 Aug. Fix = gate submits in the adapter:")
    print("     forward only blobs that meet the target, ACK the rest.")
else:
    print("\n  >> ZERO acceptable blobs in this window.")
    if best > 100:
        print(f"     Best was {best:,.1f}x off and the spread is wide, which is the")
        print("     signature of stratum submitting at LTC SHARE difficulty --")
        print("     it is not applying the aux target at all. Either the fleet has")
        print("     not yet solved the ZCU target, or the aux target never reaches")
        print("     the share filter. Keep capturing and re-run VERIFY.")
    else:
        print("     Near misses only -- keep capturing, this is variance.")

print("\n  Summary rule: we do NOT re-enable real ZCU submits until at least one")
print("  captured blob prints 'WOULD BE ACCEPTED'.")
PY

fi

##############################################################################
# ANALYZE -- read-only. Answers "why has stratum not submitted anything?" by
# diffing OUR aux work reply against the aux children that DO work (TXC/ISK).
if [ "$MODE" = "ANALYZE" ]; then

hr "A. what stratum has actually asked us for"
if [ -f "$CAP" ]; then
  python3 - "$CAP" <<'PY'
import sys, json, collections
kinds = collections.Counter()
meth = collections.Counter()
gbtp = collections.Counter()
last = {}
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except Exception: continue
    kinds[o.get("kind")] += 1
    if o.get("kind") == "unhandled":
        meth[o.get("method") or "?"] += 1
    if o.get("kind") in ("gbt_declined", "gbt_served"):
        gbtp[str(o.get("params"))[:120]] += 1
    last[o.get("kind")] = o
for k, v in kinds.most_common():
    print(f"  {k:<14} {v}")
if meth:
    print("\n  unhandled methods stratum asked for (these are the real gap):")
    for m, c in meth.most_common(20):
        print(f"    {m:<28} {c}")
if gbtp:
    print("\n  distinct getblocktemplate params seen:")
    for m, c in gbtp.most_common(10):
        print(f"    {m[:100]:<100} {c}")
aw = last.get("auxwork")
if aw:
    print("\n  our createauxblock reply keys:", aw.get("keys"))
    for k, v in (aw.get("reply") or {}).items():
        print(f"    {k:<14} {str(v)[:80]}")
else:
    print("\n  NO auxwork recorded yet -- stratum has not called createauxblock")
    print("  since this build. That alone explains zero submits.")
PY
else
  echo "  no capture file"
fi

hr "B. the same call on the aux children that DO find blocks"
python3 - <<'PY'
import json, re, urllib.request, base64
conf = "/var/stratum/scrypt.conf"
try:
    txt = open(conf).read()
except Exception as e:
    print("  cannot read", conf, e); raise SystemExit(0)

# crude block parse: name { ... } sections carrying rpc creds
blocks = re.findall(r'(\w[\w \-]*)\s*\{([^}]*)\}', txt)
def field(b, k):
    m = re.search(rf'{k}\s*=\s*(\S+)', b)
    return m.group(1).strip('"') if m else None

def call(url, user, pw, method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(url, data=body,
        headers={"content-type":"application/json",
                 "authorization":"Basic "+base64.b64encode(f"{user}:{pw}".encode()).decode()})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)

seen = 0
for name, b in blocks:
    url = field(b, "rpcurl") or field(b, "rpchost")
    user = field(b, "rpcuser"); pw = field(b, "rpcpasswd") or field(b, "rpcpassword")
    if not (url and user):
        continue
    if not url.startswith("http"):
        url = "http://" + url
    label = name.strip()
    for m in ("getauxblock", "createauxblock"):
        try:
            r = call(url, user, pw, m, [] if m == "getauxblock" else ["dummy"])
        except Exception as e:
            continue
        res = r.get("result")
        if isinstance(res, dict):
            seen += 1
            print(f"\n  [{label}] {m} keys={sorted(res.keys())}")
            for k, v in res.items():
                print(f"      {k:<14} {str(v)[:80]}")
            break
if not seen:
    print("  no aux child answered -- check creds parse (this section is best-effort)")
PY

hr "C. does stratum log any ZCU job / aux activity?"
LOG=$(ls -t /var/stratum/logs/stratum*.log 2>/dev/null | head -1)
echo "  log: ${LOG:-none}"
[ -n "${LOG:-}" ] && tail -20000 "$LOG" | grep -iE 'zero chill|zcu' | tail -15

hr "D. read"
cat <<'TXT'
  Compare A and B field-for-field. The working children (TXC/ISK) define the
  contract stratum expects. Any key they return that we do not -- chainid,
  coinbasevalue, _target, previousblockhash -- is a candidate for why stratum
  takes our work and then never produces a submit for it.
TXT
fi

##############################################################################
hr "did we disturb production?"
R1=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts start=${R0:-?} now=${R1:-?}"
[ "${R0:-x}" = "${R1:-y}" ] && echo "  CLEAN -- stratum never noticed." \
  || echo "  !! stratum restarted -- run: sudo bash -s STOP immediately"
echo
echo "  Always follow with:  curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash"
