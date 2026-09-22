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

One factory per market, driven from the registry (`ops/markets/tier1.json` in stonkhousedotfun/callhouse):

```
script/DeploySoloBatch.sh --rehearse --rpc http://127.0.0.1:8546 --tickers TSLA,GME,SPY   # anvil fork first
script/DeploySoloBatch.sh --broadcast --rpc $RH_RPC --wave canary                         # mainnet, asks for "deploy"
```

The batch runs `script/DeploySolo.s.sol` (on-chain preflight: the asset's `symbol()` and the feed's
`description()` must match `EXPECTED_TICKER`, decimals, `uiMultiplier()`, `oraclePaused()`, feed
freshness, Clear fee state, Seaport 1.6), then `script/ConfigureSolo.s.sol` (`KEEPER_ROLE` and
`GUARDIAN_ROLE` from the registry row, idempotent) and `script/VerifySolo.s.sol` (read-only, bytecode
against `out/`, every immutable, parameter and role), and writes `deployment.factory`,
`implementation`, `deployBlock`, `deployTx`, `sourcify`, `configuredAt` back into the registry.
`docs/DEPLOY.md` "Solo factory markets (Tier 1)" has the env tables, the flags and the rehearsal record.
Point the app at `NEXT_PUBLIC_FACTORY` (per market). The live pooled vault is unchanged and closed.
