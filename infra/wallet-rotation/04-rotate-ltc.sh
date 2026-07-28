#!/usr/bin/env bash
# Rotate the LTC hot wallet: fresh encrypted HD seed + new pool payout address.
#
#   sudo ./04-rotate-ltc.sh                  # pre-flight / dry run
#   sudo ./04-rotate-ltc.sh CONFIRM_ROTATE   # execute
#
# Why this is different from DOGE:
#   LTC is the PARENT chain. Its coinbase destination is the address stored in
#   the yiimp DB (`coins.master_wallet` for the LTC row) -- stratum reads it and
#   pays block rewards there. A new seed is therefore only half the job; the new
#   address must be written back to `coins.master_wallet` or rewards keep going
#   to an address the old seed controls.
#
# The old wallet.dat is MOVED ASIDE, never deleted: immature LTC coinbases still
# belong to the old seed. Re-run 01-sweep.sh (or the load-old-wallet sweep) once
# they mature (~100 confs).
set -euo pipefail

CONFIRM="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"

LTC_DIR="${LTC_DIR:-/home/ubuntu/.litecoin}"
LTC_BIN="${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}"
LCLI="$LTC_BIN/litecoin-cli -conf=$LTC_DIR/litecoin.conf"
PASS_ENV="/etc/pool-wallets/passphrase.env"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- passphrase ---------------------------------------------------------------
if [ ! -f "$PASS_ENV" ]; then
  echo "FATAL: $PASS_ENV missing. Create it (same file DOGE uses):"
  echo "  sudo mkdir -p /etc/pool-wallets"
  echo "  printf 'WALLET_PASSPHRASE=%s\\n' \"\$(openssl rand -base64 32)\" | sudo tee $PASS_ENV"
  echo "  sudo chmod 600 $PASS_ENV   # then copy it into your password manager"
  exit 1
fi
# shellcheck disable=SC1090
. "$PASS_ENV"
: "${WALLET_PASSPHRASE:?WALLET_PASSPHRASE not set in $PASS_ENV}"

# --- yiimp DB creds (for updating coins.master_wallet) -------------------------
YIIMP_KEYS="${YIIMP_KEYS:-/var/web/serverconfig.php}"
db_query() { mysql --defaults-file=/etc/mysql/debian.cnf -N -B -e "$1" 2>/dev/null; }
if ! db_query "select 1" >/dev/null 2>&1; then
  MYSQL_USER="${MYSQL_USER:-}"; MYSQL_PASS="${MYSQL_PASS:-}"; MYSQL_DB="${MYSQL_DB:-yiimpfrontend}"
  if [ -z "$MYSQL_USER" ] && [ -r "$YIIMP_KEYS" ]; then
    # yiimp stores these as: define('YAAMP_DBUSER', '<user>');
    php_def() { sed -n "s/.*define( *'$1' *, *'\([^']*\)').*/\1/p" "$YIIMP_KEYS" | head -1; }
    MYSQL_USER=$(php_def YAAMP_DBUSER)
    MYSQL_PASS=$(php_def YAAMP_DBPASSWORD)
    MYSQL_DB=$(php_def YAAMP_DBNAME); MYSQL_DB="${MYSQL_DB:-yiimpfrontend}"
  fi
  db_query() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" -N -B -e "$1"; }
fi

CUR_MASTER=$(db_query "select master_wallet from coins where symbol='LTC' limit 1" 2>/dev/null || true)
if [ -z "$CUR_MASTER" ]; then
  echo "FATAL: cannot read coins.master_wallet for LTC."
  echo "Rotating without DB write access would leave block rewards paying the OLD seed."
  echo "Fix creds (or export MYSQL_USER/MYSQL_PASS) and re-run."
  exit 1
fi


echo "=== LTC hot wallet rotation ==="
echo "Mode        : $([ "$CONFIRM" = "CONFIRM_ROTATE" ] && echo EXECUTE || echo 'DRY RUN')"
echo "Datadir     : $LTC_DIR"
echo "Current tip : $($LCLI getblockcount 2>/dev/null || echo '?')"
echo "Wallet now  : $($LCLI getwalletinfo 2>/dev/null | sed -n 's/.*"hdseedid": *"\([^"]*\)".*/\1/p;s/.*"hdmasterkeyid": *"\([^"]*\)".*/\1/p' | head -1)"
echo "Balance     : $($LCLI getbalance 2>/dev/null || echo '?')  (immature: $($LCLI getwalletinfo 2>/dev/null | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p'))"
echo "coins.master_wallet(LTC): ${CUR_MASTER:-<unreadable>}"
echo

