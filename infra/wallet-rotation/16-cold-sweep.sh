#!/usr/bin/env bash
# 16-cold-sweep.sh -- point ALL pool profit at wallets you control, and keep it
# that way automatically.
#
#   sudo bash 16-cold-sweep.sh SETUP     # record + validate your addresses
#   sudo bash 16-cold-sweep.sh STATUS    # read-only: balances, liabilities, sweepable
#   sudo bash 16-cold-sweep.sh DRAIN     # dry run of the big one-off sweep
#   sudo bash 16-cold-sweep.sh DRAIN CONFIRM
#   sudo bash 16-cold-sweep.sh INSTALL   # cron: auto-sweep both coins every 6h
#   sudo bash 16-cold-sweep.sh UNINSTALL
#
# WHY THE HOT WALLET CANNOT SIMPLY BE YOUR WALLET
#   Block rewards land in the pool's wallet because that wallet must then SEND
#   payouts to miners. If coinbase paid straight to your cold address, the pool
#   would own nothing to pay anyone with and every payout would fail.
#   The correct shape is: small hot float on the box, everything above it swept
#   to addresses only you control, continuously. That caps a server compromise
#   at roughly one payout cycle instead of the whole treasury.
#
# SAFETY
#   * never sweeps money the pool still owes miners (unpaid ledger + balances)
#   * refuses to run while a payout cycle holds its lock
#   * validates every destination with the daemon before sending
#   * dry run by default; prints every number first
set -uo pipefail

MODE="${1:-STATUS}"
CONFIRM="${2:-}"
VERSION="v2"

COLD_ENV=/etc/pool-wallets/cold.env
PASS_ENV=/etc/pool-wallets/passphrase.env
PAYOUT_LOCK=/var/web/runtime/doge-payout/doge-payout-cycle.lock
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}

DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
# Litecoin Core 0.21 is MULTI-WALLET on this box: `pool` (mining, holds the
# money) and `rental`. Without -rpcwallet the CLI talks to the default
# wallet, which is empty -- that is why LTC read as 0 on 2026-08-20.
LTC_WALLET="${LTC_WALLET:-pool}"
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=$LTC_WALLET"

# working float left behind on the box, per coin
RESERVE_DOGE="${RESERVE_DOGE:-25000}"
RESERVE_LTC="${RESERVE_LTC:-0.5}"
MIN_SWEEP_DOGE="${MIN_SWEEP_DOGE:-1000}"
MIN_SWEEP_LTC="${MIN_SWEEP_LTC:-0.05}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "cold-sweep $VERSION  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  mode=$MODE"

# shellcheck disable=SC1090
[ -r "$COLD_ENV" ] && . "$COLD_ENV"
# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY() { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e "$1" 2>/dev/null; }
num() { local v="${1:-}"; case "$v" in ''|NULL) echo 0;; *) echo "$v";; esac; }

# ---------------------------------------------------------------- SETUP -----
if [ "$MODE" = SETUP ]; then
  NEW_DOGE="${DOGE_ADDR:-${2:-}}"
  NEW_LTC="${LTC_ADDR:-${3:-}}"
  [ -n "$NEW_DOGE" ] && [ -n "$NEW_LTC" ] || {
    echo "usage: sudo DOGE_ADDR=D... LTC_ADDR=ltc1... bash $0 SETUP"; exit 1; }

  V=$($DCLI validateaddress "$NEW_DOGE" | sed -n 's/.*"isvalid": *\([a-z]*\).*/\1/p')
  [ "$V" = true ] || { echo "FATAL: $NEW_DOGE is not a valid Dogecoin address"; exit 1; }
  V=$($LCLI validateaddress "$NEW_LTC" | sed -n 's/.*"isvalid": *\([a-z]*\).*/\1/p')
  [ "$V" = true ] || { echo "FATAL: $NEW_LTC is not a valid Litecoin address"; exit 1; }

  mkdir -p /etc/pool-wallets
  printf 'COLD_DOGE=%s\nCOLD_LTC=%s\n' "$NEW_DOGE" "$NEW_LTC" > "$COLD_ENV"
  chmod 600 "$COLD_ENV"
  echo "  wrote $COLD_ENV"
  sed 's/^/    /' "$COLD_ENV"
  echo "  both addresses validated by their daemons."
  echo "  next: sudo bash $0 STATUS   then   sudo bash $0 DRAIN"
  exit 0
