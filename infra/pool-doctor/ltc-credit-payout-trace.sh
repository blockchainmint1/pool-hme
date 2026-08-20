#!/usr/bin/env bash
# ltc-credit-payout-trace v1 -- read-only. Answers exactly three questions:
#
#   Q1  Why do LTC blocks get credited (category=generate, amount>0) but
#       produce ZERO rows in `earnings`, while TXC/ISK produce 50k?
#   Q2  Why did DOGE earnings stop at 08:27 today?
#   Q3  Why has nothing been PAID OUT in 9.6 days when LTC owes 12.55,
#       the wallet is unlocked and spendable is 26.78?
#
# Writes nothing. Touches no config, no PHP, no DB rows.
#
#   curl -fsSL "https://pool.honest.money/install/ltc-credit-payout-trace.sh?v=$(date +%s)" | sudo bash
set -uo pipefail

LCLI_BIN=${LCLI_BIN:-/home/ubuntu/litecoin-0.21.4/bin/litecoin-cli}
LCONF=${LCONF:-/home/ubuntu/.litecoin/litecoin.conf}
LCLI="$LCLI_BIN -conf=$LCONF -rpcwallet=pool"
DCLI_BIN=${DCLI_BIN:-/home/ubuntu/dogecoin-1.14.9/bin/dogecoin-cli}
DCONF=${DCONF:-/home/ubuntu/.dogecoin/dogecoin.conf}
DCLI="$DCLI_BIN -conf=$DCONF"
WEB=/var/web
BLOCKS_PHP="$WEB/yaamp/core/backend/blocks.php"

MY() { mysql yiimpfrontend -t -e "$1" 2>&1; }
MYN() { mysql yiimpfrontend -N -B -e "$1" 2>&1; }

echo "ltc-credit-payout-trace v1  $(date -u '+%F %T') UTC"
echo

# ---------------------------------------------------------------- section 1
echo "===== 1. credit-fix state (is the algo-wide patch really live?)"
grep -n "POOL_MERGED_SHARE_FIX" "$BLOCKS_PHP" | sed 's/^/  /'
echo "  -- the three sites the patch should have touched --"
sed -n '78,95p' "$BLOCKS_PHP" | nl -ba -v78 | sed 's/^/  /'
echo
echo "  -- aux fallback (site 2: DOGE-only vs merged list) --"
grep -n "in_array(\$coin->symbol" "$BLOCKS_PHP" | sed 's/^/  /'
grep -n "\$coin->symbol\s*==\s*'DOGE'" "$BLOCKS_PHP" | sed 's/^/  /'
echo

# ---------------------------------------------------------------- section 2
echo "===== 2. shares table -- does LTC have anything to split against?"
MY "SELECT c.symbol, s.coinid, s.algo, s.solo, COUNT(*) n,
           MIN(FROM_UNIXTIME(s.time)) oldest, MAX(FROM_UNIXTIME(s.time)) newest,
           ROUND(SUM(s.difficulty),2) sumdiff
    FROM shares s LEFT JOIN coins c ON c.id=s.coinid
    GROUP BY s.coinid, s.algo, s.solo ORDER BY n DESC LIMIT 12;"
echo
echo "  -- coin ids in play --"
MY "SELECT id, symbol, algo, enable, auto_ready, payout_min, LEFT(master_wallet,34) master_wallet FROM coins WHERE symbol IN ('LTC','DOGE','TXC','ISK','ZCU');"
echo

# ---------------------------------------------------------------- section 3
echo "===== 3. LTC blocks: which ones should have produced earnings?"
MY "SELECT b.id, b.height, b.category, b.amount, b.confirmations, b.userid,
           FROM_UNIXTIME(b.time) found,
           (SELECT COUNT(*) FROM earnings e WHERE e.blockid=b.id) earn_rows
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='LTC' ORDER BY b.time DESC LIMIT 15;"
echo
echo "  -- same for TXC (the control group that WORKS) --"
MY "SELECT b.id, b.height, b.category, b.amount,
           (SELECT COUNT(*) FROM earnings e WHERE e.blockid=b.id) earn_rows
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='TXC' ORDER BY b.time DESC LIMIT 5;"
echo
echo "  -- blocks with no earnings row, by coin, last 24h --"
MY "SELECT c.symbol, COUNT(*) n
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE b.time > UNIX_TIMESTAMP()-86400
      AND NOT EXISTS (SELECT 1 FROM earnings e WHERE e.blockid=b.id)
    GROUP BY c.symbol ORDER BY n DESC;"
