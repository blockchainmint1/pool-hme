---
name: auxpow serialization break (ZCU binary)
description: 20 Aug 2026 — ZCU-capable stratum binary produces malformed auxpow for TXC/ISK; submitauxblock fails with CDataStream::read end of data. Frozen aux hash is a symptom, not the cause.
type: feature
---
Symptom: TXC/ISK stop finding blocks while hashrate is normal; `createauxblock` returns the
same hash for hours; log shows `aux submit skip target` floods (normal) AND, at the real
find moments, `aux submit rpc=submitauxblock ... error=CDataStream::read(): end of data: iostream error`
with `auxpow_len=1494`.

Root cause: the ZCU forward-ported stratum binary serializes a truncated/invalid auxpow blob
for legacy UTXO aux children. ZCU itself submits fine (`scrypt_submitAuxBlock accepted=1`,
len 1366) because it uses the adapter path.

Meaning: blocks ARE being solved and thrown away. This is silent revenue loss — the stratum
stays `active`, shares keep flowing, nothing crashes.

Remedy: restore the pre-ZCU stratum binary via `pool-snapshot.sh RESTORE <dir> --restart`
(binaries only, never the DB). ZCU loses merge-mining; TXC/ISK resume immediately.

Triage rule: when TXC/ISK go dry, grep the LIVE log `/var/stratum/scrypt.log` for
`aux submit rpc=` and read the `error=` field. Do NOT reason from `aux submit skip target`
lines or from a frozen aux hash — both are downstream noise.
