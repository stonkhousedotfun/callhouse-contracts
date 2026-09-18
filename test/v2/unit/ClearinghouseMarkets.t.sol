// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";

/// @notice Clearinghouse: construction, market registration bounds and roles, guardian pauses, admin pointers,
///         metadata and ERC-165.
contract ClearinghouseMarketsTest is ClearinghouseTestBase {
    string internal constant VECTORS = "test/v2/fixtures/series-ids.json";

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_state() public view {
        assertEq(ch.usdg(), address(usdg));
        assertEq(ch.calendar(), address(calendar));
        assertEq(ch.feeRecipient(), treasury);
        assertEq(ch.minRedeemPayout(), ch.DEFAULT_MIN_REDEEM_PAYOUT());
        assertEq(ch.DEFAULT_MIN_REDEEM_PAYOUT(), 1_000_000, "1 USDG");
        assertEq(ch.baseUri(), BASE_URI);
        assertTrue(ch.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin));
        assertTrue(ch.hasRole(V2Constants.GUARDIAN_ROLE, guardian));
        assertFalse(ch.hasRole(V2Constants.GUARDIAN_ROLE, admin), "admin is not guardian by default");
        assertFalse(ch.createPaused());
    }

    function test_constructor_emitsPointers() public {
        vm.expectEmit(true, false, false, true);
        emit Clearinghouse.CalendarSet(address(calendar));
        vm.expectEmit(true, false, false, true);
        emit IClearinghouse.FeeRecipientSet(treasury);
        vm.expectEmit(false, false, false, true);
        emit Clearinghouse.MinRedeemPayoutSet(1_000_000);
        vm.expectEmit(false, false, false, true);
        emit Clearinghouse.BaseUriSet("x/");
        new Clearinghouse(admin, address(usdg), address(calendar), treasury, "x/");
    }

    function test_constructor_rejectsZeroAdminOrRecipient() public {
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new Clearinghouse(address(0), address(usdg), address(calendar), treasury, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new Clearinghouse(admin, address(usdg), address(calendar), address(0), "");
    }

    function test_constructor_rejectsBadUsdg() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new Clearinghouse(admin, address(nvda), address(calendar), treasury, "");
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new Clearinghouse(admin, makeAddr("codeless"), address(calendar), treasury, "");
    }

    function test_constructor_rejectsCodelessCalendar() public {
        vm.expectRevert(V2Errors.BadExpiry.selector);
        new Clearinghouse(admin, address(usdg), makeAddr("codeless"), treasury, "");
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_registerMarket_storesAndEmits() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
            enabled: true,
            mintPaused: true,
            strikeTick: 500_000,
            exerciseFeeBps: 200,
            oracle: address(oracle),
            mintFeePpm: 0
        });
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.MarketRegistered(address(amzn), cfg);
        vm.prank(admin);
        ch.registerMarket(address(amzn), cfg);

        V2Types.MarketConfig memory got = ch.market(address(amzn));
        assertTrue(got.enabled);
        assertTrue(got.mintPaused, "registration takes mintPaused as given");
        assertEq(got.strikeTick, 500_000);
        assertEq(got.exerciseFeeBps, 200, "fee at the ceiling is accepted");
        assertEq(got.oracle, address(oracle));
    }

    function test_registerMarket_onlyAdmin() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        address[3] memory callers = [guardian, alice, keeper];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            ch.registerMarket(address(amzn), _cfg(address(oracle)));
        }
    }

    function test_registerMarket_rejectsAlreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.registerMarket(address(nvda), _cfg(address(oracle)));
    }

    function test_registerMarket_rejectsNon18DecimalTokens() public {
        MockERC20 eightDp = new MockERC20("Eight", "E8", 8);
        address[4] memory bad = [address(usdg), address(eightDp), makeAddr("codeless"), address(0)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.UnsupportedAsset.selector);
            ch.registerMarket(bad[i], _cfg(address(oracle)));
        }
    }

    function test_registerMarket_strikeTickBounds() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        uint64[4] memory bad = [uint64(0), 1, 150, 1_000_050];
        for (uint256 i; i < bad.length; ++i) {
            V2Types.MarketConfig memory cfg = _cfg(address(oracle));
            cfg.strikeTick = bad[i];
            vm.prank(admin);
            vm.expectRevert(V2Errors.BadStrike.selector);
            ch.registerMarket(address(amzn), cfg);
        }
        V2Types.MarketConfig memory ok = _cfg(address(oracle));
        ok.strikeTick = 100;
        vm.prank(admin);
        ch.registerMarket(address(amzn), ok);
        assertEq(ch.market(address(amzn)).strikeTick, 100, "PRICE_TICK itself is a valid strike tick");
    }

    function test_registerMarket_exerciseFeeCeiling() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.exerciseFeeBps = V2Constants.EXERCISE_FEE_CEIL_BPS + 1;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        ch.registerMarket(address(amzn), cfg);
    }

    function test_registerMarket_rejectsOracleWithoutCode() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        address[2] memory bad = [address(0), makeAddr("eoa")];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.NoSource.selector);
            ch.registerMarket(address(amzn), _cfg(bad[i]));
        }
    }

    function test_setMarketConfig_updatesButKeepsGuardianPause() public {
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);

        V2Types.MarketConfig memory cfg = V2Types.MarketConfig({
            enabled: false,
            mintPaused: false,
            strikeTick: 5_000_000,
            exerciseFeeBps: 50,
            oracle: address(oracle),
            mintFeePpm: 0
        });
        V2Types.MarketConfig memory expected = cfg;
        expected.mintPaused = true;
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.MarketConfigSet(address(nvda), expected);
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), cfg);

        V2Types.MarketConfig memory got = ch.market(address(nvda));
        assertFalse(got.enabled);
        assertTrue(got.mintPaused, "an admin config push cannot lift a guardian pause");
        assertEq(got.strikeTick, 5_000_000);
        assertEq(got.exerciseFeeBps, 50);
    }

    function test_setMarketConfig_boundsAndRoles() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.setMarketConfig(address(amzn), _cfg(address(oracle)));

        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.strikeTick = 0;
        vm.prank(admin);
        vm.expectRevert(V2Errors.BadStrike.selector);
        ch.setMarketConfig(address(nvda), cfg);

        cfg = _cfg(address(oracle));
        cfg.exerciseFeeBps = 201;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        ch.setMarketConfig(address(nvda), cfg);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.setMarketConfig(address(nvda), _cfg(address(0)));

        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setMarketConfig(address(nvda), _cfg(address(oracle)));
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSES
    //////////////////////////////////////////////////////////////*/

    function test_setMintPaused_guardianOnly() public {
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.MintPausedSet(address(nvda), true);
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        assertTrue(ch.market(address(nvda)).mintPaused);
        assertFalse(ch.market(address(tsla)).mintPaused, "per market");

        address[2] memory callers = [admin, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            ch.setMintPaused(address(nvda), false);
        }

        vm.prank(guardian);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.setMintPaused(makeAddr("unregistered"), true);
    }

    function test_setCreatePaused_guardianOnly() public {
        vm.expectEmit(false, false, false, true, address(ch));
        emit IClearinghouse.CreatePausedSet(true);
        vm.prank(guardian);
        ch.setCreatePaused(true);
        assertTrue(ch.createPaused());

        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setCreatePaused(false);
    }

    /*//////////////////////////////////////////////////////////////
                                POINTERS
    //////////////////////////////////////////////////////////////*/

    function test_setPayoutAdapter_ceilingAndRole() public {
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.PayoutAdapterSet(address(0xABCD), V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS);
        vm.prank(admin);
        ch.setPayoutAdapter(address(0xABCD), V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS);
        assertEq(ch.payoutAdapter(), address(0xABCD));
        assertEq(ch.maxPayoutSlippageBps(), 300);

        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        ch.setPayoutAdapter(address(adapter), V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS + 1);

        vm.prank(admin);
        ch.setPayoutAdapter(address(0), 0);
        assertEq(ch.payoutAdapter(), address(0), "zero turns conversion off");

        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setPayoutAdapter(address(adapter), 0);
    }

    function test_setFeeRecipient() public {
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.FeeRecipientSet(carol);
        vm.prank(admin);
        ch.setFeeRecipient(carol);
        assertEq(ch.feeRecipient(), carol);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setFeeRecipient(address(0));

        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setFeeRecipient(alice);
    }

    function test_setCalendar() public {
        vm.prank(admin);
        vm.expectRevert(V2Errors.BadExpiry.selector);
        ch.setCalendar(makeAddr("codeless"));

        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setCalendar(address(calendar));

        address other = address(new ClearinghouseCalendarStub());
        vm.expectEmit(true, false, false, true, address(ch));
        emit Clearinghouse.CalendarSet(other);
        vm.prank(admin);
        ch.setCalendar(other);
        assertEq(ch.calendar(), other);
    }

    function test_setKeeperRewards() public {
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.setKeeperRewards(makeAddr("codeless"));

        vm.expectEmit(true, false, false, true, address(ch));
        emit Clearinghouse.KeeperRewardsSet(address(0));
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        assertEq(address(ch.keeperRewards()), address(0));

        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setKeeperRewards(address(rewards));
    }

    function test_setMinRedeemPayout() public {
        vm.expectEmit(false, false, false, true, address(ch));
        emit Clearinghouse.MinRedeemPayoutSet(5e6);
        vm.prank(admin);
        ch.setMinRedeemPayout(5e6);
        assertEq(ch.minRedeemPayout(), 5e6);

        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setMinRedeemPayout(0);
    }

    function test_uri_isBasePlusDecimalId() public {
        uint256 longId = _call(K_240, FRI_2026_09_18);
        assertEq(ch.uri(longId), string.concat(BASE_URI, vm.toString(longId)));
        assertEq(ch.uri(_short(longId)), string.concat(BASE_URI, vm.toString(_short(longId))));
        assertEq(ch.uri(0), string.concat(BASE_URI, "0"));

        vm.prank(admin);
        ch.setBaseUri("ipfs://x/");
        assertEq(ch.uri(7), "ipfs://x/7");

        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.setBaseUri("");
    }

    function test_roles_grantRevertsWithSharedError() public {
        bytes32 guardianRole = V2Constants.GUARDIAN_ROLE;
        vm.prank(alice);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.grantRole(guardianRole, alice);
    }

    function test_supportsInterface() public view {
        assertTrue(ch.supportsInterface(type(IClearinghouse).interfaceId));
        assertTrue(ch.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(ch.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(ch.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(ch.supportsInterface(type(IERC165).interfaceId));
        assertFalse(ch.supportsInterface(0xffffffff));
    }

    /*//////////////////////////////////////////////////////////////
                                   IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev The contract's id views agree with V2Ids and with every committed vector (test/v2/InterfaceIds.t.sol pins
    ///      the vectors against an independent reference).
    function test_ids_matchVectorFile() public view {
        string memory json = vm.readFile(VECTORS);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".vectors[", vm.toString(n), "]"))) {
            string memory at = string.concat(".vectors[", vm.toString(n), "].");
            address underlying = vm.parseJsonAddress(json, string.concat(at, "underlying"));
            bool isPut = vm.parseJsonBool(json, string.concat(at, "isPut"));
            uint256 strike = vm.parseUint(vm.parseJsonString(json, string.concat(at, "strike")));
            uint256 expiry = vm.parseJsonUint(json, string.concat(at, "expiry"));
            uint256 longId = vm.parseUint(vm.parseJsonString(json, string.concat(at, "longId")));
            uint256 shortId = vm.parseUint(vm.parseJsonString(json, string.concat(at, "shortId")));
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(ch.longIdOf(underlying, isPut, uint128(strike), uint40(expiry)), longId);
            assertEq(ch.shortIdOf(longId), shortId);
            assertFalse(ch.isShortId(longId));
            assertTrue(ch.isShortId(shortId));
            ++n;
        }
        assertGe(n, 12, "vector file read");
    }

    function testFuzz_ids_matchV2Ids(address underlying, bool isPut, uint128 strike, uint40 expiry) public view {
        uint256 longId = ch.longIdOf(underlying, isPut, strike, expiry);
        assertEq(longId, V2Ids.longIdOf(underlying, isPut, strike, expiry));
        assertEq(ch.shortIdOf(longId), longId | 1);
        assertEq(ch.isShortId(longId | 1), true);
    }
}

/// @dev Any contract will do as a calendar pointer for the setter test.
contract ClearinghouseCalendarStub {}
