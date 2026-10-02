#!/usr/bin/env bash
# reject-hunt.sh v1 -- READ ONLY. Where is the 16% reject rate coming from?
#   curl -fsSL "https://pool.honest.money/install/reject-hunt.sh?v=$(date +%s)" | sudo bash
set -u
SC=/var/web/serverconfig.php
DBU=$(grep -oP "YAAMP_DBUSER'\s*,\s*'\K[^']*" $SC | head -1)
DBP=$(grep -oP "YAAMP_DBPASSWORD'\s*,\s*'\K[^']*" $SC | head -1)
MY() { mysql -u"$DBU" -p"$DBP" yiimpfrontend -t -e "$1" 2>&1 | grep -v Warning; }
H() { echo; echo "===== $*"; }
RENT=$(grep -oP '^RENTAL_LTC_ADDR=\K.*' /etc/nicehash-watcher.env 2>/dev/null | tr -d '"')
echo "reject-hunt v1  $(date -u '+%F %T') UTC  rental_login=${RENT:-unknown}"
echo "error codes: 21=stale 22=duplicate 23=low-diff 24=bad-hash 25=other"

H "1. reject rate per 10 min, last 3 hours (when did it start?)"
MY "SELECT FROM_UNIXTIME(time-time%600) t, COUNT(*) shares, SUM(valid=0) rejects,
    ROUND(100*SUM(valid=0)/COUNT(*),1) pct, ROUND(AVG(difficulty),0) avg_diff
    FROM shares WHERE time>UNIX_TIMESTAMP()-10800 GROUP BY 1 ORDER BY 1"

H "2. rejects by reason, last 10 min"
MY "SELECT error, COUNT(*) n FROM shares WHERE time>UNIX_TIMESTAMP()-600 AND valid=0 GROUP BY error ORDER BY n DESC"

H "3. top 25 machines by rejects, last 10 min"
MY "SELECT w.ip, LEFT(w.name,14) login, LEFT(w.worker,20) worker, w.difficulty vardiff,
    COUNT(*) shares, SUM(s.valid=0) rejects, ROUND(100*SUM(s.valid=0)/COUNT(*),0) pct,
    GROUP_CONCAT(DISTINCT s.error) codes
    FROM shares s JOIN workers w ON w.id=s.workerid
    WHERE s.time>UNIX_TIMESTAMP()-600 GROUP BY s.workerid HAVING rejects>0
    ORDER BY rejects DESC LIMIT 25"

H "4. rejects by source IP (one IP per site/container), last 10 min"
MY "SELECT w.ip, COUNT(DISTINCT s.workerid) machines, COUNT(*) shares, SUM(s.valid=0) rejects,
    ROUND(100*SUM(s.valid=0)/COUNT(*),1) pct, ROUND(AVG(s.difficulty),0) avg_diff
    FROM shares s JOIN workers w ON w.id=s.workerid
    WHERE s.time>UNIX_TIMESTAMP()-600 GROUP BY w.ip ORDER BY rejects DESC LIMIT 15"

H "5. rental (NiceHash) machines vs our own, last 10 min"
MY "SELECT IF(w.name='${RENT:-none}' AND w.worker NOT LIKE '%L9%', 'rental-login', 'other') who,
    COUNT(*) shares, SUM(s.valid=0) rejects, ROUND(100*SUM(s.valid=0)/COUNT(*),1) pct
    FROM shares s JOIN workers w ON w.id=s.workerid
    WHERE s.time>UNIX_TIMESTAMP()-600 GROUP BY 1"
echo "-- nicehash-watcher last 5 lines:"
journalctl -u nicehash-watcher -n 5 --no-pager 2>/dev/null | cut -c1-260

H "6. reject wording in the live stratum log (last 200k lines)"
tail -n 200000 /var/stratum/scrypt.log 2>/dev/null | grep -iE 'reject|stale|invalid|low diff|duplicate' \
  | sed -E 's/[0-9a-f]{16,}/<hex>/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<ip>/g; s/[0-9]+/N/g' \
  | sort | uniq -c | sort -rn | head -12

echo; echo "reject-hunt done -- nothing was modified. Paste everything above back to the chat."
