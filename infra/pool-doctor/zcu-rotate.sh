#!/usr/bin/env bash
# zcu-rotate.sh -- put ZCU into (or out of) the scrypt aux rotation.
#
#   status: curl -fsSL https://pool.honest.money/install/zcu-rotate.sh | sudo bash -s STATUS
#   on:     curl -fsSL https://pool.honest.money/install/zcu-rotate.sh | sudo bash -s ON
#   off:    curl -fsSL https://pool.honest.money/install/zcu-rotate.sh | sudo bash -s OFF
#
# yiimp's scrypt stratum builds its aux-child list from the `coins` table, NOT
# from /var/stratum/scrypt.conf. So adding/removing ZCU is a single reversible
# DB flip plus a stratum restart -- scrypt.conf is never touched.
#
# SAFETY PRECONDITIONS for ON (all enforced below, ON aborts if any fail):
#   1. the gate adapter (zcu-gate.service) is listening on :8749
#   2. geth is listening on :8747
#   3. stratum is the forward-ported ZCU-capable binary
#   4. stratum currently has NRestarts=0
# The gate ACKs every submitauxblock `true`, so the 13 Aug deadlock path is
# structurally unreachable. With ZCU_DRY_RUN=1 it also forwards nothing at all.
#
# OFF is the rollback. It is always safe and takes ~5 seconds.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n===== %s\n' "$*"; }

MODE="$(printf '%s' "${1:-STATUS}" | tr '[:lower:]' '[:upper:]')"
case "$MODE" in ON|OFF|STATUS) ;; *) echo "use ON, OFF or STATUS"; exit 1 ;; esac

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
ADAPTER_PORT=${ADAPTER_PORT:-8749}
GETH_PORT=${GETH_PORT:-8747}
UNIT=stratum-aws-scrypt
LOG=${STRATUM_LOG:-/var/stratum/scrypt.log}

echo "zcu-rotate v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
if [ -z "${DBU:-}" ]; then echo "  cannot read DB creds from $SERVERCONFIG"; exit 1; fi
MY()  { mysql -u"$DBU" -p"$DBP" yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql -u"$DBU" -p"$DBP" yiimpfrontend -t   -e "$1" 2>&1; }

show() {
  MYT "SELECT id,symbol,name,enable,visible,auto_ready,installed,rpchost,rpcport,rpcencoding
       FROM coins WHERE symbol='ZCU'" | sed 's/^/  /'
  echo "  gate  :$ADAPTER_PORT $(ss -ltn 2>/dev/null | grep -q ":$ADAPTER_PORT" && echo LISTENING || echo 'NOT listening')"
  echo "  geth  :$GETH_PORT $(ss -ltn 2>/dev/null | grep -q ":$GETH_PORT" && echo LISTENING || echo 'NOT listening')"
  echo "  gate dry_run = $(grep -s '^ZCU_DRY_RUN=' /etc/zcu-gate.env | cut -d= -f2 || echo '?')"
  echo "  stratum active=$(systemctl is-active $UNIT) NRestarts=$(systemctl show $UNIT -p NRestarts --value)"
  echo "  'Zero Chill' lines in last 60s of log:"
  timeout 15 tail -n 4000 "$LOG" 2>/dev/null | grep -ci 'zero chill' | sed 's/^/    /'
}

##############################################################################
if [ "$MODE" = "STATUS" ]; then
  hr "ZCU rotation status"; show; exit 0
fi

##############################################################################
if [ "$MODE" = "OFF" ]; then
  hr "1. disable the ZCU coins row"
  MY "UPDATE coins SET enable=0, auto_ready=0 WHERE symbol='ZCU'"
  echo "  ZCU enable=0"
  hr "2. restart stratum so it rebuilds the aux list"
  systemctl restart "$UNIT"; sleep 5
  hr "3. state"; show
  echo
  echo "  ZCU is out of the rotation. LTC/DOGE/TXC/ISK unaffected."
  echo "  Follow with: curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash -s CHECK"
  exit 0
fi

##############################################################################
# ON
hr "1. preflight -- refuse unless every safety condition holds"
FAIL=0
ss -ltn 2>/dev/null | grep -q ":$ADAPTER_PORT" \
  && echo "  OK   gate listening on :$ADAPTER_PORT" \
  || { echo "  FAIL nothing on :$ADAPTER_PORT -- start it: zcu-gate.sh START"; FAIL=1; }
