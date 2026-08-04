#!/usr/bin/env bash
# Point coins.master_wallet for DOGE at an address the CURRENT wallet owns.
#
#   sudo bash 11-doge-master-wallet.sh            # dry run
#   sudo bash 11-doge-master-wallet.sh CONFIRM    # apply
#
# Why: after the DOGE seed rotation (b6ff96bb…), coins.master_wallet still holds
# DBBv9bpnNV6tjJDM8q6MpiVPPhjpvatCJT, which belongs to the OLD wallet
# (validateaddress -> ismine:false). That address is where yiimp sweeps the
# pool's own profit / fee balance. Every sweep to it would be money sent to a
# key we no longer control. Mining rewards are unaffected (the coinbase address
# is taken from the wallet, and is already correct).
#
# Default destination is the sweep address that already holds the recovered
# balance; override with DEST=<addr>, or set NEW_ADDRESS=1 to have the daemon
# mint a fresh receiving address for pool profit.
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?)" >&2' ERR

CONFIRM="${1:-}"
DEST="${DEST:-DJvCw7eu1PBMjp8N99QsLxUohpVq6EEyjU}"
NEW_ADDRESS="${NEW_ADDRESS:-0}"
SERVERCONFIG="${SERVERCONFIG:-/var/web/serverconfig.php}"
DOGE_CLI="${DOGE_CLI:-/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli}"
DOGE_CONF="${DOGE_CONF:-/home/ubuntu/.dogecoin/dogecoin.conf}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$SERVERCONFIG" ] || { echo "FATAL: $SERVERCONFIG not found"; exit 1; }
[ -x "$DOGE_CLI" ]     || { echo "FATAL: $DOGE_CLI not executable"; exit 1; }

APPLY=false
[ "$CONFIRM" = "CONFIRM" ] && APPLY=true
STAMP="$(date +%Y%m%d-%H%M%S)"

dcli() { sudo -u ubuntu "$DOGE_CLI" -conf="$DOGE_CONF" "$@"; }

echo "=== DOGE coins.master_wallet -> owned address ==="
echo "Mode: $([ "$APPLY" = true ] && echo APPLY || echo 'DRY RUN')"
echo

# ------------------------------------------------------------ 1. pick dest ---
if [ "$NEW_ADDRESS" = "1" ]; then
  if [ "$APPLY" = true ]; then
    DEST="$(dcli getnewaddress "poolprofit")"
    echo "[1/4] minted new pool-profit address: $DEST"
  else
    echo "[1/4] NEW_ADDRESS=1 -- a fresh address would be minted on CONFIRM"
    echo "      (dry run keeps checking the default: $DEST)"
  fi
else
  echo "[1/4] destination: $DEST"
fi
echo

# --------------------------------------------------------- 2. verify ismine ---
echo "[2/4] validateaddress $DEST"
VAL="$(dcli validateaddress "$DEST")"
echo "$VAL" | grep -E '"isvalid"|"ismine"' | sed 's/^/      /'
echo "$VAL" | grep -q '"isvalid": *true' || { echo "FATAL: address is not valid"; exit 1; }
echo "$VAL" | grep -q '"ismine": *true'  || {
  echo "FATAL: the running wallet does NOT own $DEST -- refusing to set it as"
  echo "       master_wallet. Pass DEST=<owned addr> or NEW_ADDRESS=1."
  exit 1
}
echo "      OK: wallet owns this address."
echo

# ------------------------------------------------------------- 3. show now ---
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG")"
MYSQL=(mysql "-u${DBU}" "-p${DBP}" yiimpfrontend -N -B -e)

echo "[3/4] current coins.master_wallet"
"${MYSQL[@]}" "SELECT id, symbol, master_wallet FROM coins WHERE symbol IN ('DOGE','LTC');" \
  | awk '{printf "      id=%s %-5s %s\n", $1, $2, $3}'
echo

# ---------------------------------------------------------------- 4. apply ---
echo "[4/4] update"
if [ "$APPLY" != true ]; then
  echo "      would run: UPDATE coins SET master_wallet='$DEST' WHERE symbol='DOGE';"
  echo
  echo "DRY RUN -- nothing changed. Re-run with CONFIRM."
  exit 0
fi

"${MYSQL[@]}" "SELECT id, symbol, master_wallet FROM coins WHERE symbol IN ('DOGE','LTC');" \
  > "/var/backups/coins-master_wallet-$STAMP.txt"
"${MYSQL[@]}" "UPDATE coins SET master_wallet='$DEST' WHERE symbol='DOGE';"
echo "      after:"
"${MYSQL[@]}" "SELECT id, symbol, master_wallet FROM coins WHERE symbol IN ('DOGE','LTC');" \
  | awk '{printf "      id=%s %-5s %s\n", $1, $2, $3}'
echo "      backup: /var/backups/coins-master_wallet-$STAMP.txt"
echo

cat <<EOF
Done.

WHAT CHANGED
  DOGE pool-profit sweeps now land on $DEST, which the current
  (rotated, encrypted) wallet controls. Mining rewards were never affected.

VERIFY
  $DOGE_CLI -conf=$DOGE_CONF validateaddress $DEST | grep ismine
  mysql ... -e "SELECT symbol,master_wallet FROM coins WHERE symbol='DOGE';"

ROLLBACK
  cat /var/backups/coins-master_wallet-$STAMP.txt   # old values
EOF
