// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";
import {IBuybackExecutor} from "../interfaces/IBuybackExecutor.sol";
import {FullMath} from "../oracle/lib/FullMath.sol";
import {TickMath} from "../oracle/lib/TickMath.sol";
import {IUniswapV3PoolOracle} from "../oracle/OracleDeps.sol";
import {
    IPonsLaunchHook,
    IUniV3SwapPool,
    IV4PoolManager,
    IV4StateView,
    IWeth9,
    V4PoolKey,
    V4SwapParams
} from "./BuybackDeps.sol";

/// @notice Everything {V4BuybackExecutor} pins at deployment. Every field is immutable afterwards; a venue change is a
///         new executor and one 24 h scheduled pointer swap on the splitter (ADR-15 §3).
struct V4BuybackConfig {
    /// @dev The FeeSplitter. The ONLY address allowed to call {V4BuybackExecutor.buy}, and the address every token and
    ///      every unspent USDG goes back to.
    address splitter;
    /// @dev USDG (6 dp), the input of every buy.
    address usdg;
    /// @dev WETH9. The v3 leg's output and the native ETH the v4 leg spends.
    address weth;
    /// @dev The Uniswap v3 USDG/WETH pool the first leg swaps in and takes its TWAP floor from.
    address v3Pool;
    /// @dev The Uniswap v4 PoolManager.
    address poolManager;
    /// @dev The Uniswap v4 StateView lens over the same PoolManager (protocol fee and LP fee of the pinned pool).
    address stateView;
    /// @dev The ONE pinned PoolKey. `currency0` must be native ETH and `currency1` the token being bought.
    V4PoolKey key;
    /// @dev Fee cap, bps, over the MEASURED TOTAL of every fee component (see the contract NatSpec, FEE GUARD).
    uint16 maxTotalFeeBps;
    /// @dev v3 TWAP floor tolerance, bps, INCLUDING the v3 pool's own fee (as FeeSplitter's `_floor` route does).
    uint16 maxSlippageBps;
    /// @dev v3 TWAP window, seconds.
    uint32 twapWindow;
    /// @dev Harmonic-mean in-range liquidity floor over the TWAP window, v3 pool L units. Never 0.
    uint128 minLiquidity;
}

/// @title V4BuybackExecutor
/// @notice The flywheel's buy leg (ADR-15, F6 D2): spends the FeeSplitter's USDG on one pinned Uniswap v4 pool and
///         hands the tokens straight back, so the splitter — not this contract — holds the reserve and does the burn.
/// @dev ROUTE, pinned at deployment and not configurable afterwards:
///        1. USDG -> WETH on one Uniswap v3 pool (`pool.swap` with the callback paying USDG), under an on-chain v3
///           TWAP floor;
///        2. `WETH.withdraw` to native ETH;
///        3. ETH -> token on ONE immutable v4 PoolKey through `PoolManager.unlock` with sync / settle / take;
///        4. the tokens and any unspent USDG go to the splitter in the same call.
///      C3-602 measured this exact sequence against the live venue (`docs/V2-FLYWHEEL-ROUTE-SPIKE.md`): a contract
///      caller is accepted, no hookData is needed, and the direct `unlock` path costs about 22,700 less gas than the
///      UniversalRouter for an identical fill.
///
///      ONE CALLER, ONE POOL. {buy} reverts V2Errors.NotAuthorized for anyone but `splitter`, and both callbacks
///      ({uniswapV3SwapCallback}, {unlockCallback}) refuse a caller that is not the pinned v3 pool or PoolManager AND
///      refuse to run at all unless a {buy} is on the stack (the transient reentrancy flag). The v4 leg always trades
///      {key}, which is built from immutables, so a trap pool cannot be reached by passing different calldata. The
///      token has eleven other v4 pools with 7 %-99.12 % LP fees and dust liquidity; the constructor refuses every one
///      of them because it requires the key's hook to be a contract that is the pool's registered launch hook, and
///      none of those pools has a hook at all.
///
///      FEE GUARD (the C3-602 correction, ADR-15 §5). The cap covers the MEASURED TOTAL of the route's fee-type
///      charges, not the hook fee alone, and it is read at call time from the sources that can actually change:
///        - `launches(poolId).hookFeeBps + .creatorTaxBps` on the launch hook — the per-pool terms, frozen at
///          `registerPool` (100 + 100 bps on the pinned pool), which is where this pool's 2.00 % output cut lives.
///          The hook's GLOBAL `hookFeeBps()` getter is NEVER read: it only seeds future launches, it does not apply to
///          an already-registered pool, and it omits the creator tax. A `hookFeeBps()`-only cap is not a total-fee cap.
///        - `StateView.getSlot0(poolId)` — the PoolManager protocol fee (0 today, at most 0.10 % per direction, set by
///          the protocol-fee controller, charged on the input) and the pool's LP fee (0 today).
///        - the v3 pool's own fee tier, read from the pool at deployment (a v3 pool's fee is immutable).
///      Two checks, both fail closed:
///        - DECLARED, before a single unit of USDG moves: v3 fee + v4 LP fee + v4 protocol fee + hook fee + creator
///          tax must be at most `maxTotalFeeBps`, and the launch record must still be registered for this token with
///          native ETH as its quote. A changed record, an unregistered pool or a protocol fee above v4's own 1,000-pip
///          ceiling reverts before the buy starts.
///        - MEASURED, after the v4 fill: the hook's ACTUAL cut, taken from the hook's token balance delta across the
///          swap, replaces the declared output terms in the same sum, which must again be at most `maxTotalFeeBps`.
///          This is the tripwire for a hook that charges more than it declares; it is a second check on top of the
///          declared one, never a replacement, and it is deliberately saturating (a hook whose balance FELL during the
///          swap measures as 0 rather than reverting a legitimate buy, because the declared check already bounded it).
///      Not covered by the cap, because they are not fees: v4 price impact and v3 price impact. The v3 leg's impact is
///      bounded by the TWAP floor; the v4 leg's by the caller's `minTokenOut`. ADR-15 §4 is explicit that a
///      keeper-supplied `minTokenOut` is not an independent price.
///
///      TWAP FLOOR. The v3 leg reuses FeeSplitter's `_floor` arithmetic on this one pool: the arithmetic-mean tick
///      over `twapWindow` seconds (floored toward negative infinity), a harmonic-mean in-range liquidity floor over the
///      same window, and `minWethOut = quoted x (BPS - maxSlippageBps) / BPS`, where `maxSlippageBps` is at least the
///      pool's own fee so the tolerance is the allowance ABOVE the unavoidable fee. Unlike the splitter's view, which
///      returns `(false, 0)` so a cranker can skip, every failure here reverts: the executor is only ever called with
///      money in hand. The caller may raise the floor with `minWethOut`; it can never lower it, because the effective
///      floor is the larger of the two.
///
///      HOLDS NOTHING. Every amount is checked as a delta against the balance this contract already had at entry, so
///      tokens someone sends here directly can neither brick a buy nor be swept into one, and the final check is that
///      all four balances (USDG, WETH, token, native ETH) are back exactly where they started. There is deliberately
///      no sweep and no admin: this contract has no privileged function at all. `receive` accepts ETH only from WETH,
///      so the native balance outside a call is always 0.
///
///      REENTRANCY. {buy} holds OpenZeppelin's transient guard, which both callbacks also read as "a buy is on the
///      stack". The calls it makes reach USDG, WETH, the v3 pool, the PoolManager, the hook (through the PoolManager)
///      and the token; none can re-enter {buy}, and neither callback does anything outside a buy.
interface IStonkhouseBurn {
    function burn(uint256 amount) external;
}

