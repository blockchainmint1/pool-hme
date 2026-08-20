#!/usr/bin/env bash
# aux-freshness.sh -- READ ONLY. Answers exactly one question:
#   "TXC/ISK stopped finding blocks at HH:MM -- is the aux work stale,
#    is the target unreachable, or are the daemons unreachable?"
#
#   run:  curl -fsSL "https://pool.honest.money/install/aux-freshness.sh?v=$(date +%s)" | sudo bash
#
# Makes NO changes: no writes to config, DB, systemd or the stratum process.
#
# Why this exists (20 Aug 2026): TXC/ISK earnings + blocks both stopped at
# 11:45:48 UTC. The stratum stayed 'active', shares kept flowing, and the log
# was full of `aux submit skip target` lines -- which are NORMAL merged-mining
# filtering (see docs/infrastructure.md section 5) and therefore prove nothing
# on their own. What DOES prove something:
#   * the aux block HASH must rotate every time the child chain advances.
#     If the same TXC/ISK hash repeats for many minutes, stratum is handing the
#     fleet a DEAD template -- every solution found is worthless.
#   * child_diff must be reachable by the fleet's best shares. If child_diff
#     jumped far above the best parent_diff we ever see, finds stop by math.
#
# ---------------------------------------------------------------------------
# VERSION LOG -- newest first
#   v1  2026-08-20  Initial: aux hash rotation, child_diff drift, best share
#                   vs target, daemon tip vs template height, RPC error scan.
# ---------------------------------------------------------------------------
AUXF_VERSION="v1"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

LOG=/var/stratum/scrypt.log
NEWEST=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | head -1)
[ -n "${NEWEST:-}" ] && LOG="$NEWEST"
SAMPLE=/tmp/aux-freshness.sample
DB=yiimpfrontend
MY() { mysql "$DB" -N -B -e "$1" 2>/dev/null; }
MYT() { mysql "$DB" -t -e "$1" 2>&1; }
hr() { printf '\n===== %s\n' "$*"; }

echo "aux-freshness $AUXF_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "log=$LOG  (age $(( $(date -u +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) ))s)"

##############################################################################
hr "1. aux template rotation -- 60s LIVE sample (the decisive test)"
##############################################################################
echo "  sampling the live log for 60 seconds..."
timeout 60 tail -n 0 -F "$LOG" > "$SAMPLE" 2>/dev/null
LINES=$(wc -l < "$SAMPLE")
echo "  captured $LINES lines"
for C in TXC ISK DOGE; do
  N=$(grep -aoiE "$C aux submit skip target[^\n]*hash=[0-9a-f]+" "$SAMPLE" | grep -oE 'hash=[0-9a-f]+' | sort -u | wc -l)
  D=$(grep -aoiE "$C aux submit skip target[^\n]*child_diff=[0-9.]+" "$SAMPLE" | grep -oE 'child_diff=[0-9.]+' | sort -u | tr '\n' ' ')
  T=$(grep -aciE "$C aux submit" "$SAMPLE")
  printf '  %-4s  submit-attempts=%-6s distinct aux hashes in 60s=%-3s  child_diff seen: %s\n' "$C" "$T" "$N" "${D:-none}"
done
echo
echo "  READ: 0 distinct hashes = that child is not in the aux rotation at all."
echo "        1 distinct hash for a full 60s is EXPECTED for a ~3min block time,"
echo "        but if section 2 shows the SAME hash for >15 min the template is DEAD."

##############################################################################
hr "2. how long has each aux hash been frozen?"
##############################################################################
for C in TXC ISK; do
  FIRST=$(grep -aiE "$C aux submit skip target" "$LOG" | grep -oE '^[0-9:]+|hash=[0-9a-f]+' | paste - - 2>/dev/null | tail -n 4000 | awk '{print $1, $2}' | tac | awk 'NR==1{h=$2} $2!=h{print $1; exit}')
  LAST=$(grep -aiE "$C aux submit skip target" "$LOG" | tail -1 | cut -d: -f1-3 | cut -c1-8)
  CUR=$(grep -aiE "$C aux submit skip target" "$LOG" | tail -1 | grep -oE 'hash=[0-9a-f]+')
  echo "  $C current $CUR"
  echo "      last logged at $LAST ; previous DIFFERENT hash last seen at ${FIRST:-<not within 4000 lines -- FROZEN>}"
