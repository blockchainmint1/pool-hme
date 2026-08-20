#!/usr/bin/env bash
# payout-unstick.sh v1 -- the payout chain "passes" every gross check yet no
# money has left since Aug 12. This script finds the three faults that hide
# behind a green payout-status run, and fixes the two that are safe to fix.
#
#   curl -fsSL "https://pool.honest.money/install/payout-unstick.sh?v=$(date +%s)" | sudo bash
#   curl -fsSL "https://pool.honest.money/install/payout-unstick.sh?v=$(date +%s)" | sudo bash -s CONFIRM
#
# THE THREE FAULTS (from payout-status 2026-08-20)
#   A. DOGE wallet is LOCKED (unlocked_until=0). Earnings are being written
#      today, but every sendmany dies on "please enter the wallet passphrase".
#   B. earnings exist for DOGE yet accounts.balance shows ZERO DOGE owed.
#      Earnings only become a balance once yiimp MATURES them. If they are
#      stuck immature/unconfirmed, no payout row can ever be built.
#   C. LTC is INSOLVENT on the box: miners are owed ~12.55 LTC, the pool
#      wallet holds ~6.78. The cold sweep reserve (RESERVE_LTC=0.5) is far
#      below the liability, so the sweep drained the payout float.
#   plus: the retired daily "15 6 * * *" DOGE cron is STILL installed next to
#      the correct */10 one -- the exact regression that stranded 246 blocks.
#
# CONFIRM does ONLY these, all reversible:
#   * deletes the daily DOGE cron regression (backed up first)
#   * unlocks the DOGE wallet and installs a keep-unlocked timer like LTC has
#   * raises RESERVE_LTC in cold.env above the current liability so the sweep
#     can never again take the miners' money
# It NEVER sends coins.
set -uo pipefail

CONFIRM="${1:-}"
APPLY=false; [ "$CONFIRM" = CONFIRM ] && APPLY=true
VERSION="v1"
STAMP="$(date +%Y%m%d-%H%M%S)"

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
COLD_ENV=/etc/pool-wallets/cold.env
PASS_ENV=/etc/pool-wallets/passphrase.env
DAILY_CRON=/etc/cron.d/yiimp-doge-payout
DCLI="/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf"
LCLI="/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "payout-unstick $VERSION  $(date -u '+%F %T UTC')  mode=$([ $APPLY = true ] && echo APPLY || echo CHECK)"

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" "$SERVERCONFIG" 2>/dev/null)"
MY()  { mysql -N -B -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
MYT() { mysql -t     -u"${DBU:-}" -p"${DBP:-}" yiimpfrontend -e "$1" 2>&1 | grep -v '\[Warning\]'; }
hr()  { printf '\n===== %s\n' "$*"; }
num() { local v="${1:-}"; case "$v" in ''|NULL) echo 0;; *) echo "$v";; esac; }
FIX=""; note() { FIX="${FIX}$1"$'\n'; }

# ---------------------------------------------------------------- A. locks ---
hr "A. wallet locks (a locked wallet fails every payout, silently)"
DU=$($DCLI getwalletinfo 2>/dev/null | grep -oE '"unlocked_until": *[0-9]+' | grep -oE '[0-9]+$')
LU=$($LCLI getwalletinfo 2>/dev/null | grep -oE '"unlocked_until": *[0-9]+' | grep -oE '[0-9]+$')
NOW=$(date +%s)
printf '  DOGE unlocked_until=%s  -> %s\n' "$(num "$DU")" "$([ "$(num "$DU")" -gt "$NOW" ] 2>/dev/null && echo UNLOCKED || echo LOCKED)"
printf '  LTC  unlocked_until=%s  -> %s\n' "$(num "$LU")" "$([ "$(num "$LU")" -gt "$NOW" ] 2>/dev/null && echo UNLOCKED || echo LOCKED)"
grep -q walletpassphrase /var/web/doge-payout-cycle.sh 2>/dev/null \
  && echo "  doge-payout-cycle.sh: unlock block PRESENT" \
  || { echo "  doge-payout-cycle.sh: unlock block MISSING"; note "run patch-payout-cron.sh CONFIRM_PATCH"; }
[ "$(num "$DU")" -le "$NOW" ] && note "DOGE wallet locked -- CONFIRM installs doge-unlock.timer"