if [ "$CONFIRM" != "CONFIRM_ROTATE" ]; then
  cat <<'PLAN'
Plan:
  1. stop litecoind                       (miners keep hashing; stratum retries GBT)
  2. mv wallet.dat -> wallet.dat.old-seed-<stamp>
  3. start litecoind                       (fresh HD wallet)
  4. encryptwallet '<passphrase>'          (daemon stops; new seed on encrypt)
  5. start litecoind again, getnewaddress  -> NEW_LTC_ADDR
  6. UPDATE coins.master_wallet = NEW_LTC_ADDR for LTC
  7. restart stratum so it picks up the new coinbase address
  8. print verification (wallet id, new address, DB row, stratum log)

Old seed keeps immature coinbases -- sweep them after ~100 confs.
PLAN
  echo
  echo "Re-run with: sudo $0 CONFIRM_ROTATE"
  exit 0
fi

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
LTC_SVC=""
for s in litecoind litecoin; do svc_active "$s" && LTC_SVC="$s" && break; done

stop_ltc() {
  if [ -n "$LTC_SVC" ]; then systemctl stop "$LTC_SVC" || true; else $LCLI stop || true; fi
  for _ in $(seq 1 90); do pgrep -x litecoind >/dev/null || return 0; sleep 1; done
  echo "FATAL: litecoind still running"; exit 1
}
start_ltc() {
  if [ -n "$LTC_SVC" ]; then systemctl start "$LTC_SVC";
  else sudo -u ubuntu "$LTC_BIN/litecoind" -conf="$LTC_DIR/litecoin.conf" -daemon; fi
  for _ in $(seq 1 180); do $LCLI getwalletinfo >/dev/null 2>&1 && return 0; sleep 1; done
  echo "FATAL: litecoind did not come back"; exit 1
}

log "stopping litecoind (service='${LTC_SVC:-manual}')"
stop_ltc

log "moving old wallet aside"
mv "$LTC_DIR/wallet.dat" "$LTC_DIR/wallet.dat.old-seed-$STAMP"
chmod 600 "$LTC_DIR/wallet.dat.old-seed-$STAMP"

log "starting litecoind with a fresh wallet"
start_ltc

log "encrypting new wallet"
$LCLI encryptwallet "$WALLET_PASSPHRASE" || true
sleep 5
for _ in $(seq 1 120); do pgrep -x litecoind >/dev/null || break; sleep 1; done
pgrep -x litecoind >/dev/null || start_ltc

log "unlocking briefly to derive the new pool address"
$LCLI walletpassphrase "$WALLET_PASSPHRASE" 120 >/dev/null
NEW_ADDR=$($LCLI getnewaddress "pool-coinbase-$STAMP" legacy 2>/dev/null || $LCLI getnewaddress "pool-coinbase-$STAMP")
$LCLI walletlock >/dev/null 2>&1 || true
[ -n "$NEW_ADDR" ] || { echo "FATAL: could not derive a new address"; exit 1; }
log "new LTC pool address: $NEW_ADDR"

log "updating yiimp coins.master_wallet for LTC"
db_query "update coins set master_wallet='$NEW_ADDR' where symbol='LTC'"
db_query "select symbol, master_wallet from coins where symbol='LTC'"

log "restarting stratum so the new coinbase address takes effect"
systemctl restart stratum-aws-scrypt || true
sleep 5

echo
echo "=== verification ==="
$LCLI getwalletinfo
echo "new address : $NEW_ADDR"
echo "old seed at : $LTC_DIR/wallet.dat.old-seed-$STAMP"
systemctl --no-pager -l status stratum-aws-scrypt | head -12
echo
cat <<NEXT
NEXT STEPS
  1. Back up the new wallet:
       sudo -u ubuntu $LCLI backupwallet /home/ubuntu/ltc-wallet-backup-$STAMP.dat
  2. Watch for the next LTC block and confirm the coinbase pays $NEW_ADDR.
  3. After ~100 confs, sweep the OLD seed's matured coinbases:
       (swap wallet.dat.old-seed-$STAMP in with -rescan, sendtoaddress, swap back)
  4. If any LTC payout cron calls sendtoaddress, it now needs walletpassphrase --
     same patch shape as 03-patch-payout-cron.sh.
NEXT
