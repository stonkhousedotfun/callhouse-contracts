# v2 gas

Gas of every user and keeper entry point of the v2 core: `Clearinghouse`, `OrderBook`,
`SettlementOracle` over `ChainlinkFeedSource` and `UniV3TwapSource`, and `KeeperRewards`. All of
them are the real contracts, wired as `script/v2` will deploy them. The code is **unaudited**: no
external audit report exists at this commit, and this repository links to none.

## How the numbers are made

Every number below comes from a named test and can be reproduced with one command:

```bash
forge test --match-path test/v2/integration/V2Gas.t.sol -vv      # prints "gas | <what> | <gas>"
FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --match-path test/v2/fork/V2Fork.t.sol -vv
```

- Each figure is `vm.lastCallGas().gasTotalUsed` for one top-level call. `foundry.toml` sets
  `isolate = true`, so that call runs as its own transaction. The figure is what the transaction
  is charged on chain.
  - It **includes** the 21,000 intrinsic gas and the calldata. `test_gas_calibration` shows this
    with `setOperator` on a fresh slot: 46,880 = 21,000 intrinsic + about 600 calldata + about
    25,000 execution (one 22,100 SSTORE and a log).
  - It is **net of** the EIP-3529 refund, which is capped at 1/5 of the gas spent. This is why
    closing a whole position (60,948) costs less than closing part of one (76,184).
- Fixture (`V2IntegrationBase`): mock USDG and NVDA tokens, `MockRoundFeed` and `MockUniV3Pool`
  behind the real sources, KeeperRewards bounties set. Every write says whether storage is cold
  (first order, first balance) or warm (repeat). On chain the tokens, feed and pool are the live
  contracts, so token transfers and the feed walk can cost a little more; the fork rows show real
  figures.
- Each assertion ceiling in `V2Gas.t.sol` is loose. It only catches regressions.
- The "Source" column gives the test that logs the number. All tests are in
  `test/v2/integration/V2Gas.t.sol`, except the fork rows (`test/v2/fork/V2Fork.t.sol`).
- **Every cell below was measured against the INTERFACE_VERSION 8 contracts** on the C8-09c tree
  (`forge test --match-path test/v2/integration/V2Gas.t.sol -vv`). The source column names the
  `V2GasTest` method that printed the row. Privileged setters go through the `AccessManager`;
  `mint` reads the minter allow-list; the OrderBook's discount module and pre-fund stage are
  unconfigured at launch, so those seams cost only the empty checks / one `_funding` SLOAD per
  named order. Re-run the command above before relying on a figure after a later wiring change.

## Clearinghouse

| Operation | Case | Gas | Source |
|---|---|---:|---|
| `mint` | call, first supply of the series, receivers' first balances | 190,523 | `test_gas_mint` |
| `mint` | call, repeat | 87,923 | `test_gas_mint` |
| `mint` | put (USDG collateral), first supply of the series | 158,465 | `test_gas_mint` |
| `close` | part of a position | 76,212 | `test_gas_close` |
| `close` | whole position (balances and supply to zero, refund) | 60,970 | `test_gas_close` |
| `deposit` | USDG, repeat depositor | 58,516 | `test_gas_depositWithdraw` |
| `withdraw` | USDG | 52,708 | `test_gas_depositWithdraw` |
| `createSeries` | new series, the first of its expiry: pins the settlement configuration on the oracle and both sources (strike band read through `oracle.trySpot`) | 348,065 | `test_gas_createSeries_firstAndLaterOfAnExpiry` |
| `createSeries` | new series of an expiry already pinned by this Clearinghouse (`pin` returns at once) | 166,534 | `test_gas_createSeries_firstAndLaterOfAnExpiry` |
| `createSeries` | new series of an expiry already pinned, another strike | 166,522 | `test_gas_ladderCreate` |
| `createSeries` | existing id (no-op, calls nothing) | 28,160 | `test_gas_ladderCreate` |
| `settle` | oracle already final, + SETTLE bounty | 135,560 | `test_gas_snapshotFinalizeSettle` |
| `settle` | finalizes a due candidate inside `settle`, + SETTLE bounty | 173,051 | `test_gas_finalizeCandidate_settleFinalizesInside` |
| `settle` | already settled (no-op) | 27,295 | `test_gas_snapshotFinalizeSettle` |
| `redeem` | ITM call long, in kind to the wallet, + REDEEM bounty to a keeper with no USDG yet | 169,860 | `test_gas_pruneRedeem` |
| `redeem` | call short, in kind to the wallet, + REDEEM bounty | 122,596 | `test_gas_pruneRedeem` |
| `redeem` | put short, USDG to the wallet, + REDEEM bounty | 113,641 | `test_gas_pruneRedeem` |
| `redeem` | ITM call long, to the holder's ledger (payout worth 0.765 USDG: no bounty) | 73,683 | `test_gas_pruneRedeem` |
| `redeem` | OTM put long, zero-value burn, no bounty | 57,759 | `test_gas_pruneRedeem` |
| `redeemBatch` | 1 holder (call short, + REDEEM bounty) | 120,567 | `test_gas_pruneRedeem` |
| `redeemBatch` | 5 holders (ITM call longs in kind; payouts under the bounty threshold) | 202,320 | `test_gas_pruneRedeem` |
| `sweepFees` | NVDA | 68,283 | `test_gas_pruneRedeem` |

