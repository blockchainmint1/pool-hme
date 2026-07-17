---
name: Stratum source trees & build gotchas
description: Which source tree the live stratum binary comes from, the parallel-make link race, and the ZCU aux-child patch site
type: feature
---

# Stratum build on stratum.pool.honest.money

## Runtime binary
- systemd unit: `stratum-aws-scrypt`
- ExecStart runs `/var/stratum/stratum <algo>` (see infra doc).
- Confirm truth with:
  ```bash
  sudo systemctl cat stratum-aws-scrypt | grep -E 'ExecStart|WorkingDirectory'
  ls -l /var/stratum/stratum
  sudo readlink -f /proc/$(pgrep -f '/var/stratum/stratum' | head -1)/exe
  ```

## Candidate source trees on the box
**LIVE tree (verified 2026-07-17):** `/home/ubuntu/aws/LIVE/yiimp/live-aux-issue-doge/stratum`
- Its build produced the current `/var/stratum/stratum` (mtime Jul 17 03:16).
- Contains the ZCU aux-child patch at `coind_template.cpp:571`.

**STALE tree — do NOT patch or build:** `/home/ubuntu/aws/LIVE/LIVE-FINAL/stratum`
- Its local `stratum` binary is older than the live one and is not deployed.
- Earlier `sudo patch -p1` runs against this tree were wasted work.

Always re-verify before editing: `ls -l /var/stratum/stratum` and compare mtime to `<tree>/stratum`, plus `grep` for the patch line in `coind_template.cpp`. There is no symlink — `install -m755 stratum /var/stratum/stratum` is a plain copy.

## Build gotcha: parallel make link race
Top-level `make -j$(nproc)` races: the link of `stratum` fires before `algos/libalgos.a` and `sha3/libhash.a` finish, producing:
```
/usr/bin/ld: cannot find algos/libalgos.a: No such file or directory
/usr/bin/ld: cannot find sha3/libhash.a: No such file or directory
make: *** [Makefile:55: stratum] Error 1
```
And because scripts don't run with `set -e`, a subsequent `install`/`systemctl restart` silently reuses the OLD binary. Always verify `ls -l stratum` mtime AFTER build, BEFORE install.

### Correct build order
```bash
cd <tree>/stratum
sudo make -C iniparser
sudo make -C secp256k1
sudo make -C algos -j"$(nproc)"
sudo make -C sha3  -j"$(nproc)"
sudo make -j"$(nproc)"     # or -j1 if it still races
ls -l stratum              # MUST be a fresh mtime
sudo install -m755 stratum /var/stratum/stratum
sudo systemctl restart stratum-aws-scrypt
```

If `make` says "Nothing to be done" and the binary mtime is stale, the source wasn't actually edited in that tree — the patch went to the other tree.

## ZCU / aux-child patch
**Problem:** ZCU coind adapter returns JSON-RPC `-32601` ("method does not exist") for `getblocktemplate`. That makes `coind_create_template()` return NULL → `coind_create_job()` bails → ZCU never enters job rotation → no aux hash → no merge-mining.

TXC/ISK adapters return `-8` (method exists, wants `{"rules":["mweb","segwit"]}`) so they survive.

**Fix** (`stratum/coind_template.cpp`, top of `coind_create_job()` near line 567):
```cpp
bool coind_create_job(YAAMP_COIND *coind, bool force)
{
    // Pure-aux children (custom auxpow via createauxblock) have no
    // getblocktemplate on their adapter — skip parent-style job creation.
    if (coind->isaux && coind_uses_custom_auxpow(coind)) return false;

    bool b = rpc_connected(&coind->rpc);
    ...
```

Verify patch is in the tree you're building:
```bash
grep -n "coind_uses_custom_auxpow(coind)) return false" \
  <tree>/stratum/coind_template.cpp
```

Aux submit path (unaffected by the patch) is `coind_getauxblock_custom(coind)` — called from the scheduler at `coind_template.cpp:445`.
