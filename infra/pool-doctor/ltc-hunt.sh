#!/usr/bin/env bash
# ltc-hunt.sh -- find the pool's LTC.
#
#   ... | sudo bash            # or: sudo bash -s HUNT
#
# WHY THIS EXISTS
#   cold-sweep reported LTC spendable=0 while LTC blocks are being found.
#   Litecoin Core 0.21 is MULTI-WALLET: `litecoin-cli getbalance` with no
#   -rpcwallet talks to the *default* wallet, which on this box is empty.
#   The mining wallet is loaded under a name (`pool`). Money that lives in
#   `pool` is invisible to any command that forgets -rpcwallet.
#
#   This script asks the daemon which wallets exist, then reports balances,
#   immature coinbase, and recent generate txs for EVERY one of them, so we
#   can see exactly which wallet holds the coins before sweeping anything.
#
# Read-only. Sends nothing, changes nothing.
set -uo pipefail
MODE=${1:-HUNT}
VERSION=v1
LBIN=/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli
LCONF=/home/ubuntu/.litecoin/litecoin.conf
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "ltc-hunt $VERSION  $(date -u '+%F %T UTC')  mode=$MODE"

L() { "$LBIN" -conf="$LCONF" "$@" 2>&1; }          # no wallet (default/global)
LW() { local w=$1; shift; "$LBIN" -conf="$LCONF" -rpcwallet="$w" "$@" 2>&1; }
jnum() { grep -oE "\"$1\": *-?[0-9.]+" | head -1 | awk '{print $2}'; }

echo
echo "===== 1. daemon"
L getnetworkinfo | grep -E '"subversion"|"version"' | sed 's/^/  /'
L getblockchaininfo | grep -E '"chain"|"blocks"|"headers"|"initialblockdownload"' | sed 's/^/  /'

echo
echo "===== 2. wallets the daemon has LOADED"
LOADED=$(L listwallets | grep -oE '"[^"]*"' | tr -d '"')
if [ -z "$LOADED" ]; then echo "  (none -- listwallets returned nothing)"; fi
printf '  %s\n' ${LOADED:-} | sed 's/^  $/  ""(default)/'

echo
echo "===== 3. wallet FILES on disk (may include unloaded wallets)"
find /home/ubuntu/.litecoin -name wallet.dat -printf '  %10s  %p\n' 2>/dev/null | sort -k1 -n -r

echo
echo "===== 4. balances per loaded wallet"
printf '  %-14s %16s %16s %16s %10s\n' WALLET SPENDABLE UNCONFIRMED IMMATURE TXS
for w in $LOADED; do
  wi=$(LW "$w" getwalletinfo)
  sp=$(printf '%s' "$wi" | jnum balance)
  un=$(printf '%s' "$wi" | jnum unconfirmed_balance)
  im=$(printf '%s' "$wi" | jnum immature_balance)
  tx=$(printf '%s' "$wi" | jnum txcount)
  printf '  %-14s %16s %16s %16s %10s\n' "$w" "${sp:-?}" "${un:-?}" "${im:-?}" "${tx:-?}"
done

echo
echo "===== 5. unspent outputs per wallet (incl. immature coinbase)"
for w in $LOADED; do
  echo "  -- wallet: $w"
  # minconf 0 so we see everything the wallet can see
  LW "$w" listunspent 0 9999999 \
    | grep -oE '"amount": *[0-9.]+' | awk '{s+=$2; n++} END {printf "     mature unspent : %d outputs  %.8f LTC\n", n, s}'
  LW "$w" listtransactions "*" 200 0 \
    | grep -oE '"category": *"[a-z]+"' | sort | uniq -c | sed 's/^/     /'
done

echo
echo "===== 6. recent coinbase (generate/immature) txs, newest first"
for w in $LOADED; do
  echo "  -- wallet: $w"
  LW "$w" listtransactions "*" 40 0 \
    | grep -E '"address"|"category"|"amount"|"confirmations"|"generated"' \
    | sed 's/^/     /' | tail -60
done

echo
echo "===== 7. what yiimp thinks the LTC coinbase address is"
eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MW=$(mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e \
  "SELECT master_wallet FROM coins WHERE symbol='LTC';" 2>/dev/null)
echo "  coins.master_wallet = ${MW:-<unknown>}"
if [ -n "$MW" ]; then
  for w in $LOADED; do
    mine=$(LW "$w" getaddressinfo "$MW" | grep -oE '"ismine": *(true|false)' | awk '{print $2}')
    echo "    wallet $w owns it? ${mine:-?}"
  done
  echo "  received by that address (all wallets, minconf 0):"
  for w in $LOADED; do
    r=$(LW "$w" getreceivedbyaddress "$MW" 0 | tr -d '\n')
    echo "    $w: $r"
  done
fi

echo
echo "===== 8. LTC blocks yiimp recorded in the last 14 days"
mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -N -B -e \
  "SELECT height, category, amount, FROM_UNIXTIME(time) FROM blocks
    WHERE coin_id=(SELECT id FROM coins WHERE symbol='LTC')
      AND time > UNIX_TIMESTAMP()-14*86400
    ORDER BY height DESC LIMIT 30;" 2>/dev/null | sed 's/^/  /'

cat <<'EOF'

===== READ IT LIKE THIS
  * A wallet in section 4 with a non-zero SPENDABLE is where the money is.
    If that wallet is NOT the one cold-sweep talks to, the sweep sees zero.
    Fix = add -rpcwallet=<that wallet> to the LTC client in cold-sweep.
  * IMMATURE non-zero with SPENDABLE zero means the LTC is real but still
    locked as young coinbase (100 confirmations, ~4 hours on LTC). Nothing is
    lost -- it becomes sweepable on its own. Re-run later.
  * All zeros everywhere, but section 8 lists blocks, means the coinbase paid
    to an address this wallet does not own. Section 7 tells you which.
EOF
