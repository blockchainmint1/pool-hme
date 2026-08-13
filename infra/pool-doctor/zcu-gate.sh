#!/usr/bin/env bash
# zcu-gate.sh -- ZCU adapter that ACTUALLY SUBMITS, but only winners.
#
#   install:  curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s INSTALL
#   status:   curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STATUS
#   stop:     curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STOP
#
# VERIFY proved (13 Aug, 17,143 captured blobs): the auxpow blob and the
# parent-work maths are correct -- 3 blobs met the ZCU aux target. The single
# remaining defect is that stratum submits EVERY accepted LTC share to ZCU with
# no aux-target filter, so geth rejected ~99.98% of them, and a rejection is
# what deadlocked the whole scrypt stratum on 13 Aug.
#
# THE FIX, and why it cannot reproduce that outage:
#   1. Every submitauxblock is scrypt-checked against the target recorded when
#      that exact work was handed out. Misses are ACKed `true` and dropped --
#      geth never sees them, so it cannot reject them.
#   2. Only blobs that meet the target are forwarded to geth. That is ~3 in
#      17,000, and each one is a real block.
#   3. Even a forwarded blob that geth refuses is STILL answered `true` to
#      stratum. This adapter NEVER returns a submitauxblock error, for any
#      reason -- bad params, geth down, timeout, rejection. The deadlock path
#      is structurally unreachable, exactly as in shadow mode.
#   4. A forward rate limiter (default 6/min) means even a gating bug cannot
#      flood geth with rejects.
#
# Touches nothing owned by stratum: no scrypt.conf, no binary, no restart.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSTALL}"
MODE="$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')"
# START / RESTART / UP are all aliases for INSTALL -- installing IS starting
case "$MODE" in START|RESTART|UP) MODE=INSTALL ;; esac
GETH_PORT=${GETH_PORT:-8747}
PORT=${ADAPTER_PORT:-8749}
CAP=/var/log/zcu-capture.jsonl
PY=/opt/zcu-adapter/adapter-gate.py
LOG=/var/log/zcu-gate.log
UNIT=stratum-aws-scrypt
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-gate v5  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

case "$MODE" in
  INSTALL|STOP|STATUS|ARM|DISARM) ;;
  *) echo "  unknown mode '$MODE'. Use INSTALL (aka START), ARM, DISARM, STOP, or STATUS."; exit 1 ;;
esac

##############################################################################
# ARM  = ZCU_DRY_RUN=0, real winners forwarded to geth
# DISARM = ZCU_DRY_RUN=1, pure shadow, forwards nothing (still ACKs everything)
if [ "$MODE" = "ARM" ] || [ "$MODE" = "DISARM" ]; then
  V=0; [ "$MODE" = "DISARM" ] && V=1
  [ -f /etc/zcu-gate.env ] || { echo "  /etc/zcu-gate.env missing -- run START first"; exit 1; }
  if grep -q '^ZCU_DRY_RUN=' /etc/zcu-gate.env; then
    sed -i "s/^ZCU_DRY_RUN=.*/ZCU_DRY_RUN=$V/" /etc/zcu-gate.env
  else
    echo "ZCU_DRY_RUN=$V" >> /etc/zcu-gate.env
  fi
  systemctl restart zcu-gate
  for i in $(seq 1 10); do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; sleep 1; done
  ss -ltn 2>/dev/null | grep -q ":$PORT" \
    && echo "  gate restarted, dry_run=$V ($([ "$V" = 0 ] && echo 'ARMED -- winners forward to geth' || echo 'shadow -- forwards nothing'))" \
    || { echo "  gate did NOT come back on :$PORT"; tail -20 "$LOG"; exit 1; }
  echo "  stratum untouched: active=$(systemctl is-active "$UNIT") NRestarts=$(systemctl show "$UNIT" -p NRestarts --value)"
  exit 0
fi



R0=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts at start = ${R0:-?}"

##############################################################################
if [ "$MODE" = "STOP" ]; then
  systemctl disable --now zcu-gate >/dev/null 2>&1 && echo "  zcu-gate.service stopped and disabled" || true
  pkill -f 'adapter-gate.py'    && echo "  gate adapter stopped"    || echo "  gate was not running"
  pkill -f 'adapter-capture.py' && echo "  shadow adapter stopped"  || true
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$PORT" && echo "  WARNING :$PORT still listening" \
    || echo "  :$PORT clear -- ZCU out of the aux rotation again"
  exit 0