contract V4BuybackExecutor is IBuybackExecutor, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev The v3 and v4 balances this contract held when a buy started; everything is measured against them.
    struct Held {
        uint256 usdg;
        uint256 weth;
        uint256 token;
        uint256 eth;
    }

    /// @dev The route's fee-type charges in bps, each rounded UP so the cap is never under-counted.
    struct FeeBps {
        /// @dev The v3 pool's fee tier (1 bp for the 0.01 % pool), charged on the USDG input.
        uint16 v3;
        /// @dev The pinned v4 pool's LP fee (0 today), charged on the ETH input.
        uint16 v4Lp;
        /// @dev The PoolManager protocol fee for the zeroForOne direction (0 today, ceiling 10 bps), on the ETH input.
        uint16 v4Protocol;
        /// @dev `launches(poolId).hookFeeBps` (100), charged by the hook on the token output.
        uint16 hook;
        /// @dev `launches(poolId).creatorTaxBps` (100), charged by the hook on the token output.
        uint16 creatorTax;
    }

    /// @notice Native ETH, which is `currency0` of the pinned key.
    address internal constant NATIVE_ETH = address(0);
    /// @dev v4-core TickMath bounds; the extremes leave the whole exact input to be consumed.
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev v4-core's own ceiling on a protocol fee, per direction, in pips (0.10 %). A pool reporting more than this
    ///      is not the state this executor was pinned against, so {buy} refuses it rather than trying to price it.
    uint24 internal constant MAX_PROTOCOL_FEE_PIPS = 1000;
    /// @dev Largest swap amount either leg accepts: both Uniswap versions carry swap amounts as int128.
    uint256 internal constant MAX_SWAP_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Largest `maxTotalFeeBps` the constructor accepts, bps. The measured total on the pinned venue is 201 bps
    ///         (1 bp v3 + 100 hook + 100 creator tax) and at most 211 bps if the protocol-fee controller acts, so this
    ///         leaves room for a cap chosen above the observed total without ever allowing a 7 %-99 % trap venue.
    /// @dev SEC-47: that 201 is the sum {_totalBps} computes, and it mixes an input-side bp with two output-side
    ///      ones. It is an upper bound on the combined drag, not an exact figure -- see {_totalBps}.
    uint16 public constant MAX_TOTAL_FEE_CEIL_BPS = 2500;
    /// @notice Bounds of `twapWindow`, seconds. Same bounds as FeeSplitter's route window.
    uint32 public constant MIN_TWAP_WINDOW = 60;
    uint32 public constant MAX_TWAP_WINDOW = 1 hours;

    /// @notice The FeeSplitter: the only allowed caller of {buy} and the recipient of everything a buy produces.
    address public immutable splitter;
    /// @notice USDG (6 dp).
    IERC20 public immutable usdg;
    /// @notice WETH9.
    address public immutable weth;
    /// @notice The token being bought: `currency1` of the pinned key.
    address public immutable token;

    /// @notice The Uniswap v3 USDG/WETH pool of the first leg.
    address public immutable v3Pool;
    /// @notice That pool's fee tier, hundredths of a bip, read from the pool at deployment (a v3 fee is immutable).
    uint24 public immutable v3Fee;
    /// @notice Whether WETH is the v3 pool's token0, read from the pool at deployment and never assumed.
    bool public immutable wethIsToken0;

    /// @notice The Uniswap v4 PoolManager.
    address public immutable poolManager;
    /// @notice The StateView lens over the same PoolManager.
    address public immutable stateView;
    /// @notice The pinned key's hook, which holds this pool's frozen fee terms.
    address public immutable hooks;
    /// @notice The pinned key's LP fee field (0 on the launch pool: a static, not dynamic, fee).
    uint24 public immutable v4Fee;
    /// @notice The pinned key's tick spacing.
    int24 public immutable v4TickSpacing;
    /// @notice `keccak256(abi.encode(key))`: the one pool id this executor may ever trade or read.
    bytes32 public immutable poolId;

    /// @notice Fee cap over the measured total of every fee component, bps (see FEE GUARD).
    uint16 public immutable maxTotalFeeBps;
    /// @notice v3 TWAP floor tolerance, bps, including the v3 pool's own fee.
    uint16 public immutable maxSlippageBps;
    /// @notice v3 TWAP window, seconds.
    uint32 public immutable twapWindow;
    /// @notice Harmonic-mean in-range liquidity floor over that window, v3 pool L units.
    uint128 public immutable minLiquidity;

    /// @notice A buy completed. `usdgIn` was pulled from the splitter, `usdgSpent` reached the v3 pool and
    ///         `usdgIn - usdgSpent` went back; `tokenOut` tokens were sent to the splitter. `declaredFeeBps` is the
    ///         total read before the buy, `measuredFeeBps` the same total with the hook's actual cut.
    event Bought(
        uint256 usdgIn,
        uint256 usdgSpent,
        uint256 wethOut,
        uint256 tokenOut,
        uint256 minWethOut,
        uint256 declaredFeeBps,
        uint256 measuredFeeBps
    );
    /// @notice {execute} burned `amount` of the token. Must equal the token's total-supply delta.
    event Burned(uint256 amount);

    /// @notice The v3 leg filled `wethOut` WETH, below the effective floor `minimum` (the larger of the TWAP floor and
    ///         the caller's `minWethOut`).
    error FloorNotMet(uint256 wethOut, uint256 minimum);
    /// @notice The v4 leg filled `tokenOut` tokens, below the caller's `minimum`.
    error TooLittleTokens(uint256 tokenOut, uint256 minimum);
    /// @notice The route's total fee-type charge is `totalBps`, above this executor's `capBps`.
    error FeeCapExceeded(uint256 totalBps, uint256 capBps);
    /// @notice The pool's own hook fee is above `V2Constants.MAX_HOOK_FEE_BPS`, whatever the combined cap allows.
    /// @dev F-05-07. `IBuybackExecutor` promises this refusal and the code only ever enforced the COMBINED
    ///      `maxTotalFeeBps`, whose constructor ceiling is 2,500. Those are different quantities: a pool declaring a
    ///      301-bps hook fee under a 302-bps combined cap passed every check while breaking the published promise.
    ///      The ceiling is a hook-fee ceiling, so it is checked against the hook fee alone.
    error HookFeeCapExceeded(uint256 hookBps, uint256 capBps);

    /// @param cfg Everything the executor pins; see {V4BuybackConfig}. Reverts:
    ///        V2Errors.NotAuthorized when `splitter` is zero (nothing could ever call it);
    ///        V2Errors.UnsupportedAsset when USDG, WETH or the token is not a contract, when the key's `currency0` is
    ///        not native ETH, when the token is USDG or WETH, or when the v3 pool's {token0, token1} is not
    ///        {USDG, WETH} in either order;
    ///        V2Errors.NoSource when the PoolManager, StateView, v3 pool or the key's hook is not a contract, when the
    ///        hook or the lens points at another PoolManager, when the v3 pool's observation ring holds fewer than two
    ///        observations, or when the hook has no registered launch for this pool id with this token as `currency1`
    ///        and native ETH as its quote (which is what rejects every hookless pool of the token);
    ///        V2Errors.CeilingExceeded when the v3 fee tier, `maxTotalFeeBps`, `maxSlippageBps`, `twapWindow` or
    ///        `minLiquidity` is outside its bound.
    constructor(V4BuybackConfig memory cfg) {
        if (cfg.splitter == address(0)) revert V2Errors.NotAuthorized();
        if (cfg.key.currency0 != NATIVE_ETH) revert V2Errors.UnsupportedAsset();

        address token_ = cfg.key.currency1;
        if (token_.code.length == 0 || cfg.usdg.code.length == 0 || cfg.weth.code.length == 0) {
            revert V2Errors.UnsupportedAsset();
        }
        if (token_ == cfg.usdg || token_ == cfg.weth) revert V2Errors.UnsupportedAsset();
        if (cfg.poolManager.code.length == 0 || cfg.stateView.code.length == 0 || cfg.v3Pool.code.length == 0) {
            revert V2Errors.NoSource();
        }
        // A hookless key is one of the token's trap pools; the launch hook is what makes the pinned pool the pinned
        // pool, and it is the only place this pool's fee terms exist.
        if (cfg.key.hooks.code.length == 0) revert V2Errors.NoSource();
        if (IPonsLaunchHook(cfg.key.hooks).poolManager() != cfg.poolManager) revert V2Errors.NoSource();
        if (IV4StateView(cfg.stateView).poolManager() != cfg.poolManager) revert V2Errors.NoSource();

        // The v3 leg's pool, its token order and its fee, read from the pool rather than declared.
        address t0 = IUniswapV3PoolOracle(cfg.v3Pool).token0();
        address t1 = IUniswapV3PoolOracle(cfg.v3Pool).token1();
        bool wethIsToken0_;
        if (t0 == cfg.weth && t1 == cfg.usdg) wethIsToken0_ = true;
        else if (t0 != cfg.usdg || t1 != cfg.weth) revert V2Errors.UnsupportedAsset();
        // Observation count is not elapsed seconds; a sparse ring with two old observations can still answer
        // observe([window, 0]). {_wethFloor} performs the actual historical read before every swap.
        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(cfg.v3Pool).slot0();
        if (cardinality < 2) revert V2Errors.NoSource();
        uint24 v3Fee_ = IUniV3SwapPool(cfg.v3Pool).fee();
        if (v3Fee_ == 0 || v3Fee_ > V2Constants.MAX_ROUTE_FEE_TIER) revert V2Errors.CeilingExceeded();

        if (cfg.maxTotalFeeBps == 0 || cfg.maxTotalFeeBps > MAX_TOTAL_FEE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        // The tolerance has to leave room for the pool fee it is measured against, exactly as FeeSplitter's
        // _checkRoute requires of a route, and may not exceed the shared payout-slippage ceiling.
        if (
            cfg.maxSlippageBps < _toBpsUp(v3Fee_) || cfg.maxSlippageBps > V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS
                || cfg.twapWindow < MIN_TWAP_WINDOW || cfg.twapWindow > MAX_TWAP_WINDOW || cfg.minLiquidity == 0
        ) revert V2Errors.CeilingExceeded();

        bytes32 poolId_ = keccak256(abi.encode(cfg.key));
        (bool registered, bool memecoinIsCurrency0, address memecoin, address quoteToken,,,,,,,,,) =
            IPonsLaunchHook(cfg.key.hooks).launches(poolId_);
        if (!registered || memecoinIsCurrency0 || memecoin != token_ || quoteToken != NATIVE_ETH) {
            revert V2Errors.NoSource();
        }

        splitter = cfg.splitter;
        usdg = IERC20(cfg.usdg);
        weth = cfg.weth;
        token = token_;
        v3Pool = cfg.v3Pool;
        v3Fee = v3Fee_;
        wethIsToken0 = wethIsToken0_;
        poolManager = cfg.poolManager;
        stateView = cfg.stateView;
        hooks = cfg.key.hooks;
        v4Fee = cfg.key.fee;
        v4TickSpacing = cfg.key.tickSpacing;
        poolId = poolId_;
        maxTotalFeeBps = cfg.maxTotalFeeBps;
        maxSlippageBps = cfg.maxSlippageBps;
        twapWindow = cfg.twapWindow;
        minLiquidity = cfg.minLiquidity;
    }

    /// @dev Native ETH arrives only when WETH is unwrapped mid-buy. Refusing everyone else keeps the native balance
    ///      outside a call at exactly 0, so "holds nothing" needs no sweep.
    receive() external payable {
        if (msg.sender != weth) revert V2Errors.NotAuthorized();
    }

    /*//////////////////////////////////////////////////////////////
                                   BUY
    //////////////////////////////////////////////////////////////*/

    /// @notice Spends `usdgIn` USDG of the splitter's on the pinned route and sends every token bought, plus any
    ///         unspent USDG, back to the splitter in the same call.
    /// @dev Only `splitter` (V2Errors.NotAuthorized), which must have approved this contract for `usdgIn` first. This
    ///      contract keeps nothing: every balance is back at its entry value when the call returns. Reverts, and so
    ///      changes nothing:
    ///        - V2Errors.NotAuthorized: caller is not the splitter;
    ///        - V2Errors.BadUnits: `usdgIn` is 0 or above the int128 swap bound, a short or fee-on-transfer pull, the
    ///          v3 pool paid the wrong side or took more USDG than it was given, WETH did not unwrap one-for-one, the
    ///          v4 leg did not consume all of the ETH, the token did not arrive, or a balance is not back at entry;
    ///        - V2Errors.BadPrice: `minTokenOut` is 0 (a buy without a floor is never intended);
    ///        - V2Errors.NoSource: the v3 TWAP is unusable (the pool's ring does not reach the window, a zero
    ///          liquidity delta, a mean tick out of range, harmonic-mean liquidity below `minLiquidity`, a zero
    ///          quote), or the hook's launch record for the pinned pool id is gone or no longer names this token;
    ///        - V2Errors.CeilingExceeded: the PoolManager reports a protocol fee above v4's own 1,000-pip ceiling;
    ///        - {FeeCapExceeded}: the declared or the measured total fee is above `maxTotalFeeBps` (FEE GUARD);
    ///        - {FloorNotMet}: the v3 leg filled below the effective WETH floor;
    ///        - {TooLittleTokens}: the v4 leg filled below `minTokenOut`;
    ///        - whatever USDG, WETH, the v3 pool, the PoolManager, the hook or the token revert with.
    /// @param usdgIn USDG base units (6 dp) to pull from the splitter and spend. The splitter, not this contract,
    ///        enforces the per-buy cap and the interval.
    /// @param minTokenOut Smallest acceptable token amount (18 dp), the caller's own floor on the v4 leg. Must not be
    ///        0. ADR-15 §4: a keeper-supplied minimum is not an independent price, only a bound on this fill.
    /// @param minWethOut Optional extra floor on the v3 leg, WETH base units. The effective floor is the LARGER of
    ///        this and the on-chain TWAP floor, so passing 0 keeps the contract's own floor and no caller can weaken
    ///        it.
    /// @return usdgSpent USDG the v3 pool actually took (the rest went back to the splitter).
    /// @return tokenOut Tokens sent to the splitter, measured as this contract's own balance delta.
    function buy(uint256 usdgIn, uint256 minTokenOut, uint256 minWethOut)
        external
        nonReentrant
        returns (uint256 usdgSpent, uint256 tokenOut)
    {
        if (msg.sender != splitter) revert V2Errors.NotAuthorized();
        if (usdgIn == 0 || usdgIn > MAX_SWAP_AMOUNT) revert V2Errors.BadUnits();
        if (minTokenOut == 0) revert V2Errors.BadPrice();

        // DECLARED fee guard, before a single unit of USDG moves.
        FeeBps memory fees = _feeBps();
        // HOOK-ONLY CEILING, separate from the combined cap below. `V2Constants.MAX_HOOK_FEE_BPS` is a bound on the
        // HOOK's cut, and `maxTotalFeeBps` is a bound on every fee added together; neither implies the other, and
        // only the second was ever enforced. Checked on `fees.hook`, which is `launches(poolId).hookFeeBps` read from
        // the hook itself - the creator tax is a different party's cut and is not part of a hook-fee ceiling.
        if (fees.hook > V2Constants.MAX_HOOK_FEE_BPS) {
            revert HookFeeCapExceeded(fees.hook, V2Constants.MAX_HOOK_FEE_BPS);
        }
        uint256 declared = _totalBps(fees, uint256(fees.hook) + fees.creatorTax);
        if (declared > maxTotalFeeBps) revert FeeCapExceeded(declared, maxTotalFeeBps);

        Held memory held = _held();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        if (usdg.balanceOf(address(this)) - held.usdg != usdgIn) revert V2Errors.BadUnits();

        // Leg 1: USDG -> WETH, under the larger of the contract's TWAP floor and the caller's.
        uint256 twapFloor = _wethFloor(usdgIn);
        uint256 minWeth = twapFloor > minWethOut ? twapFloor : minWethOut;
        uint256 wethOut;
        (usdgSpent, wethOut) = _v3UsdgToWeth(usdgIn);
        if (wethOut < minWeth) revert FloorNotMet(wethOut, minWeth);
        if (wethOut > MAX_SWAP_AMOUNT) revert V2Errors.BadUnits();

        // Leg 2: unwrap. Both sides are checked, so a WETH that does not pay one-for-one stops the buy here.
        IWeth9(weth).withdraw(wethOut);
        if (IERC20(weth).balanceOf(address(this)) != held.weth) revert V2Errors.BadUnits();
        if (address(this).balance - held.eth != wethOut) revert V2Errors.BadUnits();

        // Leg 3: ETH -> token on the pinned key. The hook's cut is measured across exactly this swap.
        uint256 hookHeld = IERC20(token).balanceOf(hooks);
        (uint256 ethPaid, uint256 taken) = _v4EthToToken(wethOut);
        if (ethPaid != wethOut) revert V2Errors.BadUnits();
        tokenOut = IERC20(token).balanceOf(address(this)) - held.token;
        if (tokenOut != taken) revert V2Errors.BadUnits();
        if (tokenOut < minTokenOut) revert TooLittleTokens(tokenOut, minTokenOut);

        // MEASURED fee guard: the hook's actual cut in place of the declared output terms.
        uint256 measured = _totalBps(fees, _measuredOutputCutBps(hookHeld, tokenOut));
        if (measured > maxTotalFeeBps) revert FeeCapExceeded(measured, maxTotalFeeBps);

        // Everything home in the same call.
        uint256 splitterHeld = IERC20(token).balanceOf(splitter);
        IERC20(token).safeTransfer(splitter, tokenOut);
        if (IERC20(token).balanceOf(splitter) - splitterHeld != tokenOut) revert V2Errors.BadUnits();
        uint256 unspent = usdgIn - usdgSpent;
        if (unspent != 0) usdg.safeTransfer(splitter, unspent);

        Held memory left = _held();
        if (left.usdg != held.usdg || left.weth != held.weth || left.token != held.token || left.eth != held.eth) {
            revert V2Errors.BadUnits();
        }
        emit Bought(usdgIn, usdgSpent, wethOut, tokenOut, minWeth, declared, measured);
    }

    /// @inheritdoc IBuybackExecutor
    /// @dev Same route as {buy} with `minWethOut = 0` (the TWAP floor still raises-never-lowers). Burns `tokenOut`
    ///      so `FeeSplitter.buyback` can check `burned` against the token's total-supply delta (chain state, not a
    ///      counter). Cap and cooldown live on the splitter (`V2Constants.BUYBACK_CAP_CEIL`, `BUYBACK_COOLDOWN`).
    function execute(uint256 usdgIn, uint256 minTokenOut)
        external
        nonReentrant
        returns (uint256 tokenOut, uint256 burned)
    {
        if (msg.sender != splitter) revert V2Errors.NotAuthorized();
        if (usdgIn == 0 || usdgIn > MAX_SWAP_AMOUNT) revert V2Errors.BadUnits();
        if (minTokenOut == 0) revert V2Errors.BadPrice();

        FeeBps memory fees = _feeBps();
        // HOOK-ONLY CEILING, separate from the combined cap below. `V2Constants.MAX_HOOK_FEE_BPS` is a bound on the
        // HOOK's cut, and `maxTotalFeeBps` is a bound on every fee added together; neither implies the other, and
        // only the second was ever enforced. Checked on `fees.hook`, which is `launches(poolId).hookFeeBps` read from
        // the hook itself - the creator tax is a different party's cut and is not part of a hook-fee ceiling.
        if (fees.hook > V2Constants.MAX_HOOK_FEE_BPS) {
            revert HookFeeCapExceeded(fees.hook, V2Constants.MAX_HOOK_FEE_BPS);
        }
        uint256 declared = _totalBps(fees, uint256(fees.hook) + fees.creatorTax);
        if (declared > maxTotalFeeBps) revert FeeCapExceeded(declared, maxTotalFeeBps);

        Held memory held = _held();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        if (usdg.balanceOf(address(this)) - held.usdg != usdgIn) revert V2Errors.BadUnits();

        uint256 minWeth = _wethFloor(usdgIn);
        uint256 usdgSpent;
        uint256 wethOut;
        (usdgSpent, wethOut) = _v3UsdgToWeth(usdgIn);
        if (wethOut < minWeth) revert FloorNotMet(wethOut, minWeth);
        if (wethOut > MAX_SWAP_AMOUNT) revert V2Errors.BadUnits();

        IWeth9(weth).withdraw(wethOut);
        if (IERC20(weth).balanceOf(address(this)) != held.weth) revert V2Errors.BadUnits();
        if (address(this).balance - held.eth != wethOut) revert V2Errors.BadUnits();

        uint256 hookHeld = IERC20(token).balanceOf(hooks);
        (uint256 ethPaid, uint256 taken) = _v4EthToToken(wethOut);
        if (ethPaid != wethOut) revert V2Errors.BadUnits();
        tokenOut = IERC20(token).balanceOf(address(this)) - held.token;
        if (tokenOut != taken) revert V2Errors.BadUnits();
        if (tokenOut < minTokenOut) revert TooLittleTokens(tokenOut, minTokenOut);

        uint256 measured = _totalBps(fees, _measuredOutputCutBps(hookHeld, tokenOut));
        if (measured > maxTotalFeeBps) revert FeeCapExceeded(measured, maxTotalFeeBps);

        uint256 supplyBeforeBurn = IERC20(token).totalSupply();
        IStonkhouseBurn(token).burn(tokenOut);
        burned = supplyBeforeBurn - IERC20(token).totalSupply();
        if (burned != tokenOut) revert V2Errors.BadUnits();

        uint256 unspent = usdgIn - usdgSpent;
        if (unspent != 0) usdg.safeTransfer(splitter, unspent);

        Held memory left = _held();
        if (left.usdg != held.usdg || left.weth != held.weth || left.token != held.token || left.eth != held.eth) {
            revert V2Errors.BadUnits();
        }
        emit Bought(usdgIn, usdgSpent, wethOut, tokenOut, minWeth, declared, measured);
        emit Burned(burned);
    }

    /*//////////////////////////////////////////////////////////////
                                CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice The v3 pool asking for the input of the swap {buy} started.
    /// @dev Reverts V2Errors.NotAuthorized unless the caller is the pinned pool AND a {buy} is on the stack, so no
    ///      pool and no stranger can make this contract pay for anything it did not ask for. Reverts V2Errors.BadUnits
    ///      if the pool asks for WETH (this leg only ever sells USDG) or asks for nothing.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != v3Pool) revert V2Errors.NotAuthorized();
        if (!_reentrancyGuardEntered()) revert V2Errors.NotAuthorized();
        (int256 wethDelta, int256 usdgDelta) =
            wethIsToken0 ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (wethDelta > 0 || usdgDelta <= 0) revert V2Errors.BadUnits();
        // casting to 'uint256' is safe because the line above returns for a usdgDelta that is not positive
        // forge-lint: disable-next-line(unsafe-typecast)
        usdg.safeTransfer(msg.sender, uint256(usdgDelta));
    }

    /// @notice The PoolManager handing this contract the lock so the v4 leg can swap, settle and take.
    /// @dev Reverts V2Errors.NotAuthorized unless the caller is the pinned PoolManager AND a {buy} is on the stack.
    ///      The key is rebuilt from immutables here, never taken from `data`, so this contract can only ever move the
    ///      pinned pool. Reverts V2Errors.BadUnits when the delta is not "ETH owed, token received", which is what a
    ///      zeroForOne exact-input swap must produce.
    /// @param data `abi.encode(ethIn)`, the exact-input ETH amount.
    /// @return `abi.encode(ethPaid, tokenTaken)`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert V2Errors.NotAuthorized();
        if (!_reentrancyGuardEntered()) revert V2Errors.NotAuthorized();
        uint256 ethIn = abi.decode(data, (uint256));
        // casting to 'int256' is safe because buy() refuses a leg above MAX_SWAP_AMOUNT (int128 max)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(ethIn);
        int256 delta = IV4PoolManager(poolManager)
            .swap(
                key(),
                V4SwapParams({
                    zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1
                }),
                ""
            );
        // v4-core BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower, both signed from our point of
        // view and already net of the hook's afterSwap cut.
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 amount0 = int128(delta >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 amount1 = int128(delta);
        if (amount0 >= 0 || amount1 <= 0) revert V2Errors.BadUnits();
        // casting to 'uint128'/'uint256' is safe because the line above returns unless amount0 is negative and
        // amount1 positive, so both magnitudes fit a uint128 and widen losslessly
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ethPaid = uint256(uint128(-amount0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 taken = uint256(uint128(amount1));
        IV4PoolManager(poolManager).sync(NATIVE_ETH);
        IV4PoolManager(poolManager).settle{value: ethPaid}();
        IV4PoolManager(poolManager).take(token, address(this), taken);
        return abi.encode(ethPaid, taken);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The one PoolKey this executor may trade, rebuilt from its immutables.
    /// @dev `keccak256(abi.encode(key()))` is {poolId}.
    function key() public view returns (V4PoolKey memory) {
        return
            V4PoolKey({currency0: NATIVE_ETH, currency1: token, fee: v4Fee, tickSpacing: v4TickSpacing, hooks: hooks});
    }

    /// @notice The route's fee-type charges right now, in bps rounded up, and their total.
    /// @dev Anyone. The same read {buy}'s declared guard makes, so a keeper can staticcall it before spending and a
    ///      monitor can watch it. It FAILS CLOSED like the guard: a launch record that is gone or no longer names this
    ///      token reverts V2Errors.NoSource, and a protocol fee above v4's ceiling reverts V2Errors.CeilingExceeded.
    ///      `total` above {maxTotalFeeBps} means {buy} would refuse. Price impact is not a fee and is not in `total`.
    function feeBps()
        external
        view
        returns (uint16 v3, uint16 v4Lp, uint16 v4Protocol, uint16 hook, uint16 creatorTax, uint256 total)
    {
        FeeBps memory f = _feeBps();
        return (f.v3, f.v4Lp, f.v4Protocol, f.hook, f.creatorTax, _totalBps(f, uint256(f.hook) + f.creatorTax));
    }

    /// @notice The contract's own WETH floor for `usdgIn`, the minimum the v3 leg must fill.
    /// @dev Anyone. Reverts V2Errors.NoSource for exactly the reasons {buy} does (see its NatSpec) and
    ///      V2Errors.BadUnits for a zero `usdgIn`, so a keeper can tell "no usable TWAP" from "the price moved"
    ///      before it spends.
    function wethFloor(uint256 usdgIn) external view returns (uint256 minWethOut) {
        if (usdgIn == 0) revert V2Errors.BadUnits();
        return _wethFloor(usdgIn);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Hundredths of a bip (Uniswap's pips) to bps, rounded UP: 100 -> 1, 1,000 -> 10, 0 -> 0.
    function _toBpsUp(uint256 pips) private pure returns (uint16) {
        // casting to 'uint16' is safe because every caller bounds `pips` well below 65_535 * 100
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16((pips + 99) / 100);
    }

    /// @dev The four balances a buy is measured against.
    function _held() private view returns (Held memory h) {
        h.usdg = usdg.balanceOf(address(this));
        h.weth = IERC20(weth).balanceOf(address(this));
        h.token = IERC20(token).balanceOf(address(this));
        h.eth = address(this).balance;
    }

    /// @dev The fee terms that matter, read where they actually live (see FEE GUARD). Fails closed on a launch record
    ///      that is gone, points at another token, or is not ETH-quoted, and on a protocol fee above v4's own ceiling.
    function _feeBps() private view returns (FeeBps memory f) {
        f.v3 = _toBpsUp(v3Fee);
        (,, uint24 protocolFee, uint24 lpFee) = IV4StateView(stateView).getSlot0(poolId);
        // v4-core packs the protocol fee as two 12-bit pip values; the low twelve bits charge zeroForOne swaps, which
        // is the only direction this executor trades.
        uint24 pips = protocolFee & 0xFFF;
        if (pips > MAX_PROTOCOL_FEE_PIPS) revert V2Errors.CeilingExceeded();
        f.v4Protocol = _toBpsUp(pips);
        f.v4Lp = _toBpsUp(lpFee);
        (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,,,,
            uint16 creatorTaxBps,,,
            uint16 hookFeeBps,,
        ) = IPonsLaunchHook(hooks).launches(poolId);
        if (!registered || memecoinIsCurrency0 || memecoin != token || quoteToken != NATIVE_ETH) {
            revert V2Errors.NoSource();
        }
        f.hook = hookFeeBps;
        f.creatorTax = creatorTaxBps;
    }

    /// @dev The input-side charges plus whatever output-side cut the caller passes (declared or measured).
    ///      SEC-47: THIS SUM MIXES DENOMINATIONS AND IS NOT A BPS OF ANY ONE QUANTITY. `v3`, `v4Lp` and `v4Protocol`
    ///      are taken out of what goes IN; the hook fee and the creator tax are taken out of what comes OUT. Adding
    ///      them gives `a + b` where the charges are applied in sequence and the real drag is `a + b - ab`, so the
    ///      total this returns is always at least the true one. The error is in the SAFE direction on purpose: a cap
    ///      on this number can only refuse a route that a denomination-exact total would have allowed, never allow
    ///      one it would have refused. Read `maxTotalFeeBps` as a ceiling on the sum of the route's fee TERMS, not
    ///      as a promise about realised slippage -- {_wethFloor} and `minTokenOut` are what bound the fill.
    function _totalBps(FeeBps memory f, uint256 outputCutBps) private pure returns (uint256) {
        return uint256(f.v3) + f.v4Lp + f.v4Protocol + outputCutBps;
    }

    /// @dev The hook's ACTUAL cut of the swap's gross output, bps rounded up: the hook holds its fee and the creator
    ///      tax in the token it took them in, so its balance delta across the swap IS the cut and
    ///      `gross = tokenOut + cut`. Saturating on the way down: a hook whose balance fell during the swap (its
    ///      operator sweeping in the same transaction) measures 0 rather than reverting a buy the declared guard
    ///      already bounded.
    function _measuredOutputCutBps(uint256 hookHeld, uint256 tokenOut) private view returns (uint256) {
        uint256 held = IERC20(token).balanceOf(hooks);
        uint256 cut = held > hookHeld ? held - hookHeld : 0;
        uint256 gross = tokenOut + cut;
        if (gross == 0) return V2Constants.BPS;
        return Math.mulDiv(cut, V2Constants.BPS, gross, Math.Rounding.Ceil);
    }

    /// @dev FeeSplitter's `_floor` arithmetic on this one pool, but reverting instead of reporting `(false, 0)`.
    ///      `minWethOut = TWAP value of usdgIn x (BPS - maxSlippageBps) / BPS`, with `maxSlippageBps` covering the
    ///      pool's own fee as well as the tolerance above it.
    function _wethFloor(uint256 usdgIn) private view returns (uint256 minWethOut) {
        uint32 window = twapWindow;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory ticks, uint160[] memory secondsPerLiquidity) = IUniswapV3PoolOracle(v3Pool).observe(secondsAgos);
        if (ticks.length != 2 || secondsPerLiquidity.length != 2) revert V2Errors.NoSource();

        int256 tickDelta = int256(ticks[1]) - int256(ticks[0]);
        int256 len = int256(uint256(window));
        int256 mean = tickDelta / len;
        // Solidity division truncates toward zero; the mean tick is floored toward negative infinity, as
        // v3-periphery's OracleLibrary.consult does.
        if (tickDelta < 0 && tickDelta % len != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert V2Errors.NoSource();

        uint160 splDelta;
        unchecked {
            splDelta = secondsPerLiquidity[1] - secondsPerLiquidity[0];
        }
        if (splDelta == 0) revert V2Errors.NoSource();
        if ((uint256(window) << 128) / uint256(splDelta) < minLiquidity) revert V2Errors.NoSource();

        // casting to 'int24' is safe because the range check above returns outside [MIN_TICK, MAX_TICK]
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(int24(mean));
        // USDG is the base (what is spent) and WETH the quote (what is quoted), whichever way the pool sorts them.
        bool usdgIsToken0 = !wethIsToken0;
        uint256 quoted;
        if (sqrtRatio <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatio) * sqrtRatio;
            quoted = usdgIsToken0
                ? FullMath.mulDiv(ratioX192, usdgIn, 1 << 192)
                : FullMath.mulDiv(1 << 192, usdgIn, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
            quoted = usdgIsToken0
                ? FullMath.mulDiv(ratioX128, usdgIn, 1 << 128)
                : FullMath.mulDiv(1 << 128, usdgIn, ratioX128);
        }
        if (quoted == 0) revert V2Errors.NoSource();
        minWethOut = FullMath.mulDiv(quoted, V2Constants.BPS - maxSlippageBps, V2Constants.BPS);
        if (minWethOut == 0) revert V2Errors.NoSource();
    }

    /// @dev Exact-input USDG -> WETH in the pinned v3 pool, with the price limit at its extreme so the pool consumes
    ///      the whole input unless it runs out of in-range liquidity.
    function _v3UsdgToWeth(uint256 usdgIn) private returns (uint256 usdgSpent, uint256 wethOut) {
        bool zeroForOne = !wethIsToken0;
        // casting to 'int256' is safe because buy() refuses a usdgIn above MAX_SWAP_AMOUNT (int128 max)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = int256(usdgIn);
        (int256 amount0, int256 amount1) = IUniV3SwapPool(v3Pool)
            .swap(address(this), zeroForOne, amountSpecified, zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1, "");
        (int256 wethDelta, int256 usdgDelta) = wethIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (wethDelta >= 0 || usdgDelta <= 0) revert V2Errors.BadUnits();
        // casting to 'uint256' is safe because the line above returns unless wethDelta is negative and usdgDelta
        // positive, so both magnitudes are non-negative int256 values
        // forge-lint: disable-next-line(unsafe-typecast)
        wethOut = uint256(-wethDelta);
        // forge-lint: disable-next-line(unsafe-typecast)
        usdgSpent = uint256(usdgDelta);
        if (usdgSpent > usdgIn) revert V2Errors.BadUnits();
    }

    /// @dev Exact-input ETH -> token on the pinned key, through the PoolManager's lock.
    function _v4EthToToken(uint256 ethIn) private returns (uint256 ethPaid, uint256 taken) {
        bytes memory ret = IV4PoolManager(poolManager).unlock(abi.encode(ethIn));
        (ethPaid, taken) = abi.decode(ret, (uint256, uint256));
    }
}
