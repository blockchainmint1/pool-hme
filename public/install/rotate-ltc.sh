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
php_def() { sed -n "s/.*define( *'$1' *, *'\([^']*\)').*/\1/p" "$YIIMP_KEYS" 2>/dev/null | head -1; }
MYSQL_DB="${MYSQL_DB:-}"
if [ -z "$MYSQL_DB" ] && [ -r "$YIIMP_KEYS" ]; then MYSQL_DB=$(php_def YAAMP_DBNAME); fi
MYSQL_DB="${MYSQL_DB:-yiimpfrontend}"

DB_MODE=""
# 1) debian maintenance account (must be able to read the yiimp DB, not just connect)
if mysql --defaults-file=/etc/mysql/debian.cnf "$MYSQL_DB" -N -B -e "select 1" >/dev/null 2>&1; then
  DB_MODE="debian"
  db_query() { mysql --defaults-file=/etc/mysql/debian.cnf "$MYSQL_DB" -N -B -e "$1"; }
else
  # 2) explicit env creds, else yiimp serverconfig.php
  MYSQL_USER="${MYSQL_USER:-}"; MYSQL_PASS="${MYSQL_PASS:-}"
  if [ -z "$MYSQL_USER" ] && [ -r "$YIIMP_KEYS" ]; then
    MYSQL_USER=$(php_def YAAMP_DBUSER)
    MYSQL_PASS=$(php_def YAAMP_DBPASSWORD)
  fi
  db_query() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" -N -B -e "$1"; }
  if [ -n "$MYSQL_USER" ] && db_query "select 1" >/dev/null 2>&1; then DB_MODE="yiimp:$MYSQL_USER"; fi
fi

CUR_MASTER=""
if [ -n "$DB_MODE" ]; then
  CUR_MASTER=$(db_query "select master_wallet from coins where symbol='LTC' limit 1" 2>/dev/null || true)
fi
if [ -z "$CUR_MASTER" ]; then
  echo "FATAL: cannot read coins.master_wallet for LTC."
  echo "  db      : $MYSQL_DB"
  echo "  auth    : ${DB_MODE:-none worked}"
  echo "  config  : $YIIMP_KEYS $([ -r "$YIIMP_KEYS" ] && echo '(readable)' || echo '(NOT readable - run with sudo)')"
  echo "  user    : ${MYSQL_USER:-<empty>}  pass:$([ -n "${MYSQL_PASS:-}" ] && echo ' set' || echo ' <empty>')"
  echo "Diagnose:  sudo mysql -u<user> -p<pass> $MYSQL_DB -e \"select symbol,master_wallet from coins where symbol='LTC'\""
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

# --- resolve where wallet.dat actually lives -----------------------------------
# Core 0.17+ keeps wallets under <datadir>/wallets/. A `wallet=<name>` line in
# litecoin.conf means <datadir>/wallets/<name>/wallet.dat (this box: wallet=pool).
WALLET_NAME="$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$LTC_DIR/litecoin.conf" 2>/dev/null | head -1)"
if [ -n "$WALLET_NAME" ] && [ -f "$LTC_DIR/wallets/$WALLET_NAME/wallet.dat" ]; then
  WALLET_PATH="$LTC_DIR/wallets/$WALLET_NAME/wallet.dat"
elif [ -f "$LTC_DIR/wallets/wallet.dat" ]; then
  WALLET_PATH="$LTC_DIR/wallets/wallet.dat"; WALLET_NAME=""
elif [ -f "$LTC_DIR/wallet.dat" ]; then
  WALLET_PATH="$LTC_DIR/wallet.dat"; WALLET_NAME=""
else
  echo "FATAL: no wallet.dat found under $LTC_DIR (checked wallets/<name>/, wallets/, datadir root)"
  exit 1
fi
echo "Wallet file : $WALLET_PATH"
echo "Wallet mode : ${WALLET_NAME:+named wallet '$WALLET_NAME' (createwallet path)}${WALLET_NAME:-default wallet (encryptwallet path)}"
echo

if [ "$CONFIRM" != "CONFIRM_ROTATE" ]; then
  if [ -n "$WALLET_NAME" ]; then
    cat <<PLAN
