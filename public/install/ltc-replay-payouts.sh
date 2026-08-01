#!/usr/bin/env bash
# One-shot replay of LTC payout rows that yiimp created but never sent.
#
#   sudo bash 09-ltc-replay-payouts.sh            # dry run: show batches, send nothing
#   sudo bash 09-ltc-replay-payouts.sh CONFIRM    # send + stamp txid/completed
#
# Background: after the LTC wallet rotation the wallet was encrypted, so every
# sendmany returned "error -13 ... walletpassphrase first". yiimp writes the
# payouts row *before* the send and never retries it, so ~263 rows sit at
# completed=0. 08-ltc-unlock.sh fixed the lock; this script drains the backlog.
#
# Safety rules baked in:
#   * refuses to run unless the wallet is currently unlocked
#   * skips rows with invalid/dust amounts (the 22 "error -3: invalid amount")
#   * skips rows with a missing or invalid destination address (validateaddress)
#   * aggregates per address, batches of 100 destinations per sendmany
#   * total is compared against the spendable balance before anything is sent
#   * each row is stamped completed=1 + tx=<txid> immediately after its batch
#   * a JSON journal is written to /var/backups/ltc-replay-<ts>.json first, so a
#     crash mid-run can always be reconciled against the chain
set -euo pipefail

CONFIRM="${1:-}"
LTC_DIR="${LTC_DIR:-/home/ubuntu/.litecoin}"
LTC_BIN="${LTC_BIN:-/home/ubuntu/litecoin-0.21.4/bin}"
CONF="$LTC_DIR/litecoin.conf"
IDCOIN="${IDCOIN:-8}"
MIN_AMOUNT="${MIN_AMOUNT:-0.001}"     # below this litecoind rejects as dust
BATCH="${BATCH:-100}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

WALLET_NAME="$(sed -n 's/^[[:space:]]*wallet=\(.*\)$/\1/p' "$CONF" 2>/dev/null | head -1)"
WALLET_NAME="${WALLET_NAME:-pool}"
LCLI="$LTC_BIN/litecoin-cli -conf=$CONF -rpcwallet=$WALLET_NAME"

echo "=== LTC payout replay ==="
echo "Mode   : $([ "$CONFIRM" = CONFIRM ] && echo EXECUTE || echo 'DRY RUN')"
echo "Wallet : $WALLET_NAME"

UNLOCKED=$($LCLI getwalletinfo | sed -n 's/.*"unlocked_until": *\([0-9]*\).*/\1/p')
NOW=$(date +%s)
echo "Unlocked until: ${UNLOCKED:-0} (now $NOW)"
if [ "${UNLOCKED:-0}" -le "$NOW" ]; then
  echo "FATAL: wallet is locked. Install/start the unlock timer first:"
  echo "  sudo systemctl start ltc-unlock.timer ltc-unlock.service"
  exit 1
fi

