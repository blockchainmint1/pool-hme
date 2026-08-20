#!/usr/bin/env bash
# orphan-doctor.sh v2 -- READ ONLY.
#
#   curl -fsSL https://pool.honest.money/install/orphan-doctor.sh | sudo bash 2>&1 | tee /tmp/orphan.txt
#
# v1 established: every LTC block yiimp calls "orphan" is actually MAINCHAIN with
# real confirmations. So nothing was lost. v2 answers the two follow-ups:
#
#   1. WHO got the coinbase? (v1 read the merkleroot instead of the coinbase txid,
#      hence the bogus "error code: -5" on every row. Fixed here with a real JSON
#      parse of tx[0].)
#   2. WHY did LTC payouts stop on 11 Aug when the hot wallet holds 225 LTC and
#      only owes 12.55?
#
# Nothing is modified. No RPC call here writes state.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
LIMIT=${LIMIT:-12}

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }

# json helper: python3 is present on this box; falls back to jq.
J() { # J <jsonpath-expr-in-python>  reads stdin
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,json
try:
  d=json.load(sys.stdin)
except Exception:
  sys.exit(0)
$1" 2>/dev/null
  fi
}

detect() { local n=$1 line bin; line=$(ps -ef | grep -E "[/ ]${n}( |$)" | grep -v grep | head -1)
  bin=$(echo "$line" | grep -oE "/[^ ]*$n" | head -1); D_BIN=$(dirname "${bin:-/usr/local/bin/$n}")
  D_DIR=$(echo "$line" | grep -oE '\-datadir=[^ ]+' | cut -d= -f2)
  D_CONF=$(echo "$line" | grep -oE '\-conf=[^ ]+' | cut -d= -f2)
  [ -z "$D_CONF" ] && D_CONF="${D_DIR:-/home/ubuntu/.${n%d}}/${n%d}.conf"; }

detect litecoind; LCONF=$D_CONF; LBIN=$D_BIN
LWALLET=$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$LCONF" 2>/dev/null | head -1)
LBASE="$LBIN/litecoin-cli -conf=$LCONF"
LCLI="$LBASE ${LWALLET:+-rpcwallet=$LWALLET}"
detect dogecoind; DCONF=$D_CONF; DBIN=$D_BIN
DCLI="$DBIN/dogecoin-cli -conf=$DCONF"

echo "orphan-doctor v2  $(date -u '+%F %T UTC')"
echo "  litecoin-cli : $LBASE   conf wallet=${LWALLET:-(default)}"
echo "  v1 already proved: those 'orphans' are MAINCHAIN. This pass finds the money"
echo "  and the payout blockage."

