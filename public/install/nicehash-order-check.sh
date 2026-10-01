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

H "7. rented machines on the pool (worker name ends in .nh) — stratum log"
L=/var/stratum/scrypt.log
echo "lines mentioning .nh in last 200k log lines:"
tail -n 200000 "$L" 2>/dev/null | grep -c '\.nh'
tail -n 200000 "$L" 2>/dev/null | grep '\.nh' | grep -oiE 'reject[a-z ]*|low difficulty|stale|duplicate|invalid|authoriz[a-z]*|disconnect[a-z]*|diff[= ][0-9.]+' | sort | uniq -c | sort -rn | head -20
echo "--- last 15 .nh lines"
tail -n 200000 "$L" 2>/dev/null | grep '\.nh' | tail -15

H "8. rented workers in pool DB right now"
CR=$(sudo bash -c "php -r 'include \"/var/web/serverconfig.php\"; echo YAAMP_DBUSER.\" \".YAAMP_DBPASSWORD;'" 2>/dev/null)
U=${CR%% *}; P=${CR#* }
mysql -u"$U" -p"$P" yiimpfrontend -e "SELECT name, worker, difficulty, version, FROM_UNIXTIME(time) t FROM workers WHERE worker LIKE '%nh%' OR name LIKE '%.nh%' LIMIT 30;" 2>&1 | head -35
echo; echo "DONE (read-only)."
