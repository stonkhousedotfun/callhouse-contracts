// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {IV4PoolManager, V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V4BuybackConfig, V4BuybackExecutor} from "../../../src/v2/periphery/V4BuybackExecutor.sol";
import {ForkFloor} from "./ForkFloor.sol";
import {
    FwPoolKey,
    FwQuoteExactSingleParams,
    FwV3QuoteParams,
    IFwMemeHook,
    IFwPoolManager,
    IFwQuoterV2,
    IFwStateView,
    IFwV3Factory,
    IFwV3Pool,
    IFwV4Quoter
} from "./FlywheelRouteFork.t.sol";

/// @notice v4-core's protocol-fee ledger: what the PoolManager has kept for the fee controller, per currency.
interface IFwProtocolFees {
    function protocolFeesAccrued(address currency) external view returns (uint256 amount);
}

/// @notice C3-604's live check of {V4BuybackExecutor} against the real chain-4663 venue: the deployed executor runs
///         the whole pinned route (USDG -> WETH on the Uniswap v3 0.01 % pool under its own TWAP floor -> native ETH
///         -> STONKHOUSE through the PoolManager on the pinned launch PoolKey), EVERY fee component is reconciled
///         against a measured balance delta, the tokens reach the splitter, the executor keeps nothing, the token's
///         eleven other v4 pools do not move, and no executor can be constructed on any of them.
/// @dev Run with:  FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC --fork-block-number <N> \
///                   --match-path "test/v2/fork/V4BuybackExecutorFork.t.sol" -vv
///      Without a fork (chain id != 4663) every test logs and returns, as the other v2 fork suites do. The public RPC
///      keeps no historical state, so <N> must be a recent block; docs/V2-BUYBACK-EXECUTOR.md records the block these
///      numbers were taken at. The addresses, the pinned key and the trap-pool table come from C3-602
///      (`docs/V2-FLYWHEEL-ROUTE-SPIKE.md`), whose interface declarations this suite imports rather than restates.
contract V4BuybackExecutorForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant TOKEN = 0xc2525b7c68b6d66dE5AABFEDC7B13314F389D5C4; // STONKHOUSE, 18 dp
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant V3_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // USDG/WETH 0.01 %, WETH token0
    address constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7; // QuoterV2
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044; // PonsV2MemeHook
    bytes32 constant POOL_ID = 0x17ce8a5fccf32a6b7c7ab3a1c1d3663d6396614384661e9779cdb68c4541dddc;
    uint24 constant V3_FEE = 100;

    uint256 constant Q192 = 1 << 192;
    uint256 constant PPM = 1_000_000;
    uint256 constant BPS = 10_000;
    /// @dev v4-core `TickMath.MIN_SQRT_PRICE`, mirrored from the executor's `internal constant` of the same name so
    ///      the swap calldata section 4 expects can be built here. If the executor's limit ever moves, section 4
    ///      goes red at the pool-manager boundary, which is the point.
    uint160 constant MIN_SQRT_PRICE = 4_295_128_739;

    /// @dev The executor's configuration under test. 250 bps leaves room above the venue's 211 bps worst case.
    uint16 constant FEE_CAP_BPS = 250;
    uint16 constant SLIPPAGE_BPS = 51;
    uint32 constant WINDOW = 300;
    uint128 constant MIN_LIQUIDITY = 1e18;
    uint256 constant USDG_IN = 50e6;

    V4BuybackExecutor internal exec;
    address internal splitter = makeAddr("splitter");

    modifier onlyFork() {
        if (block.chainid != 4663) {
            console2.log("skipping: not forked onto 4663 (chainid %s)", block.chainid);
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        exec = _deploy(FEE_CAP_BPS);
        vm.label(address(exec), "V4BuybackExecutor");
        vm.label(USDG, "USDG");
        vm.label(WETH, "WETH");
        vm.label(TOKEN, "STONKHOUSE");
        vm.label(V3_POOL, "USDG/WETH 0.01%");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(HOOK, "PonsV2MemeHook");
    }

    /*//////////////////////////////////////////////////////////////
            1. THE ROUTE, WITH EVERY FEE COMPONENT RECONCILED
    //////////////////////////////////////////////////////////////*/

    function test_fork_buy_reconcilesEveryFeeComponentAgainstBalanceDeltas() public onlyFork {
        // The executor really is pinned to the launch pool, on live state.
        assertEq(exec.poolId(), POOL_ID, "the executor pinned the launch pool id");
        assertEq(keccak256(abi.encode(_fwKey())), POOL_ID, "and that id is the hash of the pinned key");
        assertEq(IFwV3Factory(V3_FACTORY).getPool(USDG, WETH, V3_FEE), V3_POOL, "the v3 leg's pool is the factory's");
        assertTrue(exec.wethIsToken0(), "WETH is the v3 pool's token0, read from the pool");
        assertEq(exec.v3Fee(), V3_FEE);

        // What the guard declares before anything is spent.
        (uint16 v3Bps, uint16 lpBps, uint16 protocolBps, uint16 hookBps, uint16 taxBps, uint256 declaredTotal) =
            exec.feeBps();
        (uint16 termsHookBps, uint16 termsTaxBps) = _terms();
        assertEq(hookBps, termsHookBps, "the hook fee comes from launches(poolId)");
        assertEq(taxBps, termsTaxBps, "so does the creator tax");
        assertTrue(declaredTotal <= FEE_CAP_BPS, "the venue is inside the configured cap");

        // Pre-trade state and quotes.
        (uint160 s3,,,,,,) = IFwV3Pool(V3_POOL).slot0();
        (, int24 tickBefore, uint24 protocolFeeRaw, uint24 lpFeeRaw) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        assertEq(lpFeeRaw, 0, "the launch pool's LP fee");
        (uint256 wethQuoted,,,) = IFwQuoterV2(V3_QUOTER)
            .quoteExactInputSingle(
                FwV3QuoteParams({tokenIn: USDG, tokenOut: WETH, amountIn: USDG_IN, fee: V3_FEE, sqrtPriceLimitX96: 0})
            );
        (uint256 tokensQuoted,) = IFwV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                FwQuoteExactSingleParams({
                    poolKey: _fwKey(),
                    zeroForOne: true,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    exactAmount: uint128(wethQuoted),
                    hookData: ""
                })
            );

        uint256 floor = exec.wethFloor(USDG_IN);
        Before memory b = _snapshot();

        deal(USDG, splitter, USDG_IN);
        vm.prank(splitter);
        IERC20(USDG).approve(address(exec), USDG_IN);
        vm.prank(splitter);
        (uint256 usdgSpent, uint256 tokenOut) = exec.buy(USDG_IN, tokensQuoted * 99 / 100, 0);
        uint256 gasTx = vm.lastCallGas().gasTotalUsed;

        /* ---------------- leg 1: the v3 fee, against the pool's own balances ---------------- */

        assertEq(usdgSpent, USDG_IN, "the v3 pool consumed the whole input");
        uint256 wethOut = b.poolWeth - IERC20(WETH).balanceOf(V3_POOL);
        assertEq(IERC20(USDG).balanceOf(V3_POOL) - b.poolUsdg, USDG_IN, "the pool's USDG rose by exactly the input");
        assertEq(wethOut, wethQuoted, "QuoterV2's pre-trade quote is the fill, to the wei");
        assertGe(wethOut, floor, "the fill cleared the executor's own TWAP floor");
        // The 0.01 % LP fee stays in the pool: the swap prices `usdgIn - fee` at the pre-trade mid, less the price
        // impact, which C3-602 measured at under 10 ppm up to 2,500 USDG.
        uint256 v3Fee = USDG_IN * V3_FEE / PPM;
        uint256 wethAtMidAfterFee = Math.mulDiv(USDG_IN - v3Fee, Q192, uint256(s3) * s3);
        assertLe(wethOut, wethAtMidAfterFee, "the fill is at most the post-fee value of the input at the mid");
        assertGe(wethOut * PPM, wethAtMidAfterFee * (PPM - 100), "and within 100 ppm of it: the rest is v3 impact");

        /* ---------------- leg 2: the hook fee and the creator tax, separately ---------------- */

        assertEq(tokenOut, tokensQuoted, "V4Quoter's pre-trade quote is the fill, to the wei");
        uint256 hookFee = IFwMemeHook(HOOK).pendingFees(POOL_ID, TOKEN) - b.pendingFee;
        uint256 creatorTax = IFwMemeHook(HOOK).pendingCreatorTax(POOL_ID, TOKEN) - b.pendingTax;
        assertEq(
            IERC20(TOKEN).balanceOf(HOOK) - b.hookToken, hookFee + creatorTax, "the hook's balance rose by its cut"
        );
        uint256 gross = tokenOut + hookFee + creatorTax;
        assertEq(hookFee, gross * hookBps / BPS, "hook fee = gross output x the pool's frozen hookFeeBps");
        assertEq(creatorTax, gross * taxBps / BPS, "creator tax = gross output x the pool's frozen creatorTaxBps");
        // The same shares the executor's measured guard computes, rounded up as it rounds them.
        assertEq(
            Math.mulDiv(hookFee, BPS, gross, Math.Rounding.Ceil), hookBps, "the measured share is the declared one"
        );
        assertEq(Math.mulDiv(creatorTax, BPS, gross, Math.Rounding.Ceil), taxBps);

        /* ---------------- leg 2: the protocol fee, against v4's own ledger ---------------- */

        assertEq(protocolFeeRaw, 0, "no protocol fee on the pinned pool at this block");
        assertEq(protocolBps, 0, "so the guard declares none");
        assertEq(lpBps, 0);
        assertEq(v3Bps, 1, "the 0.01 % tier is 1 bp");
        assertEq(
            IFwProtocolFees(POOL_MANAGER).protocolFeesAccrued(address(0)) - b.accruedEth,
            0,
            "and v4's protocol-fee ledger did not move"
        );

        /* ---------------- the swap delta, and where everything went ---------------- */

        assertEq(POOL_MANAGER.balance - b.pmEth, wethOut, "every wei of the unwrapped ETH settled into the pool");
        assertEq(b.pmToken - IERC20(TOKEN).balanceOf(POOL_MANAGER), gross, "the pool paid out exactly the gross");
        assertEq(IERC20(TOKEN).balanceOf(splitter) - b.splitterToken, tokenOut, "the splitter got every token bought");
        assertEq(IERC20(USDG).balanceOf(splitter), 0, "and no USDG came back: the fill consumed all of it");

        assertEq(IERC20(USDG).balanceOf(address(exec)), 0, "the executor kept no USDG");
        assertEq(IERC20(WETH).balanceOf(address(exec)), 0, "the executor kept no WETH");
        assertEq(IERC20(TOKEN).balanceOf(address(exec)), 0, "the executor kept no tokens");
        assertEq(address(exec).balance, 0, "the executor kept no ETH");

        assertEq(_trapStateHash(), b.traps, "the token's eleven other v4 pools are untouched");
        (, int24 tickAfter,,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        assertLt(tickAfter, tickBefore, "only the pinned pool moved, and it moved the right way");

        /* ---------------- the report ---------------- */

        uint256 measuredOutBps = Math.mulDiv(hookFee + creatorTax, BPS, gross, Math.Rounding.Ceil);
        console2.log(
            string.concat(
                "EXEC_BUY",
                _kv("block", block.number),
                _kv("timestamp", block.timestamp),
                _kv("usdg_in", USDG_IN),
                _kv("usdg_spent", usdgSpent),
                _kv("weth_floor", floor),
                _kv("weth_out", wethOut),
                _kv("weth_quoted", wethQuoted),
                _kv("tok_out", tokenOut),
                _kv("tok_quoted", tokensQuoted),
                _kv("tok_gross", gross),
                _kv("gas_tx_total", gasTx)
            )
        );
        console2.log(
            string.concat(
                "EXEC_FEES",
                _kv("v3_fee_usdg6", v3Fee),
                _kv("v3_fee_bps", v3Bps),
                _kv("v4_lp_fee_bps", lpBps),
                _kv("v4_protocol_fee_bps", protocolBps),
                _kv("hook_fee_tok", hookFee),
                _kv("hook_fee_bps", hookBps),
                _kv("creator_tax_tok", creatorTax),
                _kv("creator_tax_bps", taxBps),
                _kv("declared_total_bps", declaredTotal),
                _kv("measured_output_cut_bps", measuredOutBps),
                _kv("measured_total_bps", uint256(v3Bps) + lpBps + protocolBps + measuredOutBps),
                _kv("cap_bps", FEE_CAP_BPS)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
        2. THE PROTOCOL FEE IS THE ONE FEE THAT CAN STILL CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The per-pool hook terms are frozen, so the only live fee change is the PoolManager protocol fee (at most
    ///      0.10 % per direction). This drives the real `setProtocolFee` from its real controller, reconciles the
    ///      charge against v4's protocol-fee ledger, and shows a tighter cap refusing the same buy before it spends.
    function test_fork_protocolFeeAtCeiling_isMeasuredAndCanBeRefused() public onlyFork {
        address controller = IFwPoolManager(POOL_MANAGER).protocolFeeController();
        uint24 maxProtocolFee = 1000 | (1000 << 12);
        vm.prank(controller);
        IFwPoolManager(POOL_MANAGER).setProtocolFee(_fwKey(), maxProtocolFee);
        (,, uint24 protocolFeeRaw,) = IFwStateView(STATE_VIEW).getSlot0(POOL_ID);
        assertEq(protocolFeeRaw, maxProtocolFee, "the controller really set it");

        (,, uint16 protocolBps,,, uint256 total) = exec.feeBps();
        assertEq(protocolBps, 10, "1,000 pips per direction is 10 bps");
        assertEq(total, 211, "the venue's worst case: 1 + 100 + 100 + 10");

        // An executor whose cap sits between the two refuses, before a single unit of USDG moves.
        V4BuybackExecutor tight = _deploy(205);
        deal(USDG, splitter, USDG_IN);
        vm.prank(splitter);
        IERC20(USDG).approve(address(tight), USDG_IN);
        vm.prank(splitter);
        vm.expectRevert(abi.encodeWithSelector(V4BuybackExecutor.FeeCapExceeded.selector, 211, 205));
        tight.buy(USDG_IN, 1, 0);
        assertEq(IERC20(USDG).balanceOf(splitter), USDG_IN, "the refused buy spent nothing");

        // The 250 bps executor buys, and the charge lands in v4's ledger to the wei.
        uint256 accruedBefore = IFwProtocolFees(POOL_MANAGER).protocolFeesAccrued(address(0));
        uint256 poolWethBefore = IERC20(WETH).balanceOf(V3_POOL);
        vm.prank(splitter);
        IERC20(USDG).approve(address(exec), USDG_IN);
        vm.prank(splitter);
        (, uint256 tokenOut) = exec.buy(USDG_IN, 1, 0);
        uint256 wethOut = poolWethBefore - IERC20(WETH).balanceOf(V3_POOL);

        uint256 accrued = IFwProtocolFees(POOL_MANAGER).protocolFeesAccrued(address(0)) - accruedBefore;
        // v4 charges the protocol fee on the input and rounds it up, so it is the input less 99.90 % of it.
        assertEq(
            accrued,
            wethOut - Math.mulDiv(wethOut, PPM - 1000, PPM),
            "the protocol fee is 0.10 % of the ETH input, rounded up as v4 rounds it"
        );
        assertApproxEqAbs(accrued, wethOut * 1000 / PPM, 1, "and within one wei of a plain 0.10 %");
        assertGt(tokenOut, 0);
        assertEq(address(exec).balance, 0, "the executor still keeps nothing");
        console2.log(
            string.concat(
                "EXEC_PROTOCOL_FEE",
                _kv("protocol_fee_raw", protocolFeeRaw),
                _kv("eth_in", wethOut),
                _kv("accrued_eth_wei", accrued),
                _kv("tok_out", tokenOut),
                _kv("total_bps", total)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                3. THE ELEVEN TRAP POOLS ARE UNREACHABLE
    //////////////////////////////////////////////////////////////*/

    /// @dev None of the token's other v4 pools has a hook, and four of them are ETH-quoted, so they are shaped like
    ///      the pinned one. The constructor refuses every single one: an ETH-quoted key because a hookless key has no
    ///      launch record to read fees from, a USDG-quoted key because `currency0` is not native ETH. A key that
    ///      differs from the pinned one only in `fee` or `tickSpacing` hashes to a pool the hook never registered.
    function test_fork_executorCannotBeConstructedOnAnyOtherPool() public onlyFork {
        (FwPoolKey[11] memory keys, bytes32[11] memory ids) = _trapPools();
        for (uint256 i; i < 11; ++i) {
            assertEq(keccak256(abi.encode(keys[i])), ids[i], "the trap key re-derives its Initialize id");
            assertTrue(ids[i] != POOL_ID, "and it is not the pinned pool");
            V4BuybackConfig memory cfg = _cfg(FEE_CAP_BPS);
            cfg.key = V4PoolKey({
                currency0: keys[i].currency0,
                currency1: keys[i].currency1,
                fee: keys[i].fee,
                tickSpacing: keys[i].tickSpacing,
                hooks: keys[i].hooks
            });
            bytes4 expected =
                keys[i].currency0 == address(0) ? V2Errors.NoSource.selector : V2Errors.UnsupportedAsset.selector;
            vm.expectRevert(expected);
            new V4BuybackExecutor(cfg);
            console2.log(
                string.concat(
                    "TRAP_REFUSED",
                    _kb("id", ids[i]),
                    _ka("currency0", keys[i].currency0),
                    _kv("fee", keys[i].fee),
                    _ka("hooks", keys[i].hooks)
                )
            );
        }

        // The pinned hook, but a key the hook never registered.
        V4BuybackConfig memory near = _cfg(FEE_CAP_BPS);
        near.key.tickSpacing = 60;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(near);

        near = _cfg(FEE_CAP_BPS);
        near.key.fee = 3000;
        vm.expectRevert(V2Errors.NoSource.selector);
        new V4BuybackExecutor(near);

        // And the deployed executor's key is the pinned one, rebuilt from immutables with nothing to change it.
        assertEq(keccak256(abi.encode(exec.key())), POOL_ID);
        assertEq(exec.hooks(), HOOK);
        assertEq(exec.token(), TOKEN);
    }

    /*//////////////////////////////////////////////////////////////
       4. THE GO IS BOUND TO HOOK 0xE5e7...e044 AND TO EXACT-INPUT zeroForOne
    //////////////////////////////////////////////////////////////*/

    /// @notice T-OP-035. T-OP-021's GO on the Pons hook rests on two facts that were only READ: the executor always
    ///         submits an exact-input zeroForOne swap, and the hook takes its cut to its own balance, where the
    ///         executor's measured guard reads it. Both are executed here against the live hook
    ///         0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044 on a 4663 fork.
    /// @dev WHY BOTH, AND WHY EQUALITY. PonsV2MemeHook charges the UNSPECIFIED currency of the swap. Exact-input
    ///      zeroForOne makes that the token, so the cut lands at `hooks` in the token and `balanceOf(hooks)` across
    ///      the swap IS the cut. An exact-OUTPUT refactor would move the charge to ETH, the token read would report
    ///      0 bps for a full cut, and the tripwire would wave it through. So (i) the swap params are pinned at the
    ///      pool-manager boundary with `vm.expectCall` on the exact calldata -- key, `zeroForOne: true`,
    ///      `amountSpecified` NEGATIVE and equal to the v3 fill, the executor's price limit -- and (ii) the executor's
    ///      own `measuredFeeBps`, read from its `Bought` event, is asserted EQUAL to the legs plus the hook fee and
    ///      creator tax derived from `launches(poolId)` on the fork, never `<=`: a hook that charged 0 to itself and
    ///      the full cut elsewhere would pass the tripwire's own inequality and fail this.
    ///      The per-component reconciliation (pendingFees, pendingCreatorTax, v4's ledger) is section 1's job and
    ///      is not repeated; this test reads only what the executor and the hook's balance say.
    function test_fork_go_exactInputZeroForOneAndTheTripwireSeesTheHooksCut() public onlyFork {
        // The terms, from the fork, and the executor's declared reading of them.
        (uint16 hookBps, uint16 taxBps) = _terms();
        (uint16 v3Bps, uint16 lpBps, uint16 protocolBps, uint16 declHookBps, uint16 declTaxBps,) = exec.feeBps();
        assertEq(declHookBps, hookBps, "the executor declares the hook fee launches(poolId) records");
        assertEq(declTaxBps, taxBps, "and the creator tax");
        uint256 legBps = uint256(v3Bps) + lpBps + protocolBps;

        // (i) THE STATIC PIN. The v4 leg's input is every wei the v3 leg fills, which section 1 proved is QuoterV2's
        // quote to the wei; so the ONE swap the executor may submit is known before the buy, and it is exact-input
        // (negative amountSpecified), zeroForOne, at the executor's own price limit, with no hook data.
        (uint256 wethQuoted,,,) = IFwQuoterV2(V3_QUOTER)
            .quoteExactInputSingle(
                FwV3QuoteParams({tokenIn: USDG, tokenOut: WETH, amountIn: USDG_IN, fee: V3_FEE, sqrtPriceLimitX96: 0})
            );
        assertGt(wethQuoted, 0, "positive control: an empty quote would pin an empty swap");
        vm.expectCall(
            POOL_MANAGER,
            abi.encodeCall(
                IV4PoolManager.swap,
                (
                    exec.key(),
                    V4SwapParams({
                        zeroForOne: true, amountSpecified: -int256(wethQuoted), sqrtPriceLimitX96: MIN_SQRT_PRICE + 1
                    }),
                    bytes("")
                )
            )
        );

        // (ii) THE CUT, WHERE THE TRIPWIRE READS IT.
        uint256 hookBefore = IERC20(TOKEN).balanceOf(HOOK);
        deal(USDG, splitter, USDG_IN);
        vm.prank(splitter);
        IERC20(USDG).approve(address(exec), USDG_IN);
        vm.recordLogs();
        vm.prank(splitter);
        (, uint256 tokenOut) = exec.buy(USDG_IN, 1, 0);
        (uint256 wethOut, uint256 declaredFeeBps, uint256 measuredFeeBps) = _bought(vm.getRecordedLogs(), tokenOut);
        assertEq(wethOut, wethQuoted, "the v3 fill is the quote; the expectCall above was built from it");

        uint256 cut = IERC20(TOKEN).balanceOf(HOOK) - hookBefore;
        assertGt(cut, 0, "positive control: a hook that took nothing would satisfy every ratio below at 0 bps");
        uint256 gross = tokenOut + cut;
        assertEq(
            cut,
            gross * hookBps / BPS + gross * taxBps / BPS,
            "the hook's OWN balance grew by exactly hookFee + creatorTax of the gross output"
        );
        // The executor's rounding of that same delta, then its total, EQUAL to the fork-derived terms.
        uint256 cutBps = Math.mulDiv(cut, BPS, gross, Math.Rounding.Ceil);
        assertEq(cutBps, uint256(hookBps) + taxBps, "the cut in the executor's rounding is exactly the launch terms");
        assertEq(measuredFeeBps, legBps + cutBps, "measuredFeeBps = the legs + the cut the executor saw at hooks");
        assertEq(measuredFeeBps, legBps + hookBps + taxBps, "and that equals the bps derived from launches(poolId)");
        assertEq(measuredFeeBps, declaredFeeBps, "so on the live hook, measured == declared: the tripwire sees it all");
    }

    /// @dev The executor's `Bought(usdgIn, usdgSpent, wethOut, tokenOut, minWethOut, declaredFeeBps, measuredFeeBps)`
    ///      from a recorded log set. Exactly one, emitted by `exec`, whose `tokenOut` is the one `buy` returned.
    function _bought(Vm.Log[] memory logs, uint256 tokenOut)
        internal
        view
        returns (uint256 wethOut, uint256 declaredFeeBps, uint256 measuredFeeBps)
    {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(exec) || logs[i].topics[0] != V4BuybackExecutor.Bought.selector) continue;
            (,, uint256 w, uint256 t,, uint256 d, uint256 m) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(t, tokenOut, "the Bought event reports the tokenOut buy returned");
            (wethOut, declaredFeeBps, measuredFeeBps) = (w, d, m);
            ++seen;
        }
        assertEq(seen, 1, "exactly one Bought event from the executor");
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    struct Before {
        uint256 poolUsdg;
        uint256 poolWeth;
        uint256 pmEth;
        uint256 pmToken;
        uint256 hookToken;
        uint256 pendingFee;
        uint256 pendingTax;
        uint256 accruedEth;
        uint256 splitterToken;
        bytes32 traps;
    }

    function _snapshot() internal view returns (Before memory b) {
        b.poolUsdg = IERC20(USDG).balanceOf(V3_POOL);
        b.poolWeth = IERC20(WETH).balanceOf(V3_POOL);
        b.pmEth = POOL_MANAGER.balance;
        b.pmToken = IERC20(TOKEN).balanceOf(POOL_MANAGER);
        b.hookToken = IERC20(TOKEN).balanceOf(HOOK);
        b.pendingFee = IFwMemeHook(HOOK).pendingFees(POOL_ID, TOKEN);
        b.pendingTax = IFwMemeHook(HOOK).pendingCreatorTax(POOL_ID, TOKEN);
        b.accruedEth = IFwProtocolFees(POOL_MANAGER).protocolFeesAccrued(address(0));
        b.splitterToken = IERC20(TOKEN).balanceOf(splitter);
        b.traps = _trapStateHash();
    }

    function _cfg(uint16 capBps) internal view returns (V4BuybackConfig memory) {
        return V4BuybackConfig({
            splitter: splitter,
            usdg: USDG,
            weth: WETH,
            v3Pool: V3_POOL,
            poolManager: POOL_MANAGER,
            stateView: STATE_VIEW,
            key: V4PoolKey({currency0: address(0), currency1: TOKEN, fee: 0, tickSpacing: 200, hooks: HOOK}),
            maxTotalFeeBps: capBps,
            maxSlippageBps: SLIPPAGE_BPS,
            twapWindow: WINDOW,
            minLiquidity: MIN_LIQUIDITY
        });
    }

    function _deploy(uint16 capBps) internal returns (V4BuybackExecutor) {
        return new V4BuybackExecutor(_cfg(capBps));
    }

    /// @dev The same pinned key in C3-602's struct, for the quoters and `setProtocolFee`.
    function _fwKey() internal pure returns (FwPoolKey memory) {
        return FwPoolKey({currency0: address(0), currency1: TOKEN, fee: 0, tickSpacing: 200, hooks: HOOK});
    }

    /// @dev The pool's frozen terms, read where the executor reads them.
    function _terms() internal view returns (uint16 hookFeeBps, uint16 creatorTaxBps) {
        (bool registered,,,,,,, uint16 tax,,, uint16 fee,,) = IFwMemeHook(HOOK).launches(POOL_ID);
        assertTrue(registered, "the pinned pool is registered on the hook");
        return (fee, tax);
    }

    function _trapStateHash() internal view returns (bytes32 h) {
        (, bytes32[11] memory ids) = _trapPools();
        for (uint256 i; i < 11; ++i) {
            (uint160 s, int24 tk, uint24 pf, uint24 lf) = IFwStateView(STATE_VIEW).getSlot0(ids[i]);
            h = keccak256(abi.encode(h, s, tk, pf, lf, IFwStateView(STATE_VIEW).getLiquidity(ids[i])));
        }
    }

    /// @dev The token's other eleven v4 pools, as C3-602 read them from the PoolManager's Initialize logs. None has a
    ///      hook; LP fees run 7 % to 99.12 %.
    function _trapPools() internal pure returns (FwPoolKey[11] memory keys, bytes32[11] memory ids) {
        address e = address(0);
        keys[0] = FwPoolKey(USDG, TOKEN, 902_000, 18_000, e);
        ids[0] = 0xdc5edfb112b051864e24c2e1e3a16ad5828daa31e4ebce30a5bcaa8e0caec2f0;
        keys[1] = FwPoolKey(USDG, TOKEN, 870_000, 60, e);
        ids[1] = 0xe35be1d884537b18f1356ca63038d8823447ea5385316ca306c39da577dd5099;
        keys[2] = FwPoolKey(USDG, TOKEN, 991_200, 19_824, e);
        ids[2] = 0x8a6342ccfdfcac3a619cbd5bc81664a7968b02df7b2edcc91263c31966884196;
        keys[3] = FwPoolKey(USDG, TOKEN, 800_000, 16_000, e);
        ids[3] = 0xceff9e897feda8fe3781175db9c0394dd57f5c936d9ff336739411b9ac3ed3ff;
        keys[4] = FwPoolKey(e, TOKEN, 250_000, 2500, e);
        ids[4] = 0xd04efbc033c5a13c8a24bcb97c6bffab9c9ca38e3f6a817e43503d2c703230ff;
        keys[5] = FwPoolKey(e, TOKEN, 810_000, 19_988, e);
        ids[5] = 0x879b22a86cf1de099d77695bf759957ab142777d425e7bc73702c84a1f15f1c1;
        keys[6] = FwPoolKey(e, TOKEN, 800_269, 200, e);
        ids[6] = 0x4277fe7b6b898ccd0eb504f98aa785d18fd9f1589fedb0c47ea2a570053f14ff;
        keys[7] = FwPoolKey(USDG, TOKEN, 200_000, 2000, e);
        ids[7] = 0x36404cfadd040b846edd6ec3f483ae0b6a888d3ff82a32201ad473baba441481;
        keys[8] = FwPoolKey(USDG, TOKEN, 70_000, 700, e);
        ids[8] = 0x4ac7373102df992a4f957c9fc1efaeb3d3cdc94c777dec08cf02dbe5b274ee55;
        keys[9] = FwPoolKey(USDG, TOKEN, 500_000, 5000, e);
        ids[9] = 0xf2071fd6d692d362b2ccecc690525f4dee907307a1278aa12e492f4590d92bba;
        keys[10] = FwPoolKey(e, TOKEN, 899_900, 8999, e);
        ids[10] = 0x2762f4aead8bec92602ee453bfaefd9d0f192f24e200405a912563d32f093b68;
    }

    function _kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    function _ka(string memory k, address v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    function _kb(string memory k, bytes32 v) internal pure returns (string memory) {
        return string.concat(" ", k, "=", vm.toString(v));
    }

    /// @dev THE FLOOR (T-588). Every other test in this file carries a chain-id guard that SKIPS when no fork is
    ///      attached, so a run that never reached chain 4663 prints `0 failed` and exits 0 -- indistinguishable from
    ///      a run in which every invariant held. This test carries no such guard. Under `FOUNDRY_PROFILE=fork` it
    ///      FAILS when the suite could not have executed, and it is the only test here that can say so.
    ///
    ///      Its witness is `POOL_MANAGER`, an address this suite's own tests read.
    ///      A count of reported tests would not do: a skip IS a report, so such a floor is satisfied by a run in
    ///      which nothing ran. See `ForkFloor` for the rest of the reasoning.
    function test_fork_floor_v4BuybackExecutorForkExecutedAgainstARealFork() public {
        ForkFloor.requireExecutedAgainstRealFork(POOL_MANAGER, "V4BuybackExecutorFork");
    }
}
