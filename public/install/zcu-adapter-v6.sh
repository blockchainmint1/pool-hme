#!/usr/bin/env bash
# zcu-adapter-v6.sh -- redesigned ZCU aux adapter (post-29-Aug deadlock).
#
#   install (SHADOW, submits nothing):
#     curl -fsSL https://pool.honest.money/install/zcu-adapter-v6.sh | sudo bash -s INSTALL
#   status:  ... | sudo bash -s STATUS
#   arm:     ... | sudo bash -s ARM          (only after a clean 24h shadow)
#   shadow:  ... | sudo bash -s SHADOW
#   stop:    ... | sudo bash -s STOP
#
# WHY v6 EXISTS
# -------------
# v5 (zcu-gate.sh) deadlocked the entire scrypt stratum on 29 Aug. Two design
# defects, both fixed here:
#
#   D1  Per-share memory-hard work ON THE RPC ROUND-TRIP.
#       v5 ran hashlib.scrypt(N=1024, 256MB maxmem) inside the submitauxblock
#       handler before replying. At ~2,100 shares/min the single asyncio loop
#       saturated, the reply latency climbed, and because yiimp's aux refresh
#       is a SHARED, process-wide, blocking path, LTC/DOGE/TXC/ISK starved with
#       it until the process-wide deadlock watchdog fired.
#       v6: submitauxblock replies `true` in O(1), synchronously, ALWAYS.
#       The target check runs on a bounded background worker pool fed by a
#       BOUNDED queue. Queue full => the share is dropped and counted. There is
#       no code path in which stratum waits on scrypt, on geth, or on us.
#
#   D2  Fabricated templates. v5 turned an empty/failed eth_blockNumber into a
#       height=1 placeholder template, so the stratum saw a "healthy" child
#       serving frozen garbage work for hours.
#       v6: any geth failure returns a real JSON-RPC error, and after
#       FAIL_TRIP consecutive failures the adapter SELF-DISARMS -- it errors
#       every mining method so yiimp drops ZCU from the rotation, while
#       LTC/DOGE/TXC/ISK are untouched. It re-arms only after geth answers
#       cleanly again. This is the ZCU-only deadman, in-process.
#
# Other invariants kept from v5: never forward a non-winner; hard forward rate
# limit; touches no stratum config, binary, or unit.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSTALL}"; MODE="$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')"
case "$MODE" in START|RESTART|UP) MODE=INSTALL ;; DISARM) MODE=SHADOW ;; esac
case "$MODE" in INSTALL|STOP|STATUS|ARM|SHADOW) ;;
  *) echo "unknown mode '$MODE' (INSTALL|ARM|SHADOW|STATUS|STOP)"; exit 1 ;; esac

PORT=${ADAPTER_PORT:-8749}
GETH_PORT=${GETH_PORT:-8747}
PY=/opt/zcu-adapter/adapter-v6.py
ENVF=/etc/zcu-adapter-v6.env
CAP=/var/log/zcu-v6-capture.jsonl
LOG=/var/log/zcu-v6.log
UNIT=stratum-aws-scrypt
SVC=zcu-adapter-v6
hr() { printf '\n===== %s\n' "$*"; }
echo "zcu-adapter v6  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

