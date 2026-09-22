# v2 flywheel route spike (C3-602)

Date: 2026-09-19. Board task C3-602, plan `stonkhouse-plan/six-features/F6-buybackburn.md`.

This is a fork measurement of the approved buy-and-burn route on chain 4663. Nothing here was sent
to the real chain. Caps, cadence, the 2.5 % threshold and every other number labelled "proposal"
are still proposals for owner question Q6.4. They are not approvals.

Route: USDG -> WETH on the Uniswap v3 USDG/WETH 0.01 % pool -> unwrap to ETH -> STONKHOUSE through
the pinned Uniswap v4 launch PoolKey -> `burn(uint256)` of everything bought.

## How the numbers were made

- Suite: `test/v2/fork/FlywheelRouteFork.t.sol`, 9 tests. A test-only contract in that file,
  `FlywheelRouteBuyer`, is the direct caller. It has the shape the proposed `V4BuybackExecutor`
  (C3-604) would take: `pool.swap` with a v3 callback, `WETH.withdraw`, `PoolManager.unlock` with
  sync/settle/take on one immutable PoolKey (or the UniversalRouter with the same explicit key),
  then `burn` with a supply-delta check. It is not production code.
- Fork block: **67,296,505**, timestamp **1789842461 (2026-09-19 18:27:41 UTC)**, base fee
  66,826,000 wei (0.066826 gwei). The public RPC keeps no historical state, so the block was the
  latest one when the runs started.
- Command (exit 0, 9 passed, 0 failed, 0 skipped). It was run three times at the same block; every
  amount record the runs share is identical (the 1,000 USDG front-run rows were added after the
  first run):

  ```bash
  FOUNDRY_PROFILE=fork forge test --fork-url https://rpc.mainnet.chain.robinhood.com \
    --fork-block-number 67296505 --match-path "test/v2/fork/FlywheelRouteFork.t.sol" -vv
  ```

- Every size runs from a fresh `vm.snapshotState()` and is reverted afterwards. USDG is given to
  the caller with `deal`. The seller in the shallow-liquidity test gets STONKHOUSE with `deal`.
- Each fill asserts: `totalSupply` fell by exactly the tokens bought, the caller holds no USDG,
  WETH, ETH or STONKHOUSE afterwards, the hook's token balance rose by exactly its fee plus the
  creator tax, and the slot0 and liquidity of all 11 other pools of the token are unchanged.
- Loss is measured against the "two-mid value": USDG converted at the v3 pool's pre-trade mid,
  then at the v4 pool's pre-trade mid. ppm = parts per million; 10,000 ppm = 1 %.
- Gas per leg is a `gasleft()` difference inside the caller. "Tx total" is
  `vm.lastCallGas().gasTotalUsed` for the whole call run as its own transaction (`isolate = true`).
  It includes the 21,000 intrinsic gas and calldata and is net of refunds, as in
  `docs/V2-GAS.md`. It does not include any L1 data fee.
- Without a fork the 9 tests log and return, like the other fork suites. In the default
  `forge test` they pass without exercising anything.

## Addresses and code at the fork block

