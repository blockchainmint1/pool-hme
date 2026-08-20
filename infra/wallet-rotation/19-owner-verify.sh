#!/usr/bin/env bash
# 19-owner-verify.sh -- prove (or disprove) that the pool's coinbase addresses
# are the SAME addresses your offline cold-storage app can recover.
#
#   ... | sudo bash -s STATE                       # what the wallets/DB say right now
#   ... | sudo bash -s ADDR LTC  ltc1q...          # does the LTC wallet own this address?
#   ... | sudo bash -s ADDR DOGE DCi769...         # does the DOGE wallet own this address?
#   ... | sudo bash -s MATCH LTC  ltc1q...         # import a WIF (prompted) and check it
#   ... | sudo bash -s MATCH DOGE DCi769...        #   yields exactly this address
#
# WHY YOUR APP AND litecoind DISAGREE -- read this once:
#
#   `sethdseed` does NOT take a BIP39 mnemonic or a BIP32 master seed. It takes
#   a WIF private key and uses it as the HD master key, deriving on Bitcoin
#   Core's own path (m/0'/0'/k'), NOT BIP84 m/84'/2'/0'/0/0.
#
#   So a seed that gives ltc1qz057y99... in a BIP84 app will give a COMPLETELY
#   different address in litecoind. Neither is wrong -- they are different
#   derivation schemes over the same entropy. The consequence is what matters:
#   a Core sethdseed wallet is NOT recoverable in your BIP84 app, and vice versa.
#
#   The recovery-safe model is IMPORT, for BOTH coins:
#     1. In your cold app, take the address you want rewards to land on
#        (LTC m/84'/2'/0'/0/0, DOGE m/44'/3'/0'/0/0) and export ITS WIF.
#     2. MATCH mode here imports that WIF and asserts it produces exactly that
#        address. If it doesn't, we stop -- wrong key, wrong coin, or wrong path.
#     3. Then SETCOINBASE (18-owner-key.sh) points block rewards at it.
#   Now the app alone recovers every coinbase payment, forever.
set -uo pipefail
MODE=${1:-STATE}
COIN=${2:-}
ADDR=${3:-}
PASS_ENV=/etc/pool-wallets/passphrase.env
BK=/var/backups/pool-wallets
STAMP=$(date -u '+%Y%m%d-%H%M%S')

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "19-owner-verify v2  mode=$MODE coin=${COIN:-all}  $(date -u '+%F %T UTC')"

cli() { # cli <COIN> <args...>  -- binaries are NOT on $PATH; LTC is multi-wallet
  local c=$1; shift
  case "$c" in
    LTC)  /home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool "$@" ;;
    DOGE) /home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf "$@" ;;
    *) echo "unknown coin $c" >&2; return 1 ;;
  esac
}
unlock() {
  local c=$1 secs=$2 v
  # shellcheck disable=SC1090
  [ -f "$PASS_ENV" ] && . "$PASS_ENV"
  case "$c" in LTC) v=${LTC_PASSPHRASE:-${WALLET_PASSPHRASE:-}} ;; DOGE) v=${DOGE_PASSPHRASE:-${WALLET_PASSPHRASE:-}} ;; esac
  [ -n "$v" ] || { echo "  !! no passphrase for $c in $PASS_ENV"; return 1; }
  cli "$c" walletpassphrase "$v" "$secs" >/dev/null 2>&1 || true
}
jget() { grep -oE "\"$2\": *\"?[^\",}]+" <<<"$1" | head -1 | sed 's/.*: *"\?//'; }

describe_addr() { # describe_addr <COIN> <ADDR>
  local c=$1 a=$2 info mine wat lab path
  info=$(cli "$c" getaddressinfo "$a" 2>&1)
  if grep -qi 'error\|Invalid' <<<"$info"; then
    echo "   !! daemon rejected the address: $(head -c 160 <<<"$info")"
    return 1
  fi
  mine=$(jget "$info" ismine); wat=$(jget "$info" iswatchonly)
  path=$(jget "$info" hdkeypath); lab=$(grep -oE '"labels": *\[[^]]*\]' <<<"$info")
  printf '   address   : %s\n' "$a"
  printf '   ismine    : %s%s\n' "${mine:-false}" "$([ "${mine:-false}" = true ] && echo '   <-- wallet holds the private key' || echo '   <-- wallet CANNOT spend this')"
  [ "${wat:-false}" = true ] && printf '   watchonly : true (visible, NOT spendable)\n'
  [ -n "$path" ] && printf '   hdkeypath : %s\n' "$path"
  [ -n "$lab" ] && printf '   %s\n' "$lab"
  [ "${mine:-false}" = true ]
}

case "$MODE" in
STATE)
  echo
  echo "== 1. coinbase addresses yiimp is paying to (coins.master_wallet)"
  for c in LTC DOGE; do
    A=$(mysql -N -B yiimpfrontend -e "SELECT master_wallet FROM coins WHERE symbol='$c';" 2>/dev/null)
    echo " -- $c  $A"
    [ -n "$A" ] && describe_addr "$c" "$A" >/dev/null 2>&1
    [ -n "$A" ] && describe_addr "$c" "$A"
  done
  echo
  echo "== 2. HD seed in each wallet (Core's own scheme -- NOT your app's)"
  for c in LTC DOGE; do
    W=$(cli "$c" getwalletinfo 2>/dev/null)
    printf ' -- %-4s hdseedid=%s  keypool=%s\n' "$c" "$(jget "$W" hdseedid)" "$(grep -oE '"keypoolsize": *[0-9]+' <<<"$W" | grep -oE '[0-9]+')"
  done
  echo
  echo "== 3. has SETCOINBASE ever run? (history file)"
  if [ -s "$BK/master_wallet-history.txt" ]; then
    sed 's/^/   /' "$BK/master_wallet-history.txt"
  else
    echo "   (no history file -- coinbase addresses have NEVER been rotated by our scripts)"
  fi
  echo
  echo "== 4. keys labelled owner-coinbase (imported by you, offline-recoverable)"
  for c in LTC DOGE; do
    L=$(cli "$c" getaddressesbylabel "owner-coinbase" 2>/dev/null | grep -oE '"[a-zA-Z0-9]{20,}"' | tr -d '"')
    printf ' -- %-4s %s\n' "$c" "${L:-none}"
  done
  cat <<'EOF'

