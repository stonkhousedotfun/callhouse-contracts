// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockStockToken} from "../../../src/mocks/MockStockToken.sol";
import {MockPayoutTaxToken} from "../../../src/v2/mocks/MockPayoutTaxToken.sol";

/**
 * T-CV-CLEARINGHOUSE, checked at contracts 8adcde6f89cbbabfba4fb50227a89edac09350f7.
 *
 * These two negative doubles are load-bearing for a DOC claim as well as for the probe. The
 * T-486 ledger entry asked whether docs/V2-ARCHITECTURE.md:273's cite of Clearinghouse.sol:257
 * should be re-pointed to the enforcement at :641. ANSWER: NO. The doc sentence is about
 * registration-time state ("a v8 market always registers unpaused"), which :257 supports —
 * `mintPaused: false` inside registerMarket's MarketConfig literal. :641 is the minter allow-list
 * (`if (!isMinter[msg.sender]) revert NotMinter()`), a different mechanism. Re-pointing would have
 * made a true sentence cite a line that does not support it.
 *
 * Recorded here because a cite-drift check that matches only line numbers gets this wrong, and the
 * next such sweep will look at these doubles before it looks at the ledger.
 */
/// @notice A contract that has code and is NOT an oracle. Stands in for the realistic mistake: an admin pointing a
///         market at a token, a Safe, the book, or a mistyped address that happens to hold code.
/// @dev It answers nothing, so the probe's staticcall reverts and {Clearinghouse._requireSettlementOracle} refuses
///      it. Before SEC-07 this address was ACCEPTED, because `code.length != 0` was the whole check.
contract NotAnOracle {
    uint256 public unrelated = 1;
}

/// @notice A contract shaped like the oracle that answers ZERO. Pins the sanity half of the probe.
/// @dev Answering the selector is not the same as being the oracle. A window of zero is nonsense for a settlement
///      oracle -- the real one returns `V2Constants.SETTLEMENT_WINDOW` as a constant -- so it is refused too.
contract ZeroWindowOracle {
    function SETTLEMENT_WINDOW() external pure returns (uint32) {
        return 0;
    }
}