| Role | Address | Code size | Runtime code hash | How it was found |
|---|---|---:|---|---|
| USDG (proxy) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 170 | `0x864cc9ad53b338b82da1f7cab85ab0b3d5c8861acb422b6fec63cf36234f36a6` | registry `tier1.json` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | 2,202 | `0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353` | `SwapRouter02.WETH9()`, `QuoterV2.WETH9()` |
| STONKHOUSE | `0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4` | 3,248 | `0xa7fd544723886536ec0b8c5c20dbc45fb9f455113a147e32c7df57f17c4aab44` | plan |
| Uniswap v3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | 24,535 | `0xec72b1abd1f2faee020cfea9c646bd8994f9fb389054f6e574f103a895091739` | existing fork suites |
| v3 USDG/WETH 0.01 % pool | `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` | 22,142 | `0x3298b5dd4e6f115074c526a55ad05a36fd73a0034ac22ec6cbaab32cc9c1e8d2` | `factory.getPool(USDG, WETH, 100)` (asserted) |
| v3 QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` | 8,273 | `0x3db0868d945e9304c9bc6a8b2181948109ea617647142f3c4083e14393496a28` | existing fork suites |
| v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | 24,009 | `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626` | `hook.poolManager()` (asserted) |
| v4 StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` | 3,531 | `0x7d9c591e0956fd89d98feb4ffcfe8bf1f7a62bd485edd979fa21d104b49878a6` | venue recon 2026-09-17; `poolManager()` asserted |
| V4Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` | 6,118 | `0xd707b1da8cb165e5ea35a3b4450d971eb562ec171e23492aa117036b78a868f6` | venue recon; `poolManager()` asserted |
| UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | 24,546 | `0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde` | venue recon; exercised below |
| v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | 23,877 | `0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2` | sender of the pool's only `ModifyLiquidity` |
| Hook (PonsV2MemeHook) | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` | 15,167 | `0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db` | `Initialize` log of the pool id; Sourcify match (not exact: metadata hash differs, runtime bytes identical; T-OP-021), solc 0.8.35 |
| LP locker (RobinFunFiV2LaunchLocker) | `0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952` | 1,969 | `0x58455f80b3773871d601a025e56ec27c71ab3bbb8e2ca6b17828954450742025` | `PositionManager.ownerOf(2761804)`; Sourcify match |
| Pons v2 factory | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` | 24,177 | `0x89a27da6f703e0a7cdd4f233e7cb57604ff75b164530962d3ff7cf8483a67d84` | `hook.factory()` (asserted) |
| v4 protocol fee controller | `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` | 4,544 | `0xbdcdeb746a517e01700054c75399892be3c8276d5a65a5dc3c03a0d07b7598eb` | `PoolManager.protocolFeeController()` |

Pinned PoolKey: `{currency0: 0x0 (ETH), currency1: STONKHOUSE, fee: 0, tickSpacing: 200, hooks: 0xE5e7…e044}`.
`keccak256(abi.encode(key))` = pool id `0x17ce8a5fccf32a6b7c7ab3a1c1d3663d6396614384661e9779cdb68c4541dddc`
(asserted). The pool was initialized at block 64,068,924.

Hook roles: owner `0x263ed295dAFaE1d9AAdD6E56c4B6F9f38eE019Dd`, fee sweep operator
`0x49BbF2b70955Fb3a106e084D4BFDa92d334573d2`, pool creator (tax recipient)
`0xf7dcb00aCCc5B74b8163df1f6f9BaBbB4d53217d`.

The STONKHOUSE token is not verified on Sourcify. Its behaviour matches the verified
`PonsV2LauncherToken` source (OpenZeppelin `ERC20` + `ERC20Burnable`) in the Sourcify-verified
`PonsV2LaunchDeployer`. The spike observed that `burn` lowered `totalSupply` by exactly the amount
burned at every size.

## Hook: permissions and fees

- Permission bits (low 14 bits of the address): `0x2044` = beforeInitialize, afterSwap,
  afterSwapReturnDelta. No beforeSwap and no beforeSwapReturnDelta, so the hook cannot refuse or
  reprice a swap before it runs. No liquidity hooks. The verified source's `getHookPermissions()`
  says the same.
- The fee is charged in `afterSwap` on the swap's unspecified currency. For an exact-input
  ETH -> STONKHOUSE buy this is the STONKHOUSE output. The measured cut at every size was
  1.00 % hook fee plus 1.00 % creator tax of the gross output (asserted to the wei against the
  frozen terms).
- The terms are frozen per pool in `launches[poolId]` when the factory registers the pool:
  `hookFeeBps` 100, `creatorTaxBps` 100, `protocolFeeShareBps` 3,000, `buybackBurnBps` 5,000,
  `maxInternalPriceImpactBps` 300, `buybackEnabled` false. The verified source has no setter for
  them. The owner's `setHookFeeBps` changes only the global value new launches copy (global
  `hookFeeBps()` = 100 at the block). `registerPool` caps any pool at 2,000 bps total.
- The pool's LP fee is 0 (static, not dynamic). The PoolManager protocol fee on this pool is 0 at
  the block. The controller can set it to at most 1,000 pips (0.10 %) per direction, charged on
  the input. On this chain it has already done so on 10 of the token's 11 other pools.

## Pool state at the fork block

| | v3 USDG/WETH 0.01 % | v4 ETH/STONKHOUSE (pinned) |
|---|---|---|
| sqrtPriceX96 | 4,070,484,291,339,147,083,812,581 | 233,094,080,177,585,992,831,945,346,931,384 |
| tick | -197,537 | 159,745 |
| liquidity | 4,893,766,857,630,448,658 | 29,277,002,188,455,995,497,142 |
| mid | 2,639.568875 USDG per WETH | 8,655,722.42 STONKHOUSE per ETH |
| reserves | 17,230,078.31 USDG, 2,631.19 WETH held | full range: 9.951188 ETH and 86,134,723.8 STONKHOUSE |
| oracle | cardinality 10,439, oldest observation 67,991 s old (18.9 h) | none (v4 has no observation ring) |

Two-mid price: 304.950730 USDG per million STONKHOUSE.

The v4 pool's only liquidity is one full-range position (ticks -887,200 to 887,200), token id
2,761,804, minted to the Pons locker at graduation (the pool's single `ModifyLiquidity` event).
The locker's verified source has no withdrawal or arbitrary-call function, so this liquidity
cannot be removed. The ETH side of the pool can still shrink when the token price falls.

v3 TWAP through the repo's own `UniV3TwapSource` (`setPool(WETH, pool, 0, 300)`; WETH plays the
18-dp underlying; the pool passes the 2,401 minimum cardinality):

| Window | USDG per WETH | Mean tick | Spot minus mean (ticks) | Harmonic-mean liquidity |
|---|---:|---:|---:|---:|
| 300 s | 2,640.196750 | -197,534 | -3 | 4,856,889,542,076,085,154 |
| 1,800 s | 2,641.517112 | -197,529 | -8 | 4,891,660,109,886,419,807 |

## Route by size (direct caller)

`test_fork_routeBySize_directCaller_quotesFeesTicksGas`. Every fill was burned in full.

| USDG in | WETH out = ETH into v4 | STONKHOUSE bought and burned | Loss vs two-mid | v3 part | v4 price impact | Effective USDG per 1M tokens | v4 tick after |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.000378811860333527 | 3,213.19 | 2.0135 % | 100 ppm | 38 ppm | 311.217183 | 159,744 |
| 5 | 0.001894059271537554 | 16,063.50 | 2.0284 % | 100 ppm | 190 ppm | 311.264574 | 159,741 |
| 20 | 0.007576236634198983 | 64,217.35 | 2.0843 % | 100 ppm | 760 ppm | 311.442293 | 159,730 |
| 50 | 0.018940589325741702 | 160,360.37 | 2.1959 % | 100 ppm | 1,899 ppm | 311.797729 | 159,707 |
| 100 | 0.037881171118966610 | 320,112.55 | 2.3814 % | 100 ppm | 3,792 ppm | 312.390124 | 159,669 |
| 250 | 0.094702871303585506 | 795,754.34 | 2.9336 % | 100 ppm | 9,427 ppm | 314.167307 | 159,555 |
| 500 | 0.189405554294700505 | 1,576,644.07 | 3.8402 % | 101 ppm | 18,677 ppm | 317.129280 | 159,368 |
| 1,000 | 0.378810355341765686 | 3,095,465.14 | 5.6035 % | 103 ppm | 36,670 ppm | 323.053225 | 158,998 |
| 2,500 | 0.947020239042082909 | 7,335,141.35 | 10.5257 % | 109 ppm | 86,896 ppm | 340.825061 | 157,927 |

Fee components, identical in share at every size: v3 LP fee 100 ppm of the USDG in (the v3 price
impact stays under 10 ppm up to 2,500 USDG, and the v3 tick did not move), v4 LP fee 0,
PoolManager protocol fee 0, hook fee 10,000 ppm of gross output, creator tax 10,000 ppm of gross
output. The rest of the loss is v4 price impact. The v4 pool crosses no initialized tick at these
sizes (one full-range position).

In USDG at the two-mid price, a 5 USDG buy loses 0.1014 USDG (hook fee 0.0500, creator tax
0.0500, v3 fee 0.0005, impact 0.0010). A 50 USDG buy loses 1.0980 USDG (hook fee 0.4990,
creator tax 0.4990, v3 fee 0.0050, impact 0.0950).

Executable depth. The measured points fit the full-range constant-product curve with the ETH
reserve above; with that fit, total loss vs the two-mid value reaches 2.5 % at about 132 USDG,
3 % at about 268 USDG, 5 % at about 827 USDG and 10 % at about 2,330 USDG. The 100, 250, 1,000
and 2,500 USDG rows are the measured anchors.

Gas (direct route, flat across sizes):

| Leg | Gas |
|---|---:|
| v3 `pool.swap` incl. callback USDG transfer | 112,677 |
| `WETH.withdraw` | 15,896 |
| v4 `unlock` + swap + sync/settle ETH + take | 173,105 - 174,146 |
| `burn` (balance and supply already warm) | 5,956 |
| Whole call as one transaction (tx total) | 289,576 - 290,617 (290,597 at 50 USDG) |

At the fork block's base fee, 290,597 gas is 0.0000194 ETH, about 0.051 USDG, excluding any L1 data
fee. That is about 1 % of a 5 USDG buy and 0.1 % of a 50 USDG buy. It is paid by the cranker in
ETH, not from the reserve. Splitter and executor overhead are not included (C3-605 measures them).

## Quotes against fills

At every size, both quotes taken at the pre-trade state matched the fill to the wei:

- `QuoterV2.quoteExactInputSingle(USDG -> WETH, fee 100)` = WETH out, 9 of 9 sizes.
- `V4Quoter.quoteExactInputSingle(pinned key, zeroForOne, ETH in, "")` = STONKHOUSE out, 9 of 9
  sizes. The V4Quoter includes the hook's afterSwap cut. It also matched the fill with the
  counterfactual fee terms and with the protocol fee at its ceiling (section on fee changes).

The V4Quoter prices the same pool the buy trades. It is a simulation, not an independent price.

## UniversalRouter with the explicit PoolKey

`test_fork_universalRouter_explicitPoolKey_matchesDirect`. The router at `0x8876…0904` accepted a
stock `V4_SWAP` (command `0x10`) with actions `SWAP_EXACT_IN_SINGLE` (the pinned key,
`zeroForOne`, amount in, minimum out, empty hookData), `SETTLE(ETH, amount, payerIsUser=false)`
and `TAKE(STONKHOUSE, MSG_SENDER, OPEN_DELTA)`, with the ETH as `msg.value`.

| USDG | Direct output | Router output, contract caller | Router output, EOA | v4 leg gas direct / router | Tx total full route direct / router | EOA router tx total |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 16,063.504825599506098170 | same | same | 174,146 / 196,834 | 290,617 / 313,289 | 206,603 |
| 50 | 160,360.372138004796733305 | same | same | 174,114 / 196,802 | 290,597 / 313,269 | 206,571 |
| 250 | 795,754.343762907049033351 | same | same | 174,022 / 196,710 | 290,505 / 313,177 | 206,503 |

The router gives the identical fill and costs about 22,700 more gas in the v4 leg. The direct
`unlock` path works, so the router is a fallback, not a requirement. The router's v3 command was
not exercised; third-party notes (pons-mcp `docs/PROTOCOL.md`) say this router's `V3_SWAP` command
is a non-standard fork.

## Caller and hookData

`test_fork_callerAndHookData_noRestriction`: a contract caller is accepted; hookData
`0xdeadbeefcafe` gives the same fill as empty hookData (160,360.372 tokens at 50 USDG); a second,
freshly deployed contract gets the same fill. The verified `_afterSwap` reads neither the sender
nor hookData. No restriction was found.

## The 11 other pools of the token

Found from the PoolManager's `Initialize` logs (all pools with the token as currency1; none has it
as currency0). None has a hook. The route test asserted that none of them changed in any fill.
`test_fork_trapPools_quotedAgainstPinned` quoted the same spend on each (50 USDG, or the 0.018941
ETH it buys):

| Pool id | Quote currency | LP fee | Protocol fee | Liquidity | Quoted STONKHOUSE |
|---|---|---:|---:|---:|---:|
| `0xdc5e…c2f0` | USDG | 90.20 % | 0.1 % | 103,588,953,961,196 | 12,155.45 |
| `0xe35b…5099` | USDG | 87.00 % | 0.1 % | 0 | quote reverted |
| `0x8a63…4196` | USDG | 99.12 % | 0.1 % | 94,581,819,731,222 | 28,222.03 |
| `0xceff…d3ff` | USDG | 80.00 % | 0.1 % | 366,263,385,035,744 | 26,091.10 |
| `0xd04e…30ff` | ETH | 25.00 % | 0.1 % | 919,950,746,597,253,607 | 2,481.41 |
| `0x879b…f1c1` | ETH | 81.00 % | 0.1 % | 0 | quote reverted |
| `0x4277…14ff` | ETH | 80.03 % | 0.1 % | 0 | quote reverted |
| `0x3640…1481` | USDG | 20.00 % | 0.1 % | 0 | quote reverted |
| `0x4ac7…ee55` | USDG | 7.00 % | 0.1 % | 0 | quote reverted |
| `0xf207…2bba` | USDG | 50.00 % | 0.1 % | 0 | quote reverted |
| `0x2762…3b68` | ETH | 89.99 % | 0 | 123,215,003,612,117,022 | 902.50 |
| pinned `0x17ce…dddc` | ETH | 0 | 0 | 29,277,002,188,455,995,497,142 | 160,360.37 |

Full ids are in the test (`_trapPools`), where each is re-derived from its key and asserted.

## Adverse scenarios

### Adverse ordering on the v4 leg

`test_fork_adverseOrdering_v4FrontRun_andBackRun`. An attacker buys with `front` ETH on the pinned
pool, our route fills, then the attacker sells everything back. "Round trip alone" is the same
front and back run with no buy in between.

| Our size (USDG) | Front (ETH) | Our output lost | Attacker P&L (ETH) | Attacker round trip alone (ETH) | Attacker gain from our trade (ETH) |
|---:|---:|---:|---:|---:|---:|
| 50 | 0.1 | 1.98 % | -0.003580 | -0.003941 | +0.000361 |
| 50 | 0.5 | 9.33 % | -0.017637 | -0.019340 | +0.001703 |
| 50 | 1 | 17.41 % | -0.034661 | -0.037843 | +0.003181 |
| 50 | 2 | 30.65 % | -0.067140 | -0.072750 | +0.005610 |
| 250 | 0.1 | 1.97 % | -0.002131 | -0.003941 | +0.001810 |
| 250 | 0.5 | 9.30 % | -0.010798 | -0.019340 | +0.008542 |
| 250 | 1 | 17.36 % | -0.021888 | -0.037843 | +0.015955 |
| 250 | 2 | 30.56 % | -0.044635 | -0.072750 | +0.028115 |
| 1,000 | 0.1 | 1.94 % | +0.003398 | -0.003941 | +0.007339 |
| 1,000 | 0.5 | 9.18 % | +0.015259 | -0.019340 | +0.034599 |
| 1,000 | 1 | 17.15 % | +0.026688 | -0.037843 | +0.064531 |
| 1,000 | 2 | 30.24 % | +0.040717 | -0.072750 | +0.113467 |

- The round trip alone costs the attacker 3.6 % to 3.9 % of the front size (the 2 % hook cut on
  each leg, less the price the back-run recovers).
- At 50 and 250 USDG every tested sandwich lost money for the attacker. At 1,000 USDG every tested
  sandwich made money. The break-even size lies between 250 and 1,000 USDG at this depth; the
  spike did not search for it.
- Griefing without profit is possible at any size. At 50 USDG, a 0.1 ETH front-run cost our buy
  3,172 tokens (about 0.97 USDG at the pre-trade mid) and cost the attacker 0.00358 ETH (about
  9.45 USDG).
- A `minTokensOut` of the pre-trade V4Quoter quote less 1 % refused the 0.5 ETH front-run case at
  50, 250 and 1,000 USDG (`TooLittleReceived`). That minimum comes from the same pool and is
  supplied by the keeper; it is not an independent price.

### Adverse ordering on the v3 leg, with a TWAP floor

`test_fork_adverseOrdering_v3FrontRun_twapFloor`, 50 USDG buy. Floor = WETH at the 300 s TWAP
(2,640.196750 USDG per WETH) less the 1 bp pool fee and a 50 bps tolerance = 0.018841398846506420
WETH. The undisturbed fill (0.018940589325741702 WETH) cleared it.

| USDG front-run on v3 | v3 tick after it | Our WETH lost | Floor refused |
|---:|---:|---:|---|
| 100,000 | -197,529 | 0.08 % | no |
| 1,000,000 | -197,452 | 0.84 % | yes (`TooLittleWeth`) |
| 5,000,000 | -196,720 | 7.84 % | yes |

The test asserts the floor refuses exactly when the unguarded fill falls below it. The 50 bps
tolerance is a spike parameter, not a proposal from observed TWAP drift.

### Shallow liquidity

The pinned pool's liquidity cannot be withdrawn (locker), so the spike cannot remove it. It can
lose ETH depth when the token price falls. `test_fork_shallowLiquidity_afterTokenSellOff` sold
STONKHOUSE into the pool until the ETH reserve fell to 1/2 and to 1/4 (in-range liquidity stayed
2.9277e22, asserted), then ran the route.

| State | Tokens sold | ETH reserve | v4 tick | 5 USDG loss | 50 USDG loss | 250 USDG loss |
|---|---:|---:|---:|---:|---:|---:|
| fork block | 0 | 9.951188 | 159,745 | 2.0284 % | 2.1959 % | 2.9336 % |
| after sell-off, ETH reserve / 2 | 86,134,723.8 | 4.975594 | 173,608 | 2.0470 % | 2.3814 % | 3.8401 % |
| after sell-off, ETH reserve / 4 | 258,404,171.4 | 2.487797 | 187,472 | 2.0843 % | 2.7502 % | 5.6032 % |

Price impact scales with spend divided by the ETH reserve: 50 USDG at 1/2 depth costs the same as
100 USDG at full depth, and 250 USDG at 1/4 depth the same as 1,000 USDG at full depth.

### Changed fees

`test_fork_feeChanges_hookOwner_frozenTerms_protocolFee`, 50 USDG buy, base output 160,360.372
STONKHOUSE.

| Change | How | STONKHOUSE out | Change vs base |
|---|---|---:|---:|
| Hook owner sets global `hookFeeBps` to 1,000 (its maximum) | `vm.prank(owner)`, the real setter | 160,360.372 | none; pool terms stayed 100 / 100 |
| Pool terms 150 + 100 bps (2.5 % total) | storage write to `launches[poolId]`; no such path in the verified source | 159,542.207 | -0.51 % |
| Pool terms 1,000 + 1,000 bps (the 2,000 bps registration ceiling) | storage write, as above | 130,906.426 | -18.37 % |
| PoolManager protocol fee 0.10 % each direction | `vm.prank(controller)`, the real `setProtocolFee` | 160,200.316 | -0.10 % |

After the storage writes, `launches(poolId)` returned the written values, and the V4Quoter still
matched the fill. An executor fee check that reads `launches(poolId)` would see such a change.

## Exposure across the proposed caps and cadence

Proposals from F6 D6 / Q6.4, not approvals: daily cadence, minimum buy 5 USDG, first cap 5 USDG
then 50 USDG per buy, dust threshold 1 USDG. All figures use the fork-block state.

| Proposal | Spend per buy | Loss vs two-mid per buy | of which hook fee + creator tax | Gas per buy (L2 execution) | Spend in 30 days | Loss in 30 days |
|---|---:|---:|---:|---:|---:|---:|
| 5 USDG, daily | 5 USDG | 0.1014 USDG (2.03 %) | 0.1000 USDG | about 0.05 USDG | 150 USDG | 3.04 USDG |
| 50 USDG, daily | 50 USDG | 1.0980 USDG (2.20 %) | 0.9980 USDG | about 0.05 USDG | 1,500 USDG | 32.94 USDG |

- Spend limit. A contract-enforced cap and interval bound the spend to cap x number of intervals,
  up to the funded reserve. At 50 USDG daily that is 50 per day, 350 per week, 1,500 per 30 days.
  Fee inflows during the window refill the reserve; no automatic top-up is assumed.
- Stolen keeper key. A thief who sets `minTokensOut` to 0 can make each capped buy fill badly
  only by moving the pool first. At 50 USDG, the tested moves cost the mover about 10 to 12 times
  the value our buy lost, and no tested sandwich was profitable at 50 or 250 USDG. Each buy still
  burns what it buys.
- Depth margin. Impact scales with spend divided by the ETH reserve. A 50 USDG buy faces the
  relative depth of the 250 USDG case (no tested sandwich profitable) once the ETH reserve falls
  by 5, and of the 1,000 USDG case (every tested sandwich profitable) once it falls by 20, that
  is at about 2.0 and 0.5 ETH. Inferred from the scaling, not measured.
- The 2.5 % tax threshold is a proposal. Measured fee-type charges are 2.00 % of output (hook fee
  plus creator tax, frozen) plus 0.01 % of input (v3 fee), plus up to 0.10 % if the protocol fee
  controller acts: at most 2.11 %, below 2.5 %. If the threshold is applied to total execution loss
  (fees plus impact) instead, it limits a buy to about 132 USDG at this depth and about 66 USDG at
  half the ETH reserve.

## Findings for the executor and splitter work (C3-603, C3-604, K3-604, O3-601)

1. A fee guard must read `launches(poolId).hookFeeBps + creatorTaxBps` (200 bps now), not
   `hookFeeBps()`. The global getter is not this pool's fee. A hookFeeBps-only cap would also miss
   the creator tax.
2. Both per-pool terms are frozen, so that guard is a tripwire. The fee that can change on this
   pool is the PoolManager protocol fee (0 now, at most 0.10 %), readable through
   `StateView.getSlot0(poolId)`.
3. Settle ETH with `sync(address(0))` then `settle{value: amount}()`, then `take` the token. No
   hookData and no caller registration are needed.
4. The hook takes its cut in STONKHOUSE on a buy. The sweep operator later sells those tokens for
   ETH against the same pool; that is outside this spike.
5. The v3 leg is deep relative to the proposed caps. Its 300 s and 1,800 s TWAPs are available
   (ring 18.9 h), and `UniV3TwapSource` accepts the pool as a floor source.
6. The direct `unlock` path costs about 22,700 less gas than the UniversalRouter for the same fill.

Corrections to the dated evidence in F6 section 1, row 16: the hook owner can change fees only for
future launches, not for this pool; the pool is one permanently locked full-range position of
9.951 ETH plus 86.13M STONKHOUSE (about 52,500 USDG in total at the fork block); the hook's
permission bits `0x2044` are now confirmed by both the address and the verified source.

## GO / STOP

**GO for the route.** At block 67,296,505 the approved route executed end to end from a contract
caller, the burn lowered supply by exactly the amount bought, both quoters matched the fills to
the wei, only the pinned pool moved, the hook put no restriction on the caller or hookData, and
the per-pool fee is fixed at 2.00 % of output. At the proposed 5 and 50 USDG sizes the loss
against mid is 2.03 % and 2.20 %, and no tested sandwich was profitable.

This GO covers the route mechanics only. It does not approve caps, cadence, budget or any live
spending, which stay owner-gated (Q6.4, OWN3-606).

Stop and revisit before or during live use if any of these holds at buy time: the pinned pool's
`launches(poolId)` terms or protocol fee differ from above; the simulated loss for the chosen cap
exceeds the approved limit (for example after the ETH reserve falls); a proposed cap approaches
the sandwich-profitable range (more than 250 USDG at this depth); the pool id, hook address or
hook code hash differ from this report.

## Not proven here

- Future prices, depth, hook behaviour or MEV conditions. This is one block on a fork. The public
  RPC keeps no history, so this exact run can only be repeated from a local fork cache.
- Ordering on the live sequencer. The front-run scenarios place transactions in a chosen order;
  whether anyone can do that on chain 4663 was not studied.
- An independent price for STONKHOUSE. None exists on chain; the V4Quoter and any same-pool median
  read the pool being traded.
- The exact sandwich break-even size (only 50, 250 and 1,000 USDG were measured).
- Multi-block or sustained manipulation of the v3 TWAP; only single-block pushes were measured.
  The 50 bps floor tolerance was not derived from observed drift.
- The token's source. It is not Sourcify-verified; only its behaviour in these fills was observed.
- The fee sweep operator's internal swaps and their price effect on buys.
- Real fee inflows. USDG was given to the caller with `deal`.
- The splitter and executor contracts themselves, their gas, and the keeper path (C3-603 to C3-605,
  K3-604).
- The UniversalRouter's v3 command and Permit2 paths, and any router shape other than the
  ETH-in single-hop `V4_SWAP` above.
- Exact-output swaps, where the hook charges the input side.
- The L1 data fee part of the gas cost on chain 4663.
- The PoolManager bytecode match against Ethereum mainnet (from the 2026-09-17 venue recon; only
  the code hash was recorded here).
