---
name: Core sethdseed is NOT BIP39/BIP84
description: Why litecoind sethdseed addresses never match a Cold Storage Coins / BIP84 app, and the IMPORT-only rule for owner-recoverable coinbase addresses
type: feature
---
`sethdseed` in Litecoin/Bitcoin Core takes a **WIF private key** used as the HD
master key, deriving on Core's own path `m/0'/0'/k'`. It does NOT accept a BIP39
mnemonic or BIP32 master seed and does NOT use BIP84 `m/84'/2'/0'/0/0`.

Consequence: the same seed gives totally different addresses in Core vs a BIP84
cold-storage app. A Core `sethdseed` wallet is **not recoverable** in the app.

**Rule for pool coinbase addresses (LTC and DOGE both):** use the IMPORT model,
never SEED.
1. In the cold app, pick the receive address (LTC `m/84'/2'/0'/0/0` bech32
   `ltc1q...`; DOGE `m/44'/3'/0'/0/0` `D...`) and export **that row's WIF**.
2. `owner-verify.sh MATCH <COIN> <address>` — imports the WIF and asserts it
   derives exactly that address before anything is rotated.
3. `owner-key.sh SETCOINBASE <COIN> <address>`.

Never trust that an address is owner-recoverable without `getaddressinfo`
`ismine:true` **and** the `owner-coinbase` label. Coinbase-only import does not
cover payout change addresses — that's expected and accepted.

Scripts: `infra/wallet-rotation/19-owner-verify.sh` → `/install/owner-verify.sh`.

**Dogecoin Core 1.14 RPC gaps:** no `getaddressinfo` (returns -32601 Method not
found) and no `getaddressesbylabel`. Use `validateaddress` (it carries
ismine/iswatchonly/account) and `getaddressesbyaccount`. Its `backupwallet` can
report success while writing no readable file — always verify the file exists and
fall back to copying `~/.dogecoin/wallet.dat`.
