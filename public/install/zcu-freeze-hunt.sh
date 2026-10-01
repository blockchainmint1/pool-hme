#!/usr/bin/env bash
# zcu-freeze-hunt.sh -- READ ONLY. One question:
#   "Is ZCU what freezes the whole scrypt stratum?"
#
#   run:  curl -fsSL "https://pool.honest.money/install/zcu-freeze-hunt.sh?v=$(date +%s)" | sudo bash
#
# A "freeze" = TXC AND ISK both silent > 12 min starting at the same moment
# (they share the parent work, so a joint gap = the stratum stalled).
# For every freeze in the last 7 days this shows what the ZCU side
# (zcu-gate adapter, geth node, ZCU lines in the stratum log) was doing in the
# 10 minutes BEFORE blocks stopped, then compares against quiet periods.
# Makes NO changes.
set -u
MY()  { mysql yiimpfrontend -N -B -e "$1" 2>/dev/null; }
MYT() { mysql yiimpfrontend -t -e "$1" 2>&1; }
H() { echo; echo "===== $*"; }
GETH=http://127.0.0.1:8747
RPC() { curl -s -m 5 -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":[${2:-}]}" "$GETH"; }
ZRX='error|fail|timeout|timed out|refused|reset|exception|traceback|disarm|fake|stale|busy|queue|overload|slow'
echo "zcu-freeze-hunt v1  $(date -u '+%F %T') UTC"

H "1. ZCU as the stratum sees it right now"
MYT "SELECT id,symbol,enable,auto_ready,auxpow,rpchost,rpcport FROM coins WHERE symbol='ZCU';"
for u in zcu-gate zcu-mainnet-geth zcu-tip-sync.timer zcu-deadman.timer stratum-aws-scrypt; do
  printf '  %-22s %s  since %s  NRestarts=%s\n' "$u" "$(systemctl is-active $u 2>/dev/null)" \
    "$(systemctl show -p ActiveEnterTimestamp --value $u 2>/dev/null)" "$(systemctl show -p NRestarts --value $u 2>/dev/null)"