**Pinning (added in INTERFACE_VERSION 6).** The first series of an expiry pays for the settlement pin: the
oracle stores its copy of the source list and parameters (4 fresh slots with two sources; the pinning
Clearinghouse, `pinnedBy`, is packed into the parameters' slot) and logs `SettlementConfigPinned`, the
Chainlink source stores 1 slot and the pool source 2, each with a log and each answering the pin
selector, which the oracle checks. On this fixture that is 348,661 against 155,567 before pinning
(+188,308); every later series of the expiry pays one call that returns after two storage reads (the
caller check, then the slot holding `pinnedBy`), 162,168 against 155,579 (+6,589). Measured before
pinning with the same test on `1e2ef6c`. Making pinning fail closed (`pinnedBy`, the answer check, the
equality checks) moved these from 343,335 and 161,989 on `d341777` (+540 and +179). A series of an expiry
pinned by ANOTHER Clearinghouse (a migration, or a pin made outside a series creation) also compares the
pinned copy with the market's and asks every source to confirm, once, before `pinnedBy` moves (and marks the
previous `pinnedBy`, which the oracle then never pays a bounty while it is a contract). The AutoRoller's first roll into an expiry creates
its first series, so it carries the same cost (`AutoRollerCycleTest.test_gas_rollAndCloseOut` logs
it).

The plan's targets are `mint` ≤ 200k and `redeem` without conversion ≤ 120k. The worst mint is
180,616. A redeem without a bounty stays well under 120k. A redeem that also pays a bounty can go
over 120k: the bounty is a USDG transfer by KeeperRewards (C2-05 reported the same). Converting a
payout to USDG (C2-10) is not measured here.

## OrderBook

| Operation | Case | Gas | Source |
|---|---|---:|---|
| `place` | AskWrite, maker's first order | 216,049 | `test_gas_place` |
| `place` | AskWrite, repeat | 164,749 | `test_gas_place` |
| `place` | Bid (USDG escrow pulled) | 242,838 | `test_gas_place` |
| `place` | AskResale (ERC-1155 escrow pulled) | 217,572 | `test_gas_place` |
| `replace` | AskWrite, new price | 167,541 | `test_gas_replace` |
| `cancel` | AskWrite | 31,938 | `test_gas_cancel` |
| `cancel` | Bid (USDG refund) | 50,079 | `test_gas_cancel` |
| `cancel` | AskResale (ERC-1155 refund) | 66,523 | `test_gas_cancel` |
| `take` | buy, 1 AskWrite (mint on fill) | 225,153 | `test_gas_take_oneAndFiveOrders` |
| `take` | buy, 5 AskWrite from 5 makers | 508,383 | `test_gas_take_oneAndFiveOrders` |
| `take` | buy, 1 AskResale | 134,142 | `test_gas_take_oneAndFiveOrders` |
| `take` | buy, 5 AskResale from 5 makers | 308,111 | `test_gas_take_oneAndFiveOrders` |
| `take` | sell into 1 Bid from inventory | 159,205 | `test_gas_take_oneAndFiveOrders` |
| `take` | sell into 5 Bids from inventory | 304,055 | `test_gas_take_oneAndFiveOrders` |
| `take` | sell into 1 Bid by writing (`writeToSell`) | 223,687 | `test_gas_take_oneAndFiveOrders` |
| `take` | sell into 5 Bids by writing (`writeToSell`) | 381,566 | `test_gas_take_oneAndFiveOrders` |
| `take` | buy 1 unit of an AskWrite, buyer's first long | 327,753 | `test_gas_takeTicketSizes` |
| `take` | buy 100 units of the same AskWrite, repeat buyer | 208,113 | `test_gas_takeTicketSizes` |
| `prune` | 1 AskResale (ERC-1155 refund) | 52,122 | `test_gas_pruneRedeem` |
| `prune` | a Bid (USDG refund) and an AskWrite (no escrow) | 59,916 | `test_gas_pruneRedeem` |

