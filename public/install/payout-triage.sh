#!/usr/bin/env bash
# payout-triage.sh -- READ ONLY, ~10 lines of output. Answers exactly one question:
# why did LTC/DOGE payouts stop on 5 Aug 2026?
#
#   curl -fsSL https://pool.honest.money/install/payout-triage.sh | sudo bash
#
# Checks, in order of likelihood:
#   A. hot wallet drained by the 5 Aug float sweep  -> sendmany "Insufficient funds"
#   B. wallet locked (encrypted, unlock timer dead) -> "Please enter the wallet passphrase"
#   C. DOGE cycle cron removed / erroring out       -> ledger frozen at 5 Aug
#   D. yiimp loop2 not running                      -> nothing is even attempted
set -uo pipefail
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n--- %s\n' "$*"; }

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

echo "payout-triage $(date -u '+%F %T UTC')"

hr "A. hot wallet balances (can we even pay?)"
detect litecoind; LCONF=$D_CONF; LBIN=$D_BIN
LW=$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$LCONF" 2>/dev/null | head -1)
LCLI="$LBIN/litecoin-cli -conf=$LCONF ${LW:+-rpcwallet=$LW}"
echo "LTC : $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
detect dogecoind; DCONF=$D_CONF; DBIN=$D_BIN
DCLI="$DBIN/dogecoin-cli -conf=$DCONF"
echo "DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "DOGE getbalance: $($DCLI getbalance 2>&1 | head -1)"

hr "B. what the pool still owes"
MYT "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),4) owed
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE') GROUP BY c.symbol"

hr "C. last payout rows + why pending ones failed"
MYT "SELECT c.symbol, MAX(FROM_UNIXTIME(p.time)) last_payout, COUNT(*) n
     FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY c.symbol"
MYT "SELECT c.symbol, LEFT(IFNULL(p.errmsg,'(null)'),70) errmsg, COUNT(*) n, FROM_UNIXTIME(MAX(p.time)) newest
     FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE p.completed=0 GROUP BY 1,2 ORDER BY n DESC LIMIT 10"

hr "D. is anything scheduled / running?"
systemctl is-active ltc-unlock.timer 2>/dev/null | sed 's/^/ltc-unlock.timer: /'
ps -ef | grep -E '[l]oop2|[b]lock-loop' | head -3 | sed 's/^/proc: /' || echo "proc: (no yiimp loop running!)"
grep -rhn "payout\|loop2" /etc/cron.d/* /etc/crontab 2>/dev/null | grep -v '^#' | sed 's/^/cron: /' || echo "cron: (none)"

hr "E. DOGE cycle -- last activity"
for L in /var/log/doge-payout-cycle.log /var/web/runtime/doge-payout/cron-wrapper.log; do
  [ -f "$L" ] && echo "$L  mtime=$(date -u -d @$(stat -c%Y "$L") '+%F %H:%M UTC')  size=$(stat -c%s "$L")"
done
tail -n 25 /var/log/doge-payout-cycle.log 2>/dev/null | sed 's/^/  /'
MYT "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) amount,
            FROM_UNIXTIME(MAX(created_at)) newest, FROM_UNIXTIME(MAX(updated_at)) last_touch
     FROM doge_payout_ledger GROUP BY status ORDER BY n DESC"

hr "F. wallet float vs. obligations (the 5 Aug sweep check)"
echo "recent LTC sends:"; $LCLI listtransactions "*" 15 0 2>/dev/null | grep -E '"amount"|"time"' | paste - - | tail -5 | sed 's/^/  /'
echo "recent DOGE sends:"; $DCLI listtransactions "*" 15 0 2>/dev/null | grep -E '"amount"|"time"' | paste - - | tail -5 | sed 's/^/  /'

echo
echo "triage done -- nothing was modified."