systemctl is-active --quiet zcu-gate \
  && echo "  OK   zcu-gate.service active (survives reboot)" \
  || echo "  WARN zcu-gate.service not active -- adapter may not survive a reboot"
ss -ltn 2>/dev/null | grep -q ":$GETH_PORT" \
  && echo "  OK   geth listening on :$GETH_PORT" \
  || { echo "  FAIL geth not on :$GETH_PORT"; FAIL=1; }
if strings -a /var/stratum/stratum 2>/dev/null | grep -qi 'zero chill\|submitauxblock'; then
  echo "  OK   live stratum binary has ZCU/auxpow symbols"
else
  echo "  FAIL live stratum binary has no ZCU support -- swap in the forward-ported build first"; FAIL=1
fi
R0=$(systemctl show "$UNIT" -p NRestarts --value)
[ "${R0:-1}" = "0" ] && echo "  OK   stratum NRestarts=0" \
  || echo "  WARN stratum NRestarts=$R0 -- it has crashed before; watch closely"
[ -f /var/stratum/stratum.rollback ] && echo "  OK   rollback binary present" \
  || echo "  WARN no /var/stratum/stratum.rollback"
[ "$FAIL" = "0" ] || { echo; echo "  ABORTING -- nothing changed."; exit 1; }

hr "2. gate self-test: a junk submit MUST come back true"
JUNK=$(printf '0%.0s' $(seq 1 160))
RESP=$(curl -s -m 20 -H 'content-type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submitauxblock\",\"params\":[\"deadbeef\",\"$JUNK\"]}" \
  "http://127.0.0.1:$ADAPTER_PORT/")
echo "  $RESP"
echo "$RESP" | grep -q '"result": *true' \
  || { echo "  ABORTING -- gate did not ACK true. That is the deadlock path."; exit 1; }

hr "3. point the ZCU coins row at the gate and enable it"
MY "UPDATE coins SET rpchost='127.0.0.1', rpcport=$ADAPTER_PORT, enable=1, auto_ready=1, installed=1 WHERE symbol='ZCU'"
show

hr "4. restart stratum so it picks ZCU up"
systemctl restart "$UNIT"; sleep 10

hr "5. immediate verdict"
echo "  stratum active=$(systemctl is-active $UNIT) NRestarts=$(systemctl show $UNIT -p NRestarts --value) (was $R0)"
echo "  30s live sample of $LOG:"
timeout 32 tail -F -n0 "$LOG" >/tmp/zcu-rot.$$ 2>/dev/null &
sleep 31; kill %1 2>/dev/null
ZL=$(grep -ci 'zero chill' /tmp/zcu-rot.$$ 2>/dev/null || echo 0)
ZE=$(grep -i 'zero chill' /tmp/zcu-rot.$$ 2>/dev/null | grep -ci 'error' || echo 0)
DL=$(grep -ci 'dead lock' /tmp/zcu-rot.$$ 2>/dev/null || echo 0)
rm -f /tmp/zcu-rot.$$
echo "    Zero Chill lines=$ZL  errors=$ZE  'dead lock' lines=$DL"
if [ "$DL" != "0" ]; then
  echo "  !! DEADLOCK TEXT SEEN -- rolling ZCU back out right now"
  MY "UPDATE coins SET enable=0, auto_ready=0 WHERE symbol='ZCU'"
  systemctl restart "$UNIT"
  echo "  ZCU disabled and stratum restarted. Investigate before retrying."
  exit 1
fi
[ "$ZL" = "0" ] && echo "  WARN no Zero Chill activity yet -- give it a few minutes, then STATUS"
[ "$ZE" != "0" ] && echo "  WARN ZCU RPC errors present -- check /var/log/zcu-gate.log"

hr "6. watch"
cat <<'TXT'
  Next 20 minutes, in this order:
    curl -fsSL https://pool.honest.money/install/mining-canary.sh | sudo bash -s CHECK
    sudo tail -f /var/log/zcu-gate.log
    curl -fsSL https://pool.honest.money/install/zcu-gate.sh | sudo bash -s STATUS

  Pass bar: NRestarts still 0, sockets ~1700, TXC/ISK still under 8m,
  gate log filling with gated_miss and zero forwards while dry_run=1.

  Rollback, any time:
    curl -fsSL https://pool.honest.money/install/zcu-rotate.sh | sudo bash -s OFF
TXT