done

##############################################################################
hr "3. is the target even reachable? best share vs child_diff"
##############################################################################
for C in TXC ISK; do
  BEST=$(grep -aiE "$C aux submit skip target" "$SAMPLE" | grep -oE 'parent_diff=[0-9.]+' | cut -d= -f2 | sort -g | tail -1)
  CD=$(grep -aiE "$C aux submit skip target" "$SAMPLE" | grep -oE 'child_diff=[0-9.]+' | cut -d= -f2 | sort -g | tail -1)
  BEST24=$(grep -aiE "$C aux submit skip target" "$LOG" | tail -n 200000 | grep -oE 'parent_diff=[0-9.]+' | cut -d= -f2 | sort -g | tail -1)
  printf '  %-4s best share this sample=%-14s best in log tail=%-14s child_diff=%s\n' "$C" "${BEST:-n/a}" "${BEST24:-n/a}" "${CD:-n/a}"
done
echo "  READ: if 'best in log tail' never approaches child_diff, the child chain"
echo "        difficulty has outrun the fleet -- finds stop by arithmetic, not by bug."

##############################################################################
hr "4. daemon tip vs what stratum last recorded"
##############################################################################
MYT "SELECT c.symbol, c.enable, c.auto_ready, c.rpchost, c.rpcport,
       (SELECT MAX(FROM_UNIXTIME(b.time)) FROM blocks b WHERE b.coin_id=c.id) AS last_block,
       (SELECT MAX(b.height) FROM blocks b WHERE b.coin_id=c.id) AS db_height
     FROM coins c WHERE c.symbol IN ('LTC','DOGE','TXC','ISK','ZCU') ORDER BY c.symbol;"

for C in TXC ISK; do
  read -r H P U W < <(MY "SELECT rpchost,rpcport,rpcuser,rpcpasswd FROM coins WHERE symbol='$C' LIMIT 1")
  [ -z "${H:-}" ] && { echo "  $C: no RPC row"; continue; }
  R=$(curl -s --max-time 8 --user "$U:$W" --data-binary \
      '{"jsonrpc":"1.0","id":"a","method":"getblockcount","params":[]}' \
      -H 'content-type: text/plain;' "http://$H:$P/" 2>/dev/null)
  echo "  $C daemon getblockcount -> ${R:-<no response>}"
  R2=$(curl -s --max-time 8 --user "$U:$W" --data-binary \
      '{"jsonrpc":"1.0","id":"a","method":"getauxblock","params":[]}' \
      -H 'content-type: text/plain;' "http://$H:$P/" 2>/dev/null)
  echo "  $C getauxblock -> $(echo "${R2:-<no response>}" | cut -c1-220)"
done
echo "  READ: if getauxblock returns the SAME hash section 2 says is frozen while"
echo "        getblockcount keeps climbing, the daemon is fine and stratum is stuck."
echo "        If getauxblock errors/times out, the daemon is the fault."

##############################################################################
hr "5. RPC / template errors in the log since 11:30 today"
##############################################################################
grep -aiE 'error getblocktemplate|getauxblock|createauxblock|submitauxblock|dead ?lock|unable to|timeout|refused' "$LOG" \
  | grep -aviE 'aux submit skip target' | tail -40 || echo "  none"

##############################################################################
hr "6. block cadence (DB truth)"
##############################################################################
MYT "SELECT c.symbol, COUNT(*) n, MAX(FROM_UNIXTIME(b.time)) newest,
       ROUND((UNIX_TIMESTAMP()-MAX(b.time))/60) age_min
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE b.time > UNIX_TIMESTAMP()-86400
     GROUP BY c.symbol ORDER BY c.symbol;"

echo
echo "VERDICT GUIDE"
echo "  frozen aux hash + climbing daemon height  -> stratum stopped refreshing aux work"
echo "                                               (restart stratum-aws-scrypt, then re-run)"
echo "  getauxblock error/timeout                 -> the child daemon is the fault"
echo "  best share far below child_diff           -> difficulty outran the fleet, no bug"
echo "  none of the above                         -> paste this whole output, do not guess"
echo "done."