##############################################################################
if [ "$MODE" = "ARM" ] || [ "$MODE" = "SHADOW" ]; then
  V=1; [ "$MODE" = "ARM" ] && V=0
  [ -f "$ENVF" ] || { echo "  $ENVF missing -- run INSTALL first"; exit 1; }
  if [ "$V" = 0 ]; then
    # Refuse to arm without a proven shadow run.
    hits=$(grep -c '"kind": *"would_forward"' "$CAP" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - $(stat -c %Y "$CAP" 2>/dev/null || date +%s) ))
    first=$(stat -c %W "$CAP" 2>/dev/null || echo 0)
    run=0; [ "${first:-0}" -gt 0 ] && run=$(( $(date +%s) - first ))
    echo "  shadow evidence: would_forward=$hits  capture_age=${age}s  shadow_runtime=${run}s"
    if [ "$run" -lt 86400 ] && [ "${ZCU_FORCE_ARM:-0}" != "1" ]; then
      echo "  REFUSING to arm: shadow has run ${run}s (<24h)."
      echo "  Override deliberately with: ZCU_FORCE_ARM=1 ... bash -s ARM"
      exit 1
    fi
  fi
  sed -i "/^ZCU_DRY_RUN=/d" "$ENVF"; echo "ZCU_DRY_RUN=$V" >> "$ENVF"
  systemctl restart "$SVC"
  for i in $(seq 1 10); do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; sleep 1; done
  ss -ltn 2>/dev/null | grep -q ":$PORT" \
    && echo "  $SVC restarted dry_run=$V ($([ "$V" = 0 ] && echo 'ARMED' || echo 'SHADOW -- forwards nothing'))" \
    || { echo "  did NOT come back on :$PORT"; tail -20 "$LOG"; exit 1; }
  echo "  stratum untouched: active=$(systemctl is-active "$UNIT") NRestarts=$(systemctl show "$UNIT" -p NRestarts --value)"
  exit 0
fi

##############################################################################
if [ "$MODE" = "STOP" ]; then
  systemctl disable --now "$SVC" >/dev/null 2>&1 && echo "  $SVC stopped+disabled" || true
  pkill -f 'adapter-v6.py' && echo "  adapter stopped" || echo "  adapter was not running"
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$PORT" && echo "  WARNING :$PORT still listening" \
    || echo "  :$PORT clear"
  exit 0
fi

##############################################################################
if [ "$MODE" = "STATUS" ]; then
  hr "service"
  systemctl --no-pager -l status "$SVC" 2>/dev/null | head -8 || echo "  no $SVC"
  ss -ltn 2>/dev/null | grep ":$PORT" || echo "  nothing on :$PORT"
  grep -h '^ZCU_DRY_RUN=' "$ENVF" 2>/dev/null || echo "  (no ZCU_DRY_RUN set)"
  hr "counters"
  python3 - "$CAP" <<'PY'
import sys, json, os, collections, time
p = sys.argv[1]
if not os.path.exists(p): print("  no capture file"); raise SystemExit(0)
k = collections.Counter(); last = {}
for line in open(p):
    try: o = json.loads(line)
    except Exception: continue
    k[o.get("kind")] += 1; last[o.get("kind")] = o
for n, v in k.most_common(): print(f"  {n:<20} {v}")
print("""
  queue_dropped  = shares shed under load. NON-ZERO IS FINE -- it means the
                   bounded queue protected the stratum. Only a winner-rate
                   comparison matters, not this number.
  geth_fail      = loud failures (v5 would have faked a template here)
  self_disarm    = adapter took ZCU out of rotation on its own
  would_forward  = winners found in SHADOW (nothing submitted)
  forwarded      = real submits to geth""")
for n in ("forwarded", "forward_rejected", "forward_error", "self_disarm", "self_rearm"):
    o = last.get(n)
    if o: print(f"\n  last {n}: {json.dumps({x: str(y)[:90] for x, y in o.items() if x != 'auxpow'})}")
PY
  hr "recent log"
  tail -25 "$LOG" 2>/dev/null || echo "  no $LOG"
  hr "stratum (must be untouched)"
  echo "  active=$(systemctl is-active "$UNIT")  NRestarts=$(systemctl show "$UNIT" -p NRestarts --value)"
  exit 0
fi

##############################################################################
# INSTALL
R0=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum NRestarts at start = ${R0:-?}"