Plan (named-wallet path, wallet='$WALLET_NAME'):
  1. stop litecoind                        (miners keep hashing; stratum retries GBT)
  2. mv $WALLET_PATH
       -> $WALLET_PATH.old-seed-<stamp>
  3. start litecoind from a TEMP conf with the 'wallet=' line stripped
     (a named wallet that is missing makes the daemon refuse to boot)
  4. createwallet '$WALLET_NAME' with the passphrase -> fresh ENCRYPTED seed in one step
  5. getnewaddress -> NEW_LTC_ADDR, stop, delete temp conf
  6. start litecoind under the normal service/conf
  7. UPDATE coins.master_wallet = NEW_LTC_ADDR for LTC
  8. restart stratum so it picks up the new coinbase address
  9. print verification (wallet id, new address, DB row, stratum log)
PLAN
  else
    cat <<PLAN
Plan (default-wallet path):
  1. stop litecoind
  2. mv $WALLET_PATH -> $WALLET_PATH.old-seed-<stamp>
  3. start litecoind                       (fresh HD wallet)
  4. encryptwallet '<passphrase>'          (daemon stops; new seed on encrypt)
  5. start litecoind again, getnewaddress  -> NEW_LTC_ADDR
  6. UPDATE coins.master_wallet = NEW_LTC_ADDR for LTC
  7. restart stratum, print verification
PLAN
  fi
  echo
  echo "Old seed keeps immature coinbases -- sweep them after ~100 confs."
  echo "On any mid-way failure the script restarts litecoind automatically."
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
# never leave the parent chain daemon down if we bail mid-way
on_err() {
  echo "ERROR: aborting -- bringing litecoind back up"
  pgrep -x litecoind >/dev/null || { [ -n "$LTC_SVC" ] && systemctl start "$LTC_SVC" || sudo -u ubuntu "$LTC_BIN/litecoind" -conf="$LTC_DIR/litecoin.conf" -daemon; } || true
}
trap on_err ERR

log "wallet file: $WALLET_PATH  (named wallet: ${WALLET_NAME:-<default>})"


log "stopping litecoind (service='${LTC_SVC:-manual}')"
stop_ltc

log "moving old wallet aside"
OLD_WALLET="$WALLET_PATH.old-seed-$STAMP"
mv "$WALLET_PATH" "$OLD_WALLET"
chmod 600 "$OLD_WALLET"

if [ -n "$WALLET_NAME" ]; then
  # Named wallet: the daemon refuses to start when wallets/<name>/wallet.dat is
  # gone, so boot once from a temp conf with the wallet= line stripped, create a
  # fresh ENCRYPTED wallet under the same name, then hand back to the service.
  TMP_CONF="$LTC_DIR/litecoin.conf.rotate-$STAMP"
  grep -v '^[[:space:]]*wallet=' "$LTC_DIR/litecoin.conf" > "$TMP_CONF"
  chown ubuntu:ubuntu "$TMP_CONF"; chmod 644 "$TMP_CONF"
  TCLI="$LTC_BIN/litecoin-cli -conf=$TMP_CONF -datadir=$LTC_DIR"
  log "starting litecoind (temp conf, no wallet loaded)"
  sudo -u ubuntu "$LTC_BIN/litecoind" -conf="$TMP_CONF" -datadir="$LTC_DIR" -daemon
  for _ in $(seq 1 180); do $TCLI getblockcount >/dev/null 2>&1 && break; sleep 1; done
  rmdir "$LTC_DIR/wallets/$WALLET_NAME" 2>/dev/null || true
  log "creating fresh encrypted wallet '$WALLET_NAME'"
  $TCLI createwallet "$WALLET_NAME" false false "$WALLET_PASSPHRASE" false
  $TCLI -rpcwallet="$WALLET_NAME" walletpassphrase "$WALLET_PASSPHRASE" 120 >/dev/null
  NEW_ADDR=$($TCLI -rpcwallet="$WALLET_NAME" getnewaddress "pool-coinbase-$STAMP" legacy 2>/dev/null \
             || $TCLI -rpcwallet="$WALLET_NAME" getnewaddress "pool-coinbase-$STAMP")
  $TCLI -rpcwallet="$WALLET_NAME" walletlock >/dev/null 2>&1 || true
  $TCLI stop >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do pgrep -x litecoind >/dev/null || break; sleep 1; done
  rm -f "$TMP_CONF"
  log "starting litecoind under the normal service/conf"
  start_ltc
else
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
fi

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
echo "old seed at : $OLD_WALLET"
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
