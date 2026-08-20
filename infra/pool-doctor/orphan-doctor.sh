#!/usr/bin/env bash
# orphan-doctor.sh v1 -- READ ONLY. Answers two questions in one pass:
#
#   1. Are the LTC blocks yiimp shows as "Orphan" actually orphaned on-chain,
#      or is yiimp mislabelling blocks it can no longer see in its wallet?
#   2. Why have LTC/DOGE payouts stopped reaching the owner wallet?
#
#   curl -fsSL https://pool.honest.money/install/orphan-doctor.sh | sudo bash 2>&1 | tee /tmp/orphan.txt
#
# Nothing is modified. No RPC call here writes state.
#
# Background for the reader:
#   yiimp decides a block is "orphan" from `gettransaction <coinbase txid>` on
#   ITS OWN wallet, not from the chain. After a wallet rotation / sweep the
#   coinbase outputs belong to a wallet yiimp is no longer talking to, so
#   gettransaction returns "Invalid or non-wallet transaction id" and yiimp
#   files a perfectly valid, mainchain block as orphan with amount 0.
#   That same broken wallet handle is what stops payouts -- which is why one
#   script covers both symptoms.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
LIMIT=${LIMIT:-12}

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -t -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYN() { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }

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

echo "orphan-doctor v1  $(date -u '+%F %T UTC')"
echo "  litecoin-cli : $LBASE   conf wallet=${LWALLET:-(default)}"
echo "  dogecoin-cli : $DCLI"

# ---------------------------------------------------------------- 1
hr "1. what yiimp thinks happened to LTC blocks (last 10 days)"
MY "SELECT DATE(FROM_UNIXTIME(b.time)) d, b.category, COUNT(*) n, ROUND(SUM(b.amount),4) amount
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='LTC' AND b.time > UNIX_TIMESTAMP()-10*86400
    GROUP BY d,b.category ORDER BY d DESC, n DESC;"
echo "  ^ amount=0 on every row means yiimp never valued the block -> it never"
echo "    read the coinbase from a wallet. A true orphan usually still has an amount."

# ---------------------------------------------------------------- 2
hr "2. THE TEST -- is each 'orphan' block actually in the LTC main chain?"
echo "  confirmations >= 1 and a matching height = the block is REAL and PAID BY THE NETWORK."
echo "  confirmations = -1 = genuinely orphaned/stale."
printf '  %-9s %-12s %-14s %-8s %s\n' HEIGHT DB_CATEGORY CONFIRMATIONS CHAINHIT BLOCKHASH
while IFS=$'\t' read -r H CAT BH; do
  [ -z "${BH:-}" ] && continue
  INFO=$($LBASE getblockheader "$BH" 2>&1)
  if echo "$INFO" | grep -q '"confirmations"'; then
    CONF=$(echo "$INFO" | grep -oE '"confirmations": *-?[0-9]+' | grep -oE '\-?[0-9]+$')
    CH=$(echo "$INFO" | grep -oE '"height": *[0-9]+' | grep -oE '[0-9]+$')
    if [ "${CONF:-0}" -ge 1 ] 2>/dev/null; then HIT="MAINCHAIN"; else HIT="STALE"; fi
    [ "$CH" = "$H" ] || HIT="$HIT/h=$CH"
  else
    CONF="?"; HIT="NOT-IN-NODE"
  fi
  printf '  %-9s %-12s %-14s %-8s %s\n' "$H" "$CAT" "$CONF" "$HIT" "${BH:0:24}..."