fi

if [ -z "${COLD_DOGE:-}" ] || [ -z "${COLD_LTC:-}" ]; then
  echo "FATAL: no destinations configured. Run SETUP first:"
  echo "  sudo DOGE_ADDR=D... LTC_ADDR=ltc1... bash $0 SETUP"
  exit 1
fi

# ------------------------------------------------------------ liabilities ---
doge_owed() {
  local a b
  a=$(num "$(MY "SELECT ROUND(COALESCE(SUM(amount),0),2) FROM doge_payout_ledger WHERE paid_at IS NULL")")
  b=$(num "$(MY "SELECT ROUND(COALESCE(SUM(doge_balance),0),2) FROM accounts WHERE doge_balance>0")")
  awk -v x="$a" -v y="$b" 'BEGIN{printf "%.8f", x+y}'
}
ltc_owed() {
  local a b
  a=$(num "$(MY "SELECT ROUND(COALESCE(SUM(balance),0),8) FROM accounts a JOIN coins c ON c.id=a.coinid WHERE c.symbol='LTC' AND a.balance>0")")
  b=$(num "$(MY "SELECT ROUND(COALESCE(SUM(amount),0),8) FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE c.symbol='LTC' AND p.completed=0")")
  awk -v x="$a" -v y="$b" 'BEGIN{printf "%.8f", x+y}'
}

report() {          # coin cli balance immature owed reserve
  printf '  %-4s spendable=%s immature=%s owed=%s reserve=%s\n' "$1" "$2" "$3" "$4" "$5"
}

collect() {
  DOGE_BAL=$(num "$($DCLI getbalance 2>/dev/null)")
  DOGE_IMM=$(num "$($DCLI getwalletinfo 2>/dev/null | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')")
  LTC_BAL=$(num "$($LCLI getbalance 2>/dev/null)")
  LTC_IMM=$(num "$($LCLI getwalletinfo 2>/dev/null | sed -n 's/.*"immature_balance": *\([0-9.]*\).*/\1/p')")
  DOGE_OWED=$(doge_owed); LTC_OWED=$(ltc_owed)
  DOGE_SEND=$(awk -v b="$DOGE_BAL" -v o="$DOGE_OWED" -v r="$RESERVE_DOGE" 'BEGIN{d=b-o-r; if(d<0)d=0; printf "%.8f", d}')
  LTC_SEND=$(awk  -v b="$LTC_BAL"  -v o="$LTC_OWED"  -v r="$RESERVE_LTC"  'BEGIN{d=b-o-r; if(d<0)d=0; printf "%.8f", d}')
}

collect
echo
echo "===== wallets"
report DOGE "$DOGE_BAL" "$DOGE_IMM" "$DOGE_OWED" "$RESERVE_DOGE"
report LTC  "$LTC_BAL"  "$LTC_IMM"  "$LTC_OWED"  "$RESERVE_LTC"
echo
echo "===== destinations (yours)"
echo "  DOGE -> $COLD_DOGE"
echo "  LTC  -> $COLD_LTC"
echo
echo "===== sweepable right now"
echo "  DOGE : $DOGE_SEND"
echo "  LTC  : $LTC_SEND"
echo "  (immature coinbase is excluded; it matures at 60/100 confs -- re-run later)"

if [ "$MODE" = STATUS ]; then
  echo
  echo "read-only. To move funds: sudo bash $0 DRAIN   (dry run first)"
  exit 0
fi

# --------------------------------------------------------------- INSTALL ----
if [ "$MODE" = INSTALL ]; then
  install -m 700 "$0" /usr/local/sbin/pool-cold-sweep.sh
  cat >/etc/cron.d/pool-cold-sweep <<'EOF'
