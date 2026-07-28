#!/usr/bin/env bash
# Sweep the OLD (pre-rotation) DOGE seed into the CURRENT hot wallet.
#
#   sudo bash 06-sweep-old-doge.sh                 # dry run  (rescan + report only)
#   sudo bash 06-sweep-old-doge.sh CONFIRM_SWEEP   # rescan, then send everything
#
# Why a swap and not a second daemon:
#   Dogecoin 1.14 is pre-multiwallet. A second dogecoind cannot share the live
#   datadir (LOCK file), and a separate datadir means resyncing the whole chain.
#   So we stop the daemon, boot it against the old wallet file with -rescan,
#   sweep, then hand the datadir back to the normal service.
#
# Impact while it runs:
#   dogecoind is offline for the length of a full -rescan (typically 20-60 min).
#   Miners keep hashing; stratum retries getauxblock and DOGE aux shares queue.
#   LTC/TXC/ISK are untouched. The DOGE payout cron is held off via its lock.
set -euo pipefail

CONFIRM="${1:-}"
DDIR=/home/ubuntu/.dogecoin
DBIN=/home/ubuntu/dogecoin-1.14.9/bin
CONF="$DDIR/dogecoin.conf"
DCLI="$DBIN/dogecoin-cli -conf=$CONF"
PASS_ENV=/etc/pool-wallets/passphrase.env
PAYOUT_LOCK=/var/web/runtime/doge-payout/doge-payout-cycle.lock
SVC=dogecoind

log() { echo "[$(date '+%H:%M:%S')] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

OLD=$(ls -1t "$DDIR"/wallet.dat.old-seed-* 2>/dev/null | head -1 || true)
[ -n "$OLD" ] || { echo "FATAL: no $DDIR/wallet.dat.old-seed-* found"; exit 1; }

echo "=== Sweep old DOGE seed -> current hot wallet ==="
echo "Mode      : $([ "$CONFIRM" = CONFIRM_SWEEP ] && echo EXECUTE || echo 'DRY RUN')"
echo "Old wallet: $OLD"

# ---- destination comes from the CURRENT (rotated) wallet, before we swap it out
DEST="${DEST:-}"
if [ -z "$DEST" ]; then
  DEST=$($DCLI getnewaddress "sweep-from-old-seed" 2>/dev/null || true)
fi
[ -n "$DEST" ] || { echo "FATAL: could not get a destination address from the live wallet"; exit 1; }
CUR_SEED=$($DCLI getwalletinfo 2>/dev/null | sed -n 's/.*"hdmasterkeyid": *"\([^"]*\)".*/\1/p')
echo "Dest addr : $DEST   (current seed ${CUR_SEED:-unknown})"
echo

# ---- never fight the payout cron
if [ -f "$PAYOUT_LOCK" ]; then
  exec 9>"$PAYOUT_LOCK"
  flock -n 9 || { echo "payout cycle running -- try again in a few minutes"; exit 0; }
fi

if [ "$CONFIRM" != "CONFIRM_SWEEP" ]; then
  cat <<EOF
Plan:
  1. stop $SVC
  2. cp current wallet.dat -> wallet.dat.hot-backup-<stamp>   (untouched safety copy)
  3. cp $OLD -> $DDIR/oldseed.dat
  4. start dogecoind manually: -wallet=oldseed.dat -rescan   (20-60 min, daemon offline)
  5. report old-seed balance + immature
  6. sendtoaddress $DEST <spendable>   (subtractfeefromamount)
  7. stop the temp daemon, start $SVC on the normal wallet.dat
  8. verify: live wallet balance, old-seed leftovers

Nothing is deleted. The old seed file stays in place after the sweep.
Re-run with: sudo $0 CONFIRM_SWEEP
EOF
  exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
TMPWALLET="$DDIR/oldseed.dat"

restart_service() {
  log "restoring normal service"
  pkill -f "dogecoind.*-wallet=oldseed.dat" 2>/dev/null || true
  for i in $(seq 1 60); do pgrep -f 'dogecoind' >/dev/null || break; sleep 2; done
  systemctl start "$SVC" || true
  sleep 20
  $DCLI getwalletinfo 2>/dev/null | grep -E 'hdmasterkeyid|"balance"|immature' || true
}
trap 'echo "FAILED -- recovering"; restart_service' ERR

log "stopping $SVC"
systemctl stop "$SVC" || true
for i in $(seq 1 60); do pgrep -f dogecoind >/dev/null || break; sleep 2; done
pgrep -f dogecoind >/dev/null && { echo "FATAL: dogecoind still running"; exit 1; }

log "backing up current hot wallet"
cp -a "$DDIR/wallet.dat" "$DDIR/wallet.dat.hot-backup-$STAMP"

log "installing old seed as oldseed.dat"
cp -a "$OLD" "$TMPWALLET"
chown ubuntu:ubuntu "$TMPWALLET"

log "starting dogecoind on the old seed with -rescan (this is the slow part)"
sudo -u ubuntu "$DBIN/dogecoind" -conf="$CONF" -datadir="$DDIR" \
  -wallet=oldseed.dat -rescan -daemon

OCLI="$DCLI"
log "waiting for rescan to finish"
for i in $(seq 1 720); do   # up to 2h
  if $OCLI getwalletinfo >/dev/null 2>&1; then break; fi
  sleep 10
done
$OCLI getwalletinfo >/dev/null 2>&1 || { echo "FATAL: old-seed daemon never came up"; exit 1; }

echo
echo "--- old seed wallet ---"
$OCLI getwalletinfo | grep -E 'hdmasterkeyid|"balance"|immature|txcount'
BAL=$($OCLI getbalance)
echo

# encrypted old wallets need the passphrase
# shellcheck disable=SC1090
[ -r "$PASS_ENV" ] && . "$PASS_ENV"
if [ -n "${WALLET_PASSPHRASE:-}" ]; then
  $OCLI walletpassphrase "$WALLET_PASSPHRASE" 600 >/dev/null 2>&1 || true
fi

if awk -v b="$BAL" 'BEGIN{exit !(b <= 1)}'; then
  log "nothing spendable on the old seed (balance=$BAL) -- immature coinbases may still be pending"
else
  log "sending $BAL DOGE -> $DEST"
  TXID=$($OCLI sendtoaddress "$DEST" "$BAL" "old seed sweep" "" true)
  log "SENT txid=$TXID"
fi

$OCLI walletlock >/dev/null 2>&1 || true
log "stopping temp daemon"
$OCLI stop >/dev/null 2>&1 || true
for i in $(seq 1 90); do pgrep -f dogecoind >/dev/null || break; sleep 2; done

trap - ERR
restart_service

echo
echo "Done. Old seed file kept at $OLD"
echo "Hot wallet backup: $DDIR/wallet.dat.hot-backup-$STAMP"
echo "If immature coinbases remained on the old seed, re-run this after they mature (60 confs)."
