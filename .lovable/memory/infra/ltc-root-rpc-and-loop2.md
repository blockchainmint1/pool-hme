---
name: LTC root-RPC -19 and the real payment-runner unit name
description: Why LTC blocks showed orphan/amount 0 and payouts died for 9.6 days — multi-wallet root RPC rejection plus a dead `yiimp-loop2` (NOT `loop2`) unit
type: feature
---

20 Aug 2026. Two independent faults produced one symptom set (LTC blocks
`orphan / amount 0 / confirmations NULL`, zero LTC payouts for 9.6 days).

## 1. Multi-wallet root-RPC rejection

Litecoin Core 0.21.4 refuses EVERY wallet RPC on the bare `/` endpoint while
more than one wallet is loaded:

```
{"error":{"code":-19,"message":"Wallet file not specified
 (must request wallet RPC through /wallet/<filename> uri-path)."}}
```

yiimp's `/var/web/yaamp/core/rpc/wallet-rpc.php` calls the bare root, so
`gettransaction` / `getbalance` / `sendtoaddress` all failed for LTC. That
single fact explains the orphan blocks, the missing earnings amounts, and the
dead payouts simultaneously.

**Fix applied:** `litecoin-cli unloadwallet rental` (it held 0.00000000), so the
root resolves to `pool` alone. Verified: `POST /` getbalance now returns
`26.77558040`.

**Caveat:** if `litecoin.conf` contains a `wallet=rental` line, the wallet
reloads on the next litecoind restart and the bug returns. Check that line
before assuming this is permanently fixed. The durable fix is to give yiimp's
RPC client the `/wallet/pool` URL path (`wallet-rpc.php` already accepts a
`$url` constructor arg).

Related: LTC is multi-wallet, so every `litecoin-cli` call in scripts still
needs `-rpcwallet=pool`.

## 2. The payment runner is `yiimp-loop2`, not `loop2`

Stock yiimp names the unit `loop2`. On `stratum.pool.honest.money` it is
**`yiimp-loop2.service`**. Every diagnostic that ran `systemctl ... loop2`
reported `SubState=dead` / `ActiveEnterTimestamp=n/a` — which looked like a
dead runner but was really a nonexistent unit name.

Always resolve the unit name before judging the runner dead:

```bash
systemctl list-unit-files | grep -iE 'loop|yiimp|payment'
```

`YAAMP_PAYMENTS_FREQ` is 86400 (daily) in `/var/web/serverconfig.php`, and the
runner reads it once at boot — restart it after changing the value.
