# Isolated 1-lot accounts

This is a different product from the pooled `Vault`. No `cNVDA`. No shared NAV.

## What it does

1. Each user `createAccount`s a clone that holds **their** NVDA.
2. They `requestWrite(X)` — X whole NVDA lots.
3. The keeper `setWeek`s the strike / Friday 4:00pm window / ask, then `listFor`s each writer.
4. The account posts **X FULL 1-contract Seaport orders** of **its own** Valorem option type (same strike, expiry = week base + account index, so assignment cannot hit anyone else).
5. A fill writes that user's 1 NVDA and pays that user the premium (minus the protocol fee).
6. Unfilled lots unlock at `settle` after expiry. Exercised lots pay strike USDG to that account only.

## Deploy

```
forge script script/DeploySolo.s.sol --rpc-url $RH_RPC --broadcast --slow --non-interactive --chain 4663
```

Grant `KEEPER_ROLE` / `GUARDIAN_ROLE` on the factory. Point the app at `NEXT_PUBLIC_FACTORY`. The live pooled vault is unchanged.
