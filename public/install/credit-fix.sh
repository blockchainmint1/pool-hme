#!/usr/bin/env bash
# credit-fix v1 -- repair the reward-splitting layer for merged scrypt mining.
#
# ROOT CAUSE (proved by credit-doctor v3):
#   shares rows are keyed to coinid=8 (LTC, the parent chain) only.
#   BackendBlockNew() scopes its share query with "AND coinid = <coin->id>".
#   For a DOGE block (coinid=9) that query matches ZERO rows ->
#   $total_hash_power is 0 -> the function `return`s before writing any
#   earnings, and before the trailing "DELETE FROM shares" ever runs.
#   Result: no DOGE earnings EVER, and a shares table that never prunes
#   (2.1M rows back to 8 Jul), which also skews effort/hashrate stats.
#
# FIX: for algo='scrypt' (our merged LTC+DOGE+TXC+ISK+ZCU work), shares are
# algo-wide, not per-coin. Drop the coinid predicate inside BackendBlockNew
# for scrypt only, and widen the aux "worker row disappeared" fallback from
# DOGE-only to every merged child. Nothing else is touched.
#
# Usage:  curl -fsSL https://pool.honest.money/install/credit-fix.sh | sudo bash -s CONFIRM_FIX
#         (no arg = dry run, shows the diff and exits)
set -uo pipefail

MODE="${1:-DRYRUN}"
WEB=/var/web
SRC="$WEB/yaamp/core/backend/blocks.php"
STAMP=$(date -u +%Y%m%d-%H%M%S)
echo "credit-fix v1 $(date -u '+%F %T') UTC  mode=$MODE  src=$SRC"
echo

[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }

TMP=$(mktemp -d /tmp/credit-fix.XXXXXX)
cp "$SRC" "$TMP/blocks.php.orig"

python3 - "$TMP/blocks.php.orig" "$TMP/blocks.php.new" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8', errors='surrogateescape').read()

if 'POOL_MERGED_SHARE_FIX' in s:
    print("  already patched (marker POOL_MERGED_SHARE_FIX present) -- no change")
    open(dst,'w',encoding='utf-8',errors='surrogateescape').write(s)
    sys.exit(0)

# isolate BackendBlockNew()
m = re.search(r'function\s+BackendBlockNew\s*\(', s)
if not m:
    print("FATAL: BackendBlockNew not found"); sys.exit(2)
start = m.start()
nxt = re.search(r'\nfunction\s+\w+\s*\(', s[m.end():])
end = m.end() + nxt.start() if nxt else len(s)
body = s[start:end]
orig_body = body

# 1) scrypt merged mining: shares are algo-wide, not per-coin
pat = re.compile(
    r'if\(!YAAMP_ALLOW_EXCHANGE\)([^\n]*)\n(\s*)\$sqlCond \.= " AND coinid = "\.intval\(\$coin->id\);')
def rep(mm):
    return ('if(!YAAMP_ALLOW_EXCHANGE && $coin->algo != \'scrypt\')'
            ' // POOL_MERGED_SHARE_FIX: scrypt shares are algo-wide (merged LTC+aux)\n'
            + mm.group(2) + '$sqlCond .= " AND coinid = ".intval($coin->id);')
body, n1 = pat.subn(rep, body)

# 1b) same predicate written inline in the solo-worker share delete
pat2 = re.compile(r'\$sqlCond \.= " coinid = "\.intval\(\$coin->id\);')
body, n1b = pat2.subn(
    '$sqlCond .= ($coin->algo == \'scrypt\' ? " 1=1" : " coinid = ".intval($coin->id)); // POOL_MERGED_SHARE_FIX',
    body)

# 2) widen the aux "worker row gone" classification fallback beyond DOGE
pat3 = re.compile(r"\$coin->symbol\s*==\s*'DOGE'\)")
body, n2 = pat3.subn(
    "in_array($coin->symbol, array('DOGE','LTC','TXC','ISK','ZCU'))) // POOL_MERGED_SHARE_FIX",
    body, count=1)

# 3) the fallback share counters must not be coin-scoped either (they already
#    use algo only) -- nothing to do, but assert it
print(f"  patched: coinid-predicate sites={n1}  inline-site={n1b}  aux-fallback={n2}")
if n1 == 0 and n1b == 0:
    print("FATAL: no coinid predicate matched -- aborting, file untouched")
    sys.exit(3)

s = s[:start] + body + s[end:]
open(dst,'w',encoding='utf-8',errors='surrogateescape').write(s)
PY
rc=$?
[ $rc -eq 0 ] || { echo "patch generation failed (rc=$rc)"; exit $rc; }

echo
echo "===== proposed diff"
diff -u "$TMP/blocks.php.orig" "$TMP/blocks.php.new" || true
echo

php -l "$TMP/blocks.php.new" || { echo "FATAL: patched file fails php lint"; exit 4; }

if [ "$MODE" != "CONFIRM_FIX" ]; then
  echo
  echo "DRY RUN -- nothing written."
  echo "Re-run with:  curl -fsSL https://pool.honest.money/install/credit-fix.sh | sudo bash -s CONFIRM_FIX"
  exit 0
fi

cp -a "$SRC" "/var/backups/blocks.php.$STAMP"
cp "$TMP/blocks.php.new" "$SRC"
chown --reference="/var/backups/blocks.php.$STAMP" "$SRC" 2>/dev/null || true
echo "WROTE $SRC   (backup: /var/backups/blocks.php.$STAMP)"

echo
echo "===== restarting yiimp loop services"
for u in yiimp-loop2 yiimp-loop1 yiimp-blocknotify; do
  systemctl list-unit-files 2>/dev/null | grep -q "^$u" && { systemctl restart "$u" && echo "  restarted $u"; }
done
sleep 3
systemctl --no-pager --lines=0 status yiimp-loop2 2>/dev/null | head -5

echo
echo "===== watch for the next block credit"
echo "  tail -f /var/log/stratum/debug.log | grep -Ei 'Shared Mining Found Block|Solo Mining Found Block|Unable to insert earning'"
echo
echo "  then confirm:"
echo "  SELECT c.symbol, COUNT(*) n, MAX(FROM_UNIXTIME(e.create_time)) newest"
echo "    FROM earnings e JOIN coins c ON c.id=e.coinid GROUP BY c.symbol;"
echo
echo "done."