hr "1. stand down every older adapter"
for u in zcu-gate zcu-adapter "$SVC"; do systemctl stop "$u" >/dev/null 2>&1 || true; done
pkill -f 'adapter-gate.py'    >/dev/null 2>&1 || true
pkill -f 'adapter-capture.py' >/dev/null 2>&1 || true
pkill -f 'adapter-v6.py'      >/dev/null 2>&1 || true
sleep 2
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
  echo "  REFUSING: something still listening on :$PORT. Stop it first:"
  echo "    sudo pkill -f '/opt/zcu-adapter/adapter'"
  exit 1
fi

hr "2. write the v6 adapter"
mkdir -p /opt/zcu-adapter
cat > "$PY" <<'PYEOF'
#!/usr/bin/env python3
"""ZCU aux adapter v6 -- non-blocking, fail-loud, self-disarming.

Contract with the stratum (the part that matters):
  * submitauxblock ALWAYS returns `true` immediately. No scrypt, no geth call,
    no await on anything that can be slow. Work is handed to a bounded queue;
    if the queue is full the share is dropped and counted.
  * Every geth call has a hard timeout and is made OFF the submit path except
    for createauxblock/getblockcount, which are cheap reads.
  * A geth failure is reported as a real JSON-RPC error -- never a fabricated
    template. After FAIL_TRIP consecutive failures the adapter self-disarms and
    errors every mining method so yiimp drops ZCU alone.
"""
import asyncio, json, logging, os, time, hashlib
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from aiohttp import web, ClientSession, ClientTimeout, BasicAuth

GETH_URL   = os.environ.get("GETH_URL", "http://127.0.0.1:8747")
GETH_USER  = os.environ.get("GETH_USER", "zcu")
GETH_PASS  = os.environ.get("GETH_PASS", "zcu")
LISTEN     = os.environ.get("LISTEN_HOST", "127.0.0.1")
PORT       = int(os.environ.get("LISTEN_PORT", "8749"))
CAPTURE    = os.environ.get("CAPTURE_FILE", "/var/log/zcu-v6-capture.jsonl")
POOL_ADDR  = os.environ.get("POOL_ADDR", "0xe3Aa1b921b0865E4092EB2CE2672Fcac3990Bdfe")

RPC_TIMEOUT   = float(os.environ.get("RPC_TIMEOUT", "2.0"))    # hard, every read
SUBMIT_TIMEOUT= float(os.environ.get("SUBMIT_TIMEOUT", "10"))  # off the hot path
QUEUE_MAX     = int(os.environ.get("QUEUE_MAX", "256"))        # bounded, shed above
WORKERS       = int(os.environ.get("WORKERS", "2"))            # bounded CPU
MAX_FWD_PER_MIN = int(os.environ.get("MAX_FWD_PER_MIN", "6"))
FAIL_TRIP     = int(os.environ.get("FAIL_TRIP", "5"))          # consecutive geth fails
DRY_RUN       = os.environ.get("ZCU_DRY_RUN", "1") == "1"      # SHADOW BY DEFAULT

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zcu-v6")

session = None
WORK = {}
FWD = deque()
QUEUE: "asyncio.Queue" = None
POOL = ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="zcu-gate")

class Health:
    fails = 0
    disarmed = False
H = Health()


def record(kind, obj):
    obj["kind"] = kind; obj["ts"] = time.time()
    try:
        with open(CAPTURE, "a") as fh:
            fh.write(json.dumps(obj) + "\n")
    except Exception as e:
        log.error("capture write failed: %s", e)


def ok(rid, result):  return {"result": result, "error": None, "id": rid}
def err(rid, code, m): return {"result": None, "error": {"code": code, "message": m}, "id": rid}


def note_ok():
    if H.disarmed:
        H.disarmed = False
        log.warning("geth healthy again -- ZCU RE-ARMED")
        record("self_rearm", {})
    H.fails = 0


def note_fail(why):
    H.fails += 1
    if H.fails >= FAIL_TRIP and not H.disarmed:
        H.disarmed = True
        log.error("SELF-DISARM after %d consecutive geth failures (%s). "
                  "ZCU will now error out of the aux rotation; other coins unaffected.",
                  H.fails, why)
        record("self_disarm", {"fails": H.fails, "why": str(why)[:200]})


