// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";

/// @notice Shared fixture for the v2 tests: actors, the clock, USDG and two Stock Token markets.
/// @dev TOKENS. The v1 mocks already model everything v2 needs, so they are reused rather than forked into
///      src/v2/mocks:
///        - {MockERC20} as USDG (6 dp): `pause()` and `freeze(addr)` make transfers revert with the live Paxos
///          selectors, which is how a test drives "USDG paused / holder frozen -> ledger credit".
///        - {MockStockToken} (18 dp): `setOraclePaused`, `setUiMultiplier`, and the blocklist switch
///          `blockAccount(addr)` that makes every transfer to or from that address revert `AccountBlocked`, plus
///          the issuer's `pause()` and `adminBurn`.
///      Every mint is permissionless, so a suite funds whoever it needs with {_fund}.
///
///      CLOCK. setUp warps to START, Wednesday 2026-09-09 20:26:40 New York (EDT), after the close. The next three
///      expiries on the 16:00 New York grid are pinned below (EDT: 20:00 UTC; that week's holiday, Labor Day on
///      Monday 09-07, is already past), so a suite can create a daily series and two weeklies without a calendar. FRI_2026_09_18 is the weekly the committed
///      series-id vectors use (script/v2/EmitSeriesIds.s.sol).
///
///      EXTENSION POINTS. setUp runs tokens -> funding -> {_deployFeeds} -> {_deployCore}; the last two are empty
///      here and exist so the price sources and the core contracts can join the fixture without re-ordering it:
///        - {_deployFeeds}: one MockRoundFeed per market (src/v2/mocks/MockRoundFeed.sol, added with the price
///          sources), seeded from NVDA_FEED_ANSWER / TSLA_FEED_ANSWER; a MockUniV3Pool where a suite needs one.
///        - {_deployCore}: calendar, sources, oracle, clearinghouse, order book, keeper rewards, wired with
///          `admin` holding DEFAULT_ADMIN_ROLE and `guardian` GUARDIAN_ROLE. It runs after funding, so an override may
///          also have actors deposit or approve.
///      A suite overrides a hook and calls `super` when it extends rather than replaces it.
abstract contract BaseV2Test is Test {
    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    /// @dev DEFAULT_ADMIN_ROLE on every v2 contract (the one hot key, owner decision).
    address internal admin = makeAddr("admin");
    /// @dev GUARDIAN_ROLE: pauses new risk, vetoes uncorroborated settlements.
    address internal guardian = makeAddr("guardian");
    /// @dev Runs the permissionless lifecycle calls, with no role (ADR-06).
    address internal keeper = makeAddr("keeper");
    /// @dev Writers and buyers.
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    /// @dev Market maker (MakerVault quoter or a plain quoting wallet).
    address internal mm = makeAddr("mm");
    /// @dev Fee recipient and keeper-rewards funder.
    address internal treasury = makeAddr("treasury");

    /*//////////////////////////////////////////////////////////////
                                  CLOCK
    //////////////////////////////////////////////////////////////*/

    /// @dev Wednesday 2026-09-09 20:26:40 EDT (2026-09-10 00:26:40 UTC).
    uint256 internal constant START = 1_789_000_000;
    /// @dev Thursday 2026-09-10 16:00 EDT: a daily expiry.
    uint40 internal constant THU_2026_09_10 = 1_789_070_400;
    /// @dev Friday 2026-09-11 16:00 EDT: the weekly expiry of START's week.
    uint40 internal constant FRI_2026_09_11 = 1_789_156_800;
    /// @dev Friday 2026-09-18 16:00 EDT: next week's weekly.
    uint40 internal constant FRI_2026_09_18 = 1_789_761_600;

    /*//////////////////////////////////////////////////////////////
                             MARKET FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Spot, USDG base units (6 dp) per whole share. NVDA matches the v1 fixture (test/Base.t.sol).
    uint256 internal constant NVDA_SPOT = 220_000_000;
    uint256 internal constant TSLA_SPOT = 358_040_000;
    /// @dev The same spots as 8-dp Chainlink answers, for the feed mocks.
    int256 internal constant NVDA_FEED_ANSWER = 220_00000000;
    int256 internal constant TSLA_FEED_ANSWER = 358_04000000;
    /// @dev A 1.00 USDG strike grid: every strike a multiple of 1_000_000 (itself a multiple of PRICE_TICK).
    uint64 internal constant STRIKE_TICK = 1_000_000;

    /// @dev Default balances {_fundActors} mints: 1,000,000 USDG and 1,000 shares of each Stock Token.
    uint256 internal constant ACTOR_USDG = 1_000_000e6;
    uint256 internal constant ACTOR_SHARES = 1_000e18;

    /*//////////////////////////////////////////////////////////////
                                CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockERC20 internal usdg;
    MockStockToken internal nvda;
    MockStockToken internal tsla;

    function setUp() public virtual {
        vm.warp(START);
        _deployTokens();
        _fundActors();
        _deployFeeds();
        _deployCore();
    }

    /*//////////////////////////////////////////////////////////////
                                  HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev USDG (6 dp) and two 18-dp Stock Tokens. Symbols follow the v1 fixture.
    function _deployTokens() internal virtual {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockStockToken("NVDA Stock Token", "NVDAx");
        tsla = new MockStockToken("TSLA Stock Token", "TSLAx");
        vm.label(address(usdg), "USDG");
        vm.label(address(nvda), "NVDAx");
        vm.label(address(tsla), "TSLAx");
    }

    /// @dev Writers, buyers and the market maker get USDG and both Stock Tokens. admin, guardian, keeper and
    ///      treasury start empty, so a fee or bounty they receive shows up as their whole balance.
    function _fundActors() internal virtual {
        address[4] memory traders = [alice, bob, carol, mm];
        for (uint256 i; i < traders.length; ++i) {
            _fund(traders[i], ACTOR_USDG, ACTOR_SHARES, ACTOR_SHARES);
        }
    }

    /// @dev Price-feed mocks per market. Empty until the source mocks exist; see the contract NatSpec.
    function _deployFeeds() internal virtual {}

    /// @dev Core v2 contracts and their roles. Empty until the core contracts exist; see the contract NatSpec.
    function _deployCore() internal virtual {}

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint USDG (6 dp base units) and Stock Tokens (18 dp base units) to `who`. Zero amounts are skipped.
    function _fund(address who, uint256 usdgAmount, uint256 nvdaAmount, uint256 tslaAmount) internal {
        if (usdgAmount != 0) usdg.mint(who, usdgAmount);
        if (nvdaAmount != 0) nvda.mint(who, nvdaAmount);
        if (tslaAmount != 0) tsla.mint(who, tslaAmount);
    }
}
