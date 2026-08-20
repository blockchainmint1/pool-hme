#!/usr/bin/env bash
# 18-owner-key.sh -- put a key YOU generated offline behind the pool's coinbase
# address, so you hold a hard, portable backup of the wallet that receives
# block rewards.
#
#   ... | sudo bash -s CHECK                  # capabilities + current state (default)
#   ... | sudo bash -s SEED  LTC              # sethdseed: WHOLE wallet from your seed  (LTC only)
#   ... | sudo bash -s IMPORT DOGE            # importprivkey: ONE coinbase key         (DOGE + LTC)
#   ... | sudo bash -s SETCOINBASE LTC <addr> # point yiimp's master_wallet at it
#   ... | sudo bash -s VERIFY                 # prove the chain pays where you think
#
# The key/seed is NEVER passed as an argument (shell history, ps, logs). The
# script prompts for it on the terminal with echo off, or reads a file you
# place at /root/owner-key.<COIN> and shreds it afterwards.
#
# WHAT EACH MODE ACTUALLY BACKS UP -- read this before choosing:
#
#   SEED (sethdseed, LTC Core >=0.21):
#     Every address the wallet generates from now on -- coinbase AND the change
#     addresses payouts land on -- derives from your seed. One offline backup
#     recovers the entire future wallet. This is the real answer.
#     Dogecoin Core 1.14 is pre-Bitcoin-0.17 and has NO sethdseed, so DOGE
#     cannot use this path.
#
#   IMPORT (importprivkey, both coins):
#     Backs up exactly ONE address. Block rewards paid to it are recoverable
#     from your key alone. But when the pool spends a reward to pay miners,
#     the change goes to a wallet-generated address your key does NOT cover.
#     So this protects the coinbase, not the whole balance. Still worth doing
#     for DOGE, where it's the only option.
#
# Neither mode touches existing coins. Nothing is swept, nothing is spent.
set -uo pipefail
MODE=${1:-CHECK}
COIN=${2:-}
ARG3=${3:-}
PASS_ENV=/etc/pool-wallets/passphrase.env
BK=/var/backups/pool-wallets
STAMP=$(date -u '+%Y%m%d-%H%M%S')

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "18-owner-key v1  mode=$MODE coin=${COIN:-all}  $(date -u '+%F %T UTC')"

cli() { # cli <COIN> <args...>
  # Binaries are NOT on $PATH (see docs/infrastructure.md §2b). Use full paths + -conf.
  local c=$1; shift
  case "$c" in
    LTC)  /home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool "$@" ;;
    DOGE) /home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf "$@" ;;
    *) echo "unknown coin $c" >&2; return 1 ;;
  esac
}
unlock() { # unlock <COIN> <seconds>
  local c=$1 secs=$2 v
  # shellcheck disable=SC1090
  [ -f "$PASS_ENV" ] && . "$PASS_ENV"
  # Coin-specific var wins; fall back to shared WALLET_PASSPHRASE (both wallets
  # share one passphrase after rotation -- see docs/infrastructure.md §2b).
  case "$c" in LTC) v=${LTC_PASSPHRASE:-${WALLET_PASSPHRASE:-}} ;; DOGE) v=${DOGE_PASSPHRASE:-${WALLET_PASSPHRASE:-}} ;; esac
  [ -n "$v" ] || { echo "  !! no passphrase for $c in $PASS_ENV (need LTC_PASSPHRASE/DOGE_PASSPHRASE or WALLET_PASSPHRASE)"; return 1; }
  cli "$c" walletpassphrase "$v" "$secs" >/dev/null 2>&1 || true
}
read_secret() { # read_secret <COIN> -> echoes the secret
  local c=$1 f="/root/owner-key.$c" s=
  if [ -s "$f" ]; then
    s=$(tr -d '[:space:]' < "$f")
    echo "  read from $f (will be shredded)" >&2
    shred -u "$f" 2>/dev/null || rm -f "$f"
  else
    if [ -t 0 ]; then
      read -r -s -p "  paste the $c secret (input hidden), then Enter: " s </dev/tty; echo >&2
    else
      echo "  !! not a terminal. Put the secret in /root/owner-key.$c (chmod 600) and re-run." >&2
      return 1
    fi
  fi
  [ -n "$s" ] || { echo "  !! empty secret" >&2; return 1; }
  printf '%s' "$s"
}
backup_wallet() { # backup_wallet <COIN>
  local c=$1
  local lc out
  lc=$(printf '%s' "$c" | tr 'A-Z' 'a-z')
  out="$BK/$lc-wallet-before-ownerkey-$STAMP.dat"
  mkdir -p "$BK"; chmod 700 "$BK"
  cli "$c" backupwallet "$out" >/dev/null 2>&1 \
    && echo "  wallet backed up -> $out" \
    || echo "  !! backupwallet failed -- ABORT and investigate"
}

