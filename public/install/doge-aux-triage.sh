#!/usr/bin/env bash
# doge-aux-triage.sh -- READ ONLY. Answers exactly one question:
#   "TXC and ISK are ON TARGET but DOGE found 1 block in 24h instead of ~14.
#    Is DOGE still in the aux rotation, is its template alive, and are our
#    winning submits reaching dogecoind?"
#
#   run:  curl -fsSL "https://pool.honest.money/install/doge-aux-triage.sh?v=$(date +%s)" | sudo bash
#
# Makes NO changes: no writes to config, DB, systemd or the stratum process.
#
# Why this exists (30 Aug 2026): canary v7 section 4c showed DOGE at 1 find in
# 24h against ~13.9 expected from our own 18.6 TH/s, while TXC (441 vs 512) and
# ISK (426 vs 424) were dead on. TXC/ISK ride the SAME LTC parent shares as
# DOGE, so the parent coinbase/template/submit path is provably fine -- this is
# DOGE-specific. DOGE's last block (15:11:03) and ZCU's last (15:12:27) both
# land immediately before the stratum restart at 15:23:40 (NRestarts=1).
#
# The three things that can produce exactly this signature:
#   A. DOGE dropped out of the aux rotation on restart (config/child load
#      order) -> zero DOGE aux hashes in the live sample.
#   B. DOGE template is FROZEN -- same aux hash for many minutes while
#      dogecoind's tip advances -> every solution found is worthless.
#   C. DOGE child_diff is unreachable, or winners ARE found and then rejected
#      by dogecoind -> submit/found lines with no accepted block row.
#
# Each section below distinguishes one of those. Nothing here is a fix.
#
# ---------------------------------------------------------------------------
# VERSION LOG -- newest first
#   v1  2026-08-30  Initial: rotation presence, 90s template-rotation sample,
#                   aux-hash staleness vs dogecoind tip, child_diff vs best
#                   share, direct getauxblock/createauxblock RPC probe,
#                   chainid check, submit-vs-recorded reconciliation, and a
#                   TXC/ISK control column so a DOGE-only fault is unmissable.
# ---------------------------------------------------------------------------
DAT_VERSION="v1"
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

LOG=/var/stratum/scrypt.log
NEWEST=$(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | head -1)
[ -n "${NEWEST:-}" ] && LOG="$NEWEST"
SAMPLE=/tmp/doge-aux-triage.sample
CONF=/var/stratum/scrypt.conf
DOGECLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -datadir=/home/ubuntu/.dogecoin"
LTCCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -datadir=/home/ubuntu/.litecoin -rpcwallet=pool"
DB=yiimpfrontend
MY()  { mysql "$DB" -N -B -e "$1" 2>/dev/null; }
MYT() { mysql "$DB" -t -e "$1" 2>&1; }

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hr()   { printf '\n===== %s\n' "$*"; }

echo "doge-aux-triage $DAT_VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "log=$LOG  (age $(( $(date -u +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) ))s)"

##############################################################################
hr "0. the shape of the problem (context, not a verdict)"
##############################################################################
MYT "SELECT c.symbol, MAX(b.height) height, FROM_UNIXTIME(MAX(b.time)) last_block,
     ROUND((UNIX_TIMESTAMP()-MAX(b.time))/60,1) min_ago,
     SUM(b.time > UNIX_TIMESTAMP()-86400) finds_24h
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE','TXC','ISK','ZCU')
     GROUP BY 1 ORDER BY min_ago" | sed 's/^/  /'
SINCE=$(systemctl show stratum-aws-scrypt -p ActiveEnterTimestamp --value 2>/dev/null)
NR=$(systemctl show stratum-aws-scrypt -p NRestarts --value 2>/dev/null)
echo "  stratum active since: $SINCE   NRestarts=$NR"
echo "  READ: if DOGE's last block is just BEFORE that restart while TXC/ISK"
echo "        kept going, the restart changed something DOGE-specific."

##############################################################################
hr "1. is DOGE even in the aux rotation? (config as loaded)"
##############################################################################
if [ -r "$CONF" ]; then
  echo "  config: $CONF"
  grep -anE 'coinid|auxpow|aux|disabled|dogecoin|DOGE' "$CONF" 2>/dev/null | head -40 | sed 's/^/    /'
else
  warn "cannot read $CONF"
fi
MYT "SELECT id, symbol, name, enable, auto_ready, auxpow, rpcport
     FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU') ORDER BY symbol" | sed 's/^/  /'
