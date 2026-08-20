---
name: Parent LTC coinbase must be legacy P2PKH
description: A bech32/segwit LTC coinbase address breaks auxpow for all UTXO aux children (TXC/ISK/DOGE) with "CDataStream::read(): end of data"
type: constraint
---

The merged-mining parent (LTC) `coins.master_wallet` MUST be a legacy P2PKH
address (`L...`, `iswitness: false`). Never set a bech32 `ltc1q...` or P2SH
`M...` address there.

**Why:** on 20 Aug 2026 the LTC coinbase was rotated to a bech32 cold address
at 11:55 UTC. Every UTXO aux child (TXC, ISK, DOGE) then rejected solved
blocks with `error=CDataStream::read(): end of data: iostream error`, because
they deserialize the parent coinbase transaction embedded in the auxpow and a
P2WPKH coinbase doesn't parse. ZCU (EVM) kept accepting, which masked it.
Result: ~5.5 hours with zero TXC/ISK finds while the fleet hashed normally.

**Fix that worked:** set `master_wallet` to a legacy cold address
(`LdSHVgxVWbP5kGKzmZMm8aEXe2wprwwr32`, WIF-imported, `ismine: true`) and
restart `stratum-aws-scrypt`. Finds resumed within minutes.

**Before any coinbase rotation:** run
`litecoin-cli -rpcwallet=pool getaddressinfo <addr>` and require
`iswitness: false` AND `ismine: true`. Same rule for any future parent chain.

**Triage signal:** `grep -a 'error=CDataStream' /var/stratum/scrypt.log`.
Any hit = malformed auxpow, check the parent coinbase address type first.