fi

##############################################################################
if [ "$MODE" = "STATUS" ]; then
hr "gate status"
systemctl --no-pager -l status zcu-gate 2>/dev/null | head -8 || echo "  no zcu-gate.service"
pgrep -f adapter-gate.py >/dev/null && echo "  adapter-gate.py RUNNING" || echo "  adapter-gate.py NOT running"
ss -ltn 2>/dev/null | grep ":$PORT" || echo "  nothing on :$PORT"
python3 - "$CAP" <<'PY'
import sys, json, collections, os
p = sys.argv[1]
if not os.path.exists(p):
    print("  no capture file"); raise SystemExit(0)
k = collections.Counter(); last = {}
for line in open(p):
    try: o = json.loads(line)
    except Exception: continue
    k[o.get("kind")] += 1
    last[o.get("kind")] = o
for n, v in k.most_common():
    print(f"  {n:<16} {v}")
for n in ("forwarded", "forward_rejected", "forward_error"):
    o = last.get(n)
    if o:
        print(f"\n  last {n}: {json.dumps({x: str(y)[:90] for x, y in o.items() if x != 'auxpow'})}")
print("\n  gated_miss = shares dropped before geth saw them (this is the fix working)")
print("  forwarded  = real ZCU block candidates actually submitted")
PY
hr "recent gate log"
tail -25 "$LOG" 2>/dev/null || echo "  no $LOG"
exit 0
fi

##############################################################################
if [ "$MODE" = "INSTALL" ]; then
hr "1. stand down any other adapter first"
systemctl stop zcu-gate >/dev/null 2>&1 || true
if pgrep -f 'adapter-capture.py' >/dev/null; then
  echo "  stopping shadow adapter (capture-only) to take its port"
  pkill -f 'adapter-capture.py'; sleep 2
fi
pkill -f 'adapter-gate.py' >/dev/null 2>&1 && sleep 2 || true
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
  echo "  REFUSING: something is still listening on :$PORT."
  echo "  Stop it first:  sudo pkill -f '/opt/zcu-adapter/adapter'"
  exit 1
fi
systemctl is-enabled zcu-adapter >/dev/null 2>&1 && systemctl disable --now zcu-adapter >/dev/null 2>&1

hr "2. write the target-gated adapter"
mkdir -p /opt/zcu-adapter
cat > "$PY" <<'PYEOF'
#!/usr/bin/env python3
"""Target-gated bitcoind<->geth adapter for ZCU.

createauxblock  -> forwarded to geth (read-only, safe)
submitauxblock  -> scrypt-checked offline.
                     miss  -> recorded, ACKed true, DROPPED (geth never sees it)
                     hit   -> forwarded to geth as a real block submission
                   Either way stratum gets `true`. This adapter never returns a
                   submitauxblock error, so yiimp's deadlock detector -- the
                   thing that killed the pool on 13 Aug -- cannot fire.
"""
import asyncio, json, logging, os, time, hashlib
from collections import deque
from aiohttp import web, ClientSession, ClientTimeout, BasicAuth

GETH_URL = os.environ.get("GETH_URL", "http://127.0.0.1:8747")
GETH_USER = os.environ.get("GETH_USER", "zcu")
GETH_PASS = os.environ.get("GETH_PASS", "zcu")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8749"))
CAPTURE = os.environ.get("CAPTURE_FILE", "/var/log/zcu-capture.jsonl")
POOL_ADDR = os.environ.get("POOL_ADDR", "0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe")
# hard ceiling on forwards; even a gating bug cannot flood geth with rejects
MAX_FWD_PER_MIN = int(os.environ.get("MAX_FWD_PER_MIN", "6"))
# set to 1 to fall back to pure shadow behaviour (forward nothing) without
# reinstalling anything
DRY_RUN = os.environ.get("ZCU_DRY_RUN", "0") == "1"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zcu-gate")
session = None
WORK = {}
FWD = deque()


async def geth(method, params=None, timeout=10):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    async with session.post(GETH_URL, json=payload,
                            auth=BasicAuth(GETH_USER, GETH_PASS),
                            timeout=ClientTimeout(total=timeout)) as r:
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
    h = int(r["result"], 16) if r.get("result") else 0
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
            record("auxwork", {"reply": res, "keys": sorted(res.keys())})
        WORK[h] = res
        if len(WORK) > 512:
            for k in list(WORK)[:256]:
                WORK.pop(k, None)
    return ok(rid, res)