eval "$(sed -n "s/.*define( *'YAAMP_DBUSER' *, *'\([^']*\)').*/DBU='\1'/p;s/.*define( *'YAAMP_DBPASSWORD' *, *'\([^']*\)').*/DBP='\1'/p" /var/web/serverconfig.php)"
export DBU DBP IDCOIN MIN_AMOUNT BATCH CONFIRM LCLI

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
export JOURNAL="/var/backups/ltc-replay-$STAMP.json"

python3 - <<'PY'
import os, json, subprocess, shlex, sys, time
from decimal import Decimal

DBU, DBP = os.environ['DBU'], os.environ['DBP']
IDCOIN = os.environ['IDCOIN']
MIN = Decimal(os.environ['MIN_AMOUNT'])
BATCH = int(os.environ['BATCH'])
EXEC = os.environ['CONFIRM'] == 'CONFIRM'
LCLI = shlex.split(os.environ['LCLI'])
JOURNAL = os.environ['JOURNAL']

def my(sql):
    p = subprocess.run(['mysql', '-u'+DBU, '-p'+DBP, 'yiimpfrontend', '-N', '-B', '-e', sql],
                       capture_output=True, text=True)
    if p.returncode:
        sys.exit('mysql failed: ' + p.stderr.strip())
    return [l.split('\t') for l in p.stdout.splitlines() if l.strip()]

def cli(*args):
    p = subprocess.run(LCLI + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

rows = my(f"""SELECT p.id, a.username, p.amount
              FROM payouts p JOIN accounts a ON a.id=p.account_id
              WHERE p.idcoin={IDCOIN} AND p.completed=0
              ORDER BY p.id""")
print(f"pending rows: {len(rows)}")

good, skipped = [], []
addr_ok = {}
for pid, addr, amt in rows:
    try:
        val = Decimal(amt)
    except Exception:
        skipped.append((pid, addr, amt, 'unparseable amount')); continue
    if val < MIN:
        skipped.append((pid, addr, amt, f'below dust {MIN}')); continue
    if not addr or addr in ('NULL', ''):
        skipped.append((pid, addr, amt, 'no address')); continue
    if addr not in addr_ok:
        rc, out, _ = cli('validateaddress', addr)
        addr_ok[addr] = (rc == 0 and '"isvalid": true' in out)
    if not addr_ok[addr]:
        skipped.append((pid, addr, amt, 'invalid address')); continue
    good.append((int(pid), addr, val))

total = sum(v for _, _, v in good)
print(f"sendable: {len(good)} rows, {total} LTC")
print(f"skipped : {len(skipped)} rows")
for pid, addr, amt, why in skipped[:10]:
    print(f"  skip id={pid} {addr} {amt} -> {why}")
if len(skipped) > 10:
    print(f"  ... and {len(skipped)-10} more")

rc, out, _ = cli('getbalance')
bal = Decimal(out or '0')
print(f"spendable balance: {bal} LTC")
if total > bal:
    sys.exit(f"FATAL: need {total} LTC but only {bal} available -- aborting")

# aggregate per address, keeping the row ids that make up each destination
dest, ids_for = {}, {}
for pid, addr, val in good:
    dest[addr] = dest.get(addr, Decimal(0)) + val
    ids_for.setdefault(addr, []).append(pid)

addrs = sorted(dest)
batches = [addrs[i:i+BATCH] for i in range(0, len(addrs), BATCH)]
print(f"{len(dest)} unique addresses -> {len(batches)} sendmany batch(es)")

if not EXEC:
    for n, b in enumerate(batches, 1):
        print(f"  batch {n}: {len(b)} dests, {sum(dest[a] for a in b)} LTC")
    print("\nDRY RUN -- nothing sent. Re-run with CONFIRM.")
    sys.exit(0)

journal = {'started': time.time(), 'batches': []}
with open(JOURNAL, 'w') as f:
    json.dump(journal, f)
print(f"journal: {JOURNAL}")

for n, b in enumerate(batches, 1):
    payload = {a: float(dest[a]) for a in b}
    ids = [i for a in b for i in ids_for[a]]
    rc, out, err = cli('sendmany', '', json.dumps(payload), '1',
                       f'yiimp LTC payout replay batch {n}')
    if rc != 0:
        msg = (err or out)[:250].replace("'", "")
        print(f"  batch {n} FAILED: {msg}")
        my(f"UPDATE payouts SET errmsg='replay: {msg}' WHERE id IN ({','.join(map(str, ids))})")
        journal['batches'].append({'batch': n, 'ids': ids, 'error': msg})
        with open(JOURNAL, 'w') as f:
            json.dump(journal, f)
        sys.exit(f"aborting after batch {n} failure -- nothing further sent")
    txid = out
    print(f"  batch {n}: {len(b)} dests, {sum(dest[a] for a in b)} LTC -> {txid}")
    journal['batches'].append({'batch': n, 'ids': ids, 'txid': txid,
                               'dests': {a: str(dest[a]) for a in b}})
    with open(JOURNAL, 'w') as f:
        json.dump(journal, f)
    my(f"UPDATE payouts SET completed=1, tx='{txid}', errmsg='' "
       f"WHERE id IN ({','.join(map(str, ids))})")

if skipped:
    ids = ','.join(str(int(p)) for p, _, _, _ in skipped)
    my(f"UPDATE payouts SET errmsg='replay: skipped (dust/invalid address)' WHERE id IN ({ids})")

left = my(f"SELECT COUNT(*), IFNULL(SUM(amount),0) FROM payouts WHERE idcoin={IDCOIN} AND completed=0")[0]
print(f"\nDone. Remaining pending: {left[0]} rows, {left[1]} LTC (skipped rows stay pending on purpose)")
PY

if [ "$CONFIRM" = CONFIRM ]; then
  chmod 600 "$JOURNAL" 2>/dev/null || true
  cat <<EOF

NEXT STEPS
  * Confirm the sends on-chain:
      $LCLI listtransactions '*' 20 0 | grep -E '"category"|"amount"|"txid"'
  * Journal of every batch/txid: $JOURNAL
  * Skipped rows keep completed=0 with an explanatory errmsg; their balances
    stay credited to the miner and roll into the next normal payout cycle.
EOF
fi
