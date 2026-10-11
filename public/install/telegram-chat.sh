#!/usr/bin/env bash
# telegram-chat.sh -- point every box-side Telegram alert at one chat.
#
#   curl -fsSL "https://pool.honest.money/install/telegram-chat.sh?v=$(date +%s)" | sudo bash
#   (to use a different chat:  ... | sudo bash -s -- -1234567890)
#
# Updates TELEGRAM_CHAT_ID in the three env files that send alerts:
#   /etc/nicehash-watcher.env  (NiceHash rental watcher)
#   /etc/zcu-deadman.env       (ZCU deadman, if installed)
#   /etc/payout-watch.env      (payout watchdog, if installed)
# Then restarts ONLY the nicehash-watcher (it reads its env at start-up; the
# other two read theirs fresh every minute). Stratum is never touched.
# Sends one test message to the new chat so you can see it arrive.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
CHAT="${1:--5101771348}"
echo "telegram-chat v1  $(date -u '+%F %T UTC')  new chat: $CHAT"

TOKEN=""
for f in /etc/nicehash-watcher.env /etc/zcu-deadman.env /etc/payout-watch.env; do
  [ -f "$f" ] || { echo "  skip   $f (not installed)"; continue; }
  cp -p "$f" "$f.pre-chat" 2>/dev/null
  OLD=$(grep -s '^TELEGRAM_CHAT_ID=' "$f" | cut -d= -f2-)
  if grep -q '^TELEGRAM_CHAT_ID=' "$f"; then
    sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=$CHAT|" "$f"
  else
    echo "TELEGRAM_CHAT_ID=$CHAT" >> "$f"
  fi
  echo "  set    $f  (was: ${OLD:-blank})"
  [ -z "$TOKEN" ] && TOKEN=$(grep -s '^TELEGRAM_BOT_TOKEN=' "$f" | cut -d= -f2-)
done

if systemctl list-unit-files 2>/dev/null | grep -q '^nicehash-watcher.service'; then
  systemctl restart nicehash-watcher && echo "  restarted nicehash-watcher: $(systemctl is-active nicehash-watcher)"
fi

if [ -z "$TOKEN" ]; then
  echo "  no bot token found in the env files -- cannot send a test message"; exit 0
fi
echo "  sending test message..."
R=$(curl -sS -m 15 -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT" -d parse_mode=HTML \
  --data-urlencode text="$(printf "<b>Pool alerts moved to this chat</b>\nNiceHash watcher, ZCU deadman and payout watchdog now report here.")" 2>&1)
case "$R" in
  *'"ok":true'*) echo "  OK  test message delivered -- check the chat" ;;
  *) echo "  FAIL test message: $R"
     echo "  (If it says 'chat not found', add the bot to that group first, then re-run.)" ;;
esac
echo "telegram-chat v1 done."
