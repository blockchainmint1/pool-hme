#!/usr/bin/env bash
# frontend-audit.sh -- READ ONLY. Answers "can we shut the old yiimp PHP front
# end down, and is there anything on it we still need?"
#
#   curl -fsSL https://pool.honest.money/install/frontend-audit.sh | sudo bash
#
# It changes nothing. It tells you:
#   1. what nginx actually serves for the yiimp UI (vhosts, roots, ports)
#   2. WHO still uses it -- real hit counts per page from the access logs,
#      split into human pages vs the /api/ endpoints the new site proxies
#   3. which pages are used by miners (worker config, wallet, workers) --
#      these are the migration blockers
#   4. what MUST keep running after the UI is off (loop2, blocks.php, payout
#      cron, stratum) -- the backend is NOT the front end
#   5. whether anything on the box calls the PHP UI internally
set -uo pipefail

SERVERCONFIG=${SERVERCONFIG:-/var/web/serverconfig.php}
WEBROOT=${WEBROOT:-/var/web}
DAYS=${DAYS:-7}

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
hr() { printf '\n===== %s\n' "$*"; }
echo "frontend-audit v1  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname)"

hr "1. nginx vhosts serving the yiimp UI"
grep -rlsE "root .*${WEBROOT}|yiimp" /etc/nginx/sites-enabled/ 2>/dev/null | while read -r f; do
  echo "-- $f"
  grep -nE "server_name|listen|root|fastcgi_pass|location" "$f" | sed 's/^/   /'
done
echo
echo "php-fpm pools:"
systemctl list-units --type=service --no-pager 2>/dev/null | grep -i php | sed 's/^/   /' || echo "   (none active)"

hr "2. real usage, last $DAYS days (who would notice the lights going out)"
LOGS=$(ls /var/log/nginx/*access*.log 2>/dev/null)
if [ -z "$LOGS" ]; then
  echo "  no nginx access logs found"
else
  SINCE=$(date -u -d "-$DAYS days" '+%d/%b/%Y')
  echo "  top 25 requested paths:"
  # shellcheck disable=SC2086
  awk '{print $7}' $LOGS 2>/dev/null | sed 's/?.*//' | sort | uniq -c | sort -rn | head -25 | sed 's/^/    /'
  echo
  echo "  human UI pages vs machine API (rough split):"
  # shellcheck disable=SC2086
  awk '{print $7}' $LOGS 2>/dev/null | sed 's/?.*//' \
    | awk '{ if ($0 ~ /^\/api\//) a++; else if ($0 ~ /\.(css|js|png|jpg|svg|ico|woff2?)$/) s++; else h++ }
           END{printf "    api=%d  static=%d  html-ish=%d\n", a+0, s+0, h+0}'
  echo
  echo "  distinct client IPs hitting non-api pages:"
  # shellcheck disable=SC2086
  awk '$7 !~ /^\/api\// && $7 !~ /\.(css|js|png|jpg|svg|ico|woff2?)$/ {print $1}' $LOGS 2>/dev/null \
    | sort -u | wc -l | sed 's/^/    /'
  echo "  (ignore $SINCE-and-older lines if the log was rotated recently)"
fi

hr "3. MIGRATION BLOCKERS -- pages miners actually depend on"
for p in /site/wallet /wallet /site/worker /workers /site/miners /api/wallet /api/walletEx /api/status /api/currencies; do
  # shellcheck disable=SC2086
  N=$(awk -v p="$p" '$7 ~ "^"p {n++} END{print n+0}' $LOGS 2>/dev/null)
  printf '  %-20s hits=%s\n' "$p" "${N:-0}"
done
cat <<'NOTE'
  Reading it:
    /api/wallet, /api/walletEx, /api/status, /api/currencies  -> the yiimp API
      contract. Miners' dashboards and rental services poll these. They must
      keep answering at the SAME paths even after the HTML UI is gone.
    /site/wallet, /workers                                     -> humans looking
      up their balance. If these have real hits, the new /account page must
      cover them before the cut-over.
NOTE

hr "4. what must KEEP RUNNING after the UI is off (backend != front end)"
for u in stratum-aws-scrypt yiimp-loop2 loop2 yiimp-api nginx php8.1-fpm php7.4-fpm mysql mariadb; do
  S=$(systemctl is-active "$u" 2>/dev/null)
  [ "$S" = unknown ] || printf '  %-22s %s\n' "$u" "$S"
done
echo
echo "  loop/backend processes:"
ps -ef | grep -E '[l]oop2|[b]locks\.php|[r]unPayouts|[d]oge-payout-cycle' | sed 's/^/    /' || echo "    (none)"
echo
echo "  cron entries touching /var/web:"
grep -rn "/var/web" /etc/cron.d /etc/crontab /var/spool/cron 2>/dev/null | sed 's/^/    /' || echo "    (none)"

hr "5. anything on this box calling the PHP UI internally"
grep -rlsE "localhost/site|127\.0\.0\.1/site|/var/web/yaamp" /usr/local/sbin /var/web/*.sh /etc/cron.d 2>/dev/null | sed 's/^/  /' || echo "  none found"

hr "verdict inputs"
cat <<'EOF'
  SAFE to stop  : nginx vhost serving the yiimp HTML UI + its php-fpm pool,
                  IF section 3 shows no human traffic you still need.
  NEVER stop    : mysql, stratum-aws-scrypt, loop2 (credits blocks + pays),
                  the DOGE payout cron, yiimp-api (the new site's data source).
                  These live in /var/web but are NOT the front end.
  Cut-over tool : frontend-shutdown.sh DISABLE  (reversible in one command)

frontend-audit v1 done -- nothing was modified.
EOF
