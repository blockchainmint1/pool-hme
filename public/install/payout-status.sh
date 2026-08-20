#!/usr/bin/env bash
# payout-status.sh v1 -- READ ONLY. One page: where the payout chain stands today,
# now that the coinbase wallet rotation is done.
#
#   curl -fsSL https://pool.honest.money/install/payout-status.sh | sudo bash 2>&1 | tee /tmp/payout-status.txt
#
# The chain, in order. The first FAIL is the one to fix:
#   1. blocks found          -> blocks rows exist
#   2. reward credited       -> earnings rows exist        (credit-fix.sh patches this)
#   3. balances accrue       -> accounts.balance > 0
#   4. payout runner alive   -> loop2 / cron / doge cycle
#   5. wallet can pay        -> spendable balance + unlocked
#   6. money leaves          -> payouts rows completed=1 with a tx
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEB=$(dirname "$SERVERCONFIG")
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

VERDICT=""
note() { VERDICT="${VERDICT}$1"$'\n'; }

echo "payout-status v1 $(date -u '+%F %T UTC')  host=$(hostname)  db_user=${DBU:-UNRESOLVED}"

hr "1. blocks found (last 14d)"
MY "SELECT c.symbol, COUNT(*) n, MAX(FROM_UNIXTIME(b.time)) newest
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.time > UNIX_TIMESTAMP()-14*86400 GROUP BY c.symbol ORDER BY n DESC"

hr "2. reward credited -> earnings"
MY "SELECT c.symbol, COUNT(*) n, ROUND(SUM(e.amount),6) amount, MAX(FROM_UNIXTIME(e.create_time)) newest
    FROM earnings e JOIN coins c ON c.id=e.coinid
    WHERE e.create_time > UNIX_TIMESTAMP()-14*86400 GROUP BY c.symbol ORDER BY n DESC"
E14=$(MYN "SELECT IFNULL(COUNT(*),0) FROM earnings WHERE create_time > UNIX_TIMESTAMP()-14*86400")
echo "earnings rows in last 14d: ${E14:-?}"
if grep -q 'POOL_MERGED_SHARE_FIX' "$WEB/yaamp/core/backend/blocks.php" 2>/dev/null; then
  echo "credit-fix: APPLIED (POOL_MERGED_SHARE_FIX present in blocks.php)"
else
  echo "credit-fix: NOT APPLIED"
  note "STEP 2 FAIL: blocks.php is unpatched, so scrypt aux blocks credit nobody."
  note "  fix: curl -fsSL https://pool.honest.money/install/credit-fix.sh | sudo bash        # dry run"
  note "       curl -fsSL https://pool.honest.money/install/credit-fix.sh | sudo bash -s CONFIRM_FIX"
fi
[ "${E14:-0}" = "0" ] && note "STEP 2 FAIL: zero earnings written in 14 days -- nothing can ever be paid out."

hr "3. balances owed to miners"
MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) owed, ROUND(MAX(a.balance),6) largest
    FROM accounts a JOIN coins c ON c.id=a.coinid
    WHERE a.balance>0 GROUP BY c.symbol ORDER BY owed DESC LIMIT 8"
MY "SELECT symbol, payout_min, txfee, enable, auto_ready FROM coins WHERE symbol IN ('LTC','DOGE')"

hr "4. payout runner alive?"
ps -ef | grep -E '[l]oop2|[r]unPayouts|[b]lock-loop' | sed 's/^/  proc: /' || echo "  proc: NONE"
pgrep -f 'loop2' >/dev/null || note "STEP 4 FAIL: yiimp loop2 is not running -- no payouts are even attempted."
for u in ltc-unlock.timer yiimp-loop2 doge-payout-cycle.timer; do
  printf '  unit %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo absent)"
done
grep -rhn "payout\|loop2" /etc/cron.d/* /etc/crontab 2>/dev/null | grep -v '^#' | sed 's/^/  cron: /' || echo "  cron: none"
for L in /var/log/doge-payout-cycle.log "$WEB/runtime/doge-payout/cron-wrapper.log"; do
  [ -f "$L" ] && echo "  log: $L  mtime=$(date -u -d @"$(stat -c%Y "$L")" '+%F %H:%M UTC')"
done

hr "5. wallets: can we actually pay?"
detect litecoind; LCONF=$D_CONF; LBIN=$D_BIN
LW=$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$LCONF" 2>/dev/null | head -1); LW=${LW:-pool}
LCLI="$LBIN/litecoin-cli -conf=$LCONF -rpcwallet=$LW"
echo "  LTC  (-rpcwallet=$LW): $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
detect dogecoind; DCLI="$D_BIN/dogecoin-cli -conf=$D_CONF"
echo "  DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"

hr "6. payouts table -- did money actually leave?"
MY "SELECT c.symbol, p.completed, COUNT(*) n, ROUND(SUM(p.amount),6) amount, FROM_UNIXTIME(MAX(p.time)) newest
    FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY 1,2 ORDER BY 1,2"
MY "SELECT c.symbol, FROM_UNIXTIME(p.time) t, ROUND(p.amount,6) amount, p.completed, LEFT(IFNULL(p.tx,''),24) tx
    FROM payouts p JOIN coins c ON c.id=p.idcoin ORDER BY p.time DESC LIMIT 10"

hr "VERDICT"
if [ -z "$VERDICT" ]; then
  echo "  no blocking fault detected in the chain -- read sections 3/5/6 for amounts."
else
  printf '%s' "$VERDICT"
fi
echo
echo "read-only: nothing on this box was modified."