DENABLE=$(MY "SELECT enable FROM coins WHERE symbol='DOGE'")
[ "${DENABLE:-0}" = "1" ] && ok "DOGE is enabled in the coins table" \
  || bad "DOGE enable=$DENABLE -- it is switched OFF in the DB, that alone stops all DOGE finds"

##############################################################################
hr "2. 90s LIVE template sample -- DOGE vs the TXC/ISK control"
##############################################################################
echo "  sampling the live log for 90 seconds (TXC/ISK are the control group)..."
timeout 90 tail -n 0 -F "$LOG" > "$SAMPLE" 2>/dev/null
LINES=$(wc -l < "$SAMPLE" 2>/dev/null || echo 0)
echo "  captured $LINES lines"
printf '  %-5s %-10s %-10s %-14s %s\n' COIN attempts hashes accepted child_diff
for C in DOGE TXC ISK; do
  T=$(grep -aciE "$C aux" "$SAMPLE" 2>/dev/null || echo 0)
  H=$(grep -aoiE "$C aux[^\"]*hash=[0-9a-f]+" "$SAMPLE" 2>/dev/null | grep -oE 'hash=[0-9a-f]+' | sort -u | wc -l)
  A=$(grep -aciE "$C .*(accept|submitauxblock|block found)" "$SAMPLE" 2>/dev/null || echo 0)
  D=$(grep -aoiE "$C aux[^\"]*child_diff=[0-9.]+" "$SAMPLE" 2>/dev/null | grep -oE 'child_diff=[0-9.]+' | sed 's/child_diff=//' | sort -un | tr '\n' ' ')
  printf '  %-5s %-10s %-10s %-14s %s\n' "$C" "$T" "$H" "$A" "${D:-none}"
done
DA=$(grep -aciE "DOGE aux" "$SAMPLE" 2>/dev/null || echo 0)
TA=$(grep -aciE "TXC aux" "$SAMPLE" 2>/dev/null || echo 0)
if [ "${DA:-0}" -eq 0 ] && [ "${TA:-0}" -gt 0 ]; then
  bad "ZERO DOGE aux lines in 90s while TXC is active -- DOGE IS NOT IN THE AUX ROTATION. This is the whole bug."
elif [ "${DA:-0}" -eq 0 ] && [ "${TA:-0}" -eq 0 ]; then
  warn "no aux lines for any coin -- log verbosity too low to judge from the live sample; rely on sections 3-5"
else
  ok "DOGE aux activity present in the live sample ($DA lines)"
fi

##############################################################################
hr "3. is the DOGE template FROZEN? (aux hash rotation over the whole log)"
##############################################################################
for C in DOGE TXC ISK; do
  LAST=$(grep -aoiE "$C aux[^\"]*hash=[0-9a-f]+" "$LOG" 2>/dev/null | tail -2000 | grep -oE 'hash=[0-9a-f]+' | sort -u | wc -l)
  NEWEST_LINE=$(grep -aiE "$C aux" "$LOG" 2>/dev/null | tail -1 | cut -c1-160)
  printf '  %-5s distinct aux hashes in the last 2000 matches: %s\n' "$C" "$LAST"
  [ -n "$NEWEST_LINE" ] && printf '        newest: %s\n' "$NEWEST_LINE"
done
echo "  READ: a healthy child rotates its aux hash every time its chain advances."
echo "        1 distinct hash across thousands of lines = DEAD/FROZEN template."

##############################################################################
hr "4. dogecoind itself -- tip, aux RPC, chainid (does the daemon still serve work?)"
##############################################################################
DTIP=$($DOGECLI getblockcount 2>&1 | tr -d '\r')
DCONN=$($DOGECLI getconnectioncount 2>&1 | tr -d '\r')
echo "  dogecoind tip=$DTIP  peers=$DCONN"
case "$DTIP" in
  ''|*[!0-9]*) bad "dogecoind did not return a numeric tip: $DTIP" ;;
  *) ok "dogecoind is reachable and at height $DTIP" ;;
esac
COINB=$(MY "SELECT master_wallet FROM coins WHERE symbol='DOGE'")
echo "  DOGE coinbase (coins.master_wallet): ${COINB:-unset}"
if [ -n "${COINB:-}" ]; then
  VAL=$($DOGECLI validateaddress "$COINB" 2>&1 | tr -d '\n' | cut -c1-300)
  echo "    validateaddress: $VAL"
  MINE=$($DOGECLI getaddressinfo "$COINB" 2>/dev/null | grep -oE '"ismine": *(true|false)' | head -1)
  echo "    ${MINE:-ismine: unknown}"
  case "$COINB" in
    D*) ok "DOGE coinbase is a legacy D-address (correct for merged mining)" ;;
    *)  bad "DOGE coinbase is NOT a legacy D-address -- merged-mining coinbase must be legacy" ;;
  esac