# Managed by infra/wallet-rotation/16-cold-sweep.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 */6 * * * root /usr/local/sbin/pool-cold-sweep.sh DRAIN CONFIRM >> /var/log/pool-cold-sweep.log 2>&1
EOF
  chmod 644 /etc/cron.d/pool-cold-sweep
  systemctl restart cron >/dev/null 2>&1 || true
  echo
  echo "  installed: auto-sweep of both coins every 6h at :17 -> /var/log/pool-cold-sweep.log"
  echo "  it always keeps miner liabilities + reserve behind, so payouts can't bounce."
  exit 0
fi

if [ "$MODE" = UNINSTALL ]; then
  rm -f /etc/cron.d/pool-cold-sweep /usr/local/sbin/pool-cold-sweep.sh
  systemctl restart cron >/dev/null 2>&1 || true
  echo "  auto-sweep removed."
  exit 0
fi

[ "$MODE" = DRAIN ] || { echo "unknown mode '$MODE' (SETUP|STATUS|DRAIN|INSTALL|UNINSTALL)"; exit 1; }

# ----------------------------------------------------------------- DRAIN ----
if [ -f "$PAYOUT_LOCK" ]; then
  exec 9>"$PAYOUT_LOCK"
  flock -n 9 || { echo; echo "payout cycle running -- try again in a few minutes."; exit 0; }
fi

if [ "$CONFIRM" != CONFIRM ]; then
  echo
  echo "DRY RUN -- nothing sent."
  echo "  would send $DOGE_SEND DOGE -> $COLD_DOGE"
  echo "  would send $LTC_SEND  LTC  -> $COLD_LTC"
  echo "Re-run with: sudo bash $0 DRAIN CONFIRM"
  exit 0
fi

unlock() { # cli
  [ -n "${WALLET_PASSPHRASE:-}" ] || return 0
  $1 walletpassphrase "$WALLET_PASSPHRASE" 300 >/dev/null 2>&1
}
relock() { $DCLI walletlock >/dev/null 2>&1 || true; $LCLI walletlock >/dev/null 2>&1 || true; }
trap relock EXIT

echo
if awk -v s="$DOGE_SEND" -v m="$MIN_SWEEP_DOGE" 'BEGIN{exit !(s>=m)}'; then
  unlock "$DCLI" || { echo "  DOGE unlock FAILED (wrong passphrase?) -- skipping DOGE"; DOGE_SEND=0; }
  if awk -v s="$DOGE_SEND" 'BEGIN{exit !(s>0)}'; then
    TX=$($DCLI sendtoaddress "$COLD_DOGE" "$DOGE_SEND" "cold sweep" "" true) \
      && echo "  DOGE sent $DOGE_SEND txid=$TX" || echo "  DOGE send FAILED: $TX"
  fi
else
  echo "  DOGE below MIN_SWEEP_DOGE=$MIN_SWEEP_DOGE -- skipped"
fi

if awk -v s="$LTC_SEND" -v m="$MIN_SWEEP_LTC" 'BEGIN{exit !(s>=m)}'; then
  unlock "$LCLI" || { echo "  LTC unlock FAILED (wrong passphrase?) -- skipping LTC"; LTC_SEND=0; }
  if awk -v s="$LTC_SEND" 'BEGIN{exit !(s>0)}'; then
    TX=$($LCLI sendtoaddress "$COLD_LTC" "$LTC_SEND" "cold sweep" "" true) \
      && echo "  LTC  sent $LTC_SEND txid=$TX" || echo "  LTC  send FAILED: $TX"
  fi
else
  echo "  LTC below MIN_SWEEP_LTC=$MIN_SWEEP_LTC -- skipped"
fi

echo
echo "done. Balances after:"
echo "  DOGE $($DCLI getbalance 2>/dev/null)   LTC $($LCLI getbalance 2>/dev/null)"
echo "Make it permanent:  sudo bash $0 INSTALL"