/// @notice An 18-dp ERC-20 that charges the SENDER `feeBps` of every transfer between two non-zero addresses ON TOP of
///         the amount, so the recipient receives `amount` and the sender loses more. The opposite of
///         MockPayoutTaxToken, where the recipient absorbs the fee.
/// @dev SEC-12. This is the fee shape that breaks invariant I2' through an unprobed registration: every Clearinghouse
///      outflow books `amount` but costs the contract `amount + fee`.
contract SenderChargedToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Sender Charged Stock Token", "SCx") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) super._update(from, address(0), value * feeBps / 10_000);
        super._update(from, to, value);
    }
}

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
        (bool adminListing,) = manager.hasRole(V8Roles.LISTING, admin);
        (bool guardianOk,) = manager.hasRole(V8Roles.GUARDIAN, guardian);
        assertTrue(adminListing, "admin holds LISTING on the manager");
        assertTrue(guardianOk, "guardian holds GUARDIAN on the manager");
        assertEq(ch.authority(), address(manager));
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
        new Clearinghouse(address(manager), address(usdg), address(calendar), treasury, "x/");
    }

    function test_constructor_rejectsZeroAdminOrRecipient() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new Clearinghouse(address(0), address(usdg), address(calendar), treasury, "");
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        new Clearinghouse(address(manager), address(usdg), address(calendar), address(0), "");
    }

    function test_constructor_rejectsBadUsdg() public {
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new Clearinghouse(address(manager), address(nvda), address(calendar), treasury, "");
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        new Clearinghouse(address(manager), makeAddr("codeless"), address(calendar), treasury, "");
    }

    function test_constructor_rejectsCodelessCalendar() public {
        vm.expectRevert(V2Errors.BadExpiry.selector);
        new Clearinghouse(address(manager), address(usdg), makeAddr("codeless"), treasury, "");
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_registerMarket_storesAndEmits() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        V2Types.MarketConfig memory expected = V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: 500_000,
            exerciseFeeBps: FEE_BPS,
            oracle: address(oracle),
            mintFeePpm: 0
        });
        vm.expectEmit(true, false, false, true, address(ch));
        emit IClearinghouse.MarketRegistered(address(amzn), expected);
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);

        V2Types.MarketConfig memory got = ch.market(address(amzn));
        assertTrue(got.enabled);
        assertFalse(got.mintPaused, "a v8 market always registers unpaused");
        assertEq(got.strikeTick, 500_000);
        assertEq(got.exerciseFeeBps, FEE_BPS, "the default fee applies");
        assertEq(got.oracle, address(oracle), "the default oracle applies");
    }

    function test_registerMarket_onlyAdmin() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        address[3] memory callers = [guardian, alice, keeper];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(V2Errors.NotAuthorized.selector);
            ch.registerMarket(address(amzn), 500_000, true);
        }
    }

    function test_registerMarket_rejectsAlreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        ch.registerMarket(address(nvda), STRIKE_TICK, true);
    }

    function test_registerMarket_rejectsNon18DecimalTokens() public {
        MockERC20 eightDp = new MockERC20("Eight", "E8", 8);
        address[4] memory bad = [address(usdg), address(eightDp), makeAddr("codeless"), address(0)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.UnsupportedAsset.selector);
            ch.registerMarket(bad[i], 500_000, true);
        }
    }

    function test_registerMarket_strikeTickBounds() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        uint64[4] memory bad = [uint64(0), 1, 150, 1_000_050];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.BadStrike.selector);
            ch.registerMarket(address(amzn), bad[i], true);
        }
        vm.prank(admin);
        ch.registerMarket(address(amzn), 100, true);
        assertEq(ch.market(address(amzn)).strikeTick, 100, "PRICE_TICK itself is a valid strike tick");
    }

    /// @dev SEC-12, first half of the {registerMarket} @dev: a fee the RECIPIENT absorbs registers (nothing probes a
    ///      transfer) and cannot open a gap, because {deposit} measures what arrived and every outflow costs this
    ///      contract exactly the amount it books. Balance == free at every step, not merely >=.
    function test_registerMarket_recipientChargedTokenRegistersAndKeepsI2() public {
        MockPayoutTaxToken tax = new MockPayoutTaxToken(100); // 1 %, burned out of what the recipient receives
        vm.prank(admin);
        ch.registerMarket(address(tax), 500_000, true);
        assertEq(ch.market(address(tax)).strikeTick, 500_000, "registration does not probe a transfer");

        address[2] memory who = [alice, bob];
        for (uint256 i; i < who.length; ++i) {
            tax.mint(who[i], 1e18);
            vm.startPrank(who[i]);
            tax.approve(address(ch), type(uint256).max);
            ch.deposit(address(tax), 1e18, who[i]);
            vm.stopPrank();
            assertEq(ch.free(who[i], address(tax)), 0.99e18, "deposit credits the measured delta");
        }
        assertEq(tax.balanceOf(address(ch)), ch.free(alice, address(tax)) + ch.free(bob, address(tax)), "I2' in");

        vm.prank(alice);
        ch.withdraw(address(tax), 0.99e18, alice);
        assertEq(tax.balanceOf(alice), 0.9801e18, "the recipient absorbs the fee on the way out");
        assertEq(tax.balanceOf(address(ch)), ch.free(bob, address(tax)), "I2' holds after the outflow");

        vm.prank(bob);
        ch.withdraw(address(tax), 0.99e18, bob);
        assertEq(tax.balanceOf(address(ch)), 0, "the last holder is paid in full");
    }

    /// @dev SEC-12, second half of the {registerMarket} @dev, and the reason it says "not an enforced one": a token
    ///      that charges the SENDER on top REGISTERS, and the first outflow leaves the next holder's credit unbacked by
    ///      exactly the fee. This pins the contract's CURRENT behaviour so the NatSpec cannot drift from it. If a
    ///      registration-time probe is ever added, the registration below must revert instead, and this test and the
    ///      @dev both change in the same commit.
    function test_registerMarket_senderChargedTokenRegistersAndOutflowsBreakI2() public {
        SenderChargedToken sc = new SenderChargedToken(100); // 1 %, burned from the sender on top of the amount
        vm.prank(admin);
        ch.registerMarket(address(sc), 500_000, true);
        assertEq(ch.market(address(sc)).strikeTick, 500_000, "the contract does not refuse it");

        address[2] memory who = [alice, bob];
        for (uint256 i; i < who.length; ++i) {
            sc.mint(who[i], 2e18);
            vm.startPrank(who[i]);
            sc.approve(address(ch), type(uint256).max);
            ch.deposit(address(sc), 1e18, who[i]);
            vm.stopPrank();
            assertEq(ch.free(who[i], address(sc)), 1e18, "the depositor paid the fee, the full amount arrived");
        }
        assertEq(sc.balanceOf(address(ch)), 2e18, "I2' holds on the way in");

        vm.prank(alice);
        ch.withdraw(address(sc), 1e18, alice);
        uint256 fee = 1e18 * 100 / 10_000;
        assertEq(sc.balanceOf(alice), 1.99e18, "alice is paid in full: 2 - 1.01 on the way in, + 1 back");
        assertEq(sc.balanceOf(address(ch)), 1e18 - fee, "the outflow cost the contract amount + fee");
        assertEq(ch.free(bob, address(sc)), 1e18, "bob's credit did not move");
        assertEq(ch.free(bob, address(sc)) - sc.balanceOf(address(ch)), fee, "I2' short by exactly the fee");

        // The fee is burned from the contract first (0.99e18 -> 0.98e18), then the 1e18 transfer finds too little.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(ch), 0.98e18, 1e18)
        );
        ch.withdraw(address(sc), 1e18, bob);
    }

    function test_setMarketFees_exerciseFeeCeiling() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        ch.setMarketFees(address(amzn), V2Constants.EXERCISE_FEE_CEIL_BPS + 1, 0);
    }

    function test_setMarketOracle_rejectsOracleWithoutCode() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);
        address[2] memory bad = [address(0), makeAddr("eoa")];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(V2Errors.NoSource.selector);
            ch.setMarketOracle(address(amzn), bad[i]);
        }
    }

    /// @notice SEC-07: a pointer with code that is not the oracle is refused, on every path that sets one.
    /// @dev THIS IS THE CASE `code.length != 0` COULD NOT SEE. Both setters that take an oracle FROM A CALLER
    ///      are checked here rather than trusting that they still share
    ///      {Clearinghouse._requireSettlementOracle} -- a later edit that inlines one of them is what this
    ///      catches.
    function test_setMarketOracle_rejectsAContractThatIsNotAnOracle() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);

        address notAnOracle = address(new NotAnOracle());
        assertGt(notAnOracle.code.length, 0, "precondition: it has code, so the old check would have passed it");

        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.setMarketOracle(address(amzn), notAnOracle);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.setDefaultOracle(notAnOracle);

        // THE THIRD PATH IS NOT TESTABLE FROM OUTSIDE, and saying so beats implying it was checked.
        // `_checkConfigMemory` guards the composed config {registerMarket} builds, but that config takes
        // `oracle: defaultOracle` (Clearinghouse.sol:237) -- no setter hands it an oracle independently. So it
        // can only ever see a pointer {setDefaultOracle} has already probed, and the guard there is defence in
        // depth against a later edit that gives it its own input.
    }

    /// @notice A contract that answers the oracle's surface with nonsense is refused too.
    function test_setMarketOracle_rejectsAnOracleShapeThatAnswersZero() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);

        // DEPLOYED BEFORE THE CHEATCODE IS ARMED. `vm.expectRevert` attaches to THE NEXT CALL, and a `new`
        // inside the argument list is that call -- the creation succeeds, the expectation is spent on it, and
        // the test fails with "next call did not revert as expected" while the guard it is testing is fine.
        // Same shape as a `vm.prank` spent on an argument's `balanceOf`; the trace is the only thing that says so.
        address zeroWindow = address(new ZeroWindowOracle());
        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        ch.setMarketOracle(address(amzn), zeroWindow);
    }

    /// @notice THE CONTROL. The real oracle is still accepted, on every path.
    /// @dev Without this the two refusals above are satisfied by a setter that refuses EVERYTHING, which is the
    ///      failure mode of a probe that is too strict -- and the one that would have shipped if the row's
    ///      suggested `supportsInterface` check had been taken: {SettlementOracle} implements no ERC-165.
    function test_setMarketOracle_stillAcceptsTheRealOracle() public {
        MockStockToken amzn = new MockStockToken("AMZN Stock Token", "AMZNx");
        vm.prank(admin);
        ch.registerMarket(address(amzn), 500_000, true);

        vm.prank(admin);
        ch.setMarketOracle(address(amzn), address(oracle));
        assertEq(ch.market(address(amzn)).oracle, address(oracle), "the real oracle was accepted");

        vm.prank(admin);
        ch.setDefaultOracle(address(oracle));
        assertEq(ch.defaultOracle(), address(oracle), "and on the default pointer too");
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
        _reconfigure(ch, address(nvda), cfg);

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
        _reconfigure(ch, address(amzn), _cfg(address(oracle)));

        V2Types.MarketConfig memory cfg = _cfg(address(oracle));
        cfg.strikeTick = 0;
        vm.prank(admin);
        vm.expectRevert(V2Errors.BadStrike.selector);
        _reconfigure(ch, address(nvda), cfg);

        cfg = _cfg(address(oracle));
        cfg.exerciseFeeBps = 201;
        vm.prank(admin);
        vm.expectRevert(V2Errors.CeilingExceeded.selector);
        _reconfigure(ch, address(nvda), cfg);

        vm.prank(admin);
        vm.expectRevert(V2Errors.NoSource.selector);
        _reconfigure(ch, address(nvda), _cfg(address(0)));

        vm.prank(guardian);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        _reconfigure(ch, address(nvda), _cfg(address(oracle)));
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
        vm.prank(alice);
        vm.expectRevert();
        manager.grantRole(V8Roles.GUARDIAN, alice, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(ch.supportsInterface(type(IClearinghouse).interfaceId));
        assertTrue(ch.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(ch.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertFalse(ch.supportsInterface(type(IAccessControl).interfaceId), "roles live on the manager");
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