async def m_getblocktemplate(rid, p):
    """Minimal well-formed template so coind_create_job() reaches createauxblock.

    Proven necessary: stratum only ever calls us with [{}] and never retries
    with rules, so any error here drops ZCU from the job cycle entirely.
    """
    r = await geth("eth_blockNumber")
    height = int(r["result"], 16) if r.get("result") else 0
    prev = "%064x" % height
    tmpl = {
        "version": 536870912, "rules": [], "vbavailable": {}, "vbrequired": 0,
        "previousblockhash": prev, "transactions": [], "coinbaseaux": {"flags": ""},
        "coinbasevalue": 0, "longpollid": prev + str(int(time.time())),
        "target": "0" * 8 + "f" * 56, "mintime": int(time.time()) - 600,
        "mutable": ["time", "transactions", "prevblock"],
        "noncerange": "00000000ffffffff", "sigoplimit": 80000,
        "sizelimit": 4000000, "weightlimit": 4000000,
        "curtime": int(time.time()), "bits": "1d00ffff", "height": height + 1,
    }
    return ok(rid, tmpl)


async def m_listsinceblock(rid, p):
    return ok(rid, {"transactions": [], "lastblock": "00" * 32})


async def m_getbalance(rid, p):
    return ok(rid, 0.0)



def scrypt_display(hdr80: bytes) -> int:
    h = hashlib.scrypt(hdr80, salt=hdr80, n=1024, r=1, p=1, dklen=32,
                       maxmem=256 * 1024 * 1024)
    return int.from_bytes(h[::-1], "big")


def meets_target(auxpow_hex: str, work: dict):
    """Return (verdict, ratio). verdict True only when geth would accept.

    Any decode problem returns False -- when in doubt we DROP, because a
    forwarded reject is the one outcome that can hurt the pool.
    """
    tgt_hex = (work or {}).get("target") or ""
    tgt_hex = tgt_hex.replace("0x", "")
    if not tgt_hex:
        return False, None
    try:
        raw = bytes.fromhex(auxpow_hex.replace("0x", ""))
        tgt = int(tgt_hex, 16)
    except Exception:
        return False, None
    if len(raw) < 80 or tgt <= 0:
        return False, None
    disp = scrypt_display(raw[-80:])
    return disp <= tgt, disp / tgt


def fwd_allowed():
    now = time.time()
    while FWD and now - FWD[0] > 60:
        FWD.popleft()
    if len(FWD) >= MAX_FWD_PER_MIN:
        return False
    FWD.append(now)
    return True


async def m_submitauxblock(rid, p):
    """Gate. Always answers true to stratum, no matter what happens below."""
    if len(p) < 2:
        record("gated_bad", {"params": str(p)[:200]})
        return ok(rid, True)
    h = str(p[0] or "").lower().replace("0x", "")
    auxpow = str(p[1] or "")
    work = WORK.get(h)

    try:
        hit, ratio = await asyncio.to_thread(meets_target, auxpow, work)
    except Exception as e:
        log.error("gate check failed, dropping: %s", e)
        record("gated_error", {"hash": h, "error": str(e)})
        return ok(rid, True)

    if not hit:
        record("gated_miss", {"hash": h, "ratio": ratio, "auxpow_len": len(auxpow)})
        return ok(rid, True)

    if DRY_RUN:
        log.warning("WINNER (ratio=%.4f) but ZCU_DRY_RUN=1 -- not forwarding", ratio or 0)
        record("would_forward", {"hash": h, "ratio": ratio, "auxpow": auxpow})
        return ok(rid, True)

    if not fwd_allowed():
        log.error("WINNER suppressed by rate limit (%d/min) -- gating may be wrong",
                  MAX_FWD_PER_MIN)
        record("forward_ratelimited", {"hash": h, "ratio": ratio})
        return ok(rid, True)

    log.warning("WINNER hash=%s ratio=%.4f -- FORWARDING to geth", h, ratio or 0)
    try:
        r = await geth("scrypt_submitAuxBlock", [p[0], p[1]], timeout=15)
    except Exception as e:
        log.error("forward threw: %s (stratum still gets true)", e)
        record("forward_error", {"hash": h, "error": str(e)})
        return ok(rid, True)

    if r.get("error"):
        log.error("geth REJECTED a gated winner: %s -- stratum still gets true", r["error"])
        record("forward_rejected", {"hash": h, "ratio": ratio, "error": r["error"]})
    else:
        log.warning("ZCU BLOCK ACCEPTED by geth: %s", str(r.get("result"))[:120])
        record("forwarded", {"hash": h, "ratio": ratio, "result": r.get("result")})
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
    "getbalance": m_getbalance,
    "submitauxblock": m_submitauxblock,
    # The forward-ported stratum calls the geth-style names directly, lowercased
    # by our dispatcher. Without these aliases they fell through to the
    # "method not supported" error and ZCU never entered the job cycle.
    # scrypt_submitauxblock MUST map to the gated handler -- otherwise submits
    # would bypass the target filter entirely (the 13 Aug deadlock path).
    "scrypt_createauxblock": m_createauxblock,
    "scrypt_getauxblock": m_createauxblock,
    "scrypt_submitauxblock": m_submitauxblock,
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
            record("unhandled", {"method": method, "params": str(params)[:400]})
            out.append(err(rid, -32601, "method not supported"))
            continue
        try:
            out.append(await h(rid, params))
        except Exception as e:
            log.error("handler %s failed: %s", method, e)
            # submitauxblock must NEVER surface an error to stratum
            out.append(ok(rid, True) if method.endswith("submitauxblock")
                       else err(rid, -32603, str(e)))
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
    log.info("zcu GATE adapter on %s:%d -> geth %s  dry_run=%s max_fwd=%d/min "
             "(misses dropped, only target-meeting blobs forwarded)",
             LISTEN_HOST, LISTEN_PORT, GETH_URL, DRY_RUN, MAX_FWD_PER_MIN)
    while True:
        await asyncio.sleep(3600)