async def geth(method, params=None, timeout=None):
    """Never raises. Returns (result, error_string)."""
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    try:
        async with session.post(GETH_URL, json=payload,
                                auth=BasicAuth(GETH_USER, GETH_PASS),
                                timeout=ClientTimeout(total=timeout or RPC_TIMEOUT)) as r:
            j = await r.json(content_type=None)
    except Exception as e:
        note_fail(e); record("geth_fail", {"method": method, "error": str(e)[:200]})
        return None, f"geth unreachable: {e}"
    if not isinstance(j, dict) or j.get("error"):
        e = (j or {}).get("error")
        note_fail(e); record("geth_fail", {"method": method, "error": str(e)[:200]})
        return None, f"geth error: {e}"
    if j.get("result") is None:
        note_fail("empty result"); record("geth_fail", {"method": method, "error": "empty result"})
        return None, "geth returned empty result"
    note_ok()
    return j["result"], None


# ---------------------------------------------------------------- mining RPCs
def disarmed_guard(rid):
    if H.disarmed:
        return err(rid, -32603, "ZCU adapter self-disarmed: geth unhealthy")
    return None


async def m_getblockcount(rid, p):
    g = disarmed_guard(rid)
    if g: return g
    res, e = await geth("eth_blockNumber")
    if e: return err(rid, -32603, e)          # LOUD. never a fake height.
    return ok(rid, int(res, 16))


async def m_getinfo(rid, p):
    g = disarmed_guard(rid)
    if g: return g
    res, e = await geth("eth_blockNumber")
    if e: return err(rid, -32603, e)
    return ok(rid, {"version": 1000000, "protocolversion": 70015,
                    "blocks": int(res, 16), "connections": 8, "difficulty": 1,
                    "testnet": False, "errors": ""})


async def m_getmininginfo(rid, p):
    g = disarmed_guard(rid)
    if g: return g
    res, e = await geth("eth_blockNumber")
    if e: return err(rid, -32603, e)
    return ok(rid, {"blocks": int(res, 16), "difficulty": 1, "networkhashps": 0,
                    "chain": "main", "warnings": ""})


async def m_getblocktemplate(rid, p):
    """Real height or a real error -- v5's height=1 placeholder is gone."""
    g = disarmed_guard(rid)
    if g: return g
    res, e = await geth("eth_blockNumber")
    if e: return err(rid, -32603, e)
    height = int(res, 16)
    now = int(time.time())
    prev = "%064x" % height
    return ok(rid, {
        "version": 536870912, "rules": [], "vbavailable": {}, "vbrequired": 0,
        "previousblockhash": prev, "transactions": [], "coinbaseaux": {"flags": ""},
        "coinbasevalue": 0, "longpollid": prev + str(now),
        "target": "0" * 8 + "f" * 56, "mintime": now - 600,
        "mutable": ["time", "transactions", "prevblock"],
        "noncerange": "00000000ffffffff", "sigoplimit": 80000,
        "sizelimit": 4000000, "weightlimit": 4000000,
        "curtime": now, "bits": "1d00ffff", "height": height + 1,
    })


async def m_createauxblock(rid, p):
    g = disarmed_guard(rid)
    if g: return g
    addr = p[0] if p else POOL_ADDR
    res, e = await geth("scrypt_createAuxBlock", [addr])
    if e: return err(rid, -32603, e)
    h = (res.get("hash") or "").lower().replace("0x", "") if isinstance(res, dict) else ""
    if h:
        if h not in WORK:
            record("auxwork", {"keys": sorted(res.keys())})
        WORK[h] = res
        if len(WORK) > 512:
            for k in list(WORK)[:256]:
                WORK.pop(k, None)
    return ok(rid, res)