done < <(MYN "SELECT b.height, b.category, b.blockhash FROM blocks b JOIN coins c ON c.id=b.coin_id
              WHERE c.symbol='LTC' AND b.time > UNIX_TIMESTAMP()-10*86400
              ORDER BY b.id DESC LIMIT $LIMIT;")
echo
echo "  >>> If most rows say MAINCHAIN, NOTHING WAS LOST TO THE NETWORK."
echo "      The coins exist; yiimp just cannot see them in its wallet."

# ---------------------------------------------------------------- 3
hr "3. who actually received those coinbase rewards?"
for BH in $(MYN "SELECT b.blockhash FROM blocks b JOIN coins c ON c.id=b.coin_id
                 WHERE c.symbol='LTC' AND b.time > UNIX_TIMESTAMP()-10*86400
                 ORDER BY b.id DESC LIMIT 4"); do
  [ -z "$BH" ] && continue
  CBTXID=$($LBASE getblock "$BH" 1 2>/dev/null | grep -oE '"[0-9a-f]{64}"' | sed -n '2p' | tr -d '"')
  [ -z "$CBTXID" ] && { echo "  block ${BH:0:16}.. : coinbase txid unavailable"; continue; }
  RAW=$($LBASE getrawtransaction "$CBTXID" 1 2>&1)
  ADDRS=$(echo "$RAW" | grep -oE '"(ltc1|[LM3])[a-zA-Z0-9]{20,70}"' | tr -d '"' | sort -u | paste -sd, )
  VAL=$(echo "$RAW" | grep -oE '"value": *[0-9.]+' | grep -oE '[0-9.]+' | sort -rn | head -1)
  echo "  block ${BH:0:16}..  reward=${VAL:-?} LTC  paid to: ${ADDRS:-<unparsed>}"
  echo "     wallet sees this tx? $($LCLI gettransaction "$CBTXID" 2>&1 | head -1 | cut -c1-90)"
done
echo "  ^ 'Invalid or non-wallet transaction id' here is the smoking gun:"
echo "    the reward went to an address the CURRENT yiimp wallet does not own."

# ---------------------------------------------------------------- 4
hr "4. wallet handles -- the 'unable to find the wallet for coinid 8' error"
echo "  wallets loaded in litecoind: $($LBASE listwallets 2>&1 | tr -d '\n ' | cut -c1-160)"
$LCLI getwalletinfo 2>&1 | grep -E 'walletname|"balance"|immature|unlocked_until' | sed 's/^/    /'
echo "  addresses yiimp has on file for LTC/DOGE:"
MY "SELECT id,symbol,LEFT(master_wallet,42) master_wallet,LEFT(IFNULL(errors,''),40) errors,
           enable,auto_ready,payout_min,txfee
    FROM coins WHERE symbol IN ('LTC','DOGE');"
echo "  does the current wallet own the address yiimp thinks is the master?"
for A in $(MYN "SELECT master_wallet FROM coins WHERE symbol='LTC' AND master_wallet<>''"); do
  echo "    $A -> $($LCLI getaddressinfo "$A" 2>&1 | grep -oE '"ismine": *(true|false)' | head -1)"
done

# ---------------------------------------------------------------- 5
hr "5. payouts -- why nothing has landed in the owner wallet"
MY "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) owed
    FROM accounts a JOIN coins c ON c.id=a.coinid
    WHERE a.balance>0 AND c.symbol IN ('LTC','DOGE') GROUP BY c.symbol;"
MY "SELECT c.symbol, MAX(FROM_UNIXTIME(p.time)) last_payout, SUM(p.completed=1) done,
           SUM(p.completed=0) pending
    FROM payouts p JOIN coins c ON c.id=p.idcoin GROUP BY c.symbol;"
MY "SELECT c.symbol, LEFT(IFNULL(p.errmsg,'(null / never attempted)'),70) errmsg, COUNT(*) n,
           FROM_UNIXTIME(MAX(p.time)) newest
    FROM payouts p JOIN coins c ON c.id=p.idcoin WHERE p.completed=0
    GROUP BY 1,2 ORDER BY n DESC LIMIT 10;"
echo "  spendable float right now:"
echo "    LTC : $($LCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "    DOGE: $($DCLI getwalletinfo 2>&1 | tr -d ' \n' | grep -oE '"balance":[0-9.]+|"immature_balance":[0-9.]+|"unlocked_until":[0-9]+' | paste -sd' ')"
echo "  yiimp payout loop:"
ps -ef | grep -E '[l]oop2|[b]lock-loop' | head -3 | sed 's/^/    proc: /' || echo "    proc: NONE RUNNING"
systemctl is-active ltc-unlock.timer 2>/dev/null | sed 's/^/    ltc-unlock.timer: /'
grep -rhn "payout\|loop2\|doge-payout" /etc/cron.d/* /etc/crontab 2>/dev/null | grep -v '^#' | sed 's/^/    cron: /'

# ---------------------------------------------------------------- 6
hr "6. earnings -- did miners ever get credited for these blocks?"
MY "SELECT DATE(created) d, COUNT(*) rows_, ROUND(SUM(amount),6) amount
    FROM earnings WHERE created > NOW()-INTERVAL 10 DAY GROUP BY d ORDER BY d DESC;"
MY "SELECT status, COUNT(*) n, ROUND(SUM(amount),2) amount, FROM_UNIXTIME(MAX(created_at)) newest
    FROM doge_payout_ledger GROUP BY status ORDER BY n DESC;"

hr "verdict hints"
echo "  A) section 2 mostly MAINCHAIN + section 3 'non-wallet transaction id'"
echo "     => blocks are REAL, rewards are SAFE on-chain at the address in section 3."
echo "        Recovery = point yiimp at the wallet that owns them (or import the key),"
echo "        then re-run block maturity so amounts/earnings backfill."
echo "  B) section 2 mostly STALE / -1 confirmations"
echo "     => genuine orphans. Those are gone; cause is upstream (bad LTC node, forked"
echo "        chain, stale getblocktemplate). Nothing to recover, must fix propagation."
echo "  C) section 5 pending payouts with empty errmsg + no loop2 process"
echo "     => payouts were never attempted; the payout loop is dead, not the wallet."
echo
echo "orphan-doctor v1 done -- nothing was modified."
