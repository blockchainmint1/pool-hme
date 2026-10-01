#!/usr/bin/env bash
# nicehash-order-check.sh — READ-ONLY. Shows what the NiceHash auto-renter did
# over the last 3 days and whether rented machines actually mined on our pool.
# Changes nothing.
set -u
H(){ echo; echo "================ $* ================"; }
J(){ journalctl -u nicehash-watcher --since "3 days ago" --no-pager -o short-iso 2>/dev/null; }

H "1. watcher service"
systemctl show nicehash-watcher -p ActiveState -p ActiveEnterTimestamp -p NRestarts 2>/dev/null
grep -E '^(DRY_RUN|LOW_CONFIRMATIONS|TXC_STALL_MIN|TRIGGER|RENT_CAP|ORDER_AMOUNT|REFILL|BID|POOL_HOST|DAILY_BTC_CAP)' /etc/nicehash-watcher.env 2>/dev/null

H "2. orders created / cancelled / failed (last 3 days)"
J | grep -E 'Creating rental order|Order created|cancelling|Orders no longer active|ERROR|WARN|NiceHash pool ready|suppress|TXC' | tail -80

H "3. order speed samples (accepted vs limit) — last 60"
J | grep -E 'order status' | tail -60

H "4. counts per day"
for k in 'Order created' 'cancelling' 'ERROR' 'Underfilled'; do
  echo "--- $k"; J | grep -F "$k" | cut -c1-10 | sort | uniq -c
done

H "5. raw order detail (most recent)"
J | grep -A40 'Order detail (raw' | tail -45

H "6. state file"
cat /var/lib/nicehash-watcher/state.json 2>/dev/null | head -c 3000; echo

RA=$(grep -E '^RENTAL_LTC_ADDR=' /etc/nicehash-watcher.env 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ')
echo; echo "rental login address: ${RA:-<not set>}"
L=/var/stratum/scrypt.log
PAT='\.nh'; [ -n "$RA" ] && PAT="\\.nh|$RA"

H "7. rented machines in stratum log (.nh OR rental address)"
echo "matching lines in last 500k log lines:"
tail -n 500000 "$L" 2>/dev/null | grep -cE "$PAT"
tail -n 500000 "$L" 2>/dev/null | grep -E "$PAT" | grep -oiE 'reject[a-z ]*|low difficulty|stale|duplicate|invalid|authoriz[a-z]*|disconnect[a-z]*|diff[= ][0-9.]+' | sort | uniq -c | sort -rn | head -20
echo "--- first 5 / last 10 matching lines"
tail -n 500000 "$L" 2>/dev/null | grep -E "$PAT" | head -5
tail -n 500000 "$L" 2>/dev/null | grep -E "$PAT" | tail -10
echo "--- rotated logs mentioning the rental address (file: count)"
for f in /var/stratum/logs/*.log /var/stratum/scrypt.log.*; do
  [ -f "$f" ] || continue
  c=$(grep -cE "$PAT" "$f" 2>/dev/null); [ "${c:-0}" -gt 0 ] && echo "$f: $c"
done

CR=$(sudo bash -c "php -r 'include \"/var/web/serverconfig.php\"; echo YAAMP_DBUSER.\" \".YAAMP_DBPASSWORD;'" 2>/dev/null)
U=${CR%% *}; P=${CR#* }
Q(){ mysql -u"$U" -p"$P" yiimpfrontend -e "$1" 2>&1 | grep -v 'Using a password'; }

H "8. rented workers in pool DB right now"
Q "SELECT name, worker, difficulty, version, FROM_UNIXTIME(time) t FROM workers WHERE worker LIKE '%nh%' OR name LIKE '%.nh%' ${RA:+OR name='$RA'} LIMIT 30;" | head -35
if [ -n "$RA" ]; then
  echo "--- account row + recent earnings for rental address"
  Q "SELECT id, username, balance FROM accounts WHERE username='$RA';"
  Q "SELECT c.symbol, COUNT(*) n, ROUND(SUM(e.amount),8) amt, FROM_UNIXTIME(MIN(e.create_time)) first, FROM_UNIXTIME(MAX(e.create_time)) last FROM earnings e JOIN accounts a ON a.id=e.userid JOIN coins c ON c.id=e.coinid WHERE a.username='$RA' AND e.create_time > UNIX_TIMESTAMP()-4*86400 GROUP BY c.symbol;"
fi

H "9. timeline: order events vs pool hashrate vs blocks (UTC, last 3 days)"
echo "--- order events"
J | grep -E 'Order created|cancelling|Orders no longer active' | cut -c1-200 | tail -40
echo "--- hourly avg pool hashrate (TH/s)"
Q "SELECT FROM_UNIXTIME(FLOOR(time/3600)*3600) hr, ROUND(AVG(hashrate)/1e12,2) ths FROM hashrate WHERE algo='scrypt' AND time > UNIX_TIMESTAMP()-3*86400 GROUP BY hr ORDER BY hr;"
echo "--- blocks per hour per coin"
Q "SELECT FROM_UNIXTIME(FLOOR(b.time/3600)*3600) hr, SUM(c.symbol='TXC') TXC, SUM(c.symbol='ISK') ISK, SUM(c.symbol='ZCU') ZCU, SUM(c.symbol='DOGE') DOGE, SUM(c.symbol='LTC') LTC FROM blocks b JOIN coins c ON c.id=b.coin_id WHERE b.time > UNIX_TIMESTAMP()-3*86400 GROUP BY hr ORDER BY hr;"
echo; echo "DONE (read-only)."
