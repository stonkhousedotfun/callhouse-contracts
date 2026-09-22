# V4BuybackExecutor (C3-604)

Date: 2026-09-19. Board task C3-604; route ADR `stonkhouse-plan/adr/ADR-15-flywheel.md`; plan
`stonkhouse-plan/six-features/F6-buybackburn.md` D2 / D6; route evidence
[`V2-FLYWHEEL-ROUTE-SPIKE.md`](V2-FLYWHEEL-ROUTE-SPIKE.md) (C3-602).

`src/v2/periphery/V4BuybackExecutor.sol` is the flywheel's **buy leg only**. It holds nothing, owns nothing and
decides nothing about size or cadence: the FeeSplitter (C3-603) keeps the reserve, enforces the per-buy cap and the
interval, checks what came back and burns it. Nothing here was sent to the real chain, and nothing here authorises a
deployment, a funding or a live buy.

## What it does

`buy(usdgIn, minTokenOut, minWethOut)`, callable **only** by the splitter:

1. pulls `usdgIn` USDG from the splitter (measured, so a short or fee-on-transfer pull reverts);
2. swaps it for WETH on the pinned Uniswap v3 pool with `pool.swap` and a callback that pays USDG, under the
   contract's own v3 TWAP floor;
3. unwraps the WETH to native ETH;
4. buys the token through `PoolManager.unlock` on ONE immutable PoolKey, with `sync(ETH)` / `settle{value}` / `take`;
5. sends every token bought and any unspent USDG to the splitter, and reverts unless all four balances (USDG, WETH,
   token, native ETH) are back at their entry values.

Everything is pinned at deployment (`V4BuybackConfig`): splitter, USDG, WETH, the v3 pool, the PoolManager, the
StateView lens, the PoolKey, the fee cap, the TWAP window, the slippage tolerance and the liquidity floor. There is no
admin function, no setter and no sweep. A venue change is a new executor and one 24 h scheduled pointer swap on the
splitter (ADR-15 §3).

## The fee guard

The C3-602 correction, recorded in ADR-15 §5: **the pool's fee terms are frozen per pool inside the hook's
`launches(poolId)` record, and the hook's global `hookFeeBps()` getter does not apply to this pool.** The executor
therefore never reads `hookFeeBps()`. A `hookFeeBps()`-only cap would read a value that seeds future launches, and it
would miss the creator tax entirely — half of the 200 bps this pool actually charges.

**The cap covers the measured total, not just the hook fee.** `maxTotalFeeBps` bounds the sum of every fee-type
charge on the route:

| Component | Where it is read, at call time | On the pinned venue |
|---|---|---:|
| v3 LP fee | the v3 pool's own `fee()`, read at deployment (a v3 fee is immutable), on the USDG input | 1 bp |
| v4 LP fee | `StateView.getSlot0(poolId).lpFee`, on the ETH input | 0 |
| v4 protocol fee | `StateView.getSlot0(poolId).protocolFee`, low 12 bits (the zeroForOne direction), on the ETH input | 0, ceiling 10 bps |
| hook fee | `launches(poolId).hookFeeBps`, on the token output | 100 bps |
| creator tax | `launches(poolId).creatorTaxBps`, on the token output | 100 bps |
| **total** | | **201 bps**, 211 bps if the protocol-fee controller acts |

Two checks, both fail closed:

- **DECLARED**, before one unit of USDG moves: the five rows above must sum to at most `maxTotalFeeBps`, the launch
  record must still be `registered` for this token with native ETH as its quote, and the protocol fee must be within
  v4's own 1,000-pip ceiling. A raised per-pool term, a record that moved, or a nonsense protocol fee stops the call
  before the v3 swap. `feeBps()` is the same read as a view, so a keeper can staticcall it and a monitor can watch it;
  it reverts for the same reasons.
- **MEASURED**, after the v4 fill: the hook's *actual* cut, taken from the hook's token balance delta across the swap,
  replaces the declared output terms in the same sum, which must again be at most `maxTotalFeeBps`. This catches a hook
  that charges more than it declares. It is a second check on top of the declared one, never a replacement, and it is
  deliberately saturating on the way down (a hook whose balance *fell* during the swap measures 0 rather than reverting
  a buy the declared check already bounded).

Price impact is **not** a fee and is not in either total. The v3 leg's impact is bounded by the TWAP floor; the v4
leg's by the caller's `minTokenOut`, which ADR-15 §4 is explicit is not an independent price.

The token's eleven other v4 pools (LP fees 7 %–99.12 %) are unreachable. The constructor requires the key's hook to be
a contract that holds a registered launch for exactly this pool id, token and ETH quote; none of those eleven pools has
a hook at all, and the four ETH-quoted ones are refused for that reason while the seven USDG-quoted ones are refused
because `currency0` is not native ETH. `unlockCallback` rebuilds the key from immutables and never reads it from
calldata.

## The TWAP floor

`_wethFloor` is FeeSplitter's `_floor` arithmetic applied to this one pool: the arithmetic-mean tick over `twapWindow`
seconds (floored toward negative infinity), a harmonic-mean in-range liquidity floor over the same window, and
`minWethOut = quoted × (BPS − maxSlippageBps) / BPS`. `maxSlippageBps` must be at least the pool's own fee in bps and at
most `V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS` (300), so the tolerance is the allowance *above* the unavoidable fee —
the same rule `FeeSplitter._checkRoute` applies to a route. Unlike the splitter's view, which returns `(false, 0)` so a
cranker can skip, every failure here reverts: the executor is only ever called with money in hand. A caller's
`minWethOut` can only raise the floor, never lower it (the effective floor is the larger of the two).