async def m_validateaddress(rid, p):
    a = p[0] if p else ""
    return ok(rid, {"isvalid": bool(a), "address": a, "ismine": True, "isscript": False})

async def m_getrawchangeaddress(rid, p): return ok(rid, POOL_ADDR)
async def m_getdifficulty(rid, p):       return ok(rid, 1.0)
async def m_getbalance(rid, p):          return ok(rid, 0.0)
async def m_listsinceblock(rid, p):      return ok(rid, {"transactions": [], "lastblock": "00" * 32})


# ---------------------------------------------------------------- the gate
def scrypt_display(hdr80: bytes) -> int:
    h = hashlib.scrypt(hdr80, salt=hdr80, n=1024, r=1, p=1, dklen=32,
                       maxmem=256 * 1024 * 1024)
    return int.from_bytes(h[::-1], "big")


def meets_target(auxpow_hex: str, work: dict):
    """(hit, ratio). Any doubt => False: a forwarded reject is the costly outcome."""
    tgt_hex = ((work or {}).get("target") or "").replace("0x", "")
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
    """O(1). Enqueue or shed -- then ACK true. Never blocks, never errors."""
    if len(p) >= 2:
        item = (str(p[0] or "").lower().replace("0x", ""), str(p[1] or ""), p[0], p[1])
        try:
            QUEUE.put_nowait(item)
        except asyncio.QueueFull:
            record("queue_dropped", {"hash": item[0]})
    else:
        record("gated_bad", {"params": str(p)[:200]})
    return ok(rid, True)


async def gate_worker(n):
    loop = asyncio.get_running_loop()
    while True:
        h, auxpow, raw_h, raw_aux = await QUEUE.get()
        try:
            work = WORK.get(h)
            hit, ratio = await loop.run_in_executor(POOL, meets_target, auxpow, work)
            if not hit:
                record("gated_miss", {"hash": h, "ratio": ratio})
                continue
            if DRY_RUN:
                log.warning("SHADOW WINNER hash=%s ratio=%.6f (not submitted)", h, ratio or 0)
                record("would_forward", {"hash": h, "ratio": ratio, "auxpow": auxpow})
                continue
            if not fwd_allowed():
                log.error("winner suppressed by rate limit %d/min -- gating suspect", MAX_FWD_PER_MIN)
                record("forward_ratelimited", {"hash": h, "ratio": ratio})
                continue
            log.warning("WINNER hash=%s ratio=%.6f -- forwarding", h, ratio or 0)
            res, e = await geth("scrypt_submitAuxBlock", [raw_h, raw_aux],
                                timeout=SUBMIT_TIMEOUT)
            if e:
                log.error("geth refused a gated winner: %s", e)
                record("forward_rejected", {"hash": h, "ratio": ratio, "error": e})
            else:
                log.warning("ZCU BLOCK ACCEPTED: %s", str(res)[:120])
                record("forwarded", {"hash": h, "ratio": ratio, "result": res})
        except Exception as ex:
            log.error("gate worker %d error (share dropped): %s", n, ex)
            record("gated_error", {"hash": h, "error": str(ex)[:200]})
        finally:
            QUEUE.task_done()


HANDLERS = {
    "getinfo": m_getinfo, "getblockcount": m_getblockcount,
    "getdifficulty": m_getdifficulty, "getmininginfo": m_getmininginfo,
    "validateaddress": m_validateaddress,
    "getrawchangeaddress": m_getrawchangeaddress, "getnewaddress": m_getrawchangeaddress,
    "createauxblock": m_createauxblock, "getauxblock": m_createauxblock,
    "getblocktemplate": m_getblocktemplate,
    "listsinceblock": m_listsinceblock, "getbalance": m_getbalance,
    "submitauxblock": m_submitauxblock,
    # geth-style aliases the forward-ported stratum calls directly
    "scrypt_createauxblock": m_createauxblock,
    "scrypt_getauxblock": m_createauxblock,
    "scrypt_submitauxblock": m_submitauxblock,
}


