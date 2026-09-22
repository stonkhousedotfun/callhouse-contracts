# v2 accounting

The money maths of the Stonkhouse v2 contracts: where every balance lives, the units, the rounding
of every division, why value is conserved, and the fees, with worked examples. Read it before
changing anything under `src/v2/`. [V2-ARCHITECTURE.md](V2-ARCHITECTURE.md) has the components,
roles and oracle. The v1 vault's maths are in [ACCOUNTING.md](ACCOUNTING.md).

> **Status.** INTERFACE_VERSION 8. Unaudited: no external audit report exists at this commit and
> this repository links to none. Not deployed. Under the owner's build-mode directive of 2026-09-19
> the suites named below are written but are not run as a condition of shipping, so a figure here is
> only as good as the last run that produced it. The code on branch `v2` is the specification.

> **Paths.** Paths resolve from the root of this repository, stonkhousedotfun/callhouse-contracts.

> **Numbers.** Every figure here is asserted by the test named next to it. The worked examples run on
> the real contracts: `forge test --match-contract V2DocsNumbersTest -vv` prints them, and
> `LifecycleTest` repeats the same trades inside a whole weekly ladder. [§11](#11-reproducing-every-number)
> lists the commands.

---

## 1. Where the money is

| Balance | Held by | Unit | Moves on |
|---|---|---|---|
| `free[account][asset]` | Clearinghouse | base units of `asset` (USDG or a registered Stock Token) | `deposit`, `withdraw`, `mint`, `close`, a redemption paid to the ledger |
| `locked(longId)` | Clearinghouse | base units of the series' collateral asset | derived, never stored: see [§3.2](#32-mint-close-and-locked) |
| `accruedFees[asset]` | Clearinghouse | base units of `asset` | exercise fees on long redemptions; collateral rent at `settle`; `sweepFees` |
| `series(longId).mintFeesHeld` | Clearinghouse | base units of the series' collateral asset | `mint` (charged), `close` (refunded pro rata), `settle` (moved to `accruedFees`) — [§3.3](#33-collateral-rent-the-writer-fee) |
| open bid escrow | OrderBook | USDG base units | `place` / `replace` / `cancel` / `prune` of a bid; sales into bids |
| resale escrow | OrderBook | long units per id | `place` / `replace` / `cancel` / `prune` of a resale ask; purchases from it |
| `owed[account]` | OrderBook | USDG base units | a payment the book could not transfer; `claimOwed` |
| bounty budget | KeeperRewards | USDG base units (its balance) | `fund`, `defund`, bounties paid |
| reward budget | RewardsDistributor | USDG base units (its balance) | `fund`, `defund`, claims |
| inventory | MakerVault | USDG, Stock Tokens, its own Clearinghouse ledger and positions | admin and quoter actions |

The PayoutAdapter and the AutoRoller hold nothing between calls; the AutoRoller forwards the bounties
it earns inside a roll to the roll's caller.

**Consequence you must remember:** premium never passes through the Clearinghouse. A `take` moves
USDG from the buyer (or the bid escrow) to the makers and the fee recipient inside the same
transaction. The Clearinghouse holds collateral, exercise fees and — since INTERFACE_VERSION 7 — the
collateral rent it has taken and not yet refunded or accrued, nothing else. That last balance is 0 on
every market at launch, because the rent rate is 0 ([§3.3](#33-collateral-rent-the-writer-fee)); the
identity below holds either way. Its token balance per asset is
exactly `Σ free + Σ locked + Σ mintFeesHeld + accruedFees` (invariant 2′,
[§10](#10-the-invariants-as-asserted)).

---

## 2. Units, stated once

| Quantity | Unit | Example | Asserted by |
|---|---|---|---|
| ERC-1155 amount, `units` | 0.01 share | 100 units = 1 share; 10 units = 0.1 share | `InterfaceIdsTest.test_constants_units` |
| one unit of an 18-dp Stock Token | `UNIT = 1e16` base units | a call locks `1e16` per unit | `InterfaceIdsTest.test_constants_units` |
| `price`, `strike`, `spot`, settlement price | USDG base units (6 dp) **per whole share**, a multiple of 100 | `221_700_000` = 221.70 USDG | `InterfaceIdsTest.test_constants_units` |
| premium, fees, rebates, bounties | USDG base units | `100_000` = 0.10 USDG | `V2DocsNumbersTest.test_docs_orderBookFees_microTicketAndOneShare` |
| `*PerUnit` settlement amounts | base units of the collateral asset per unit: the Stock Token for calls, USDG for puts | a 210 call's long gets `502_740_189_445_196` NVDA base units per unit at 221.70 | `V2DocsNumbersTest.test_docs_settlementAndRedemption` |
| every `*Bps` | basis points of `10_000` | `500` = 5 % | `InterfaceIdsTest.test_constants_units` |

One unit costs `price / 100` USDG base units, exactly, because every price is a multiple of 100:
`OptionMath.premium(1_900_000, 1) = 19_000` and `premium(240_000_000, 10) = 24_000_000`, 0.1 share at
240 (`OptionMathTest.test_premium_table`).

---

## 3. Collateral

### 3.1 What a unit locks

```
collateralPerUnit(call)            = UNIT = 1e16 Stock Token base units      (0.01 share)
collateralPerUnit(put, strike)     = strike / 100 USDG base units             (the strike of 0.01 share)
```

A put strike is a multiple of the market's tick, itself a multiple of 100, so the division is exact:
a 231 put locks `2_310_000` (2.31 USDG) per unit, a strike of 1 USDG locks `10_000`
(`OptionMathTest.test_collateralPerUnit_table`).

### 3.2 Mint, close and locked

- `mint(longId, units, writer, longTo)` moves `units × collateralPerUnit` from `free[writer]` into the
  series, mints `units` longs to `longTo` and `units` shorts to the writer, and adds `units` to
  `openInterest(underlying, expiry)`. From INTERFACE_VERSION 7 it also takes the collateral **rent** out of
  `free[writer]` — on top of the collateral, never out of it ([§3.3](#33-collateral-rent-the-writer-fee)).
  From INTERFACE_VERSION 8 the caller must be on the Clearinghouse's minter allow-list **and** be the
  writer or its operator (`NotMinter`, then `NotAuthorized`: `src/v2/Clearinghouse.sol:634-635`). At
  launch the only minter is the OrderBook, so every long that exists was created inside a fill at a
  price the protocol saw, which is what makes the seller fee of [§8](#8-fees-the-whole-list)
  unavoidable.
- `close(longId, units)` burns `units` longs and `units` shorts of the caller and moves
  `units × collateralPerUnit` back to `free[caller]`, plus the unused part of that rent. It takes nothing.
- Longs and shorts are only minted and burned in pairs before settlement, so for an unsettled series:

```
totalSupply(longId) == totalSupply(shortId)
locked(longId)      == totalSupply(longId) × collateralPerUnit
```

`locked` is computed from the supplies rather than stored; a counter would cost a storage write in
every mint, close and redemption to restate the same identity. A one-share call locks exactly
`1e18` NVDA base units and a one-share 230 put locks `230_000_000` USDG base units
(`V2DocsNumbersTest.test_docs_settlementAndRedemption`).

### 3.3 Collateral rent: the writer fee

INTERFACE_VERSION 7 made the writer fee **rent on the collateral a pair locks, for the time it is
locked** (owner decision `status/DECISIONS-2026-09-17.md` §5, sweep finding contracts-c05), because the
OrderBook's premium fee was avoidable: only writers who let the book mint ever paid it, and a writer
could mint into a one-tick bid of a second address of its own, sell the long as a resale and pay
`resaleFeeBps` instead.

**INTERFACE_VERSION 8 turns the rent off and brings the premium fee back.** The dodge is closed at its
root rather than priced around: `mint` sits behind the Clearinghouse's minter allow-list and the only
minter at launch is the OrderBook ([§3.2](#32-mint-close-and-locked)), so there is no un-sold,
un-charged inventory to launder, and the writer pays `premiumFeeBps` of the premium on the **first
sale** — 500 bps, 5 %, at launch ([§8](#8-fees-the-whole-list)). The rent rate is **0 on every market
and on the default** (`ops/markets/tier1.json`: `v2.fees.mintFeePpm` and every `markets[].v2.mintFeePpm`
across all 35 launch markets, stonkhousedotfun/callhouse), so nothing in the rest of this section
charges anybody anything today.

The rent code is kept, tested, and left as a **dial**: `MARKET_FEE_MANAGER` can raise a market's rate
up to `MINT_FEE_CEIL_PPM` on the 72 h lane, in public, with the guardian able to cancel it while it
waits ([V2-ARCHITECTURE.md §2.2](V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case)). Read
the rest of §3.3 as that dial's specification — every formula, refund and invariant below is live code
and is exercised at a non-zero rate by its tests; it simply evaluates to 0 at the launch rate.

**The rate.** Each market carries `MarketConfig.mintFeePpm`, millionths of the locked collateral per
`MINT_FEE_PERIOD` (7 days) of remaining life, at most `MINT_FEE_CEIL_PPM` (5000 = 0.5 %/week).
`createSeries` **pins** it into `Series.mintFeePpm`, so a rate change reaches series created after it and
never an existing one or a resting order (`ClearinghouseMintFeeTest`).

**Charged at mint, in the collateral asset.**

```
fee    = ceil(units × collateralPerUnit × mintFeePpm × (E − now) / (1e6 × 604800))
free[writer][asset] -= units × collateralPerUnit + fee
series.mintFeesHeld += fee
```

The fee comes out of **free** collateral, never out of the collateral the pair locks, so `locked()`, the
settlement identity and every payout are untouched. A writer without the headroom is refused
`InsufficientCollateral(have, need + fee)`; an `AskWrite` whose maker cannot cover collateral **plus** rent
is skipped by the book rather than reverting the take
([V2-ARCHITECTURE.md §4.3](V2-ARCHITECTURE.md)).

**Refunded pro rata by `close`, to whoever closes.**

```
refund = floor(units × collateralPerUnit × mintFeePpm × (E − now) / (1e6 × 604800))     (0 at or after E)
free[msg.sender][asset] += units × collateralPerUnit + refund
series.mintFeesHeld     -= refund
```

Net of the refund the fee is rent on **open interest × time**: the only way to pay less is to keep the pair
open for less time, which is the thing being priced. A market maker's write → buy back → close round trip
costs only the seconds the pair was open, so two-sided quoting stays viable.

**Accrued at `settle`.** Whatever is still held moves to `accruedFees[asset]` and `MintFeesAccrued` is
emitted (log order: `SeriesSettled`, then `MintFeesAccrued` when non-zero, then the SETTLE bounty).
`sweepFees` sends exercise fees and rent together.

**Why a refund can never exceed what is held.** Per unit the refund at `t` is `c·ppm·(E − t)/D` **floored**,
and the fee that unit paid when it was minted at `s ≤ t` is the same expression at `s`, **ceiled** — never
smaller, because rent falls with time and `ppm` is fixed per series. Supply never goes negative, so at every
instant cumulative closes ≤ cumulative mints and every closed unit can be matched with a distinct
earlier-minted one. Summing over the matched units:

```
Σ floored refunds  ≤  Σ exact refunds  ≤  Σ matched exact fees  ≤  Σ ceiled fees  =  mintFeesHeld
```

`close` still clamps the refund to `mintFeesHeld`. The clamp is dead code by the argument above; it is kept
so that `close` can never be blocked if the argument is ever wrong, and
`ClearinghouseMintFeeTest.testFuzz_mintFee_refundsNeverExceedHeld` plus invariant **I7**
([§10](#10-the-invariants-as-asserted)) pin that it never binds.

**Views.** `mintFee(longId, units)` and `closeRefund(longId, units)` answer, base unit for base unit, what
`mint` would charge and `close` would refund in that same block; `closeRefund` is 0 once the series is
settled or at/after expiry and never exceeds `mintFeesHeld`.

**Worked numbers**, at a rate nobody is charged at launch — the dial turned to NVDA's v7 rate of 80
ppm, weekly expiry 2026-10-02, Monday 09:45 roll, 368,100 s left
(`ClearinghouseMintFeeTest.test_mintFee_docsWorkedNumbers`):

| what | amount |
|---|---:|
| 1 unit call, rent | `486_904_761_905` NVDA base units ≈ **107** USDG base units (2.7 % of 3,949 of premium) |
| 100 units call, rent | `48_690_476_190_477` |
| …closed Wednesday 09:45, refund | `25_833_333_333_333` (rent kept `22_857_142_857_144`, ≈ 0.0050 USDG at 218.98) |
| daily rung 1 at 09:45 on expiry day (22,500 s left), 1 unit | `29_761_904_762` ≈ 6.5 USDG base units on 2,404 of premium (0.3 %) |
| 1 unit put, strike 230 (collateral `2_300_000` USDG base units) | `ceil(111.99)` = **112** |

**Who holds ledger headroom.** The MakerVault needs free collateral for rent as well as for collateral: the
MM bot sizes `AskWrite` and `writeToSell` against `free ≥ units × c + mintFee`, which is `units × c`
exactly while the rate is 0 and grows the moment the dial moves. Rent is debited from and
refunded to the Clearinghouse ledger, which the vault's outflow cap deliberately excludes
([§8](#8-fees-the-whole-list)), so minting and closing never move that counter.

---

## 4. The order book

### 4.1 Formulas

For one `take` that fills orders `i` (in the caller's order):

```
premium_i   = price_i × units_i / 100                                   exact on the price grid
premium     = Σ premium_i
takerFee    = min(takerFeeFlat, premium × takerFeeCapBps / 10_000)       once per take call
sellerFee_i = premium_i × (primary_i ? premiumFeeBps : resaleFeeBps) / 10_000
share_i     = takerFee × premium_i / premium                             the last fill: takerFee − Σ earlier shares
rebate_i    = share_i × rebateBps(maker_i) / 10_000                      rebateBps = registry tier, else makerRebateBps
```

A fill is **primary** when its units are minted in the fill: a write-on-fill ask hit by a buyer, or a
sale with `writeToSell`. Resale asks and sales from inventory are not primary.

Primary is decided by how the book delivers the fill, not by where the longs came from
(`OrderBookTakeTest.test_sellerFee_followsTheFill_notWhereTheLongsCameFrom`), and `OrderFilled.primary`
marks exactly those fills. In v6 and v7 that made the premium fee avoidable, because a writer could
`mint` outside the book for nothing and then sell the longs as a resale at `resaleFeeBps`; it is sweep
finding contracts-c05, and the fix chosen for it was first the collateral rent of
[§3.3](#33-collateral-rent-the-writer-fee) and then, in INTERFACE_VERSION 8, closing `mint` itself.
`mint` now reverts `NotMinter` for anyone not on the Clearinghouse's allow-list, and at launch that
list holds the OrderBook alone (`src/v2/Clearinghouse.sol:634`), so there is no route to a long that
does not pass through a fill: 100 units at 2.50 net carol `2_425_000` through her write-on-fill ask,
and bob can only resell longs he bought through a fill that already paid the 5 %. What is left is
writing to yourself through the book — a primary fill of your own `AskWrite` from a second wallet at
the minimum price, then a resale at 0 % — which is an accepted cost, not an open finding
([§8](#8-fees-the-whole-list)).

| Who | Buying take (hits asks) | Selling take (hits bids) |
|---|---|---|
| taker | pays `premium + takerFee` | receives `premium − Σ sellerFee − takerFee` at the recipient |
| each maker | receives `premium_i − sellerFee_i + rebate_i` | receives `rebate_i` (its escrow paid the premium) |
| fee recipient | receives `Σ sellerFee + takerFee − Σ rebate` | same |
| collateral | a primary fill locks the maker's free collateral | `writeToSell` locks the taker's free collateral |

The parameters the registry and the devnet use are premium fee 500 bps, resale fee 0, taker flat
fee `100_000`, taker cap 1000 bps, rebate 5000 bps (`DevDeployTest.test_runWith_wiresTheCoreSet`);
the ceilings are in [§8](#8-fees-the-whole-list). With those numbers the flat fee takes over from the
cap at a premium of 1 USDG: 39, 40 and 41 units at 2.50 pay fees of `97_500`, `100_000` and `100_000`
(`OrderBookTakeTest.test_fees_capAndFlatMeetAtOneUsdgOfPremium`). A take that hits three orders pays
one fee: 300 units at 5.00 pay `100_000` (`OrderBookTakeTest.test_fees_takerFeeChargedOncePerCall`).

### 4.2 Worked example: a micro ticket

bob buys 1 unit (0.01 share) of the NVDA 210 call from carol's write-on-fill ask at 12.50
(`V2DocsNumbersTest.test_docs_orderBookFees_microTicketAndOneShare`, the same trade as `LifecycleTest`'s
first buy).

```
premium        125_000     12_500_000 × 1 / 100                              0.125 USDG
taker fee       12_500     min(100_000, 125_000 × 1000 / 10_000)            the 10 % cap binds
seller fee       6_250     125_000 × 500 / 10_000                           primary: a write-on-fill ask
share           12_500     the only fill takes the whole fee
rebate           6_250     12_500 × 5000 / 10_000

bob pays       137_500     premium + taker fee
carol gets     125_000     125_000 − 6_250 + 6_250
fee recipient   12_500     6_250 + 12_500 − 6_250
carol's collateral   1e16 NVDA base units moved from free to locked
```

### 4.3 Worked example: a one-share ticket across two makers

bob then buys 100 units naming carol's ask (99 units left at 12.50) and alice's ask (13.00): one take,
one taker fee, rebates pro rata by premium (same test; `LifecycleTest`'s third buy).

```
                    carol (99 @ 12.50)   alice (1 @ 13.00)   total
premium               12_375_000            130_000         12_505_000
taker fee                                                       100_000   the flat fee binds
share                     98_960              1_040             100_000   100_000 × 12_375_000 / 12_505_000 floors; alice takes the rest
seller fee               618_750              6_500             625_250   5 %
rebate                    49_480                520              50_000   50 % of each share
maker receives        11_805_730            124_020

bob pays              12_605_000     premium + taker fee
fee recipient            675_250     625_250 + 100_000 − 50_000
```

### 4.4 Worked example: selling into a bid

mm bids 9.00 for 60 units, escrowing `5_400_000`. bob sells 40 units he holds; then carol sells 10
units by writing them (`V2DocsNumbersTest.test_docs_orderBookFees_sellIntoBid`).

```
bob, from inventory (not primary)          carol, writeToSell (primary)
premium        3_600_000                    premium          900_000
taker fee        100_000   flat             taker fee         90_000   10 % cap
seller fee             0   resale fee 0     seller fee        45_000   5 %
rebate to mm      50_000                    rebate to mm      45_000
bob receives   3_500_000                    carol receives   765_000   900_000 − 45_000 − 90_000
fee recipient     50_000                    fee recipient     90_000   45_000 + 90_000 − 45_000
                                            carol's collateral 10e16 NVDA base units locked
bid escrow left: 900_000 (10 units)
```

### 4.5 Conservation per take

Buying: the book pulls `premium + takerFee` and pays
`Σ (premium_i − sellerFee_i + rebate_i) + (Σ sellerFee + takerFee − Σ rebate) = premium + takerFee`.
Selling: the escrow releases `premium` and the book pays
`(premium − Σ sellerFee − takerFee) + Σ rebate + (Σ sellerFee + takerFee − Σ rebate) = premium`.
The book keeps nothing, so its USDG is always exactly open bid escrow plus `Σ owed` (invariant B1).

Two facts make every term non-negative:

- `Σ share_i = takerFee` exactly, because the last planned fill takes the remainder; with a 100 %
  rebate the last maker absorbs the flooring dust, `33_334` in a three-maker take
  (`OrderBookTakeTest.test_rebates_fullRebate_lastMakerAbsorbsRounding_sumIsExactlyTheFee`). So
  `Σ rebate ≤ takerFee`.
- A seller's `Σ sellerFee + takerFee ≤ premium`, because each is at most 10 % of the premium under the
  compiled ceilings ([§8](#8-fees-the-whole-list)).

A fill that fails at execution (a write-on-fill mint the Clearinghouse refuses, a bid maker that rejects
tokens, a delivery that does not complete within its 500,000-gas cap, [V2-ARCHITECTURE.md §6.10](V2-ARCHITECTURE.md#610-makers-that-are-contracts))
is skipped with its state undone; the book re-plans from the next order id and shares the fee over
the fills that went through (`OrderBookTakeTest.test_take_buying_writerRefusingItsShorts_laterAsksFillAsIfItWereAbsent`).
After a skip each rebate is also clamped so the rebates never exceed the taker fee on what actually
filled; invariant B3 checks that on every take (`V2InvariantTest.invariant_book_takesConserveAndRebatesStayUnderTheFee`). The fuzz
suites check conservation on arbitrary takes (`OrderBookFuzzTest.testFuzz_take_buying_conservesValueAndUnits`,
`OrderBookFuzzTest.testFuzz_take_selling_conservesValueAndUnits`).

A payment the book cannot transfer (USDG paused, recipient frozen) is credited to `owed` and withdrawn
later with `claimOwed` (`OrderBookTakeTest.test_owed_makerWhoseUsdgTransferReverts_isCredited`).

---

## 5. Settlement

### 5.1 Per-unit amounts

At settlement price `P` for strike `K`, exercise fee rate `bps` pinned in the series, collateral
`c = collateralPerUnit`:

```
gross (call) = P > K ? UNIT × (P − K) / P : 0          Stock Token base units: (P − K) worth of shares at P
gross (put)  = P < K ? (K − P) / 100 : 0               USDG base units
fee          = gross == 0 ? 0 : min(c × bps / 10_000, gross × 1000 / 10_000)
long         = gross − fee
short        = c − gross
```

A call is paid **in kind**: its gross is the intrinsic value converted into shares at the settlement
price, so it can never exceed the 0.01 share it locked, however high `P` runs.

### 5.2 Conservation per unit

```
long + fee + short = (gross − fee) + fee + (c − gross) = c          exactly, for every input
```

Both subtractions are safe: `fee ≤ gross / 10 ≤ gross`, and `gross ≤ c` (a call's `UNIT × (P − K) / P`
is below `UNIT`; a put's `(K − P) / 100` is at most `K / 100`). Long and short are differences, not
separate divisions, so there is no rounding gap to reconcile (`OptionMathTest.testFuzz_conservation_call`,
`OptionMathTest.testFuzz_conservation_put`). The fee leaves the long's share only: the writer's result does
not depend on the fee rate (`OptionMathTest.test_settlement_callTable`, rows at 0, 25 and 200 bps with the
same short).

### 5.3 Worked example: one expiry, four series

NVDA weekly Friday 2026-09-18, exercise fee 25 bps. The feed prints 221.00 two hours before expiry and
222.40 fifteen minutes before, so the Chainlink TWAP over the window is `221_700_000`; the pool agrees
and the price is final at `E + 120 s` (`V2DocsNumbersTest.test_docs_settlementAndRedemption`,
`LifecycleTest.test_lifecycle_weeklyLadder_callsAndPuts_itmAndOtm`). Per unit:

| Series | gross | fee | long | short | fee leg that binds |
|---|---:|---:|---:|---:|---|
| call 210 (ITM), NVDA base units | 527_740_189_445_196 | 25_000_000_000_000 | 502_740_189_445_196 | 9_472_259_810_554_804 | rate: `1e16 × 25 / 10_000` |
| call 220 (ITM), NVDA base units | 76_680_198_466_396 | 7_668_019_846_639 | 69_012_178_619_757 | 9_923_319_801_533_604 | 10 % of gross |
| call 230 (OTM), NVDA base units | 0 | 0 | 0 | 10_000_000_000_000_000 | none: nothing is charged out of the money |
| put 230 (ITM), USDG base units | 83_000 | 5_750 | 77_250 | 2_217_000 | rate: `2_300_000 × 25 / 10_000` |

Each row adds up to its collateral: `1e16` for the calls, `2_300_000` for the put. The 210 call's gross
is worth `116_999` USDG base units at 221.70, not `117_000`: the division floors against the long
(`V2DocsNumbersTest.test_docs_settlementAndRedemption`).

A final price above `2^128 − 1` is clamped before anything is computed, so a series can always settle
(`ClearinghouseSettleTest.test_settle_hugePriceIsClamped`).

---

## 6. Redemption

### 6.1 What a holder is paid

`redeem(tokenId, holder)` burns the holder's whole balance `b` of that id (at most `2^64 − 1` units per
call; a larger balance takes a second call, `ClearinghouseRedeemTest.test_redeem_extremeSizes`) and pays:

```
long:   owed = b × longPayoutPerUnit        accruedFees[asset] += b × feePerUnit      openInterest −= b
short:  owed = b × shortPayoutPerUnit
value   = put ? owed : owed × P / 1e18                                                 USDG base units at P
```

Where it goes, in order:

1. **An ITM call long converts to USDG** when the holder has not chosen in kind, a payout adapter is
   set, and `minOut ≠ 0`:
   `minOut = owed × floorPrice / 1e18 × (10_000 − min(maxPayoutSlippageBps + routeFee, 300)) / 10_000`, where
   `floorPrice` is the higher of `P` and the series oracle's spot whenever the oracle answers **ok** for it —
   that is, a reading inside the market's own `spotMaxAge` (90,000 s, 25 h, at launch), with the oracle not
   paused and the price non-zero; the Clearinghouse applies no age bound of its own
   (INTERFACE_VERSION 7 dropped it, owner sign-off c01). Without an ok spot it is `P` for the holder, its operator, or any
   caller until `E + 30 min`, and a later third-party
   redemption does not convert (`ClearinghousePayoutTest.test_floorPrice_freshSpotAboveSettlement_valuesThePayoutAtSpot`,
   `ClearinghousePayoutTest.test_floorPrice_freshnessIsTheMarketsSpotMaxAgeAndNothingTighter`,
   `ClearinghousePayoutTest.test_floorPrice_noFreshSpot_lateThirdPartyPaysInKind`). `routeFee` is
   the adapter's `routeFeeBps(asset)`, the route's pool fee in bps rounded up, clamped to 100 and read as 0
   when the read fails (`ClearinghousePayoutTest.test_floor_addsRouteFee`,
   [V2-ARCHITECTURE.md §6.8](V2-ARCHITECTURE.md#68-conversion-slippage-and-who-captures-it)). The
   Clearinghouse approves the adapter for exactly `owed` and has the swap pay the USDG to the Clearinghouse
   itself, then requires that its own Stock Token balance fell by exactly `owed` and its own USDG rose by at
   least `minOut`, and sends that USDG on to the holder's wallet (a ledger holder is credited instead).
   Measured at the holder's wallet, the rise could be the holder's own USDG pushed there during the swap by a
   contract the Clearinghouse does not lock (an expired bid pruned from the OrderBook, a RewardsDistributor
   claim), and the adapter would keep the whole payout (sweep contracts-c30). Anything else, including a
   transfer to the holder that fails, reverts inside a try/catch and the payout falls back to step 2
   (`ClearinghousePayoutTest.test_convert_belowMinOut_paysInKind`,
   `ClearinghousePayoutTest.test_convert_adapterPullsPartially_paysInKind`,
   `ClearinghousePayoutTest.test_convert_adapterPayingWithTheHoldersOwnUsdg_paysInKind`).
2. **Otherwise in kind**: the collateral asset (Stock Token for calls, USDG for puts), to the holder's
   free ledger when it chose `setPayoutToLedger(true)`, else by transfer.
3. **A transfer that fails** (paused token, frozen or blocklisted holder) is credited to the holder's
   free ledger instead. A redemption never reverts because of the recipient
   (`ClearinghouseRedeemTest.test_redeem_pausedUsdgCreditedToLedger`).

A zero balance is a no-op. An out-of-the-money long is burned for 0, with a `Redeemed` log of amount 0,
and pays no fee and no bounty (`ClearinghouseRedeemTest.test_redeem_otmAndAtmCall`).

### 6.2 Conservation over a series

At settlement the series has `N` longs and `N` shorts outstanding ([§3.2](#32-mint-close-and-locked)) and
holds `N × c`. After settlement nothing can mint (the mint cutoff has passed) and nothing can close
(`AlreadySettled`); supplies only fall, by redemptions. Redeeming balances `b_1 … b_k` of the long
(`Σ b = N`) and `d_1 … d_m` of the short (`Σ d = N`) pays out

```
Σ b × (long + fee) + Σ d × short = N × (long + fee + short) = N × c
```

in any order, to the base unit. Until the last holder is redeemed, `locked(longId)` is exactly what the
unredeemed balances are still owed:

```
locked(settled series) = totalSupply(longId) × (long + fee) + totalSupply(shortId) × short
```

Invariant 3 asserts `payouts + fees ≤ held at settlement` and `locked == held − paid` after every call
([§10](#10-the-invariants-as-asserted)); `ClearinghouseRedeemTest.testFuzz_redeem_conservesLocked` fuzzes it.

### 6.3 Worked example: redeeming one-share tickets

Continuing [§5.3](#53-worked-example-one-expiry-four-series): alice wrote 100 units (one share) of each
series; bob holds the 210 call, 230 call and 230 put longs, carol the 220 call longs. The admin has set a
payout adapter with a 100 bps slippage bound that reports a route fee of 0 (this example's adapter; the
launch bound is 30 bps above each route's pool fee,
[V2-ARCHITECTURE.md §6.8](V2-ARCHITECTURE.md#68-conversion-slippage-and-who-captures-it)). Everything below
is asserted by `V2DocsNumbersTest.test_docs_settlementAndRedemption`.

```
210 call, bob's 100 longs, converted to USDG at E + 120 s
  owed                 50_274_018_944_519_600 NVDA base units   100 × 502_740_189_445_196
  value at P                       11_145_749 USDG base units    owed × 221_700_000 / 1e18
  spot                            222_400_000                    the feed's last print, 1_020 s old, above P
  value at the spot                11_180_941                    owed × 222_400_000 / 1e18
  minOut at 100 + 0 bps            11_069_131                    11_180_941 × 9_900 / 10_000
  bob receives                     11_145_749 USDG               the adapter paid a fair rate
  exercise fee accrued  2_500_000_000_000_000 NVDA base units   100 × 25e12, worth 554_250 at P
  keeper bounty                         REDEEM                   value ≥ 1 USDG

210 call, alice's 100 shorts, in kind
  owed                947_225_981_055_480_400 NVDA base units   worth 210_000_000 at P: the strike
  long + fee + short  1_000_000_000_000_000_000                  the 1 NVDA locked

220 call, carol's 100 longs, in kind by preference
  owed                  6_901_217_861_975_700 NVDA base units   worth 1_530_000 at P
220 call, alice's 100 shorts
  owed                992_331_980_153_360_400 NVDA base units   worth 220_000_000 at P: the strike

230 call (out of the money)
  bob's longs                               0                    burned
  alice's shorts    1_000_000_000_000_000_000 NVDA base units   the whole share back

230 put
  bob's longs                       7_725_000 USDG base units
  exercise fee                        575_000
  alice's shorts                  221_700_000
  total                           230_000_000                    the 230 USDG locked
```

A covered-call writer whose call finishes in the money ends with Stock Tokens worth the strike at the
settlement price, give or take the floor: the 210 and 220 shorts above are worth exactly `210_000_000`
and `220_000_000`.

### 6.4 The REDEEM bounty

A redemption pays its caller the REDEEM bounty only when the payout's value at the settlement price is
non-zero and at least `minRedeemPayout` (1 USDG at deploy, `V2DocsNumbersTest.test_docs_contractConstants`).
A put payout just under the threshold pays no bounty, one above it does, and a zero payout never does,
whatever the threshold (`ClearinghouseRedeemTest.test_redeem_bountyThreshold`).
The value of a call payout is taken at the settlement price, not at the conversion's output
(`ClearinghouseRedeemTest.test_redeem_bountyValuesCallsAtSettlementPrice`).

---

## 7. Rounding: every division

| Division | Rounds | In whose favour | Test |
|---|---|---|---|
| `premium = price × units / 100` | exact on the price grid; off the grid it floors once per call | the buyer (never reached: the book refuses off-grid prices) | `OptionMathTest.test_premium_offGridFloorsOncePerCall`, `OptionMathTest.testFuzz_premium_exactOnTickGrid` |
| taker fee cap leg `premium × capBps / 10_000` | floor | the taker | `OrderBookTakeTest.test_fees_microTicket_takerFeeIsTheTenPercentCap` |
| seller fee | floor | the seller | `OrderBookTakeTest.test_sellerFee_primaryVersusResale_buyingAndSelling` |
| taker-fee share `takerFee × premium_i / premium` | floor, last fill takes the remainder | exact in total | `OrderBookTakeTest.test_rebates_fullRebate_lastMakerAbsorbsRounding_sumIsExactlyTheFee` |
| rebate `share × bps / 10_000` | floor | the fee recipient | `OrderBookTakeTest.test_rebates_withoutRegistry_defaultForEveryMaker` |
| put collateral `strike / 100` | exact (strikes are multiples of 100) | — | `OptionMathTest.test_collateralPerUnit_table` |
| call gross `UNIT × (P − K) / P` | floor | the short (the long loses under one base unit per unit) | `OptionMathTest.test_settlement_callTable` (off-grid TWAP row) |
| put gross `(K − P) / 100` | floor | the short | `OptionMathTest.test_settlement_putTable` (off-grid TWAP row) |
| exercise fee, both legs | floor; a gross below 10 base units pays no fee | the long | `OptionMathTest.test_settlement_putTable` ("gross below 10 is fee-free", "gross 10 pays 1") |
| payout value `owed × P / 1e18`, `minOut` | floor | lower floor for the conversion, by under one base unit | `V2DocsNumbersTest.test_docs_settlementAndRedemption` |
| Chainlink TWAP, pool mean tick | floor (the mean tick toward negative infinity) | — | `ChainlinkFeedSourceTest.test_window_severalRounds_handComputed`, `UniV3TwapSourceTest.test_meanTick_halfTicks_floorTowardNegativeInfinity` |
| `adminResolve` band edges (and the Held single-price band `[p × 8_000 / 10_000, p × 10_000 / 8_000]` from `E + 7 days`) | floor | both edges move down by under one base unit | `SettlementOracleResolveTest.test_adminResolve_lowerEdgeAccepted`, `SettlementOracleResolveTest.test_adminResolve_heldSingleSource_widensAfterSevenDays` |
| AutoRoller strike `spot × (10_000 + otmBps) / 10_000` up to the tick; ask `spot × askBps / 10_000` up to 100 | ceiling | the writer: never closer to spot, never cheaper than the strategy | `AutoRollerTimingTest.testFuzz_strikeAndPrice_formula` |
| MakerVault ask floor and bid cap | floor | — | `MakerVaultGuardsTest.testFuzz_askFloor` |
| collateral rent at `mint`, `collateral × ppm × remaining / (1e6 × 604800)` | **ceiling** (under one base unit per call) | the protocol | `OptionMathTest.test_mintFee_table`, `OptionMathTest.test_mintFee_ceilsAnyNonZeroProductToAtLeastOne` |
| the same product refunded by `close` | **floor** | the protocol, which is what keeps `mintFeesHeld` sufficient ([§3.3](#33-collateral-rent-the-writer-fee), invariant 7) | `OptionMathTest.test_mintFee_table` |
| MakerVault `outflow().used`, `refilled / OUTFLOW_WINDOW` | ceiling | the protocol: `available` is never overstated | `MakerVaultOutflowTest.test_outflowCap_refillsLinearly` |

---

## 8. Fees: the whole list

| Fee | Paid by | Base | Formula | Registry and devnet value | Compiled ceiling | Goes to |
|---|---|---|---|---|---|---|
| **collateral rent** (the writer fee of INTERFACE_VERSION 7; in v8 a dial set to 0) | the writer, at `mint` | the collateral the pair locks × the time to expiry | `ceil(units × c × mintFeePpm × (E − now) / (1e6 × 604800))`, refunded `floor(…)` pro rata by `close` — [§3.3](#33-collateral-rent-the-writer-fee) | **0**, on every one of the 35 launch markets and on the default (`ops/markets/tier1.json`, INTERFACE_VERSION 8). A dial, not a charge — [§3.3](#33-collateral-rent-the-writer-fee) | `MINT_FEE_CEIL_PPM` 5000 ppm: 0.5 % of the locked collateral per 7-day `MINT_FEE_PERIOD` of remaining life (`src/v2/interfaces/V2Constants.sol:96-99`) | held in the series, accrues to `accruedFees` at `settle`, then the Clearinghouse fee recipient via `sweepFees` |
| premium fee — **the writer fee from INTERFACE_VERSION 8** | the seller, on primary fills only: an `AskWrite` that is hit, or a `writeToSell` take (`src/v2/OrderBook.sol:861`) | premium of the fill | `premium_i × premiumFeeBps / 10_000` | **500 bps**, 5 % of the premium on first sale (`ops/markets/tier1.json` `v2.fees.premiumFeeBps`). It was 500 bps in v6, 0 in v7, and 500 again in v8 | `PREMIUM_FEE_CEIL_BPS` 1000 bps (`src/v2/interfaces/V2Constants.sol:74-75`) | OrderBook fee recipient — the FeeSplitter at launch — every take |
| resale fee | the seller, on resale fills | premium of the fill | `premium_i × resaleFeeBps / 10_000` | **0**, so a true resale — a market maker's round trip, a holder's early exit — is not taxed | `PREMIUM_FEE_CEIL_BPS` 1000 bps (the same ceiling) | same |
| taker fee | the taker, once per `take` | premium of the whole take | `min(takerFeeFlat, premium × takerFeeCapBps / 10_000)` | `100_000` flat, 1000 bps cap | `1_000_000` flat, 1000 bps cap | same, less rebates |
| maker rebate | paid **to** makers out of the taker fee | each fill's share of the taker fee | `share_i × rebateBps / 10_000` | 5000 bps, or the maker's registry tier | 10_000 bps, the whole share (`OrderBookOrdersTest.test_setFeeParams_onlyAdminAndUnderCeilings`, `MakerRegistryTest.test_setTier_adminOnlyBoundedAndLogged`); never more than the taker fee in total | makers |
| exercise fee | the long holder, from an in-the-money payout | the series' collateral per unit, capped by the gross | `min(c × bps / 10_000, gross × 1000 / 10_000)`, pinned per series | 25 bps | 200 bps, and 1000 bps of the gross | accrues in the Clearinghouse; `sweepFees` sends it to the Clearinghouse fee recipient |

Registry and devnet values: `DevDeployTest.test_runWith_wiresTheCoreSet`. Ceilings:
`InterfaceIdsTest.test_constants_feeCeilings`. The production values are set at deploy from the
registry and can be changed by the admin under the ceilings
([V2-ARCHITECTURE.md §2.2](V2-ARCHITECTURE.md#22-every-admin-power-and-its-worst-case)). The book's fee
parameters (premium, resale, taker flat, taker cap, rebate) change `FEE_CHANGE_DELAY` after they are
scheduled on the book — **48 hours**, raised from 24 h by INTERFACE_VERSION 8
(`src/v2/interfaces/V2Constants.sol:60`), with another 48 h of `FEE_MANAGER` delay on the manager
before the schedule is even made: `OrderBook.pendingFeeParams()` shows it until then, and every take,
resting orders included, pays the fees in effect in its block
(`OrderBookFeeDelayTest.test_take_restingOrders_payOldFeesBeforeEffectiveAt_newFeesFromIt`). The exercise
fee is pinned per series when the series is created.

**Why the premium fee is back, and 5 %.** The v6 premium fee was charged only on primary fills, so a
writer who minted outside the book and resold the long never paid it: write into a one-tick bid of a
second address of your own, then sell the long as a resale. v7 answered by moving the writer fee to the
collateral rent of [§3.3](#33-collateral-rent-the-writer-fee), whose base contains nothing the writer
chooses except size and tenor. INTERFACE_VERSION 8 answers the same hole at its root instead: `mint` is
gated by the Clearinghouse's minter allow-list and the OrderBook is the only minter at launch
(`src/v2/Clearinghouse.sol:634`, `script/v2/roles.v8.json:167-169`), so every long that exists was
created inside a fill with a known premium and there is no un-sold, un-charged inventory to launder.
The writer therefore pays 5 % of the premium on the first sale and nothing per unit of time, and true
resales stay at 0.

**What still dodges it, accepted.** A writer can fill its own `AskWrite` from a second wallet at the
minimum price and resell at 0 %. That is an owner decision to leave open (V3-D18) rather than a gap
nobody noticed: it costs the protocol only the 5 % on writers who bother, the taker and exercise fees
are unaffected, and the protocol's own MakerVault and AutoRoller writers cannot do it. The pattern — a
minimum-price primary fill, then a resale of the same units from a linked wallet — is meant to be
flagged by the indexer so it can be measured.

**The deploy guard is inverted from v7, and the inversion has landed.** v7's shape was premium 0,
resale 0, rent non-zero, and three layers of tooling enforced exactly that: a `premiumFeeBps <=
resaleFeeBps` rule and a refusal of any market whose `mintFeePpm` was 0. Both are now gone. The
rule is deleted in the deploy library (`script/v2/lib/V2DeployBase.sol:842`, whose comment says so
in as many words), the verifier records the deletion (`script/v2/VerifyV8.s.sol:89`), and the
wrapper says the same (`script/v2/DeployV2Batch.sh:16`, `:314`). The rent refusal is inverted rather
than deleted: 0 is the launch value and a **non-zero** rent is what a run refuses unless
`--allow-rent` is passed with `--dry-run` (`script/v2/DeployV2Batch.sh:442-446`,
`script/v2/batch-refusals.sh:161`). The v8 shape — premium 500, resale 0, rent 0 — is what the
tooling now expects.

**Never charged:**

- deposits, withdrawals and ledger credits;
- `close` beyond what it refunds — it never takes anything, and it is never pausable;
- ERC-1155 transfers;
- placing, replacing, cancelling or pruning an order; `claimOwed`;
- settlement and redemption themselves: an out-of-the-money long and every short pay no fee;
- the USDG conversion: the protocol takes nothing, the holder bears only the pool's price for the swap,
  bounded by the slippage limit above the pool's fee (30 bps at launch,
  [V2-ARCHITECTURE.md §6.8](V2-ARCHITECTURE.md#68-conversion-slippage-and-who-captures-it));
- the AutoRoller: its asks pay the book's fees when they fill, like any maker's;
- keeper bounties: paid from the KeeperRewards budget (treasury money), never from users.

---

## 9. Keeper bounties

```
paid = min(bounty(action), dailyCap − spentToday, KeeperRewards USDG balance)       0 pays nothing, never reverts
```

| Action | Paid by | Eligible when | Test |
|---|---|---|---|
| SNAPSHOT | SettlementOracle | a source recorded for the first time in the call, the expiry has open interest, and the current Clearinghouse pinned it on this oracle | `SettlementOracleBountyTest.test_snapshotBounty_paidOnceWithOpenInterest` |
| FINALIZE | SettlementOracle | the call advanced the expiry (capture, upgrade, candidate or final), with open interest, on an expiry the current Clearinghouse pinned on this oracle; never when the caller is the Clearinghouse, or a contract whose pin a later Clearinghouse confirmed (an old Clearinghouse after a migration) | `SettlementOracleBountyTest.test_finalizeBounty_paidPerAdvance`, `SettlementOracleBountyTest.test_finalizeBounty_notPaidToClearinghouse`, `SettlementOracleBountyTest.test_bounty_notPaidOnAnExpiryTheClearinghouseDidNotPinHere`, `SettlementOracleBountyTest.test_bounty_neverPaidToAClearinghouseThePinMovedFrom` |
| SETTLE | Clearinghouse | the series settled in the call, has long supply, and its collateral valued at the settlement price is non-zero and ≥ `minRedeemPayout` (the REDEEM threshold, so a dust series cannot farm the shared cap) | `ClearinghouseSettleTest.test_settle_zeroSupplyPaysNoBounty`, `ClearinghouseSettleTest.test_settle_bountyNeedsTheSeriesWorthMinRedeemPayout` |
| REDEEM | Clearinghouse | payout value ≥ `minRedeemPayout` and > 0 | `ClearinghouseRedeemTest.test_redeem_bountyThreshold` |
| ROLL | AutoRoller | the roll placed at least `minRollUnits` | `AutoRollerStrategyTest.test_bounty_belowMinRollUnits_placesWithoutBounty` |
| CANCEL_STALE | AutoRoller | `cancelStale` actually cancelled a tracked live ask the market had reached, and the cancelled remainder is at least `minRollUnits`. At most one per position per period, so at most one per ROLL (added in INTERFACE_VERSION 7) | `AutoRollerStaleTest` |

The cap is a rolling window in 6-hour epochs: a payment counts in its own epoch and the four after it,
so no 24-hour interval pays more than `dailyCap`, and capacity comes back between 24 and 30 hours after
a payment (`KeeperRewardsTest.test_cap_epochsReleaseOneAtATime`). With a cap of 1 USDG and a bounty of
`400_000`, three calls pay `400_000`, `400_000` and `200_000`, and the fourth pays 0 without reverting
(`KeeperRewardsTest.test_cap_clampsLastPaymentThenStops`). With a budget of `70_000` and a bounty of
`50_000`, the second call pays the `20_000` left (`KeeperRewardsTest.test_reward_partialBudget`).

The devnet funds 1_000 USDG with a 100 USDG daily cap and bounties of `50_000` (SNAPSHOT, FINALIZE,
SETTLE, ROLL) and `20_000` (REDEEM, CANCEL_STALE) (`DevDeployTest.test_runWith_wiresTheCoreSet`). The launch
values are the same six (`V2DeployBase.LAUNCH_BOUNTY_*`). Bounties are meant
to cover gas, not to be income.

---

## 10. The invariants, as asserted

`test/v2/invariant/V2Invariant.t.sol` asserts these after every call of the handler
(`test/v2/invariant/V2Handler.sol`), on the real contracts, 256 runs × 64 calls per invariant. Formulas
are what the code checks.

```
1. unsettled series are fully backed                    invariant_1_unsettledSeriesAreFullyBacked
   for every unsettled series:
     totalSupply(longId) == totalSupply(shortId)
     locked(longId)      == totalSupply(longId) × collateralPerUnit(longId)
   for every expiry: openInterest(nvda, expiry) == Σ totalSupply(longId) over its series

2'. the Clearinghouse holds every claim                 invariant_2_clearinghouseHoldsEveryClaim
   per asset (USDG, NVDA):
     accruedFees + Σ free (every account) + Σ locked (every series of that asset)
       + Σ mintFeesHeld (every UNSETTLED series of that asset)     [the v7 term: collateral rent taken
                                                                   and not yet refunded or accrued]
       == token.balanceOf(Clearinghouse)                (the spec asks <=; equality holds)
     token.balanceOf(Clearinghouse) == ghost deposits − ghost withdrawals, payouts and sweeps

3. settled series pay no more than they held           invariant_3_settledSeriesPayNoMoreThanTheyHeld
   for every settled series:
     long + fee + short == collateralPerUnit
     paidOut <= lockedAtSettle
     locked(longId) == lockedAtSettle − paidOut
   and every redemption paid exactly balance × per-unit amount

4. exits are never blocked, and gates hold             invariant_4_exitsNeverBlockedAndGatesHold
   the handler predicts success or revert for every call; unexpected reverts == 0 and
   unexpected successes == 0, under every pause flag, oracle fault and USDG pause or freeze

5. only the owner moves its funds                      invariant_5_onlyTheOwnerMovesItsFunds
   no call changes another account's wallet, ledger or tokens, except a take spending exactly the
   collateral of that account's filled write-on-fill asks, and a redemption that pays it

6. expiries settle on their pinned configuration       invariant_6_expiriesSettleOnTheirPinnedConfiguration
   while the admin re-points market, feed and pool mid-life, takes the oracle off a source's allow-list,
   and pre-pins expiries through the Clearinghouse pointer and the source allow-lists (29 handler actions):
   for every listed expiry
     settlementConfig(nvda, expiry).pinned, pinnedBy(nvda, expiry), each source's pinned feed / pool
                                    == the handler's model of every pin, pre-pins included
   for every expiry a series creation pinned or confirmed
     settlementConfig(nvda, expiry) == (pinned, the sources, deviation and delay in force at that creation)
     recordedSources(nvda, expiry)  == those sources and that deviation, once captured
     settlementPrice ∈ [190, 250] USDG when market, feed and pool were all honest at the pin (every
       replacement prices NVDA at 400)
   for every series on the oracle
     its expiry is pinned on the oracle and on every real source of the pinned list

7. held rent always covers every refund it owes        invariant_7_heldRentAlwaysCoversEveryRefundItOwes
   (added in INTERFACE_VERSION 7, the matching proof of §3.3)
   for every unsettled series:  mintFeesHeld >= closeRefund(longId, totalSupply(longId))
   for every settled series:    mintFeesHeld == 0
   so the clamp inside close() never binds, and no close can be blocked for want of held rent

B1. book USDG                                          invariant_book_usdgIsBidEscrowPlusOwed
   usdg.balanceOf(book) == Σ price × (units − filled) / 100 over open bids + Σ owed

B2. book longs                                         invariant_book_longsAreResaleEscrow
   balanceOf(book, longId) == Σ (units − filled) over open resale asks; balanceOf(book, shortId) == 0;
   nvda.balanceOf(book) == 0

B3. takes conserve                                     invariant_book_takesConserveAndRebatesStayUnderTheFee
   per take: Σ rebates <= taker fee; fills add up to the take's units and premium; the book pays out
   exactly what it takes in
```

`V2InvariantTest.test_handler_walkReachesEveryStage` shows the handler reaches every stage these
invariants are about, with no reverted call.

---

## 11. Reproducing every number

```bash
forge test --match-contract V2DocsNumbersTest -vv                 # §3, §4.2-4.4, §5.3, §6.3, §6.4, fee constants
forge test --match-contract LifecycleTest -vv                     # the same trades and prices inside a whole ladder
forge test --match-contract OptionMathTest -vv                    # §2, §3.1, §5.2, §7
forge test --match-contract OrderBookTakeTest -vv                 # §4.1, §4.5, §7
forge test --match-contract KeeperRewardsTest -vv                 # §9
forge test --match-contract V2InvariantTest                       # §10
forge test --match-contract "InterfaceIdsTest|DevDeployTest" -vv  # units, ceilings, registry values
```
