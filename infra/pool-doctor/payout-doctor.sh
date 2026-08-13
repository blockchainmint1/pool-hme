#!/usr/bin/env bash
# payout-doctor.sh -- READ ONLY. Explains why LTC / DOGE payouts stopped.
#
#   curl -fsSL https://pool.honest.money/install/payout-doctor.sh | sudo bash
#
# Changes nothing. Prints every link in the payout chain:
#   yiimp loop2 -> YAAMP_PAYMENTS_FREQ -> payouts rows -> wallet unlock -> sendmany
#   DOGE: cron.d -> doge-payout-cycle.sh -> doge_payout_ledger -> dogecoind
set -uo pipefail

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
LTC_DIR=${LTC_DIR:-/home/ubuntu/.litecoin}
LTC_BIN=${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}
DOGE_DIR=${DOGE_DIR:-/home/ubuntu/.dogecoin}
DOGE_BIN=${DOGE_BIN:-/home/ubuntu/dogecoin/bin}
DOGE_CYCLE=${DOGE_CYCLE:-/var/web/doge-payout-cycle.sh}
DOGE_LOG=${DOGE_LOG:-/var/web/runtime/doge-payout/cron-wrapper.log}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n=== %s ===\n' "$*"; }

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e "$1" 2>&1; }
MYT() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1; }

echo "payout-doctor  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"

hr "1. yiimp payout config"
grep -nE "YAAMP_PAYMENTS_FREQ|YAAMP_PAYMENTS_MINI|YAAMP_ALLOW_EXCHANGE" "$SERVERCONFIG" 2>/dev/null || echo "(no payment defines found)"
MYT "SELECT symbol, payout_min, txfee, enable, auto_ready FROM coins WHERE symbol IN ('LTC','DOGE')"

hr "2. yiimp loop services"
for u in yiimp-loop2 loop2 yiimp yiimp-loop; do
  systemctl is-active "$u" >/dev/null 2>&1 && { echo "-- $u"; systemctl status "$u" --no-pager -n 5 | sed 's/^/   /'; }
done
ps -ef | grep -E '[l]oop2|[r]unPayouts|[b]lock-loop' | sed 's/^/   /' || true
echo "-- cron entries touching payouts:"
grep -rn "payout\|loop2" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | sed 's/^/   /' || echo "   (none)"

hr "3. payouts table (LTC id=8, DOGE id=9)"
MYT "SELECT c.symbol, COUNT(*) rows_, SUM(p.completed=1) done, SUM(p.completed=0) pending,
            ROUND(SUM(p.amount),6) amt, FROM_UNIXTIME(MAX(p.time)) last_row
     FROM payouts p JOIN coins c ON c.id=p.idcoin
     WHERE p.time > UNIX_TIMESTAMP()-30*86400 GROUP BY c.symbol ORDER BY c.symbol"
echo "-- last 10 payout rows, any coin:"
MYT "SELECT p.id, c.symbol, p.amount, p.completed, LEFT(IFNULL(p.errmsg,''),60) errmsg, FROM_UNIXTIME(p.time) t
     FROM payouts p JOIN coins c ON c.id=p.idcoin ORDER BY p.id DESC LIMIT 10"
echo "-- distinct errors on pending rows:"
MYT "SELECT c.symbol, LEFT(IFNULL(p.errmsg,'(null)'),80) errmsg, COUNT(*) n
     FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE p.completed=0 GROUP BY 1,2 ORDER BY n DESC LIMIT 15"

hr "3b. the 5 stuck LTC pending payout rows"
MYT "SELECT p.id, p.idcoin, p.account_id, p.amount, p.fee, p.tx, p.completed,
            LEFT(IFNULL(p.errmsg,'(null)'),60) errmsg, FROM_UNIXTIME(p.time) t
     FROM payouts p WHERE p.completed=0 ORDER BY p.id DESC LIMIT 20"

hr "4. unpaid balances waiting in accounts"
echo "-- accounts columns:"; MY "SHOW COLUMNS FROM accounts" | awk '{printf "%s ", $1}'; echo
MYT "SELECT c.symbol, COUNT(*) accounts_, ROUND(SUM(a.balance),6) balance
     FROM accounts a JOIN coins c ON c.id=a.coinid WHERE a.balance>0 GROUP BY c.symbol"
echo "-- top 10 LTC/DOGE accounts by unpaid balance:"
MYT "SELECT a.id, c.symbol, a.username, ROUND(a.balance,6) balance
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND a.balance>0 ORDER BY a.balance DESC LIMIT 10"

hr "5. blocks vs credits (last 7 days)"
MYT "SELECT c.symbol, COUNT(*) blocks_, SUM(b.category='generate') matured, SUM(b.category='immature') immature,
            SUM(b.category='orphan') orphan, FROM_UNIXTIME(MAX(b.time)) last_block
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE b.time > UNIX_TIMESTAMP()-7*86400 GROUP BY c.symbol ORDER BY c.symbol"