echo

# ---------------------------------------------------------------- section 4
echo "===== 4. DOGE: why did earnings stop at 08:27?"
MY "SELECT b.id, b.height, b.category, b.amount, b.confirmations,
           FROM_UNIXTIME(b.time) found,
           (SELECT COUNT(*) FROM earnings e WHERE e.blockid=b.id) earn_rows
    FROM blocks b JOIN coins c ON c.id=b.coin_id
    WHERE c.symbol='DOGE' ORDER BY b.time DESC LIMIT 10;"
echo "  -- doge payout cycle cron + last run --"
cat /etc/cron.d/yiimp-doge-payout-cycle 2>/dev/null | sed 's/^/  /' || echo "  (no cron file)"
tail -20 /var/log/doge-payout-cycle.log 2>/dev/null | sed 's/^/  /' || echo "  (no cycle log)"
echo

# ---------------------------------------------------------------- section 5
echo "===== 5. DELIVERY -- the 12.55 LTC that will not send"
echo "  -- payouts table by state --"
MY "SELECT p.idcoin, c.symbol, p.completed, COUNT(*) n, ROUND(SUM(p.amount),8) amt,
           MAX(FROM_UNIXTIME(p.time)) newest
    FROM payouts p LEFT JOIN coins c ON c.id=p.idcoin
    GROUP BY p.idcoin, p.completed ORDER BY p.idcoin, p.completed;"
echo "  -- most recent payout rows w/ error text --"
MY "SELECT p.id, c.symbol, p.completed, p.amount, LEFT(IFNULL(p.errmsg,''),60) err,
           FROM_UNIXTIME(p.time) t
    FROM payouts p LEFT JOIN coins c ON c.id=p.idcoin
    ORDER BY p.id DESC LIMIT 12;"
echo
echo "  -- who is owed (accounts with balance >= payout threshold) --"
MY "SELECT a.id, c.symbol, LEFT(a.username,26) addr, a.balance, a.paid,
           FROM_UNIXTIME(a.last_earning) last_earning
    FROM accounts a LEFT JOIN coins c ON c.id=a.coinid
    WHERE a.balance > 0 ORDER BY a.balance DESC LIMIT 15;"
echo
echo "  -- payment settings actually loaded by loop2 --"
grep -nE "YAAMP_PAYMENTS_FREQ|YAAMP_PAYMENTS_MINI|payout_min|YAAMP_ALLOW_EXCHANGE" \
  "$WEB/serverconfig.php" 2>/dev/null | sed 's/^/  /'
echo "  -- loop2 process + age (it reads serverconfig ONCE at boot) --"
systemctl is-active yiimp-loop2 2>/dev/null | sed 's/^/  active=/'
ps -o pid=,lstart=,etime=,cmd= -C php 2>/dev/null | grep -i loop | sed 's/^/  /'
echo "  -- loop2 recent log, payment lines only --"
journalctl -u yiimp-loop2 -n 400 --no-pager 2>/dev/null \
  | grep -aiE "payment|payout|sendmany|sendtoaddress|insufficient|passphrase|error" \
  | tail -25 | sed 's/^/  /'
echo

# ---------------------------------------------------------------- section 6
echo "===== 6. wallets (correct binaries + -rpcwallet=pool)"
if [ -x "$LCLI_BIN" ]; then
  echo "  -- LTC --"
  $LCLI listwallets 2>&1 | sed 's/^/    /'
  $LCLI getwalletinfo 2>&1 | grep -E '"walletname"|"balance"|"immature|unlocked_until' | sed 's/^/    /'
  echo "    last 5 send txs:"
  $LCLI listtransactions '*' 20 0 2>/dev/null \
    | grep -aE '"category"|"amount"|"time"' | tail -15 | sed 's/^/      /'
else
  echo "  LTC cli not at $LCLI_BIN"
fi
if [ -x "$DCLI_BIN" ]; then
  echo "  -- DOGE --"
  $DCLI getwalletinfo 2>&1 | grep -E '"balance"|unlocked_until' | sed 's/^/    /'
else
  echo "  DOGE cli not at $DCLI_BIN"
fi
echo
echo "done -- nothing was modified."
