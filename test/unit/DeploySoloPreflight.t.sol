// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySolo} from "../../script/DeploySolo.s.sol";
import {AccountFactory} from "../../src/solo/AccountFactory.sol";
import {WriterAccount} from "../../src/solo/Account.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockFeed} from "../../src/mocks/MockFeed.sol";
import {MockClear} from "../../src/mocks/MockClear.sol";
import {MockSeaport} from "../../src/mocks/MockSeaport.sol";

/// @notice Drives `script/DeploySolo.s.sol` end to end (environment in, factory out) against the mocks,
///         and proves each preflight line refuses the input it is there for.
/// @dev ONE test function, cases in order. `vm.setEnv` writes the PROCESS environment, and forge runs the
///      functions of a test contract on parallel threads: two cases in separate functions setting ASSET
///      would race each other (and any other env-driven test in the suite). Sequenced in one function, and
///      with no other test reading these variables, there is nothing to race. Every variable the script
///      reads is set before each run and blanked at the end (`envOr` treats a blank as unset).
///
///      The Seaport mock answers `information()` with version "1.6" and a ZERO ConduitController, so the
///      canonical-controller line is skipped through PREFLIGHT_SKIP_CONDUIT_CONTROLLER, the script's
///      test-only flag; one case below sets the flag back to false and shows the check is on by default.
contract DeploySoloPreflightTest is Test {
    uint256 internal constant DEPLOYER_PK = 0xA11CE;
    uint256 internal constant CAP = 27e18;
    int256 internal constant SPOT_FEED = 358_04000000;

    address internal admin = makeAddr("admin");
    address internal feeSafe = makeAddr("feeSafe");

    MockStockToken internal tsla;
    MockERC20 internal usdg;
    MockClear internal clear;
    MockSeaport internal seaport;
    MockFeed internal feed;

    function setUp() public {
        vm.warp(1_789_000_000);
        tsla = new MockStockToken("Tesla Stock Token", "TSLA");
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        clear = new MockClear();
        seaport = new MockSeaport();
        feed = new MockFeed(8, SPOT_FEED, "Robinhood TSLA / USD");
    }

    /// @dev Sets every variable the script reads; the three that vary per case are parameters.
    function _env(address asset, address priceFeed, uint256 cap) internal {
        vm.setEnv("DEPLOYER_PK", vm.toString(DEPLOYER_PK));
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("SAFE_FEE", vm.toString(feeSafe));
        vm.setEnv("USDG", vm.toString(address(usdg)));
        vm.setEnv("CLEARINGHOUSE", vm.toString(address(clear)));
        vm.setEnv("SEAPORT", vm.toString(address(seaport)));
        vm.setEnv("EXPECTED_TICKER", "TSLA");
        vm.setEnv("PREFLIGHT_SKIP_CONDUIT_CONTROLLER", "true");
        vm.setEnv("ASSET", vm.toString(asset));
        vm.setEnv("PRICE_FEED", vm.toString(priceFeed));
        vm.setEnv("DEPOSIT_CAP", vm.toString(cap));
    }

    function _unsetEnv() internal {
        string[12] memory names = [
            "DEPLOYER_PK",
            "ADMIN",
            "SAFE_FEE",
            "USDG",
            "CLEARINGHOUSE",
            "SEAPORT",
            "EXPECTED_TICKER",
            "PREFLIGHT_SKIP_CONDUIT_CONTROLLER",
            "ASSET",
            "PRICE_FEED",
            "DEPOSIT_CAP",
            "SAFE_ADMIN"
        ];
        for (uint256 i; i < names.length; i++) {
            vm.setEnv(names[i], "");
        }
    }

    /// @dev Expect `run()` to revert with exactly `reason` for the current environment.
    function _refused(string memory reason) internal {
        DeploySolo script = new DeploySolo();
        vm.expectRevert(bytes(reason));
        script.run();
    }

    function test_preflight_everyCaseInOrder() public {
        // ---------------------------------------------------------------- happy path
        _env(address(tsla), address(feed), CAP);
        AccountFactory factory = new DeploySolo().run();
        assertEq(address(factory.asset()), address(tsla), "asset");
        assertEq(address(factory.usdg()), address(usdg), "usdg");
        assertEq(address(factory.clear()), address(clear), "clear");
        assertEq(address(factory.seaport()), address(seaport), "seaport");
        assertEq(address(factory.priceFeed()), address(feed), "feed");
        assertEq(factory.conduitKey(), bytes32(0), "conduit key");
        assertEq(factory.maxPriceAge(), 4 days, "max price age");
        assertEq(factory.depositCap(), CAP, "deposit cap from DEPOSIT_CAP");
        assertEq(factory.feeRecipient(), feeSafe, "fee recipient from SAFE_FEE");
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin), "ADMIN holds DEFAULT_ADMIN_ROLE");
        assertFalse(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), vm.addr(DEPLOYER_PK)), "the deployer holds nothing");
        WriterAccount impl = factory.implementation();
        assertEq(address(impl.factory()), address(factory), "implementation.factory");
        assertEq(address(impl.asset()), address(tsla), "implementation.asset");
        assertEq(address(impl.priceFeed()), address(feed), "implementation.priceFeed");
        assertTrue(impl.initialized(), "implementation locked");
        assertEq(impl.owner(), address(0), "implementation has no owner");
        (uint16 minOtm, uint16 maxOtm, uint16 minPrem, uint16 maxUtil, uint16 feeBps, uint64 maxContracts) =
            factory.policy();
        assertEq(minOtm, 300);
        assertEq(maxOtm, 1200);
        assertEq(minPrem, 40);
        assertEq(maxUtil, 9500);
        assertEq(feeBps, 500);
        assertEq(maxContracts, 50);

        // ---------------------------------------------------------------- fat-fingered ASSET: symbol
        MockStockToken aapl = new MockStockToken("Apple Stock Token", "AAPL");
        _env(address(aapl), address(feed), CAP);
        _refused(
            string.concat(
                "asset symbol mismatch: ASSET ", vm.toString(address(aapl)), " is \"AAPL\", EXPECTED_TICKER is \"TSLA\""
            )
        );

        // ---------------------------------------------------------------- fat-fingered PRICE_FEED: description
        MockFeed aaplFeed = new MockFeed(8, SPOT_FEED, "Robinhood AAPL / USD");
        _env(address(tsla), address(aaplFeed), CAP);
        _refused(
            string.concat(
                "feed description mismatch: PRICE_FEED ",
                vm.toString(address(aaplFeed)),
                " is \"Robinhood AAPL / USD\", EXPECTED_TICKER is \"TSLA\""
            )
        );

        // ---------------------------------------------------------------- feed decimals != 8
        MockFeed sixDp = new MockFeed(6, 358_040000, "Robinhood TSLA / USD");
        _env(address(tsla), address(sixDp), CAP);
        _refused("unexpected feed decimals");

        // ---------------------------------------------------------------- stale feed (older than MAX_PRICE_AGE)
        _env(address(tsla), address(feed), CAP);
        feed.setUpdatedAt(block.timestamp - 5 days);
        _refused("feed is stale: age 432000 s > MAX_PRICE_AGE 345600");
        feed.setAnswer(SPOT_FEED); // fresh again (setAnswer stamps `now`)
        new DeploySolo().run(); // and accepted again, so the case above failed on age alone

        // ---------------------------------------------------------------- answer <= 0
        feed.setAnswer(0);
        _refused("feed answer <= 0");
        feed.setAnswer(-1);
        _refused("feed answer <= 0");
        feed.setAnswer(SPOT_FEED);

        // ---------------------------------------------------------------- issuer halted its oracle
        tsla.setOraclePaused(true);
        _refused("asset oraclePaused() is true: the issuer has halted its oracle");
        tsla.setOraclePaused(false);

        // ---------------------------------------------------------------- DEPOSIT_CAP 0
        _env(address(tsla), address(feed), 0);
        _refused("DEPOSIT_CAP must be > 0");

        // ---------------------------------------------------------------- token decimals != 18 (right symbol)
        MockERC20 sixDecimals = new MockERC20("Tesla", "TSLA", 6);
        _env(address(sixDecimals), address(feed), CAP);
        _refused("asset decimals != 18");

        // ---------------------------------------------------------------- an ERC-20 that is not a Stock Token
        MockERC20 plain = new MockERC20("Tesla", "TSLA", 18);
        _env(address(plain), address(feed), CAP);
        _refused("asset uiMultiplier() probe failed: not a Robinhood Stock Token?");

        // ---------------------------------------------------------------- Clear fee switch on
        _env(address(tsla), address(feed), CAP);
        clear.setFeesEnabled(true);
        _refused("clear fee switch is ON: accept it explicitly after deploy, or wait");
        clear.setFeesEnabled(false);

        // ---------------------------------------------------------------- the controller check is on by default
        vm.setEnv("PREFLIGHT_SKIP_CONDUIT_CONTROLLER", "false");
        _refused("unexpected conduit controller");
        vm.setEnv("PREFLIGHT_SKIP_CONDUIT_CONTROLLER", "true");

        // ---------------------------------------------------------------- an empty ticker is refused, not a wildcard
        // (`envOr` hands a blank string back as "", a valid string, so the NVDA default is not reachable
        // from a test; the batch script always sets EXPECTED_TICKER and the fork rehearsal runs it so.)
        vm.setEnv("EXPECTED_TICKER", "");
        _refused(
            string.concat(
                "asset symbol mismatch: ASSET ", vm.toString(address(tsla)), " is \"TSLA\", EXPECTED_TICKER is \"\""
            )
        );

        _unsetEnv();
    }
}