async def handle(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response(err(None, -32700, "parse error"))
    rid = body.get("id")
    method = str(body.get("method", "")).lower()
    params = body.get("params") or []
    fn = HANDLERS.get(method)
    if not fn:
        record("unhandled", {"method": method})
        return web.json_response(err(rid, -32601, f"method not supported: {method}"))
    try:
        return web.json_response(await fn(rid, params))
    except Exception as e:
        log.error("handler %s threw: %s", method, e)
        # submitauxblock can never reach here (it cannot throw), so an error is safe
        return web.json_response(err(rid, -32603, str(e)))


async def main():
    global session, QUEUE
    QUEUE = asyncio.Queue(maxsize=QUEUE_MAX)
    session = ClientSession()
    for i in range(WORKERS):
        asyncio.create_task(gate_worker(i))
    app = web.Application()
    app.router.add_post("/", handle)
    runner = web.AppRunner(app); await runner.setup()
    await web.TCPSite(runner, LISTEN, PORT).start()
    log.warning("zcu-adapter v6 listening on %s:%d  dry_run=%s workers=%d queue=%d "
                "rpc_timeout=%.1fs", LISTEN, PORT, DRY_RUN, WORKERS, QUEUE_MAX, RPC_TIMEOUT)
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    asyncio.run(main())
PYEOF
chmod +x "$PY"
python3 -c "import ast,sys; ast.parse(open('$PY').read())" || { echo "  adapter failed to parse"; exit 1; }
echo "  wrote $PY (syntax OK)"

hr "3. env (SHADOW by default)"
if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<EOF
GETH_URL=http://127.0.0.1:$GETH_PORT
LISTEN_PORT=$PORT
CAPTURE_FILE=$CAP
ZCU_DRY_RUN=1
RPC_TIMEOUT=2.0
QUEUE_MAX=256
WORKERS=2
FAIL_TRIP=5
MAX_FWD_PER_MIN=6
EOF
  echo "  created $ENVF"
else
  echo "  keeping existing $ENVF"
fi
grep -q '^ZCU_DRY_RUN=' "$ENVF" || echo "ZCU_DRY_RUN=1" >> "$ENVF"

hr "4. systemd unit"
cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=ZCU aux adapter v6 (non-blocking, fail-loud)
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 $PY
Restart=always
RestartSec=5
StandardOutput=append:$LOG
StandardError=append:$LOG
# bounded CPU so a gating bug can never starve the box the stratum runs on
CPUQuota=150%
MemoryMax=1G

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now $SVC
for i in $(seq 1 10); do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; sleep 1; done

hr "5. verify"
ss -ltn 2>/dev/null | grep -q ":$PORT" && echo "  listening on :$PORT" \
  || { echo "  NOT listening"; tail -30 "$LOG"; exit 1; }
echo -n "  getblockcount -> "
curl -s -m 5 -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}' \
  "http://127.0.0.1:$PORT/" | head -c 200; echo
R1=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null)
echo "  stratum: active=$(systemctl is-active "$UNIT")  NRestarts=${R0:-?} -> ${R1:-?} (must be unchanged)"

cat <<EOF

NEXT STEPS
  1. ZCU is still OUT of the yiimp rotation (coins.enable=0). This adapter is
     running in SHADOW: it answers, gates, and logs winners, but submits
     nothing and nothing routes to it yet.
  2. Leave it 24h. Check with:  ... | sudo bash -s STATUS
     Want: self_disarm=0, geth_fail low, gated_miss climbing, stratum
     NRestarts unchanged, LTC/DOGE/TXC/ISK find rates flat (mining-canary).
  3. Only then re-enable ZCU in coins and ARM:
       curl -fsSL https://pool.honest.money/install/zcu-adapter-v6.sh | sudo bash -s ARM
     ARM refuses if shadow has run <24h.
EOF
fi