READ THIS:
  If section 4 says "none" for a coin, that coin's block rewards are NOT
  recoverable from your cold-storage app. Nothing is lost -- the daemon still
  owns the keys and can spend them -- but your only backup is the wallet.dat
  file on the box.

  To fix, per coin: export the WIF for the address you want from your app, then
    ... | sudo bash -s MATCH LTC  <the-address-your-app-shows>
  It imports the key and proves it lands on that exact address before you commit.
EOF
  ;;

ADDR)
  case "$COIN" in LTC|DOGE) ;; *) echo "usage: ADDR LTC|DOGE <address>"; exit 1;; esac
  [ -n "$ADDR" ] || { echo "give the address"; exit 1; }
  echo
  echo "-- $COIN"
  if describe_addr "$COIN" "$ADDR"; then
    echo "   VERDICT: the $COIN wallet owns this address. Safe to SETCOINBASE."
  else
    echo "   VERDICT: the $COIN wallet does NOT own this address."
    echo "            Import its WIF first:  ... | sudo bash -s MATCH $COIN $ADDR"
  fi
  ;;

MATCH)
  case "$COIN" in LTC|DOGE) ;; *) echo "usage: MATCH LTC|DOGE <expected-address>"; exit 1;; esac
  [ -n "$ADDR" ] || { echo "give the address your cold app shows for that key"; exit 1; }

  echo "  expected address: $ADDR"
  if describe_addr "$COIN" "$ADDR" >/dev/null 2>&1; then
    echo "  already owned by the wallet -- nothing to import."
    describe_addr "$COIN" "$ADDR"
    echo "  next: 18-owner-key.sh SETCOINBASE $COIN $ADDR"
    exit 0
  fi

  # back up before touching the wallet -- daemon writes as ubuntu, stage first
  lc=$(printf '%s' "$COIN" | tr 'A-Z' 'a-z')
  stage=/home/ubuntu/.wallet-backup-stage; mkdir -p "$stage" "$BK"
  chown ubuntu:ubuntu "$stage" 2>/dev/null; chmod 700 "$stage" "$BK"
  tmp="$stage/$lc-wallet-before-match-$STAMP.dat"
  if err=$(cli "$COIN" backupwallet "$tmp" 2>&1); then
    mv -f "$tmp" "$BK/$lc-wallet-before-match-$STAMP.dat"; chmod 600 "$BK/$lc-wallet-before-match-$STAMP.dat"
    echo "  wallet backed up -> $BK/$lc-wallet-before-match-$STAMP.dat"
  else
    echo "  !! backupwallet failed -- ABORT: ${err:-<no output>}"; exit 1
  fi

  # secret is never an argument; prompt on the real terminal (stdin is the curl pipe)
  f="/root/owner-key.$COIN"; S=
  if [ -s "$f" ]; then
    S=$(tr -d '[:space:]' < "$f"); echo "  read from $f (shredding)"; shred -u "$f" 2>/dev/null || rm -f "$f"
  elif [ -r /dev/tty ]; then
    read -r -s -p "  paste the $COIN WIF private key for $ADDR (hidden), then Enter: " S </dev/tty; echo
  else
    echo "  !! no terminal. Put the WIF in $f (chmod 600) and re-run."; exit 1
  fi
  [ -n "$S" ] || { echo "  !! empty"; exit 1; }

  unlock "$COIN" 300
  echo "  importing (no rescan -- we only care that the key derives the address)"
  out=$(cli "$COIN" importprivkey "$S" "owner-coinbase" false 2>&1)
  unset S
  if grep -qi 'error' <<<"$out"; then
    echo "  !! import rejected: $(head -c 200 <<<"$out")"
    echo "     Common causes: WIF is for the wrong coin/network, or it was"
    echo "     copied with a leading/trailing character."
    exit 1
  fi

  echo
  if describe_addr "$COIN" "$ADDR"; then
    echo
    echo "  MATCH CONFIRMED. The key you hold offline produces exactly $ADDR,"
    echo "  and the $COIN wallet can now spend it."
    echo "  next: 18-owner-key.sh SETCOINBASE $COIN $ADDR"
  else
    echo
    echo "  !! MISMATCH. The key imported fine, but it does NOT derive $ADDR."
    echo "     Addresses this key DOES control:"
    cli "$COIN" getaddressesbylabel "owner-coinbase" 2>/dev/null | grep -oE '"[a-zA-Z0-9]{20,}"' | tr -d '"' | sed 's/^/       /'
    echo "     Likely cause: the WIF came from a different derivation path than"
    echo "     the address you pasted. For LTC use m/84'/2'/0'/0/0 (bech32 ltc1q...),"
    echo "     for DOGE m/44'/3'/0'/0/0 (D...). Re-export the WIF for THAT exact row."
    echo "     Nothing was rotated -- coinbase is untouched. Safe to retry."
    exit 1
  fi
  ;;
*) echo "usage: STATE | ADDR <COIN> <addr> | MATCH <COIN> <expected-addr>"; exit 1;;
esac