A buyer's first take costs more (327,753 for 1 unit, against 208,113 for 100 units later). The
first take creates the buyer's long balance, the writer's short balance and the series supply.
The unit count barely matters.

Every delivery the book catches (a write-on-fill mint, a sale into a bid from inventory or by
writing, a resale refund in `prune`) runs with at most 500,000 gas, the receivers' acceptance hooks
included (`OrderBook.DELIVERY_GAS`). A maker whose hook burns all the gas it is given therefore adds at
most 500,000 per order of it that a take or a prune batch names, and the call goes on without it: a
take naming two such orders next to an honest one fills within 2,000,000 gas, and a prune batch
within 1,500,000 (`OrderBookTakeTest.test_take_buying_writerBurningAllHookGas_costsAStipendPerAsk_laterAsksFill`,
`OrderBookTakeTest.test_take_selling_bidMakerBurningAllHookGas_costsAStipendPerBid_laterBidsFill`,
`OrderBookOrdersTest.test_prune_makerBurningAllHookGas_costsAStipendPerOrder_othersPruned`). Honest
receivers whose hooks spend 100,000 gas each still fill
(`OrderBookTakeTest.test_take_receiversSpendingHonestHookGas_stillFill`).

The fixture sets no maker registry. With one set, every fill also reads `rebateBps` with at most
30,000 gas and copies one word of the answer, so a registry that burns its gas or answers at length
adds at most 30,000 per fill (`OrderBookTakeTest.test_rebates_registryBurningGasOrAnsweringHugeData_costsACapPerFill`).
Making that read a capped raw call re-measured every take row 52 to 156 gas lower, and `cancel` and
`prune` of a Bid 26 lower.

## The collateral-rent dial, the outflow cap, the stale cancel (INTERFACE_VERSION 8: rent launches at 0)

