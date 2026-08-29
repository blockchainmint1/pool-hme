#!/usr/bin/env bash
# doge-unlock-cycle.sh -- clear a STALE internal lock in /var/web/doge-payout-cycle.sh
#
#   curl -fsSL https://pool.honest.money/install/doge-unlock-cycle.sh | sudo bash              # inspect only
#   curl -fsSL https://pool.honest.money/install/doge-unlock-cycle.sh | sudo bash -s CLEAR CONFIRM  # clear + run one live cycle
#
# WHY
#   REVIVE fixed the cron wiring, but the cycle itself refused to run:
#     "DOGE payout cycle is already running. Exiting without scanning, capturing, or sending."
#   That message is the cycle's OWN guard (a pid/lock file it writes at start and
#   removes at exit), not flock. The last cron-wrapper write was 2026-08-05 06:16 --
#   a run was killed mid-flight that morning and left the lock behind. Every run
#   since has seen the lock, printed that line, and exited. Three weeks of DOGE
#   blocks aged out into wallet float because of one orphan file.
#
#   This script finds the guard the cycle actually uses, proves no cycle process is
#   alive, removes the stale artifact, and runs one live cycle.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-INSPECT}"
CONFIRM="${2:-}"
CYCLE="${CYCLE:-/var/web/doge-payout-cycle.sh}"
RUNDIR="${RUNDIR:-/var/web/runtime/doge-payout}"
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }

echo "doge-unlock-cycle v1  $(date -u '+%F %T UTC')  mode=$MODE"
[ -f "$CYCLE" ] || { echo "FATAL: $CYCLE missing"; exit 1; }
echo

# -------------------------------------------------- 1. what guard does it use?
echo "===== 1. the cycle's own guard (this is what printed 'already running')"
grep -nE 'already running|LOCK|lock|pid|PID|flock|mkdir' "$CYCLE" | head -30 | sed 's/^/    /'
echo
echo "  candidate lock/pid artifacts in $RUNDIR:"
ls -la "$RUNDIR" 2>/dev/null | sed 's/^/    /'

# collect candidates: anything lock/pid-ish the cycle references, plus files on disk
mapfile -t REFS < <(grep -ohE '(/var|\$RUNDIR|\$\{RUNDIR\})[A-Za-z0-9_/.$\{\}-]*(lock|pid)[A-Za-z0-9_.-]*' "$CYCLE" 2>/dev/null | sort -u)
echo
echo "  paths the cycle itself names:"
for r in "${REFS[@]:-}"; do
  [ -n "$r" ] || continue
  p="${r//\$\{RUNDIR\}/$RUNDIR}"; p="${p//\$RUNDIR/$RUNDIR}"
  printf '    %-60s %s\n' "$p" "$([ -e "$p" ] && echo EXISTS || echo absent)"
done

# -------------------------------------------------- 2. is anything actually alive?
echo
echo "===== 2. is a cycle process actually running right now?"
ALIVE=$(pgrep -af 'doge-payout-cycle' | grep -v "$$" | grep -v doge-unlock-cycle)
if [ -n "$ALIVE" ]; then
  echo "$ALIVE" | sed 's/^/    /'
  echo "  !! a real cycle process IS alive. Do NOT clear the lock -- let it finish."
else
  echo "    (none) -- no doge-payout-cycle process exists. Any lock on disk is STALE."
fi

echo
echo "  age of each existing lock-ish file (stale = older than a few minutes):"
NOW=$(date +%s); STALE_FILES=()
while IFS= read -r f; do
  [ -e "$f" ] || continue
  AGE=$(( NOW - $(stat -c %Y "$f") ))
  printf '    %-58s %sh old\n' "$f" "$((AGE/3600))"
  # a pid file: check whether that pid still exists
  if [ -f "$f" ] && [ "$(stat -c %s "$f")" -lt 32 ]; then
    P=$(tr -dc '0-9' < "$f" | head -c 10)
    if [ -n "$P" ]; then
      kill -0 "$P" 2>/dev/null \
        && { echo "        holds pid $P which IS alive -- leaving alone"; continue; } \
        || echo "        holds pid $P which is DEAD -- stale"
    fi
  fi
  [ "$AGE" -gt 900 ] && STALE_FILES+=("$f")
done < <(find "$RUNDIR" -maxdepth 1 \( -name '*lock*' -o -name '*.pid' -o -name '*running*' \) 2>/dev/null)

echo
if [ "${#STALE_FILES[@]}" -eq 0 ]; then
  echo "  no stale artifacts found in $RUNDIR."
else
  echo "  STALE (>15 min old, no live owner):"
  printf '    %s\n' "${STALE_FILES[@]}"
fi

# -------------------------------------------------- 3. clear
if [ "$MODE" != CLEAR ]; then
  echo
  echo "inspect-only. To clear and run one live cycle:"
  echo "  curl -fsSL https://pool.honest.money/install/doge-unlock-cycle.sh | sudo bash -s CLEAR CONFIRM"
  exit 0
fi
if [ "$CONFIRM" != CONFIRM ]; then
  echo; echo "CLEAR needs CONFIRM as the second argument. Nothing changed."; exit 0
fi
if [ -n "$ALIVE" ]; then
  echo; echo "REFUSING: a cycle process is alive. Re-run when it exits."; exit 1
fi

echo
echo "===== 3. CLEAR"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUNDIR/stale-$STAMP"
for f in "${STALE_FILES[@]:-}"; do
  [ -e "$f" ] || continue
  mv "$f" "$RUNDIR/stale-$STAMP/" && echo "  moved aside: $f"
done
echo "  (originals preserved in $RUNDIR/stale-$STAMP)"

echo
echo "===== 4. one live cycle"
flock -n "$RUNDIR/doge-payout-cycle.lock" bash "$CYCLE" 2>&1 | tail -60

echo
echo "===== 5. ledger after"
MY "SELECT status, COUNT(*) rows_, ROUND(SUM(amount),2) doge,
           FROM_UNIXTIME(MAX(updated_at)) last_touch
    FROM doge_payout_ledger GROUP BY status ORDER BY doge DESC"
echo
echo "  capture in the last hour (should be non-zero if blocks were found):"
MY "SELECT COUNT(*) new_rows, ROUND(IFNULL(SUM(amount),0),2) doge
    FROM doge_payout_ledger WHERE created_at > UNIX_TIMESTAMP()-3600"
echo
echo "  next automatic run: within 10 minutes. Watch:"
echo "    sudo tail -f $RUNDIR/cycle.log"