asyncio.run(main())
PYEOF
chmod 755 "$PY"
: > "$CAP"; chmod 600 "$CAP"   # truncate: stale shadow-adapter entries must not contaminate gate counters
echo "  wrote $PY"

hr "3. install the systemd unit and start it"
cat > /etc/zcu-gate.env <<EOF
GETH_URL=http://127.0.0.1:$GETH_PORT
LISTEN_PORT=$PORT
CAPTURE_FILE=$CAP
ZCU_DRY_RUN=${ZCU_DRY_RUN:-0}
MAX_FWD_PER_MIN=${MAX_FWD_PER_MIN:-6}
EOF
chmod 600 /etc/zcu-gate.env
cat > /etc/systemd/system/zcu-gate.service <<EOF
[Unit]
Description=ZCU target-gated auxpow adapter (bitcoind RPC -> geth)
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/zcu-gate.env
ExecStart=/usr/bin/python3 $PY
Restart=always
RestartSec=5
StandardOutput=append:$LOG
StandardError=append:$LOG

[Install]
WantedBy=multi-user.target
EOF
touch "$LOG"; chmod 640 "$LOG"
systemctl daemon-reload
systemctl enable --now zcu-gate >/dev/null 2>&1 || systemctl enable zcu-gate >/dev/null 2>&1
systemctl restart zcu-gate
for i in $(seq 1 10); do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; sleep 1; done
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
  echo "  listening on :$PORT   dry_run=${ZCU_DRY_RUN:-0}   (systemd unit zcu-gate, survives reboot)"
else
  echo "  FAILED to start -- see $LOG"; tail -20 "$LOG"
  systemctl --no-pager -l status zcu-gate | head -20
  exit 1
fi


hr "4. smoke test the read path"
curl -s -m 10 -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"createauxblock","params":["0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe"]}' \
  "http://127.0.0.1:$PORT/" | head -c 300; echo

hr "5. self-test the gate with a deliberate junk submit"
# 80 bytes of zeros will never meet the target -- must come back true AND be
# recorded as gated_miss, never forwarded.
JUNK=$(printf '0%.0s' $(seq 1 160))
curl -s -m 20 -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submitauxblock\",\"params\":[\"deadbeef\",\"$JUNK\"]}" \
  "http://127.0.0.1:$PORT/" | head -c 200; echo
echo "  ^ must be {\"result\": true ...}. An error here means STOP immediately."

hr "6. what happens next"
cat <<'TXT'
  Stratum keeps submitting every share; the adapter now drops the ~99.98% that
  miss and forwards only real winners. Expect roughly 1 forward per 1-2 hours
  at current hashrate and aux difficulty.

  Watch, in this order:
    sudo tail -f /var/log/zcu-gate.log        # WINNER / ACCEPTED lines
    curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STATUS
    curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash

  If the canary ever shows a stratum restart, stop the adapter first and ask
  questions second:
    curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STOP
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