case "$MODE" in
CHECK)
  for c in LTC DOGE; do
    echo
    echo "-- $c"
    v=$(cli "$c" getnetworkinfo 2>/dev/null | grep -oE '"subversion": *"[^"]+"' | cut -d'"' -f4)
    echo "   daemon        : ${v:-UNREACHABLE}"
    if cli "$c" help sethdseed >/dev/null 2>&1; then
      echo "   sethdseed     : AVAILABLE  -> SEED mode possible (whole-wallet backup)"
    else
      echo "   sethdseed     : not supported -> IMPORT mode only (coinbase-only backup)"
    fi
    hd=$(cli "$c" getwalletinfo 2>/dev/null | grep -oE '"hdseedid": *"[^"]+"' | cut -d'"' -f4)
    echo "   current hdseed: ${hd:-none}"
    enc=$(cli "$c" getwalletinfo 2>/dev/null | grep -c unlocked_until)
    echo "   encrypted     : $([ "$enc" -gt 0 ] && echo yes || echo NO)"
  done
  echo
  echo "-- yiimp coinbase addresses in use (coins.master_wallet)"
  mysql -N -B yiimpfrontend -e \
    "SELECT symbol, master_wallet FROM coins WHERE symbol IN ('LTC','DOGE');" 2>/dev/null | sed 's/^/   /'
  cat <<'EOF'

How to generate the secret OFFLINE (on your laptop, never on this box):
  LTC seed  : any BIP32 hex seed you control, or an existing wallet's
              `dumpwallet` hdseed. 32 bytes hex, or a WIF from your own wallet.
  DOGE key  : a WIF private key from a wallet you control (Dogecoin Core
              `dumpprivkey <addr>`, or a hardware/paper wallet export).
Then either paste it at the prompt, or scp it to /root/owner-key.LTC (chmod 600)
and re-run -- the script shreds the file after reading.
EOF
  ;;

SEED)
  [ "$COIN" = LTC ] || { echo "SEED mode is LTC-only (Dogecoin Core has no sethdseed). Use IMPORT for DOGE."; exit 1; }
  cli LTC help sethdseed >/dev/null 2>&1 || { echo "this litecoind does not support sethdseed"; exit 1; }
  backup_wallet LTC
  echo "  NOTE: existing keys stay in the wallet and keep working."
  echo "        Only NEW addresses derive from your seed."
  S=$(read_secret LTC) || exit 1
  unlock LTC 120
  # keeppool=true so the existing keypool isn't wiped mid-payout
  if cli LTC sethdseed true "$S" 2>&1 | grep -qi error; then
    echo "  !! sethdseed rejected the value. It must be a WIF private key that"
    echo "     litecoind accepts as an HD seed (LTC Core takes a WIF here)."
    unset S; exit 1
  fi
  unset S
  NEW=$(cli LTC getnewaddress "" bech32 2>/dev/null || cli LTC getnewaddress)
  echo "  OK  wallet now derives from YOUR seed."
  echo "  new owner-derived address: $NEW"
  echo "  next: ... | sudo bash -s SETCOINBASE LTC $NEW"
  ;;