fi
echo "  --- direct aux work probe (this is what stratum asks dogecoind for) ---"
AUXOUT=$($DOGECLI createauxblock "$COINB" 2>&1 | tr -d '\n' | cut -c1-400)
if [ -z "$AUXOUT" ]; then
  AUXOUT=$($DOGECLI getauxblock 2>&1 | tr -d '\n' | cut -c1-400)
  echo "    getauxblock: $AUXOUT"
else
  echo "    createauxblock: $AUXOUT"
fi
case "$AUXOUT" in
  *error*|*Error*|*"couldn't connect"*)
    bad "dogecoind refused to produce aux work -- stratum cannot merge-mine DOGE at all right now" ;;
  *chainid*|*target*|*hash*)
    ok "dogecoind produced a valid aux block template on demand" ;;
  *)
    warn "unrecognised aux probe response -- read the raw line above" ;;
esac
CHAINID=$(echo "$AUXOUT" | grep -oE '"chainid": *[0-9]+' | head -1)
echo "    ${CHAINID:-chainid: not reported}  (DOGE mainnet chainid is 98)"

##############################################################################
hr "5. did we FIND DOGE winners and then lose them? (submit reconciliation)"
##############################################################################
for F in $(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | head -4); do
  S=$(grep -acieE 'doge.*(submitauxblock|block found|block candidate|submit block)' "$F" 2>/dev/null || echo 0)
  R=$(grep -acieE 'doge.*(reject|invalid|stale|duplicate|bad-|end of data)' "$F" 2>/dev/null || echo 0)
  printf '  %-70s submits=%-6s rejects=%s\n' "$(basename "$F")" "$S" "$R"
done
echo "  --- newest DOGE submit/reject flavoured lines ---"
grep -ahiE 'doge.*(submitauxblock|block found|block candidate|reject|invalid|end of data)' \
  $(ls -t /var/stratum/scrypt.log /var/stratum/logs/stratum*.log 2>/dev/null | head -4) 2>/dev/null \
  | tail -12 | cut -c1-200 | sed 's/^/    /'
DSUB=$(grep -achieE 'doge.*(submitauxblock|block found|block candidate)' "$LOG" 2>/dev/null || echo 0)
DREC=$(MY "SELECT COUNT(*) FROM blocks b JOIN coins c ON c.id=b.coin_id
           WHERE c.symbol='DOGE' AND b.time > UNIX_TIMESTAMP()-86400")
echo "  DOGE submit-ish lines in the live log: ${DSUB:-0}   DOGE block rows recorded in 24h: ${DREC:-0}"
if [ "${DSUB:-0}" -gt 0 ] && [ "${DREC:-0}" -le 1 ]; then
  bad "we SUBMITTED DOGE winners but almost none were recorded -- blocks are being found and LOST, not unlucky"
elif [ "${DSUB:-0}" -eq 0 ]; then
  warn "no DOGE submit lines at all in the live log -- consistent with DOGE never receiving work (sections 2-4)"
else
  ok "DOGE submits and recorded blocks are consistent"
fi

##############################################################################
hr "6. share difficulty vs what DOGE needs (is a win even reachable?)"
##############################################################################
MYT "SELECT COUNT(*) shares_10m, ROUND(MIN(difficulty),3) min_diff,
     ROUND(AVG(difficulty),3) avg_diff, ROUND(MAX(difficulty),3) max_diff
     FROM shares WHERE time > UNIX_TIMESTAMP()-600" | sed 's/^/  /'
echo "  DOGE network difficulty: $($DOGECLI getdifficulty 2>/dev/null)"
echo "  LTC  network difficulty: $($LTCCLI getdifficulty 2>/dev/null)"
echo "  READ: DOGE aux difficulty is far BELOW LTC's, so any share that could"
echo "        win LTC wins DOGE many times over. If LTC finds are on target and"
echo "        DOGE is not, difficulty is NOT the explanation -- work delivery is."

##############################################################################
hr "verdict"
##############################################################################
if [ "$FAIL" -eq 0 ]; then
  echo "  No hard DOGE fault proven by this run. Re-read sections 2 and 3: a frozen"
  echo "  or absent DOGE template shows up there first, and may need a longer sample."
else
  echo "  DOGE-SPECIFIC FAULT PROVEN ABOVE. TXC/ISK on target rules out the parent"
  echo "  path, so do NOT touch the LTC coinbase, the stratum binary, or the payout"
  echo "  code. Fix only the DOGE child, and re-run the canary afterwards."
fi
exit $FAIL