## Deployment bounds (constructor-enforced, not owner-approved values)

| Field | Bound | Used in the fork run below |
|---|---|---:|
| `maxTotalFeeBps` | `0 < x <= MAX_TOTAL_FEE_CEIL_BPS` (2,500) | 250 |
| `maxSlippageBps` | `ceil(v3Fee/100) <= x <= 300` | 51 |
| `twapWindow` | 60 s … 1 h | 300 s |
| `minLiquidity` | non-zero | 1e18 |

These are the values the fork suite runs with. They are **not** an owner decision: per-buy cap, minimum buy, cadence
and budget are Q6.4 / OQ-12 and live on the splitter, not here.

## Fork evidence

`test/v2/fork/V4BuybackExecutorFork.t.sol`, 3 tests, run against the live chain-4663 venue at block **67,409,012**
(timestamp 1,789,853,750 — 2026-09-19 21:35:50 UTC). The public RPC keeps no historical state, so the block was the
latest one when the run started; the suite takes the block from `--fork-block-number` and skips cleanly without a fork.

```bash
FOUNDRY_PROFILE=fork forge test --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 67409012 --match-path test/v2/fork/V4BuybackExecutorFork.t.sol -vv
```

A 50 USDG buy through the deployed executor, with every fee component reconciled against a measured balance delta:

| | Amount | Reconciled against |
|---|---:|---|
| USDG in / spent | 50.000000 / 50.000000 | the v3 pool's USDG balance rose by exactly the input |
| v3 TWAP floor (300 s, 51 bps) | 0.018947201356581406 WETH | the fill cleared it |
| WETH out | 0.019058760141604518 | the v3 pool's WETH balance fell by exactly this; equals `QuoterV2`'s pre-trade quote to the wei |
| v3 LP fee | 0.005000 USDG (1 bp) | the fill is at most the post-fee value of the input at the pre-trade mid and within 100 ppm of it |
| ETH into the PoolManager | 0.019058760141604518 | the PoolManager's native balance rose by exactly the unwrapped WETH |
| gross token output | 170,910.390882715700019532 | the PoolManager's token balance fell by exactly this |
| hook fee | 1,709.103908827157000195 | `pendingFees(poolId, TOKEN)` delta; exactly `gross × 100 bps` |
| creator tax | 1,709.103908827157000195 | `pendingCreatorTax(poolId, TOKEN)` delta; exactly `gross × 100 bps`; the hook's token balance rose by the sum of the two |
| v4 protocol fee | 0 | `slot0.protocolFee` is 0 and `protocolFeesAccrued(ETH)` did not move |
| tokens to the splitter | 167,492.183065061386019142 | the executor's own balance delta, equal to the `unlock` swap delta and to `V4Quoter`'s pre-trade quote to the wei |
| executor afterwards | 0 USDG, 0 WETH, 0 token, 0 ETH | |
| the other 11 pools | unchanged | hash over every pool's `slot0` and liquidity |
| declared / measured total | 201 bps / 201 bps, cap 250 | |
| gas, whole call as one transaction | 430,617 | `isolate = true`, net of refunds, no L1 data fee |

The protocol fee is the one fee that can still change on this pool, so the suite drives the real
`PoolManager.setProtocolFee` from its real controller at v4's ceiling (`1000 | (1000 << 12)`, raw `4097000`):

- `feeBps()` then declares 10 bps of protocol fee and a 211 bps total;
- an executor with `maxTotalFeeBps = 205` reverts `FeeCapExceeded(211, 205)` **before spending anything** — the
  splitter's USDG is untouched;
- the 250 bps executor buys, and `protocolFeesAccrued(ETH)` rises by exactly 19,058,760,141,605 wei, which is the ETH
  input less 99.90 % of it (v4 rounds the charge up). The fill drops to 167,325.016750598150742909 tokens, 0.0998 %
  lower.

Gas is about 140,000 above C3-602's bare 290,597: this call also pulls USDG from the splitter, reads the TWAP, reads
the launch record and `slot0`, reads the hook's balance twice and pays two transfers back to the splitter. It does not
include the burn, which is the splitter's (C3-605 measures the splitter and executor together).

## Gates

| Command | Result |
|---|---|
| `forge build` | exit 0 |
| `forge test` | exit 0, 105 suites, 1,676 tests passed (baseline 102 / 1,633, plus the three suites below) |
| `forge fmt --check` on the new files | exit 0 |
| the fork command above | exit 0, 3 passed |

Unit suites: `test/v2/unit/V4BuybackExecutor.t.sol` (29 tests) and `test/v2/unit/V4BuybackExecutorFees.t.sol`
(11 tests), over the mocks in `test/v2/mocks/`.

## Not proven here

- Future prices, depth, hook behaviour or MEV. This is one block on a fork, like C3-602's.
- An independent price for the token. None exists on chain; `minTokenOut` is the caller's, and the V4Quoter reads the
  pool it prices.
- The splitter side: the cap, the interval, the reserve accounting and the burn are C3-603, and the two together are
  C3-605.
- Exact-output swaps, the UniversalRouter path and Permit2. The executor only does exact input through `unlock`.
- The L1 data fee on chain 4663.
- That the measured guard catches a hook which takes its cut somewhere other than its own balance. The unit suite
  drives an undeclared cut that the hook keeps; a hook that routed its cut elsewhere inside the same call would be
  bounded by the declared check alone.
