---
name: ZCU reference stratum repo
description: Public GitHub repo blockchainmint1/pool-yiimp-zcu holds the "last good" ZCU-aware stratum source — the correct ZCU merged-mining design (out-of-band submit path, full-256 target gate, scrypt_submitAuxBlock, ZCUAUXCOMMIT coinbase output)
type: reference
---

Repo: https://github.com/blockchainmint1/pool-yiimp-zcu (public, clonable with plain
`git clone --depth 1`, no connector or token needed). Single commit: "Replace stratum
with corrected ZCU Yiimp last good source". Contains `stratum/`, `sql/` schema,
`systemd/`, `docs/`.

**This tree is the reference design for ZCU. The binary running on the box
(built from `LIVE-FINAL/`) does NOT necessarily match it — verify before assuming.**

Check what the live binary actually has:
```
sudo strings /var/stratum/stratum | grep -c 'scrypt_submitAuxBlock'   # >0 = ZCU-aware build
sudo strings /var/stratum/stratum | grep -c 'ZCU full256 gate'
```

## How the reference tree handles ZCU (and why it does not deadlock)

1. **ZCU is NOT in `templ->auxs[]`.** `coind_template.cpp` routes ZCU to
   `coind_create_template_zcu()` and `zcu_should_suppress_parent_job()` keeps it out
   of the normal parent job rotation. It is therefore *impossible* for a failing ZCU
   child to stall the shared aux loop — which is exactly the 13 Aug 2026 failure mode.
2. **Submission happens after the aux loop**, via a single dedicated call at the end
   of `client_submit.cpp`: `zcu_submit_from_ltc_parent(client, coind, templ, submitvalues, hash_int, block_hex)`.
   Only an LTC parent share can trigger it.
3. **Full 256-bit target gate.** `zcu_parent_hash_meets_target_full256()` compares the
   whole parent hash against `templ->zcu_aux_target`. The generic aux loop only does
   `hash_int > coin_target_aux` using the 64-bit `get_hash_difficulty()` truncation —
   that truncated gate is why a naive ZCU-in-auxs build submits essentially every
   share (17,143 captured submits, 3 real winners).
4. **RPC is ZCU-specific**: `coind_submitauxblock_zcu()` calls `scrypt_submitAuxBlock`
   (not `submitauxblock`); template refresh calls `scrypt_createAuxBlock` via
   `coind_getauxblock_zcu()` and converts the 256-bit target to nbits with
   `zcu_target_to_nbits()`.
5. **Coinbase commitment**: LTC's coinbase gets an extra OP_RETURN-style output with
   magic `5a4355415558434f4d4d4954` = ASCII `ZCUAUXCOMMIT`, followed by the 64-hex ZCU
   aux hash (`coinbase_append_zcu_aux_output`). Submit-side
   `zcu_extract_work_hash()` reads it back and refuses to submit on mismatch.
6. **Dedupe** is keyed on `child_aux_hash + ":" + parent_proof_hash`, not aux hash
   alone — a ZCU aux hash can persist across several LTC parent proofs and a later
   parent may be the one that actually advances ZCU.

## Implication for our adapter work

`zcu-gate.sh` re-implements gate logic (1)–(3) *outside* stratum in a Python shim
because the running binary lacks it. If the live binary already exports
`scrypt_submitAuxBlock` + `ZCU full256 gate`, the shim is redundant and the correct
move is to configure ZCU natively rather than run an adapter on :8749.
