#!/usr/bin/env bash
# frontend-shutdown.sh -- reversibly take the old yiimp PHP UI offline while
# leaving the yiimp BACKEND (loop2, payouts, blocks.php, stratum, MySQL) and
# the /api/* contract fully intact.
#
#   ... | sudo bash -s CHECK      # what would change (default)
#   ... | sudo bash -s DISABLE    # HTML UI off, /api/* still answers
#   ... | sudo bash -s ENABLE     # put it straight back
#
# DISABLE does NOT stop php-fpm, mysql, loop2, cron or stratum. It only makes
# the human-facing yiimp pages return 410 while keeping /api/ locations live.
set -uo pipefail
MODE=${1:-CHECK}
WEBROOT=${WEBROOT:-/var/web}
SNIP=/etc/nginx/snippets/yiimp-ui-retired.conf
STAMP=$(date -u '+%Y%m%d-%H%M%S')
BK=/var/backups/yiimp-frontend-retire

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
echo "frontend-shutdown v1  mode=$MODE  $(date -u '+%F %T UTC')"

vhosts() { grep -rlsE "root .*${WEBROOT}" /etc/nginx/sites-enabled/ 2>/dev/null; }

case "$MODE" in
CHECK)
  echo "vhosts that would be edited:"; vhosts | sed 's/^/  /'
  echo
  echo "still-served after DISABLE:  /api/*  (yiimp API contract for miners/rentals)"
  echo "returns 410 after DISABLE :  /site/*, /, and other HTML pages"
  echo "untouched services        :  mysql, loop2, payout cron, stratum, yiimp-api"
  echo
  echo "run again with DISABLE when the audit says nobody needs the HTML pages."
  ;;
DISABLE)
  mkdir -p "$BK"
  cat > "$SNIP" <<'EOF'
# yiimp HTML UI retired -- superseded by pool.honest.money.
# /api/ locations are declared BEFORE this include and still match first.
location / {
    default_type text/plain;
    return 410 "The old pool front end has been retired. Use https://pool.honest.money\n";
}
EOF
  n=0
  for f in $(vhosts); do
    cp -a "$f" "$BK/$(basename "$f").$STAMP"
    grep -q "yiimp-ui-retired" "$f" || \
      sed -i "0,/^}/s|^}|    include $SNIP;\n}|" "$f"
    n=$((n+1))
  done
  echo "patched $n vhost(s); backups in $BK"
  nginx -t && systemctl reload nginx && echo "OK  HTML UI retired, /api/* still live."
  ;;
ENABLE)
  n=0
  for f in $(vhosts); do
    sed -i "\|include $SNIP;|d" "$f"; n=$((n+1))
  done
  rm -f "$SNIP"
  echo "reverted $n vhost(s)"
  nginx -t && systemctl reload nginx && echo "OK  old front end is back."
  ;;
*) echo "usage: CHECK | DISABLE | ENABLE"; exit 1;;
esac