The `V2Gas` fixture registers NVDA at `mintFeePpm` **0**, so every figure above is the "no rent" case
and is directly comparable with v6. From INTERFACE_VERSION 8 that is also the **launch** case: the rent
rate is 0 on every market and on the default, with the rent kept as a dial
([V2-ACCOUNTING.md §3.3](V2-ACCOUNTING.md#33-collateral-rent-the-writer-fee)). So the table above is
what a production market costs today, and the rows below are what turning the dial on would add. They
re-run the same calls at **80 ppm**, NVDA's v7 rate (`test_gas_*_withRent`, same file).

| Operation | Case | No rent | With rent (80 ppm) | Delta |
|---|---|---:|---:|---:|
| `mint` | call, first supply of the series | 190,523 | 193,996 | +3,473 |
| `mint` | call, repeat | 87,923 | 91,396 | +3,473 |
| `mint` | put, first supply of the series | 158,465 | 161,938 | +3,473 |
| `close` | part of a position | 76,212 | 79,902 | +3,690 |
| `close` | whole position | 60,970 | 63,922 | +2,952 |
| `createSeries` | first of an expiry (a 0 → non-zero SSTORE on the appended slot) | 348,065 | 367,965 | +19,900 |
| `createSeries` | later of the same expiry | 166,534 | 186,434 | +19,900 |
| `take` | buy 1 unit of an AskWrite, buyer's first long | 327,753 | 331,301 | +3,548 |
| `take` | buy 100 units, repeat buyer | 208,113 | 211,661 | +3,548 |
| `settle` | + SETTLE bounty, rent held, accrues and emits `MintFeesAccrued` | 135,664 | 162,682 | +27,018 |

At a non-zero rate the rent costs a minting call about 3.5k (the maths, the appended-slot write and one
more event word) and a close about 3k, well inside `OrderBook.DELIVERY_GAS` (500,000) — a first mint on fresh balances uses about
167k of it. `createSeries` pays 19.9k once per series for the zero-to-non-zero write of the appended slot;
that is the price of **appending** `mintFeePpm` and `mintFeesHeld` to `Series` instead of packing them into
an existing slot, which was chosen deliberately so a v6 positional decoder still reads the first eleven
fields correctly (`ops/v2/monitor.mjs` holds a hand-written `series()` ABI). The `settle` delta is the
accrual plus the new event; it is larger here because that call also warms `accruedFees[asset]`.

### AutoRoller

| Operation | Case | Gas | Source |
|---|---|---:|---|
| `cancelStale` | cancels the ask and pays the `CANCEL_STALE` bounty | 182,061 | `AutoRollerStaleTest.test_gas_cancelStale` |
| `cancelStale` | cancels with no rewards contract wired (no bounty) | 135,193 | same |
| `cancelStale` | no position for that writer: the early `false` | 30,292 | same |

The keeper budgets `GAS.cancelStale = 350,000`, which the worst case above sits comfortably inside. The
early-false figure is what a cranker pays per writer it checks and finds nothing to do for, so a loop over
a few dozen writers is cheap. `roll` gains roughly 10-13k when it places (the `seriesExists` +
`mintFee` reads that size it net of rent, and one or two extra `isRegularSession` calls for the open
grace); `reprice` gains about 16k for the one `series()` read that refuses an in-the-money ask.

### MakerVault

| Operation | Case | Gas | Source |
|---|---|---:|---|
| `place` | Bid: booked and enforced against the outflow cap | 489,064 | `MakerVaultOutflowTest.test_gas_outflowBookedCalls` |
| `place` | AskWrite: not booked | 267,634 | same |
| `cancel` | a Bid: booked, never enforced (a cancel can never be blocked) | 138,396 | same |
| `cancel` | an ask: not booked | 95,604 | same |

These are absolute costs, not four measurements of the booking: a bid escrows USDG and an ask does not, so
most of the gap between the two `place` rows is the escrow. What the booking itself adds to a booked call
is two `_cash()` reads (`usdg.balanceOf` + `orderBook.owed`) and the single slot that the level and its
timestamp share — roughly 18-25k. Every unbooked call (`close`, `depositToClearinghouse`,
`withdrawFromClearinghouse`, `claimOwed`, `sync`, `refreshApprovals`, `deposit`, `withdraw`,
`withdrawPosition`, and every ask) pays nothing at all for the cap, which is why the unwinding path is
never slowed by it and why a cap of 0 is a spend freeze rather than a lock.

## SettlementOracle

| Operation | Case | Gas | Source |
|---|---|---:|---|
| `snapshot` | pool source records the window, + SNAPSHOT bounty | 189,745 | `test_gas_snapshotFinalizeSettle` |
| `snapshot` | repeat (nothing new) | 50,613 | `test_gas_snapshotFinalizeSettle` |
| `finalize` | first capture of both sources, corroborated, + FINALIZE bounty | 280,986 | `test_gas_snapshotFinalizeSettle` |
| `finalize` | first capture, Chainlink only, uncorroborated candidate announced, + bounty | 317,745 | `test_gas_finalizeCandidate_settleFinalizesInside` |
| `finalize` | candidate still inside its delay | 50,165 | `test_gas_finalizeCandidate_settleFinalizesInside` |
| `finalize` | already final | 24,852 | `test_gas_snapshotFinalizeSettle` |
| `finalize` | **live 4663 fork**: capture over the real NVDA feed walk + the pool snapshot, corroborated, + bounty | 353,177 | `test_fork_callSeries_settlesOnRealHistory_twoSourcesCorroborate_payoutsConserve` |
| `settle` | **live 4663 fork**: oracle already final, + SETTLE bounty paid in real USDG | 140,956 | `test_fork_callSeries_settlesOnRealHistory_twoSourcesCorroborate_payoutsConserve` |

The two fork rows were measured on 2026-09-17 against block time 1789631087, before the SETTLE bounty
threshold (sweep contracts-c02) added about 600 gas to a settle that pays (575 on the mock fixture). They settled the
2026-09-16 16:00 New York close: feed TWAP 213.748012, pool 213.969687, 10.4 bps apart. Live gas
moves with the number of feed rounds printed after the close. The feed walk is capped at 96
reads; `test_fork_96ReadWalkGas` in `test/v2/fork/SourcesFork.t.sol` measures the longest walk
(661k in C2-03). A keeper that snapshots and then finalizes one expiry in the normal flow pays
189,767 + 280,948 = 470,715 on the mock fixture. Reading an expiry's pinned configuration costs the
settlement path a few thousand gas (snapshot +2,780, first finalize +764 against `1e2ef6c`). The snapshot row is 404 higher since
`MockUniV3Pool` models the observation ring (sweep contracts-c10): the mock checks the ring's depth on each
`observe`, and the contracts did not change. Every row that pays a SNAPSHOT or FINALIZE bounty is then 445 higher
(the fork rows predate it and would be about as much higher): the oracle checks that the current Clearinghouse
pinned the expiry and that a contract caller is not an earlier Clearinghouse (sweep contracts-c11).