# ---------------------------------------------------------------- 1
hr "1. THE MONEY -- coinbase of each mislabelled block, and who owns it"
printf '  %-9s %-10s %-46s %s\n' HEIGHT REWARD PAID_TO ISMINE
TOTAL=0
while IFS=$'\t' read -r H BH; do
  [ -z "${BH:-}" ] && continue
  CB=$($LBASE getblock "$BH" 2 2>/dev/null | J "
tx=d.get('tx') or []
print(tx[0]['txid'] if tx and isinstance(tx[0],dict) else (tx[0] if tx else ''))
o=(tx[0].get('vout') if tx and isinstance(tx[0],dict) else []) or []
best=max(o,key=lambda x:x.get('value',0)) if o else None
print(best.get('value','') if best else '')
sp=(best or {}).get('scriptPubKey',{})
a=sp.get('address') or (sp.get('addresses') or [''])[0]
print(a)")
  CBTXID=$(echo "$CB" | sed -n 1p); VAL=$(echo "$CB" | sed -n 2p); ADDR=$(echo "$CB" | sed -n 3p)
  if [ -z "$CBTXID" ]; then
    # older node: getblock verbosity 2 unsupported -> resolve via tx list + getrawtransaction
    CBTXID=$($LBASE getblock "$BH" 1 2>/dev/null | J "print((d.get('tx') or [''])[0])")
    RAW=$($LBASE getrawtransaction "$CBTXID" 1 2>/dev/null)
    VAL=$(echo "$RAW" | J "
o=d.get('vout') or []
b=max(o,key=lambda x:x.get('value',0)) if o else {}
print(b.get('value',''))")
    ADDR=$(echo "$RAW" | J "
o=d.get('vout') or []
b=max(o,key=lambda x:x.get('value',0)) if o else {}
sp=b.get('scriptPubKey',{})
print(sp.get('address') or (sp.get('addresses') or [''])[0])")
  fi
  MINE="?"
  [ -n "$ADDR" ] && MINE=$($LCLI getaddressinfo "$ADDR" 2>/dev/null | J "print(d.get('ismine'))")
  printf '  %-9s %-10s %-46s %s\n' "$H" "${VAL:-?}" "${ADDR:-<unparsed>}" "${MINE:-?}"
  [ -n "${VAL:-}" ] && TOTAL=$(awk "BEGIN{print $TOTAL+${VAL:-0}}")
  echo "     wallet gettransaction: $($LCLI gettransaction "$CBTXID" 2>&1 | J "print('SEEN conf=%s amount=%s' % (d.get('confirmations'), d.get('amount')))" || true)$( $LCLI gettransaction "$CBTXID" >/dev/null 2>&1 || echo "NOT IN WALLET ($($LCLI gettransaction "$CBTXID" 2>&1 | head -1 | cut -c1-60))")"
done < <(MYN "SELECT b.height, b.blockhash FROM blocks b JOIN coins c ON c.id=b.coin_id
              WHERE c.symbol='LTC' AND b.time > UNIX_TIMESTAMP()-10*86400
              ORDER BY b.id DESC LIMIT $LIMIT;")
echo "  ----"
echo "  total coinbase value across those blocks: ~$TOTAL LTC"
echo "  ismine=True  => the coins ARE in the 'pool' wallet; only the DB label is wrong."
echo "  ismine=False => coins went to a rotated/other wallet; recovery = import that key."

# ---------------------------------------------------------------- 2
hr "2. why yiimp filed them as orphan"
echo "  yiimp calls gettransaction(coinbase) on the wallet named in its coin row."
echo "  If litecoind has MULTIPLE wallets loaded and yiimp does not send -rpcwallet,"
echo "  the RPC hits the default handle and fails -> orphan, amount 0."
echo "  wallets loaded: $($LBASE listwallets 2>&1 | tr -d '\n ' )"
echo "  ^ two wallets loaded and NO default = every wallet RPC without -rpcwallet fails."
echo "    That is the 'unable to find the wallet for coinid 8' error verbatim."
grep -nE 'rpcwallet|^wallet=' "$LCONF" 2>/dev/null | sed 's/^/    litecoin.conf: /'
MY "SELECT id,symbol,LEFT(master_wallet,40) master_wallet,rpcport,
           LEFT(IFNULL(rpcuser,''),12) rpcuser, enable, auto_ready
    FROM coins WHERE symbol IN ('LTC','DOGE');"

# ---------------------------------------------------------------- 3
hr "3. PAYOUTS -- 5 LTC payouts pending since 9 Aug with no errmsg"
MY "SELECT p.id, c.symbol, FROM_UNIXTIME(p.time) t, p.amount, p.completed,
           LEFT(IFNULL(p.tx,''),20) tx, LEFT(IFNULL(p.errmsg,'(null)'),40) errmsg,
           LEFT(p.address,36) address
    FROM payouts p JOIN coins c ON c.id=p.idcoin
    WHERE p.completed=0 ORDER BY p.time DESC LIMIT 10;"
echo "  loop2 is running, wallet is unlocked, balance is 225 LTC and only 12.55 is owed."
echo "  So the blocker is NOT funds. Most likely: loop2's payout stage is throwing"
echo "  before it writes errmsg, or YAAMP_PAYMENTS_FREQ / payout_min gates it."
echo "  yiimp payout settings:"
grep -hnE "PAYMENTS_FREQ|payout|MINIMUM" /var/web/serverconfig.php 2>/dev/null | grep -v PASSWORD | sed 's/^/    /'
echo "  last 40 payout-relevant lines from the yiimp debug log:"
for L in /var/web/log/debug.log /var/log/yiimp/debug.log /var/web/yaamp/runtime/application.log; do
  [ -f "$L" ] && { echo "    -- $L"; grep -iE 'payout|sendmany|sendtoaddress|insufficient|wallet' "$L" 2>/dev/null | tail -20 | sed 's/^/      /'; }
done
echo "  loop2 stage timings (is the payout stage even reached?):"
ps -o etime=,cmd= -p "$(pgrep -f loop2.sh | head -1)" 2>/dev/null | sed 's/^/    /'
tail -30 /var/web/log/loop2.log 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 4
hr "4. DOGE -- last payout 12 Aug, 1.04M DOGE sitting in the hot wallet"
echo "  DOGE wallet: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '\"balance\":[0-9.]+|\"unlocked_until\":[0-9]+' | paste -sd' ')"
echo "  ^ unlocked_until=0 means the DOGE wallet is LOCKED -> sends fail instantly."
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) amount,
           FROM_UNIXTIME(MAX(created_at)) newest, FROM_UNIXTIME(MAX(updated_at)) touched
    FROM doge_payout_ledger GROUP BY status ORDER BY n DESC;"
echo "  doge cycle log tail:"
tail -20 /var/log/doge-payout-cycle.log 2>/dev/null | sed 's/^/    /'
echo "  NOTE: two DOGE crons exist (*/10 and a daily 06:15). The daily one is the"
echo "        retired schedule and should not be there -- see docs section on cadence."

# ---------------------------------------------------------------- 5
hr "5. earnings table (v1 used the wrong column name)"
ECOL=$(MYN "SELECT GROUP_CONCAT(column_name) FROM information_schema.columns
            WHERE table_schema='yiimpfrontend' AND table_name='earnings';")
echo "  columns: $ECOL"
TCOL=time; echo "$ECOL" | grep -q '\bcreate_time\b' && TCOL=create_time
MY "SELECT DATE(FROM_UNIXTIME(e.$TCOL)) d, COUNT(*) rows_, ROUND(SUM(e.amount),6) amount
    FROM earnings e JOIN coins c ON c.id=e.coinid
    WHERE c.symbol='LTC' AND e.$TCOL > UNIX_TIMESTAMP()-10*86400
    GROUP BY d ORDER BY d DESC;"
echo "  ^ empty/zero rows on orphan days = miners were never credited for those blocks."

hr "what to do next (read this before touching anything)"
echo "  If section 1 shows ismine=True with real reward values:"
echo "    the coins are already yours; the fix is a DB relabel (orphan -> generate)"
echo "    plus a maturity replay so earnings backfill. Reversible, and I'll ship it"
echo "    as a separate script with a dry-run mode -- do NOT hand-edit blocks rows."
echo "  If section 2 shows two wallets and no default:"
echo "    the durable fix is making yiimp pass -rpcwallet=pool (or setting a default"
echo "    wallet), otherwise every future block gets mislabelled the same way."
echo "  If section 4 shows unlocked_until=0:"
echo "    DOGE payouts cannot send at all until the wallet is unlocked, same pattern"
echo "    as the LTC unlock timer."
echo
echo "orphan-doctor v2 done -- nothing was modified."