done
ls -l --time-style=+%F_%T /opt/zcu-adapter/*.py 2>/dev/null | sed 's/^/  /'

H "2. ZCU network load -- is real usage rising? (tx per block, gas, txpool)"
T0=$(date +%s%N); TIP=$(RPC eth_blockNumber | grep -o '"result":"[^"]*' | cut -d'"' -f4); T1=$(date +%s%N)
echo "  geth tip=$((TIP)) (hex $TIP)  rpc_latency=$(( (T1-T0)/1000000 ))ms  peers=$(( $(RPC net_peerCount | grep -o '0x[0-9a-f]*' | head -1) ))"
echo "  txpool: $(RPC txpool_status | grep -o '"result":{[^}]*}')"
if [ -n "$TIP" ]; then
  echo "  block    txs  gasUsed     (sampled every 50 blocks, newest first)"
  for i in 0 50 100 200 400 800 1600 3200 6400; do
    n=$(( TIP - i )); [ $n -lt 1 ] && break
    b=$(RPC eth_getBlockByNumber "\"$(printf '0x%x' $n)\",false")
    tx=$(echo "$b" | grep -o '"transactions":\[[^]]*\]' | grep -o '0x[0-9a-f]\{64\}' | wc -l)
    gas=$(echo "$b" | grep -o '"gasUsed":"0x[0-9a-f]*' | cut -d'"' -f4)
    printf '  %-8s %-4s %s\n' "$n" "$tx" "$(( ${gas:-0} ))"
  done
fi

H "3. ZCU trouble per hour vs TXC finds per hour (last 48h)"
echo "  hour(UTC)        gate_errs geth_errs TXC_finds ISK_finds"
GATE=$(journalctl -u zcu-gate --since -48h -o short-iso --no-pager 2>/dev/null; grep -a '' /var/log/zcu-gate.log 2>/dev/null | tail -200000)
GETHL=$(journalctl -u zcu-mainnet-geth --since -48h -o short-iso --no-pager 2>/dev/null)
for h in $(seq 47 -1 0); do
  k=$(date -u -d "-$h hour" '+%Y-%m-%dT%H'); k2=$(date -u -d "-$h hour" '+%Y-%m-%d %H')
  ge=$(echo "$GATE"  | grep -aE "^($k|$k2)|\[$k2" | grep -aciE "$ZRX")
  ce=$(echo "$GETHL" | grep -aE "^$k" | grep -aciE 'error|fail|timeout|lvl=eror|WARN')
  tf=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='TXC' AND DATE_FORMAT(FROM_UNIXTIME(b.time),'%Y-%m-%d %H')='$k2'")
  isf=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ISK' AND DATE_FORMAT(FROM_UNIXTIME(b.time),'%Y-%m-%d %H')='$k2'")
  printf '  %s:00  %8s %9s %9s %9s\n' "$k2" "$ge" "$ce" "$tf" "$isf"
done
echo "  READ: if gate/geth errors spike in the hours where TXC finds collapse, ZCU is the trigger."

H "4. every FREEZE (TXC+ISK both silent >12 min, same start) in the last 7 days"
FREEZES=$(MY "SELECT t.prev_t, t.t FROM (
   SELECT b.time t, LAG(b.time) OVER (ORDER BY b.time) prev_t FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE c.symbol='TXC' AND b.time>UNIX_TIMESTAMP()-7*86400) t
 JOIN (SELECT b.time t, LAG(b.time) OVER (ORDER BY b.time) prev_t FROM blocks b JOIN coins c ON c.id=b.coin_id
   WHERE c.symbol='ISK' AND b.time>UNIX_TIMESTAMP()-7*86400) i
   ON ABS(i.prev_t-t.prev_t)<=90
 WHERE t.prev_t IS NOT NULL AND t.t-t.prev_t>720 AND i.t-i.prev_t>720 ORDER BY t.prev_t")
echo "  found $(echo "$FREEZES" | grep -c .) freezes"

logfor() { # epoch -> stratum log covering it
  local d=$(date -u -d @$1 '+%Y%m%d') hh=$(date -u -d @$1 '+%H') b
  b=$(printf '%02d' $(( 10#$hh / 3 * 3 )))
  ls /var/stratum/logs/stratum-$d-${b}0000-pid*.log 2>/dev/null | head -1
}
SUMZ=0; SUMN=0
echo "$FREEZES" | while read s e; do
  [ -z "${s:-}" ] && continue
  from=$(date -u -d @$((s-600)) '+%F %T'); to=$(date -u -d @$((s+300)) '+%F %T')
  echo
  echo "--- freeze $(date -u -d @$s '+%F %T') -> $(date -u -d @$e '+%T')  ($(( (e-s)/60 )) min)"
  echo "    ZCU blocks recorded in the freeze: $(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE c.symbol='ZCU' AND b.time BETWEEN $s AND $e")"
  echo "    stratum death within freeze: $(journalctl -u stratum-aws-scrypt --since "@$s" --until "@$e" --no-pager 2>/dev/null | grep -acE 'Main process exited|dead lock')"
  echo "    zcu-gate  (-10m..+5m) problem lines: $(journalctl -u zcu-gate --since "$from" --until "$to" --no-pager 2>/dev/null | grep -aciE "$ZRX")"
  journalctl -u zcu-gate --since "$from" --until "$to" --no-pager 2>/dev/null | grep -aiE "$ZRX" | tail -6 | cut -c1-200 | sed 's/^/      /'
  echo "    geth      (-10m..+5m) problem lines: $(journalctl -u zcu-mainnet-geth --since "$from" --until "$to" --no-pager 2>/dev/null | grep -aciE 'error|fail|timeout|WARN')"
  journalctl -u zcu-mainnet-geth --since "$from" --until "$to" --no-pager 2>/dev/null | grep -aiE 'error|fail|timeout|WARN' | tail -4 | cut -c1-200 | sed 's/^/      /'
  f=$(logfor $s)
  if [ -n "$f" ]; then
    hm0=$(date -u -d @$((s-600)) '+%H:%M:%S'); hm1=$(date -u -d @$((s+300)) '+%H:%M:%S')
    W=$(awk -v a="$hm0" -v b="$hm1" 'substr($0,1,8)>=a && substr($0,1,8)<=b' "$f")
    echo "    stratum log $(basename $f): lines=$(echo "$W" | grep -c .) ZCU=$(echo "$W" | grep -ac ZCU) ZCU_non_skip=$(echo "$W" | grep -a ZCU | grep -avc 'skip target') errors=$(echo "$W" | grep -aciE 'error|fail|timeout|dead lock|could not|unable')"
    echo "$W" | grep -aiE 'ZCU|error|fail|timeout|dead lock|could not|unable' | grep -av 'skip target' | tail -10 | cut -c1-200 | sed 's/^/      /'
    echo "    last stratum line before blocks stopped vs last line in window (a hole = stratum stopped logging):"
    echo "$W" | awk '{print substr($0,1,5)}' | uniq -c | tr '\n' ' ' | sed 's/^/      lines per minute: /'; echo
  else
    echo "    stratum log for that time: not retained"
  fi
done

H "5. control: the same counts for a random QUIET 15-min window (no freeze)"
q=$(( $(date +%s) - 3600 ))
echo "    zcu-gate problem lines in last-hour 15m window: $(journalctl -u zcu-gate --since "@$((q-600))" --until "@$((q+300))" --no-pager 2>/dev/null | grep -aciE "$ZRX")"
echo "    geth problem lines:                            $(journalctl -u zcu-mainnet-geth --since "@$((q-600))" --until "@$((q+300))" --no-pager 2>/dev/null | grep -aciE 'error|fail|timeout|WARN')"
echo "  READ: freezes with far more ZCU problem lines than this quiet window = ZCU is the trigger."

H "6. the crash spot vs ZCU (every stratum death, last 30 days)"
journalctl -u stratum-aws-scrypt --since -30d -o short-unix --no-pager 2>/dev/null | grep -a 'Main process exited' | while read ts rest; do
  t=${ts%.*}
  printf '  %s  gate_errs(-15m)=%s  geth_errs(-15m)=%s\n' "$(date -u -d @$t '+%F %T')" \
    "$(journalctl -u zcu-gate --since "@$((t-900))" --until "@$t" --no-pager 2>/dev/null | grep -aciE "$ZRX")" \
    "$(journalctl -u zcu-mainnet-geth --since "@$((t-900))" --until "@$t" --no-pager 2>/dev/null | grep -aciE 'error|fail|timeout|WARN')"
done

echo; echo "DONE. Paste everything above back to the chat. (no changes were made)"