# ------------------------------------------------------- B. maturation gap ---
hr "B. earnings -> balances: are earnings maturing?"
MYT "SELECT c.symbol, e.status, COUNT(*) n, ROUND(SUM(e.amount),4) amount,
            MAX(FROM_UNIXTIME(e.create_time)) newest
     FROM earnings e JOIN coins c ON c.id=e.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND e.create_time > UNIX_TIMESTAMP()-30*86400
     GROUP BY 1,2 ORDER BY 1,2"
echo "  status: 0 = immature/unconfirmed (cannot pay), 1 = matured into accounts.balance"
MYT "SELECT c.symbol, COUNT(*) accts, ROUND(SUM(a.balance),6) owed
     FROM accounts a JOIN coins c ON c.id=a.coinid
     WHERE c.symbol IN ('LTC','DOGE') AND a.balance>0 GROUP BY 1"
IMM=$(MY "SELECT IFNULL(COUNT(*),0) FROM earnings e JOIN coins c ON c.id=e.coinid
          WHERE c.symbol='DOGE' AND e.status=0")
echo "  immature DOGE earnings rows: $(num "$IMM")"
[ "$(num "$IMM")" -gt 0 ] && note "DOGE earnings stuck immature: blocks need confirmations + loop2 maturation pass"

hr "B2. blocks found but never credited (last 14d)"
MYT "SELECT c.symbol, b.category, COUNT(*) n, ROUND(SUM(b.amount),6) amount,
            MAX(FROM_UNIXTIME(b.time)) newest
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time > UNIX_TIMESTAMP()-14*86400
     GROUP BY 1,2 ORDER BY 1,2"
MYT "SELECT c.symbol, COUNT(*) blocks_without_earnings
     FROM blocks b JOIN coins c ON c.id=b.coin_id
     LEFT JOIN earnings e ON e.blockid=b.id
     WHERE c.symbol IN ('LTC','DOGE') AND b.time > UNIX_TIMESTAMP()-14*86400
       AND e.id IS NULL GROUP BY 1"

# --------------------------------------------------------- C. LTC solvency ---
hr "C. solvency: can the wallet actually cover what miners are owed?"
LBAL=$(num "$($LCLI getbalance 2>/dev/null)")
DBAL=$(num "$($DCLI getbalance 2>/dev/null)")
LOWED=$(num "$(MY "SELECT IFNULL(ROUND(SUM(a.balance),8),0) FROM accounts a JOIN coins c ON c.id=a.coinid WHERE c.symbol='LTC' AND a.balance>0")")
DOWED=$(num "$(MY "SELECT IFNULL(ROUND(SUM(a.balance),8),0) FROM accounts a JOIN coins c ON c.id=a.coinid WHERE c.symbol='DOGE' AND a.balance>0")")
printf '  LTC  spendable=%-14s owed=%-14s %s\n' "$LBAL" "$LOWED" \
  "$(awk -v b="$LBAL" -v o="$LOWED" 'BEGIN{print (b>=o)?"SOLVENT":"INSOLVENT -- shortfall " (o-b) " LTC"}')"
printf '  DOGE spendable=%-14s owed=%-14s %s\n' "$DBAL" "$DOWED" \
  "$(awk -v b="$DBAL" -v o="$DOWED" 'BEGIN{print (b>=o)?"SOLVENT":"INSOLVENT -- shortfall " (o-b) " DOGE"}')"
[ -r "$COLD_ENV" ] && { echo "  cold.env reserves:"; grep -E 'RESERVE_(LTC|DOGE)' "$COLD_ENV" | sed 's/^/    /' || echo "    (defaults: LTC 0.5, DOGE 25000)"; }
LSHORT=$(awk -v b="$LBAL" -v o="$LOWED" 'BEGIN{print (o>b)?1:0}')
[ "$LSHORT" = 1 ] && note "LTC insolvent -- send LTC back from cold to the pool wallet, and raise RESERVE_LTC"
echo
echo "  where the LTC went (recent outgoing from pool wallet):"
$LCLI listtransactions '*' 15 2>/dev/null | grep -oE '"(category|amount|address|txid)": *[^,]+' | paste -sd' ' - | tr '"' ' ' | fold -w 160 | sed 's/^/    /'

# ------------------------------------------------------------ D. cron dupe ---
hr "D. DOGE cron cadence (daily is fatal -- yiimp purges the round's shares)"
grep -rn "doge-payout-cycle" /etc/cron.d /etc/crontab 2>/dev/null | sed 's/^/  /'
DAILY_FILES=$(grep -rl "15 6 \* \* \*.*doge-payout-cycle" /etc/cron.d 2>/dev/null)
[ -n "$DAILY_FILES" ] && note "daily DOGE cron still installed: $DAILY_FILES"

# ----------------------------------------------------------------- APPLY ----
if [ "$APPLY" = true ]; then
  hr "APPLYING"
  # D. kill the daily regression
  for f in $DAILY_FILES; do
    cp -a "$f" "/var/backups/$(basename "$f").bak-$STAMP"
    if grep -qv "doge-payout-cycle" "$f" && [ "$(grep -cvE '^\s*(#|$)' "$f")" -gt 1 ]; then
      sed -i '/15 6 \* \* \*.*doge-payout-cycle/d' "$f"; echo "  removed daily line from $f"
    else
      rm -f "$f"; echo "  removed $f (backup in /var/backups)"
    fi
  done
  systemctl restart cron >/dev/null 2>&1 && echo "  cron reloaded"

  # A. DOGE keep-unlocked timer, mirroring ltc-unlock.timer
  if [ -r "$PASS_ENV" ]; then
    cat >/usr/local/sbin/doge-unlock.sh <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
. /etc/pool-wallets/passphrase.env
/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli -conf=/home/ubuntu/.dogecoin/dogecoin.conf \
  walletpassphrase "$WALLET_PASSPHRASE" 3600 >/dev/null 2>&1
EOS
    chmod 700 /usr/local/sbin/doge-unlock.sh
    cat >/etc/systemd/system/doge-unlock.service <<'EOS'
[Unit]
Description=Keep the Dogecoin payout wallet unlocked
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/doge-unlock.sh
EOS
    cat >/etc/systemd/system/doge-unlock.timer <<'EOS'
[Unit]
Description=Refresh the Dogecoin wallet unlock every 30 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOS
    systemctl daemon-reload
    systemctl enable --now doge-unlock.timer >/dev/null 2>&1
    /usr/local/sbin/doge-unlock.sh
    NU=$($DCLI getwalletinfo 2>/dev/null | grep -oE '"unlocked_until": *[0-9]+' | grep -oE '[0-9]+$')
    echo "  doge-unlock.timer installed; unlocked_until=$(num "$NU")"
  else
    echo "  SKIP unlock: $PASS_ENV unreadable"
  fi

  # C. protect the payout float from the cold sweep
  if [ -w "$COLD_ENV" ] || [ -d "$(dirname "$COLD_ENV")" ]; then
    NEWRES=$(awk -v o="$LOWED" 'BEGIN{r=o*2; if(r<5)r=5; printf "%.2f", r}')
    cp -a "$COLD_ENV" "$COLD_ENV.bak-$STAMP" 2>/dev/null
    if grep -q '^RESERVE_LTC=' "$COLD_ENV" 2>/dev/null; then
      sed -i "s/^RESERVE_LTC=.*/RESERVE_LTC=$NEWRES/" "$COLD_ENV"
    else
      echo "RESERVE_LTC=$NEWRES" >> "$COLD_ENV"
    fi
    echo "  RESERVE_LTC set to $NEWRES (2x current LTC liability, min 5)"
  fi
fi

hr "WHAT TO DO NEXT"
if [ -z "$FIX" ]; then
  echo "  nothing outstanding -- watch section 6 of payout-status for new payout rows."
else
  printf '%s' "$FIX"
fi
cat <<'EOF'

  LTC shortfall is the one thing this script will not fix for you: coins must
  come back from cold storage to the pool wallet before those 12.55 LTC can
  pay out. Send to the pool wallet's receive address:

    /home/ubuntu/litecoin-0.21.4/bin/litecoin-cli \
      -conf=/home/ubuntu/.litecoin/litecoin.conf -rpcwallet=pool getnewaddress

  Then re-read the chain:
    curl -fsSL "https://pool.honest.money/install/payout-status.sh?v=$(date +%s)" | sudo bash
EOF
