#!/usr/bin/env bash
# doge-target-check.sh -- READ ONLY. One question:
#   "Do enough of our shares beat DOGE's target, and if they do, what stops them
#    from being submitted?"
# run: curl -fsSL "https://pool.honest.money/install/doge-target-check.sh?v=$(date +%s)" | sudo bash
# Makes NO changes anywhere.
# v1 2026-10-06 initial
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
DOGECLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -datadir=/home/ubuntu/.dogecoin"
hr() { printf '\n===== %s\n' "$*"; }
echo "doge-target-check v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
LOGS=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum-2*.log 2>/dev/null | head -60)
ALL=/tmp/doge-target-check.all
for F in $LOGS; do grep -aE 'aux submit|aux compare stage=|DOGE aux template' "$F" 2>/dev/null; done > "$ALL"
echo "  log files scanned: $(echo "$LOGS" | wc -w)   lines kept: $(wc -l < "$ALL")"

hr "1. per coin: how many shares reached the submit decision, and what happened"
for C in DOGE TXC ISK; do
  echo "  --- $C ---"
  grep -aE "^[0-9: ]*$C aux submit" "$ALL" | sed -E 's/^[0-9: -]+//; s/ hash=.*//; s/ parent_diff=.*//; s/ [a-z_]+=[0-9a-f.]+.*//' \
    | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
done

hr "2. best shares vs each coin's target (from 'skip target' lines)"
python3 - "$ALL" <<'PY'
import sys,re
pd=re.compile(r'parent_diff=([0-9.]+)'); cd=re.compile(r'child_diff=([0-9.]+)')
for c in ("DOGE","TXC","ISK"):
    ps=[];cs=[]
    for l in open(sys.argv[1],errors="ignore"):
        if f"{c} aux submit skip target" not in l: continue
        a=pd.search(l); b=cd.search(l)
        if a: ps.append(float(a.group(1)))
        if b: cs.append(float(b.group(1)))
    if not ps: print(f"  {c:4}  no 'skip target' lines"); continue
    ps.sort(); cmed=sorted(cs)[len(cs)//2] if cs else 0
    over=sum(1 for p in ps if cmed and p>=cmed)
    print(f"  {c:4}  lines={len(ps):>8}  best share={ps[-1]:>14,.0f}  typical target={cmed:>14,.0f}  shares above target={over}")
PY
echo "  READ: a coin's 'skip target' lines are shares that did NOT reach its target."
echo "        If DOGE's best share sits far below DOGE's target while TXC's reaches TXC's,"
echo "        DOGE is getting the wrong target number, not bad luck."

hr "3. DOGE wins that got past the target: submitted, stale, or refused?"
grep -aE 'DOGE.*(stage=|submit dispatch|skip stale|reject|accepted=)' "$ALL" | grep -av 'skip target' | tail -20 | cut -c1-220 | sed 's/^/  /'

hr "4. is the DOGE job behind the DOGE network? (job height vs node tip)"
TIP=$($DOGECLI getblockcount 2>/dev/null)
LAST=$(grep -a 'DOGE aux template' "$ALL" | tail -1 | grep -oE 'height=[0-9]+' | cut -d= -f2)
echo "  node tip=$TIP   newest job height in log=$LAST   (job height should be tip or tip+1)"
python3 - "$ALL" <<'PY'
import sys,re
h=[int(m.group(1)) for l in open(sys.argv[1],errors="ignore") if "DOGE aux template" in l for m in [re.search(r' height=(\d+)',l)] if m]
hs=[int(m.group(1)) for l in open(sys.argv[1],errors="ignore") if "DOGE aux template" in l for m in [re.search(r'hash=([0-9a-f]+)',l)] if m]
print(f"  DOGE job refreshes in logs: {len(h)}")
PY
grep -a 'DOGE template mode' /var/stratum/scrypt.log 2>/dev/null | tail -2000 > /tmp/dtc.mode
grep -a 'DOGE aux template' /var/stratum/scrypt.log 2>/dev/null | tail -2000 > /tmp/dtc.aux
paste -d' ' <(grep -oE 'height=[0-9]+' /tmp/dtc.mode | cut -d= -f2) <(grep -oE ' height=[0-9]+' /tmp/dtc.aux | cut -d= -f2) 2>/dev/null \
  | awk 'NF==2{d=$1-$2; c[d]++} END{for(k in c) printf "  template-minus-job gap %s blocks: %d times\n",k,c[k]}' | sort
echo "  READ: a gap of 1 is normal. Gaps of 2+ most of the time mean the miners work on"
echo "        a DOGE block that is already old -- every win on it would be stale."

hr "done -- paste everything to the assistant"