# Autodetect daemon paths from the running processes (overrides the defaults above).
detect() { # detect <daemon-name> -> sets D_BIN D_CONF D_DIR
  local name=$1 line bin
  line=$(ps -ef | grep -E "[/ ]${name}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE '/[^ ]*'"$name" | head -1)
  D_BIN=$(dirname "${bin:-/usr/local/bin/$name}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-$HOME/.${name%d}}/${name%d}.conf"
}

hr "6. LTC wallet + unlock timer"
detect litecoind; LTC_BIN=${D_BIN:-$LTC_BIN}; LTC_CONF=${D_CONF}
echo "   litecoind: bin=$LTC_BIN conf=$LTC_CONF"
CONF="${LTC_CONF:-$LTC_DIR/litecoin.conf}"
WALLET=$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$CONF" 2>/dev/null | head -1); WALLET=${WALLET:-pool}
LCLI="$LTC_BIN/litecoin-cli -conf=$CONF -rpcwallet=$WALLET"
$LCLI getwalletinfo 2>&1 | grep -E 'walletname|"balance"|unconfirmed|immature|unlocked_until' | sed 's/^/   /'
$LCLI getblockchaininfo 2>&1 | grep -E '"blocks"|"headers"|verificationprogress|initialblockdownload' | sed 's/^/   /'
systemctl status ltc-unlock.timer --no-pager -n 3 2>&1 | sed 's/^/   /'
journalctl -u ltc-unlock.service -n 10 --no-pager 2>/dev/null | sed 's/^/   /'

hr "7. DOGE wallet"
detect dogecoind; DOGE_BIN=${D_BIN:-$DOGE_BIN}; DCONF=${D_CONF:-$DOGE_DIR/dogecoin.conf}
echo "   dogecoind: bin=$DOGE_BIN conf=$DCONF"
ps -ef | grep [d]ogecoind | sed 's/^/   /' || echo "   !! dogecoind is NOT running"
DCLI="$DOGE_BIN/dogecoin-cli -conf=$DCONF"
$DCLI getwalletinfo 2>&1 | grep -E 'walletname|"balance"|unconfirmed|immature|unlocked_until' | sed 's/^/   /'
$DCLI getinfo 2>&1 | grep -E '"blocks"|"errors"|"balance"' | sed 's/^/   /'

hr "8. DOGE custom payout cycle"
ls -l "$DOGE_CYCLE" 2>&1 | sed 's/^/   /'
grep -rn "doge-payout-cycle" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | sed 's/^/   /' || echo "   (no cron entry!)"
for L in /var/log/doge-payout-cycle.log "$DOGE_LOG"; do
  [ -f "$L" ] || continue
  echo "-- $L  (size $(stat -c%s "$L"), mtime $(date -u -d @$(stat -c%Y "$L") '+%Y-%m-%d %H:%M UTC'))"
  tail -n 40 "$L" | sed 's/^/   /'
done
echo "-- doge_payout_ledger by status:"
MYT "SELECT status, COUNT(*) n, ROUND(SUM(amount),4) amount,
            FROM_UNIXTIME(MIN(created_at)) oldest, FROM_UNIXTIME(MAX(created_at)) newest,
            FROM_UNIXTIME(MAX(updated_at)) last_touch
     FROM doge_payout_ledger GROUP BY status ORDER BY n DESC"
echo "-- stuck immature rows (block_confirmations vs maturity_confirmations):"
MYT "SELECT block_id, COUNT(*) rows_, MIN(block_confirmations) conf_min, MAX(block_confirmations) conf_max,
            MAX(maturity_confirmations) need, ROUND(SUM(amount),4) amount,
            FROM_UNIXTIME(MAX(updated_at)) last_touch
     FROM doge_payout_ledger WHERE status='immature' GROUP BY block_id ORDER BY block_id DESC LIMIT 10"
echo "-- ledger rows created per day, last 14 days:"
MYT "SELECT DATE(FROM_UNIXTIME(created_at)) d, COUNT(*) n, ROUND(SUM(amount),2) amount
     FROM doge_payout_ledger WHERE created_at > UNIX_TIMESTAMP()-14*86400 GROUP BY d ORDER BY d"
echo "-- token window / cadence settings inside the cycle script:"
grep -nE 'TOKEN_WINDOW_HOURS|MATURITY|CONFIRM|MIN_PAYOUT|DRY_RUN|LOCK|exit ' "$DOGE_CYCLE" 2>/dev/null | head -30 | sed 's/^/   /'
echo "-- run the cycle script read-only to see where it stops:"
sudo -u ubuntu bash -c "DRY_RUN=1 timeout 90 bash '$DOGE_CYCLE'" 2>&1 | tail -n 40 | sed 's/^/   /'
echo "-- doge_address_links freshness (token_seen_at drives eligibility):"
MYT "SELECT COUNT(*) links, SUM(FROM_UNIXTIME(token_seen_at) > NOW()-INTERVAL 7 DAY) seen_7d,
            FROM_UNIXTIME(MAX(token_seen_at)) newest_token FROM doge_address_links"

hr "9. recent on-chain sends from each wallet"
echo "-- LTC last 8 send txs:"
$LCLI listtransactions "*" 40 0 2>/dev/null | grep -E '"category"|"amount"|"time"|"txid"' | paste - - - - | grep send | head -8 | sed 's/^/   /'
echo "-- DOGE last 8 send txs:"
$DCLI listtransactions "*" 40 0 2>/dev/null | grep -E '"category"|"amount"|"time"|"txid"' | paste - - - - | grep send | head -8 | sed 's/^/   /'

hr "10. disk + yiimp debug log tail"
df -h / /var 2>/dev/null | sed 's/^/   /'
for f in /var/web/log/debug.log /var/log/yiimp/debug.log /var/web/yiimp.log; do
  [ -f "$f" ] && { echo "-- $f"; grep -iE 'payout|sendmany|error' "$f" | tail -n 30 | sed 's/^/   /'; }
done

echo
echo "payout-doctor done -- nothing was modified."