IMPORT)
  case "$COIN" in LTC|DOGE) ;; *) echo "usage: IMPORT LTC|DOGE"; exit 1;; esac
  backup_wallet "$COIN"
  S=$(read_secret "$COIN") || exit 1
  unlock "$COIN" 300
  echo "  importing (rescan disabled -- this key is new, nothing to find)"
  if cli "$COIN" importprivkey "$S" "owner-coinbase" false 2>&1 | grep -qi error; then
    echo "  !! import failed -- is it a valid $COIN WIF for this network?"
    unset S; exit 1
  fi
  unset S
  echo "  imported. Addresses now owned by this key:"
  cli "$COIN" getaddressesbylabel "owner-coinbase" 2>/dev/null | grep -oE '"[a-zA-Z0-9]{20,}"' | tr -d '"' | sed 's/^/    /'
  echo "  pick the one matching your offline record, then:"
  echo "    ... | sudo bash -s SETCOINBASE $COIN <that-address>"
  ;;

SETCOINBASE)
  case "$COIN" in LTC|DOGE) ;; *) echo "usage: SETCOINBASE LTC|DOGE <address>"; exit 1;; esac
  ADDR=$ARG3
  [ -n "$ADDR" ] || { echo "give the address"; exit 1; }
  MINE=$(cli "$COIN" getaddressinfo "$ADDR" 2>/dev/null | grep -oE '"ismine": *(true|false)' | awk '{print $2}')
  [ "$MINE" = true ] || { echo "  !! $COIN wallet does NOT own $ADDR -- refusing. Rewards would be unspendable."; exit 1; }
  OLD=$(mysql -N -B yiimpfrontend -e "SELECT master_wallet FROM coins WHERE symbol='$COIN';")
  echo "  old master_wallet: $OLD"
  echo "  new master_wallet: $ADDR"
  mkdir -p "$BK"; echo "$COIN $OLD" >> "$BK/master_wallet-history.txt"
  mysql yiimpfrontend -e "UPDATE coins SET master_wallet='$ADDR' WHERE symbol='$COIN';"
  echo "  DB updated (previous value appended to $BK/master_wallet-history.txt)"
  echo "  restarting stratum so the new coinbase address takes effect..."
  systemctl restart stratum-aws-scrypt && sleep 4
  systemctl is-active stratum-aws-scrypt | sed 's/^/  stratum: /'
  echo "  next block found on $COIN pays to $ADDR."
  ;;

VERIFY)
  echo "-- coinbase address ownership + backup status"
  for c in LTC DOGE; do
    A=$(mysql -N -B yiimpfrontend -e "SELECT master_wallet FROM coins WHERE symbol='$c';" 2>/dev/null)
    M=$(cli "$c" getaddressinfo "$A" 2>/dev/null | grep -oE '"ismine": *(true|false)' | awk '{print $2}')
    L=$(cli "$c" getaddressinfo "$A" 2>/dev/null | grep -oE '"labels": *\[[^]]*\]')
    printf '  %-5s %s\n        ismine=%s  %s\n' "$c" "$A" "${M:-?}" "${L:-}"
  done
  echo
  echo "-- most recent coinbase payments actually landing there"
  for c in LTC DOGE; do
    echo "  $c:"
    cli "$c" listtransactions "*" 5 0 2>/dev/null \
      | grep -E '"address"|"category"|"amount"|"confirmations"' | sed 's/^/    /'
  done
  echo
  echo "  A green run = ismine:true on both, label owner-coinbase (or an"
  echo "  owner-derived address), and generate txs landing on that address."
  ;;
*) echo "usage: CHECK | SEED LTC | IMPORT LTC|DOGE | SETCOINBASE <COIN> <addr> | VERIFY"; exit 1;;
esac
