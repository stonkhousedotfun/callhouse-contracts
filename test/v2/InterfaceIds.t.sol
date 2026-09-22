// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPayoutAdapter} from "../../src/v2/interfaces/IPayoutAdapter.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../src/v2/interfaces/V2Errors.sol";
import {V2Ids} from "../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {IPriceSource} from "../../src/v2/interfaces/IPriceSource.sol";
import {ISettlementOracle} from "../../src/v2/interfaces/ISettlementOracle.sol";
import {IAutoRoller} from "../../src/v2/interfaces/IAutoRoller.sol";
import {IBuybackExecutor} from "../../src/v2/interfaces/IBuybackExecutor.sol";
import {IClearinghouse} from "../../src/v2/interfaces/IClearinghouse.sol";
import {IFeeDiscount} from "../../src/v2/interfaces/IFeeDiscount.sol";
import {IFeeSplitter} from "../../src/v2/interfaces/IFeeSplitter.sol";
import {IEarnVault} from "../../src/v2/interfaces/IEarnVault.sol";
import {IEarnVenueAdapter} from "../../src/v2/interfaces/IEarnVenueAdapter.sol";
import {IFundingSource} from "../../src/v2/interfaces/IFundingSource.sol";
import {IKeeperRewards} from "../../src/v2/interfaces/IKeeperRewards.sol";
import {IMakerRegistry} from "../../src/v2/interfaces/IMakerRegistry.sol";
import {IOrderBook} from "../../src/v2/interfaces/IOrderBook.sol";
import {IPayoutRouter} from "../../src/v2/interfaces/IPayoutRouter.sol";
import {IStockZap} from "../../src/v2/interfaces/IStockZap.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {IRewardsDistributor} from "../../src/v2/interfaces/IRewardsDistributor.sol";
import {V8Roles} from "../../src/v2/access/V8Roles.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {OrderBook} from "../../src/v2/OrderBook.sol";
import {MakerVault} from "../../src/v2/mm/MakerVault.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {EmitSeriesIds} from "../../script/v2/EmitSeriesIds.s.sol";

/// @notice Pins the frozen v2 constants, the series-id formula and the shared error ABI (interface v1, task F2-03).
/// @dev Off-chain code (keeper, indexer, web) mirrors every value checked here, so a change that slips past review
///      must fail loudly in this file first. The id checks compare V2Ids against a reference written independently
///      below (hand-laid 32-byte words, arithmetic instead of bit masks) and against test/v2/fixtures/series-ids.json,
///      the same vectors the TypeScript seriesId.ts is tested against.
contract InterfaceIdsTest is Test {
    string internal constant VECTORS = "test/v2/fixtures/series-ids.json";
    string internal constant ERRORS_ARTIFACT = "out/V2Errors.sol/V2Errors.json";

    /*//////////////////////////////////////////////////////////////
                               REFERENCE IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev abi.encode(address, bool, uint128, uint40) written out as four left-padded 32-byte words, then the hash
    ///      rounded down to even. Deliberately shares no code with V2Ids.
    function _refLongId(address underlying, bool isPut, uint128 strike, uint40 expiry) internal pure returns (uint256) {
        bytes memory words = bytes.concat(
            bytes32(uint256(uint160(underlying))),
            bytes32(isPut ? uint256(1) : uint256(0)),
            bytes32(uint256(strike)),
            bytes32(uint256(expiry))
        );
        assert(words.length == 128);
        uint256 h = uint256(keccak256(words));
        return h - (h % 2);
    }

    /// @dev Valid for long ids only (even), which is all the reference is ever given.
    function _refShortId(uint256 longId) internal pure returns (uint256) {
        return longId + 1;
    }

    function _refIsShort(uint256 id) internal pure returns (bool) {
        return id % 2 == 1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_constants_units() public pure {
        assertEq(V2Constants.UNIT, 1e16, "1 unit = 0.01 share of an 18-dp token");
        assertEq(V2Constants.UNITS_PER_SHARE, 100, "100 units per share");
        assertEq(V2Constants.UNIT * V2Constants.UNITS_PER_SHARE, 1e18, "a whole share is 1e18 base units");
        assertEq(V2Constants.PRICE_TICK, 100, "prices and strikes are multiples of 100");
        assertEq(V2Constants.BPS, 10_000, "bps denominator");
    }

    function test_constants_times() public pure {
        assertEq(uint256(V2Constants.SETTLEMENT_WINDOW), 1800, "30 minute TWAP window");
        assertEq(uint256(V2Constants.SETTLEMENT_WINDOW), 30 minutes);
        assertEq(uint256(V2Constants.FINALIZE_DELAY), 120, "finalize from expiry + 120 s");
        assertEq(uint256(V2Constants.SNAPSHOT_GRACE), 600, "UniV3 snapshot within 10 minutes");
        assertEq(uint256(V2Constants.RESOLVE_DELAY), 48 hours, "adminResolve from expiry + 48 h");
        assertEq(uint256(V2Constants.RESOLVE_DELAY), 172_800);
        assertEq(uint256(V2Constants.MAX_TENOR), 45 days, "45 day max tenor");
        assertEq(uint256(V2Constants.MAX_TENOR), 3_888_000);
        assertEq(uint256(V2Constants.MIN_SERIES_LEAD), 1 hours, "series created at least 1 h before expiry");
        assertEq(uint256(V2Constants.MIN_SERIES_LEAD), 3600);
        // INTERFACE_VERSION 8 raised this from 24 h (owner decision V3-D13). Every off-chain mirror moves with it:
        // the keeper's FEE_CHANGE_DELAY_S, the web's pending-fee notice and the monitor.
        assertEq(uint256(V2Constants.FEE_CHANGE_DELAY), 48 hours, "an OrderBook fee change takes effect 48 h later");
        assertEq(uint256(V2Constants.FEE_CHANGE_DELAY), 172_800);
    }

    /// @dev Compiles only while the documented types hold: the time offsets combine with a uint40 expiry and the
    ///      ceilings drop into the struct fields they bound, all without casts.
    function test_constants_typesNeedNoCasts() public pure {
        uint40 expiry = 1_789_761_600;
        uint32 window = V2Constants.SETTLEMENT_WINDOW;
        uint40 cutoff = expiry - V2Constants.SETTLEMENT_WINDOW;
        uint40 finalizeFrom = expiry + V2Constants.FINALIZE_DELAY;
        uint40 resolveFrom = expiry + V2Constants.RESOLVE_DELAY;
        uint40 feesFrom = expiry + V2Constants.FEE_CHANGE_DELAY;
        assertEq(uint256(window), 1800);
        assertEq(uint256(cutoff), 1_789_759_800, "mint cutoff = expiry - SETTLEMENT_WINDOW");
        assertEq(uint256(finalizeFrom), 1_789_761_720);
        assertEq(uint256(resolveFrom), 1_789_934_400);
        assertEq(uint256(feesFrom), 1_789_934_400, "a fee change scheduled at t applies from t + FEE_CHANGE_DELAY");

        V2Types.FeeParams memory ceil = V2Types.FeeParams({
            premiumFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            resaleFeeBps: V2Constants.PREMIUM_FEE_CEIL_BPS,
            takerFeeFlat: V2Constants.TAKER_FEE_FLAT_CEIL,
            takerFeeCapBps: V2Constants.TAKER_FEE_CAP_CEIL_BPS,
            makerRebateBps: 5000
        });
        V2Types.MarketConfig memory m = V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: 1_000_000,
            exerciseFeeBps: V2Constants.EXERCISE_FEE_CEIL_BPS,
            oracle: address(0),
            mintFeePpm: 0
        });
        assertEq(uint256(ceil.takerFeeFlat), 1_000_000);
        assertEq(uint256(m.exerciseFeeBps), 200);
    }

    function test_constants_feeCeilings() public pure {
        assertEq(uint256(V2Constants.PREMIUM_FEE_CEIL_BPS), 1000, "premium/resale fee <= 10%");
        assertEq(uint256(V2Constants.EXERCISE_FEE_CEIL_BPS), 200, "exercise fee <= 2% of collateral");
        assertEq(V2Constants.EXERCISE_FEE_MAX_PAYOUT_SHARE_BPS, 1000, "exercise fee <= 10% of payout");
        assertEq(uint256(V2Constants.TAKER_FEE_FLAT_CEIL), 1_000_000, "taker fee flat <= 1 USDG");
        assertEq(uint256(V2Constants.TAKER_FEE_CAP_CEIL_BPS), 1000, "taker fee cap <= 10%");
        assertEq(V2Constants.MAX_BOUNTY, 1_000_000, "bounty <= 1 USDG");
        assertEq(uint256(V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS), 300, "payout conversion slippage <= 3%");
        assertEq(uint256(V2Constants.MAX_ROUTE_FEE_BPS), 100, "route fee added to the slippage bound <= 1%");
        assertEq(uint256(V2Constants.MAX_ROUTE_FEE_TIER), 10_000, "payout route fee tier <= 1%");
        assertEq(
            uint256(V2Constants.MAX_ROUTE_FEE_TIER),
            uint256(V2Constants.MAX_ROUTE_FEE_BPS) * 100,
            "the same 1% as a tier"
        );
    }

    /// @dev The route fee read the Clearinghouse makes on every conversion (INTERFACE_VERSION 6). uint16 like the bound
    ///      it is added to, so the constant and the answer compare without casts.
    function test_interfaceV6_routeFeeBps() public pure {
        assertEq(IPayoutAdapter.routeFeeBps.selector, bytes4(keccak256("routeFeeBps(address)")), "routeFeeBps");
        uint16 fee = V2Constants.MAX_ROUTE_FEE_BPS;
        assertEq(uint256(fee + V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS), 400);
    }

    /// @dev v7 ONLY. INTERFACE_VERSION 8 replaces the per-contract bytes32 role table with one AccessManager and the
    ///      uint64 ids of `V8Roles` (pinned in test_interfaceV8_roles). These four constants survive the freeze only
    ///      because the targets have not migrated to `Managed` yet; the last of C8-01..C8-05 deletes them and this
    ///      test with them.
    function test_constants_roles() public pure {
        assertEq(V2Constants.DEFAULT_ADMIN_ROLE, bytes32(0), "OpenZeppelin AccessControl admin role");
        assertEq(V2Constants.GUARDIAN_ROLE, keccak256("GUARDIAN_ROLE"));
        assertEq(V2Constants.PRICER_ROLE, keccak256("PRICER_ROLE"));
        assertEq(V2Constants.QUOTER_ROLE, keccak256("QUOTER_ROLE"));
    }

    function test_constants_bountyActions() public pure {
        assertEq(V2Constants.ACTION_SNAPSHOT, keccak256("SNAPSHOT"));
        assertEq(V2Constants.ACTION_FINALIZE, keccak256("FINALIZE"));
        assertEq(V2Constants.ACTION_SETTLE, keccak256("SETTLE"));
        assertEq(V2Constants.ACTION_REDEEM, keccak256("REDEEM"));
        assertEq(V2Constants.ACTION_ROLL, keccak256("ROLL"));
        // INTERFACE_VERSION 7 (c16). Six actions now; `DeployV2`, `DevDeploy` and `VerifyV2` all carry six.
        assertEq(V2Constants.ACTION_CANCEL_STALE, keccak256("CANCEL_STALE"));
        assertEq(
            V2Constants.ACTION_CANCEL_STALE,
            bytes32(0x7bf1982cc047ace888325e61ec5f1e6f173a1d0d7f3d38fc1a42c4776bd35d2b),
            "the value ops/v2/monitor.mjs and the keeper quote"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     INTERFACE_VERSION 6: PINNING
    //////////////////////////////////////////////////////////////*/

    /// @dev The signatures the keeper, indexer and web decode for the settlement-pinning interface.
    function test_interfaceV6_pinSignatures() public pure {
        assertEq(ISettlementOracle.pin.selector, bytes4(keccak256("pin(address,uint40)")), "oracle pin");
        assertEq(IPriceSource.pin.selector, bytes4(keccak256("pin(address,uint40)")), "source pin");
        assertEq(
            ISettlementOracle.SettlementConfigPinned.selector,
            keccak256("SettlementConfigPinned(address,uint40,address[],uint16,uint32)"),
            "SettlementConfigPinned topic"
        );
        assertEq(SettlementOracle.pinnedBy.selector, bytes4(keccak256("pinnedBy(address,uint40)")), "pinnedBy view");
        // the values docs/V2-ARCHITECTURE.md §7 and the keeper's revert decoding quote
        assertEq(ISettlementOracle.pin.selector, bytes4(0xbbb87c27), "pin 0xbbb87c27 (also each source's answer)");
        assertEq(SettlementOracle.pinnedBy.selector, bytes4(0xa2c864c7), "pinnedBy 0xa2c864c7");
        assertEq(V2Errors.PinMismatch.selector, bytes4(0x52e8e6d6), "PinMismatch 0x52e8e6d6");
        assertEq(V2Errors.SourceNotPinned.selector, bytes4(0xf54720df), "SourceNotPinned 0xf54720df");
        assertEq(V2Errors.NotAuthorized.selector, bytes4(0xea8e4eb5), "NotAuthorized 0xea8e4eb5");
        assertEq(V2Errors.NoSource.selector, bytes4(0x7d19c0ff), "NoSource 0x7d19c0ff");
        assertEq(
            ISettlementOracle.SettlementConfigPinned.selector,
            bytes32(0x0f5665a813c1eb146df6e986b55707c10b6a66f14f3e23a39ca428cee92808eb),
            "SettlementConfigPinned topic0"
        );
        assertEq(V2Errors.PinMismatch.selector, bytes4(keccak256("PinMismatch()")), "PinMismatch");
        assertEq(
            V2Errors.SourceNotPinned.selector,
            bytes4(keccak256("SourceNotPinned(address,bytes4)")),
            "SourceNotPinned (the oracle's wrapper of any source pin failure)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                  INTERFACE_VERSION 7: c05, c16, c21
    //////////////////////////////////////////////////////////////*/

    /// @dev The whole v7 ABI delta, pinned selector by selector and topic by topic (v7 design §4.7). Every consumer --
    ///      keeper, ops/v2/monitor.mjs (two hand-written ABIs), indexer, web, notifier -- decodes these, and a v6
    ///      decoder left on a v7 deployment mis-decodes silently rather than failing, so a drift has to break here.
    function test_interfaceV7_clearinghouseSelectorsAndTopics() public pure {
        // MarketConfig and Series both grew, so the two config setters changed selector.
        // INTERFACE_VERSION 8 added `registerMarket(address,uint64,bool)` beside this one, so `Clearinghouse
        // .registerMarket.selector` is ambiguous until C8-02 deletes the v7 form. The v7 selector is hashed from its
        // signature instead; the v8 one is pinned against the contract in test_interfaceV8_clearinghouse below.
        assertEq(
            bytes4(keccak256("registerMarket(address,(bool,bool,uint64,uint16,address,uint32))")),
            bytes4(0xfb2a821f),
            "v7 registerMarket 0x45baaccb -> 0xfb2a821f"
        );
        assertEq(
            bytes4(keccak256("setMarketConfig(address,(bool,bool,uint64,uint16,address,uint32))")),
            bytes4(0x8a8e5070),
            "setMarketConfig 0x05aa2668 -> 0x8a8e5070 -- removed by C8-02"
        );
        // Both tuples GREW, so the readers keep their selectors: a v6 positional decoder still reads the first
        // fields correctly, which is exactly why Series appends rather than reorders (v7 design §3.5).
        assertEq(IClearinghouse.market.selector, bytes4(0x9f382f6a), "market() unchanged, longer tuple");
        assertEq(IClearinghouse.series.selector, bytes4(0xdc22cb6a), "series() unchanged, two appended fields");
        // The two new views (c05).
        assertEq(IClearinghouse.mintFee.selector, bytes4(keccak256("mintFee(uint256,uint64)")), "mintFee signature");
        assertEq(IClearinghouse.mintFee.selector, bytes4(0xdb66f63c), "mintFee 0xdb66f63c");
        assertEq(
            IClearinghouse.closeRefund.selector,
            bytes4(keccak256("closeRefund(uint256,uint64)")),
            "closeRefund signature"
        );
        assertEq(IClearinghouse.closeRefund.selector, bytes4(0x963ecf0d), "closeRefund 0x963ecf0d");

        // Four topics changed and one is new.
        assertEq(
            IClearinghouse.MarketRegistered.selector,
            bytes32(0x9ffefa3e10b786e4dc202bedcdb98708c0feff476372922f9343e2f0c6010100),
            "MarketRegistered topic0 (v6 0x79f0fc18...)"
        );
        assertEq(
            IClearinghouse.MarketConfigSet.selector,
            bytes32(0x52cc1e23344c6f013d28b8fb05397e8f657e760f6610261c48d84c70161ca366),
            "MarketConfigSet topic0 (v6 0x6e4c7086...)"
        );
        assertEq(
            IClearinghouse.SeriesCreated.selector,
            keccak256("SeriesCreated(uint256,address,bool,uint128,uint40,address,uint16,uint32)"),
            "SeriesCreated signature gained mintFeePpm"
        );
        assertEq(
            IClearinghouse.SeriesCreated.selector,
            bytes32(0xed90937236a5c12f4e39a0ccb003b3b4d84470457df12240e681b3b525e10515),
            "SeriesCreated topic0 (v6 0x5d56647f...)"
        );
        assertEq(
            IClearinghouse.Minted.selector,
            keccak256("Minted(uint256,address,address,uint64,uint256,uint256)"),
            "Minted signature gained fee"
        );
        assertEq(
            IClearinghouse.Minted.selector,
            bytes32(0x89b7f2e14bc7bca4f2fd443683827b62e46c6f22ac4145d38f930082a62fcab5),
            "Minted topic0 (v6 0x1dc8a729...)"
        );
        assertEq(
            IClearinghouse.Closed.selector,
            keccak256("Closed(uint256,address,uint64,uint256,uint256)"),
            "Closed signature gained feeRefund"
        );
        assertEq(
            IClearinghouse.Closed.selector,
            bytes32(0x895110f6bb596a7019986496b866a4cebf45e0d53ff8946c952974d456540381),
            "Closed topic0 (v6 0x254f9b52...)"
        );
        assertEq(
            IClearinghouse.MintFeesAccrued.selector,
            keccak256("MintFeesAccrued(uint256,address,uint256)"),
            "MintFeesAccrued signature"
        );
        assertEq(
            IClearinghouse.MintFeesAccrued.selector,
            bytes32(0x7370e99169ee22a18273e3ff9c18124c7a0019b6f23db1f73cb86777d2b245fb),
            "MintFeesAccrued topic0 (new in v7)"
        );
    }

    function test_interfaceV7_autoRollerSelectorsAndTopics() public pure {
        assertEq(
            IAutoRoller.cancelStale.selector, bytes4(keccak256("cancelStale(address,address)")), "cancelStale signature"
        );
        assertEq(IAutoRoller.cancelStale.selector, bytes4(0xbd1a6747), "cancelStale 0xbd1a6747");
        assertEq(
            IAutoRoller.StaleAskCancelled.selector,
            keccak256("StaleAskCancelled(address,address,uint256,uint256,uint256,uint256)"),
            "StaleAskCancelled signature"
        );
        assertEq(
            IAutoRoller.StaleAskCancelled.selector,
            bytes32(0xcebe2d1e4742352b05b507fd5e0c0df36f9521884bd871d344cb9969b15ff942),
            "StaleAskCancelled topic0 (new in v7)"
        );
        // A public constant's getter has no `.selector`, so the signature is hashed directly; the value the keeper's
        // roll planner mirrors is pinned beside it.
        assertEq(bytes4(keccak256("ROLL_OPEN_GRACE()")), bytes4(0x9783cf07), "ROLL_OPEN_GRACE() 0x9783cf07");
        // The value itself is pinned against a deployed roller in AutoRollerTimingTest.test_constants_rollOpenGrace.
    }

    function test_interfaceV7_makerVaultSelectorsAndTopics() public pure {
        // Limits gained a sixth field, so setLimits and LimitsSet moved; limits() kept its selector and answers six.
        assertEq(
            MakerVault.setLimits.selector,
            bytes4(keccak256("setLimits((uint64,uint128,uint16,uint16,uint32,uint128))")),
            "setLimits signature"
        );
        assertEq(MakerVault.setLimits.selector, bytes4(0x6693cc27), "setLimits 0x6818ecdd -> 0x6693cc27");
        assertEq(MakerVault.limits.selector, bytes4(0x860aefcf), "limits() unchanged, six fields");
        assertEq(
            MakerVault.LimitsSet.selector,
            keccak256("LimitsSet((uint64,uint128,uint16,uint16,uint32,uint128))"),
            "LimitsSet signature"
        );
        assertEq(
            MakerVault.LimitsSet.selector,
            bytes32(0x7a591068b05ad6b1421ee8724ea1c282ebc7abaf323518b0cfd55b97d6fb8d98),
            "LimitsSet topic0 (v6 0x4dd15ad3...)"
        );
        assertEq(MakerVault.outflow.selector, bytes4(0xc5c96bb4), "outflow() 0xc5c96bb4 (new in v7)");
        assertEq(bytes4(keccak256("OUTFLOW_WINDOW()")), bytes4(0xcf3556ab), "OUTFLOW_WINDOW() 0xcf3556ab (new in v7)");
        // The value (86,400 = the bot's OUTFLOW_WINDOW_S) is pinned against a deployed vault in
        // MakerVaultQuoterTest.test_constructor_wiresTheBookAndRoles.
    }

    /// @dev The two new errors, in the order V2Errors appends them, with the selectors the keeper's and the MM bot's
    ///      revert decoders switch on.
    function test_interfaceV7_newErrors() public pure {
        assertEq(V2Errors.InTheMoney.selector, bytes4(keccak256("InTheMoney()")), "InTheMoney signature");
        assertEq(V2Errors.InTheMoney.selector, bytes4(0x1ca67bc5), "InTheMoney 0x1ca67bc5");
        assertEq(
            V2Errors.OutflowCapExceeded.selector,
            bytes4(keccak256("OutflowCapExceeded(uint256,uint256)")),
            "OutflowCapExceeded signature"
        );
        assertEq(V2Errors.OutflowCapExceeded.selector, bytes4(0xa713bc61), "OutflowCapExceeded 0xa713bc61");
        (string[37] memory sig,) = _errors();
        assertEq(sig[30], "InTheMoney()", "InTheMoney is appended 31st");
        assertEq(sig[31], "OutflowCapExceeded(uint256,uint256)", "OutflowCapExceeded is appended 32nd");
    }

    /// @dev `supportsInterface` answers and the `ERC165` ids every consumer feature-detects with. `IOrderBook`,
    ///      `ISettlementOracle`, `IPriceSource`, `IPayoutAdapter`, `IKeeperRewards` and `IMakerRegistry` are unchanged
    ///      by v7 and are pinned here so a later edit to a shared struct cannot move them unnoticed.
    ///      INTERFACE_VERSION 8 moved `IClearinghouse` (0xf9e1eb5d), `IOrderBook` (0xb9044893) and `IKeeperRewards`
    ///      (0xc412cde6); their new values are pinned in test_interfaceV8_interfaceIds, old -> new. The five below
    ///      are UNCHANGED in v8 as well, and stay here so a later edit to a shared struct cannot move them unnoticed.
    function test_interfaceV7_interfaceIds() public pure {
        assertEq(type(IAutoRoller).interfaceId, bytes4(0xaea42a0d), "IAutoRoller 0x13be4d4a -> 0xaea42a0d");
        assertEq(type(ISettlementOracle).interfaceId, bytes4(0x1c16c97f), "ISettlementOracle unchanged");
        assertEq(type(IPriceSource).interfaceId, bytes4(0x3682e305), "IPriceSource unchanged");
        assertEq(type(IPayoutAdapter).interfaceId, bytes4(0xff09bb7d), "IPayoutAdapter unchanged in v8 too");
        assertEq(type(IMakerRegistry).interfaceId, bytes4(0xe0f0e90c), "IMakerRegistry unchanged");
    }

    /// @dev The rent constants and the pool-ring floor the deploy scripts, the preflight and VerifyV2 all quote.
    function test_interfaceV7_rentAndPoolConstants() public pure {
        assertEq(V2Constants.PPM, 1_000_000, "millionths");
        assertEq(uint256(V2Constants.MINT_FEE_PERIOD), 7 days, "rent is quoted per week of remaining life");
        assertEq(uint256(V2Constants.MINT_FEE_PERIOD), 604_800);
        assertEq(uint256(V2Constants.MINT_FEE_CEIL_PPM), 5_000, "0.5 %/week, about 3.3x the highest launch rate");
        // Owner sign-off c10: the observation ring a market needs before it may carry a UniV3 TWAP source.
        assertEq(
            V2Constants.MIN_POOL_OBSERVATION_CARDINALITY,
            uint256(V2Constants.SETTLEMENT_WINDOW) + V2Constants.SNAPSHOT_GRACE + 1,
            "SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1"
        );
        assertEq(V2Constants.MIN_POOL_OBSERVATION_CARDINALITY, 2401);
    }

    /// @dev The two tuples, laid out field by field so a reorder (rather than an append) fails here. A v6 positional
    ///      decoder reads the first five `MarketConfig` and first eleven `Series` fields correctly, which is what
    ///      `ops/v2/monitor.mjs`'s hand-written `series()` ABI relies on until it is regenerated.
    function test_interfaceV7_tupleLayouts() public pure {
        V2Types.MarketConfig memory m = V2Types.MarketConfig({
            enabled: true,
            mintPaused: false,
            strikeTick: 2_500_000,
            exerciseFeeBps: 25,
            oracle: address(uint160(0xa11ce)),
            mintFeePpm: 80
        });
        assertEq(
            keccak256(abi.encode(m)),
            keccak256(abi.encode(true, false, uint64(2_500_000), uint16(25), address(uint160(0xa11ce)), uint32(80))),
            "MarketConfig is (bool,bool,uint64,uint16,address,uint32) in that order"
        );

        V2Types.Series memory s;
        s.underlying = address(uint160(0xbeef));
        s.isPut = true;
        s.expiry = 1_789_675_200;
        s.strike = 215_000_000;
        s.oracle = address(uint160(0xca11));
        s.exerciseFeeBps = 25;
        s.settled = false;
        s.settlementPrice = 1;
        s.longPayoutPerUnit = 2;
        s.feePerUnit = 3;
        s.shortPayoutPerUnit = 4;
        s.mintFeePpm = 80;
        s.mintFeesHeld = 5;
        bytes memory encoded = abi.encode(s);
        assertEq(encoded.length, 13 * 32, "thirteen fields, the last two appended in v7");
        // The two appended fields are the LAST two words: that is what keeps a v6 decoder correct.
        assertEq(uint256(bytes32(_word(encoded, 11))), 80, "mintFeePpm is field 12");
        assertEq(uint256(bytes32(_word(encoded, 12))), 5, "mintFeesHeld is field 13");
        assertEq(uint256(bytes32(_word(encoded, 0))), uint256(uint160(address(uint160(0xbeef)))), "underlying first");
    }

    function _word(bytes memory b, uint256 i) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(b, 32), mul(i, 32)))
        }
    }

    /*//////////////////////////////////////////////////////////////
       INTERFACE_VERSION 8: THE FREEZE (F8-02, 03-INTERFACES §1-§3)
    //////////////////////////////////////////////////////////////*/

    // Every selector, topic, tuple and interface id that moves between interface 7 and interface 8 is pinned below,
    // old -> new, and listed in `v8-plan/status/INTERFACE-CHANGES-V8.md` entry 1. A moved selector that is NOT
    // pinned here is the exact failure this task exists to prevent: 59 of the 74 v8 tasks code against this surface,
    // and a v7 decoder left on a v8 deployment mis-decodes silently rather than failing.
    //
    // Selectors of a contract that C8-* has not written yet (`PayoutRouter`, `FeeSplitter`, `V4BuybackExecutor`) are
    // pinned against their FROZEN INTERFACE, which is what the ABI export publishes and what the implementations
    // must satisfy. Where a v7 function still exists beside its v8 replacement (`registerMarket`, `defund`,
    // `withdraw`, `withdrawPosition`) the name is overloaded, so `.selector` is ambiguous and the signature is
    // hashed directly; those v7 forms are deleted by the task named beside them.

    /// @dev The compiled constants INTERFACE_VERSION 8 adds. Off-chain mirrors: the keeper's fee-delay constant, the
    ///      monitor's hand-copied ceilings, the web's fee copy, the cranker's buyback planner.
    function test_interfaceV8_constants() public pure {
        // Fee-discount seam (design §7)
        assertEq(uint256(V2Constants.MAX_DISCOUNT_BPS), 5_000, "a discount module can never take more than half");
        assertEq(V2Constants.DISCOUNT_READ_GAS, 30_000, "same budget as the rebate read");
        // Just-in-time funding (design §8.2)
        assertEq(V2Constants.FUNDING_GAS, 400_000, "gas per IFundingSource.fund call");
        assertEq(V2Constants.FUNDABLE_READ_GAS, 50_000, "gas per IFundingSource.fundable staticcall");
        assertEq(V2Constants.MAX_FUNDED_MAKERS_PER_TAKE, 4, "further funded makers are planned without funding");
        // Flywheel (design §6)
        assertEq(V2Constants.BUYBACK_CAP_CEIL, 1_000_000_000, "1,000 USDG ceiling on the per-call buyback cap");
        assertEq(uint256(V2Constants.BUYBACK_COOLDOWN), 5 minutes, "compiled cooldown between buybacks");
        assertEq(uint256(V2Constants.BUYBACK_COOLDOWN), 300);
        assertEq(uint256(V2Constants.MAX_HOOK_FEE_BPS), 300, "hook fee ceiling on the pinned v4 pool");
        // Two new bounty action ids. KeeperRewards accepts any id, so these are ids and nothing else.
        assertEq(V2Constants.ACTION_DISTRIBUTE, keccak256("DISTRIBUTE"));
        assertEq(
            V2Constants.ACTION_DISTRIBUTE,
            bytes32(0xca4be9bd739a9ff5362f4ef138b18f1b41c542345f6f1c2ebd90f78da1e5b354),
            "ACTION_DISTRIBUTE"
        );
        assertEq(V2Constants.ACTION_BUYBACK, keccak256("BUYBACK"));
        assertEq(
            V2Constants.ACTION_BUYBACK,
            bytes32(0xde40ba297f8e4a9f1224e656c3a9c0f9bfe64ee19ef70e60233b6664cc242e4b),
            "ACTION_BUYBACK"
        );
        // Unchanged, and pinned here because the flywheel and the router now depend on them too.
        assertEq(uint256(V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS), 300);
        assertEq(uint256(V2Constants.MAX_ROUTE_FEE_TIER), 10_000);
    }

    /// @dev The role ids and execution delays of the one AccessManager (design §2.2). `script/v2/roles.v8.json` is
    ///      the source of truth the deploy script, VerifyV8, the access-matrix test, the indexer and the monitor read;
    ///      `V8Roles` is its compiled mirror and the access-matrix test compares the two. ADMIN is 0 because
    ///      OpenZeppelin fixes `AccessManager.ADMIN_ROLE` there.
    function test_interfaceV8_roles() public pure {
        assertEq(uint256(V8Roles.ADMIN), 0, "ADMIN is OpenZeppelin's own ADMIN_ROLE");
        assertEq(uint256(V8Roles.FEE_MANAGER), 1);
        assertEq(uint256(V8Roles.MARKET_FEE_MANAGER), 2);
        assertEq(uint256(V8Roles.CONFIG_ADMIN), 3);
        assertEq(uint256(V8Roles.TREASURY_ADMIN), 4);
        assertEq(uint256(V8Roles.LISTING), 5);
        assertEq(uint256(V8Roles.OPS_ADMIN), 6);
        assertEq(uint256(V8Roles.GUARDIAN), 7);
        assertEq(uint256(V8Roles.PRICER), 8);
        assertEq(uint256(V8Roles.QUOTER), 9);
        assertEq(uint256(V8Roles.BUYBACK), 10);
        assertEq(uint256(V8Roles.COUNT), 11, "eleven roles in the manifest");

        assertEq(uint256(V8Roles.ADMIN_DELAY), 172_800, "role changes wait 48 h");
        assertEq(uint256(V8Roles.FEE_MANAGER_DELAY), 172_800, "48 h");
        assertEq(uint256(V8Roles.MARKET_FEE_MANAGER_DELAY), 259_200, "72 h: exercise fee and the rent dial");
        assertEq(uint256(V8Roles.CONFIG_ADMIN_DELAY), 86_400, "24 h");
        assertEq(uint256(V8Roles.TREASURY_ADMIN_DELAY), 86_400, "24 h");
        assertEq(uint256(V8Roles.LISTING_DELAY), 3_600, "1 h");
        assertEq(uint256(V8Roles.OPS_ADMIN_DELAY), 0, "hot-key rotation is instant");
        assertEq(uint256(V8Roles.GUARDIAN_DELAY), 0, "a brake that waits is not a brake");
        assertEq(uint256(V8Roles.PRICER_DELAY), 0);
        assertEq(uint256(V8Roles.QUOTER_DELAY), 0);
        assertEq(uint256(V8Roles.BUYBACK_DELAY), 0);

        assertEq(uint256(V8Roles.delayOf(V8Roles.MARKET_FEE_MANAGER)), 259_200, "delayOf mirrors the table");
        assertEq(uint256(V8Roles.delayOf(V8Roles.BUYBACK)), 0);
        assertEq(keccak256(bytes(V8Roles.nameOf(V8Roles.LISTING))), keccak256("LISTING"), "names match roles.v8.json");
        assertEq(keccak256(bytes(V8Roles.nameOf(uint64(99)))), keccak256(""), "an unknown id has no name");
    }

    /// @dev The Clearinghouse's split market surface (§2.1). The two MARKET EVENTS DO NOT MOVE -- that is the whole
    ///      point of composing the stored tuple -- so indexer and monitor handlers keep working and only the setters
    ///      change. `market()` and `series()` keep their selectors as well, because neither tuple changed in v8.
    function test_interfaceV8_clearinghouseSelectorsAndTopics() public pure {
        assertEq(
            IClearinghouse.registerMarket.selector,
            bytes4(keccak256("registerMarket(address,uint64,bool)")),
            "registerMarket signature"
        );
        assertEq(IClearinghouse.registerMarket.selector, bytes4(0x9ae621ee), "registerMarket 0xfb2a821f -> 0x9ae621ee");
        assertEq(
            IClearinghouse.setMarketListing.selector,
            bytes4(keccak256("setMarketListing(address,bool,uint64)")),
            "setMarketListing signature"
        );
        assertEq(IClearinghouse.setMarketListing.selector, bytes4(0xcb8fffcc), "setMarketListing 0xcb8fffcc (new)");
        assertEq(
            IClearinghouse.setMarketFees.selector,
            bytes4(keccak256("setMarketFees(address,uint16,uint32)")),
            "setMarketFees signature"
        );
        assertEq(IClearinghouse.setMarketFees.selector, bytes4(0x93b406fa), "setMarketFees 0x93b406fa (new)");
        assertEq(
            IClearinghouse.setMarketOracle.selector,
            bytes4(keccak256("setMarketOracle(address,address)")),
            "setMarketOracle signature"
        );
        assertEq(IClearinghouse.setMarketOracle.selector, bytes4(0xd93a11a0), "setMarketOracle 0xd93a11a0 (new)");
        assertEq(
            IClearinghouse.setDefaultMarketFees.selector,
            bytes4(keccak256("setDefaultMarketFees(uint16,uint32)")),
            "setDefaultMarketFees signature"
        );
        assertEq(
            IClearinghouse.setDefaultMarketFees.selector, bytes4(0x16d1ffcb), "setDefaultMarketFees 0x16d1ffcb (new)"
        );
        assertEq(
            IClearinghouse.setDefaultOracle.selector,
            bytes4(keccak256("setDefaultOracle(address)")),
            "setDefaultOracle signature"
        );
        assertEq(IClearinghouse.setDefaultOracle.selector, bytes4(0xc44014d2), "setDefaultOracle 0xc44014d2 (new)");
        assertEq(IClearinghouse.setMinter.selector, bytes4(keccak256("setMinter(address,bool)")), "setMinter signature");
        assertEq(IClearinghouse.setMinter.selector, bytes4(0xcf456ae7), "setMinter 0xcf456ae7 (new)");
        assertEq(IClearinghouse.isMinter.selector, bytes4(0xaa271e1a), "isMinter 0xaa271e1a (new)");
        assertEq(IClearinghouse.defaultMarketFees.selector, bytes4(0x4e5cb245), "defaultMarketFees 0x4e5cb245 (new)");
        assertEq(IClearinghouse.defaultOracle.selector, bytes4(0x80dce169), "defaultOracle 0x80dce169 (new)");

        // Removed by C8-02, pinned so nobody re-adds them under the same name by accident.
        assertEq(
            bytes4(keccak256("setMarketConfig(address,(bool,bool,uint64,uint16,address,uint32))")),
            bytes4(0x8a8e5070),
            "v7 setMarketConfig 0x8a8e5070 -- REMOVED in v8"
        );
        assertEq(
            bytes4(keccak256("registerMarket(address,(bool,bool,uint64,uint16,address,uint32))")),
            bytes4(0xfb2a821f),
            "v7 registerMarket 0xfb2a821f -- overlap overload until C8-04"
        );

        // Readers keep their selectors: MarketConfig and Series are byte-identical to v7.
        assertEq(IClearinghouse.market.selector, bytes4(0x9f382f6a), "market() unchanged in v8");
        assertEq(IClearinghouse.series.selector, bytes4(0xdc22cb6a), "series() unchanged in v8");
        assertEq(IClearinghouse.mint.selector, bytes4(keccak256("mint(uint256,uint64,address,address)")), "mint");

        // The two market topics DO NOT MOVE. Pinned against the v7 values on purpose.
        assertEq(
            IClearinghouse.MarketRegistered.selector,
            bytes32(0x9ffefa3e10b786e4dc202bedcdb98708c0feff476372922f9343e2f0c6010100),
            "MarketRegistered topic0 UNCHANGED in v8"
        );
        assertEq(
            IClearinghouse.MarketConfigSet.selector,
            bytes32(0x52cc1e23344c6f013d28b8fb05397e8f657e760f6610261c48d84c70161ca366),
            "MarketConfigSet topic0 UNCHANGED in v8"
        );

        // Three new topics.
        assertEq(
            IClearinghouse.DefaultMarketFeesSet.selector,
            keccak256("DefaultMarketFeesSet(uint16,uint32)"),
            "DefaultMarketFeesSet signature"
        );
        assertEq(
            IClearinghouse.DefaultMarketFeesSet.selector,
            bytes32(0xa20eb2fd8695b7b27879d7fb19174625c3f42b8167d57c41bebeb8795f98bba3),
            "DefaultMarketFeesSet topic0 (new in v8)"
        );
        assertEq(
            IClearinghouse.DefaultOracleSet.selector,
            bytes32(0x63dd05c06e75fb6bc19eea47dc0be12d8c10d838f9083e90baf782eb1a94dd86),
            "DefaultOracleSet topic0 (new in v8)"
        );
        assertEq(
            IClearinghouse.MinterSet.selector,
            bytes32(0x583b0aa0e528532caf4b907c11d7a8158a122fe2a6fb80cd9b09776ebea8d92d),
            "MinterSet topic0 (new in v8)"
        );
    }

    /// @dev The OrderBook. `TakeParams` grew a tenth field, so `take` and `quoteTake` both moved; `quoteTake` also
    ///      grew a fourth return, which does not affect the selector but does change every decoder.
    function test_interfaceV8_orderBookSelectorsAndTopics() public pure {
        assertEq(
            IOrderBook.take.selector,
            bytes4(keccak256("take((uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128))")),
            "take signature"
        );
        assertEq(IOrderBook.take.selector, bytes4(0xcf96851b), "take 0x086a0eb1 -> 0xcf96851b");
        assertEq(
            IOrderBook.quoteTake.selector,
            bytes4(keccak256("quoteTake((uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128))")),
            "quoteTake signature"
        );
        assertEq(IOrderBook.quoteTake.selector, bytes4(0xe2e13f01), "quoteTake 0xda4a0010 -> 0xe2e13f01");
        // The concrete book carries exactly the frozen pair.
        assertEq(OrderBook.take.selector, IOrderBook.take.selector, "OrderBook implements the frozen take");
        assertEq(OrderBook.quoteTake.selector, IOrderBook.quoteTake.selector, "and the frozen quoteTake");
        // MakerVault forwards the struct, so its own take moved with it.
        assertEq(MakerVault.take.selector, IOrderBook.take.selector, "MakerVault.take forwards the same struct");

        assertEq(
            IOrderBook.setDiscountModule.selector,
            bytes4(keccak256("setDiscountModule(address)")),
            "setDiscountModule signature"
        );
        assertEq(IOrderBook.setDiscountModule.selector, bytes4(0x55c161ad), "setDiscountModule 0x55c161ad (new)");
        assertEq(IOrderBook.discountModule.selector, bytes4(0x2adbf5d2), "discountModule 0x2adbf5d2 (new)");
        assertEq(
            IOrderBook.setFundingAllowed.selector,
            bytes4(keccak256("setFundingAllowed(address,bool)")),
            "setFundingAllowed signature"
        );
        assertEq(IOrderBook.setFundingAllowed.selector, bytes4(0x9e9696b3), "setFundingAllowed 0x9e9696b3 (new)");
        assertEq(IOrderBook.setFunding.selector, bytes4(0xeb3a2345), "setFunding 0xeb3a2345 (new)");
        assertEq(IOrderBook.fundingOf.selector, bytes4(0x6469e625), "fundingOf 0x6469e625 (new)");

        // Unchanged: the fee setters, the pause and the fill logs. Pinned so the v8 gate migration cannot move them.
        assertEq(
            bytes4(keccak256("setFeeParams((uint16,uint16,uint32,uint16,uint16))")),
            bytes4(0x81a6c4aa),
            "setFeeParams unchanged in v8"
        );
        assertEq(bytes4(keccak256("setTradingPaused(bool)")), bytes4(0xae69b95b), "setTradingPaused unchanged in v8");

        assertEq(
            IOrderBook.DiscountModuleSet.selector,
            bytes32(0x43fab025147db74d6b090f20292d9d2228109b30e23de9f14d9b53c473093b52),
            "DiscountModuleSet topic0 (new in v8)"
        );
        assertEq(
            IOrderBook.FundingAllowedSet.selector,
            bytes32(0xbc66bf4ea8c4a8444b42db703bec5bf0340d1ac1514247a09162ae3dac04eb3e),
            "FundingAllowedSet topic0 (new in v8)"
        );
        assertEq(
            IOrderBook.FundingSet.selector,
            bytes32(0x5a8146a40edb7234dddb3a2029b3f836238a7b4b4cfb6ae12f49cc76ea7b3713),
            "FundingSet topic0 (new in v8)"
        );
        assertEq(IOrderBook.Funded.selector, keccak256("Funded(address,address,uint256,uint256)"), "Funded signature");
        assertEq(
            IOrderBook.Funded.selector,
            bytes32(0x73884fbf40e5433ea6f75b9343f3208649c9b8430641c927f0ed89d4eac6945b),
            "Funded topic0 (new in v8)"
        );
        assertEq(
            IOrderBook.FundingFailed.selector,
            bytes32(0x5a80313c271886611b13f355965ff5db0c079da4a0ab83f1ae545c0f41b70151),
            "FundingFailed topic0 (new in v8)"
        );
        // The fill logs are untouched: funding logs precede them, they do not replace them.
        assertEq(
            IOrderBook.Taken.selector,
            keccak256("Taken(address,uint256,bool,uint64,uint256,uint256)"),
            "Taken UNCHANGED in v8"
        );
        assertEq(
            IOrderBook.OrderFilled.selector,
            keccak256(
                "OrderFilled(uint256,uint256,address,address,uint64,uint128,uint256,uint256,uint256,bool,bool,address)"
            ),
            "OrderFilled UNCHANGED in v8"
        );
    }

    /// @dev `TakeParams` field by field, so an INSERT rather than an append fails here. The web builds this struct
    ///      and the MM bot mirrors it; a field moved into the middle would silently shift `recipient`.
    function test_interfaceV8_takeParamsLayout() public pure {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        V2Types.TakeParams memory p = V2Types.TakeParams({
            longId: 1,
            buying: true,
            orderIds: ids,
            units: 2,
            minUnits: 3,
            limitPrice: 4,
            writeToSell: false,
            recipient: address(uint160(0xa11ce)),
            deadline: 5,
            maxTotalFee: type(uint128).max
        });
        // `TakeParams` carries a dynamic member (`orderIds`), so the struct is a DYNAMIC tuple: `abi.encode(p)`
        // prepends a 0x20 offset head word that the field-by-field `abi.encode(...)` does not emit. The v7 twin
        // above compares `Series` directly only because every one of its fields is static. Comparing the two forms
        // without allowing for that head word is what made this assertion fail the first time it was ever executed.
        assertEq(
            keccak256(abi.encode(p)),
            keccak256(
                bytes.concat(
                    bytes32(uint256(0x20)),
                    abi.encode(
                        uint256(1),
                        true,
                        ids,
                        uint64(2),
                        uint64(3),
                        uint128(4),
                        false,
                        address(uint160(0xa11ce)),
                        uint40(5),
                        type(uint128).max
                    )
                )
            ),
            "TakeParams is (uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128) in that order"
        );
        assertEq(uint256(p.maxTotalFee), type(uint128).max, "maxTotalFee is the TENTH and last field");
    }

    /// @dev Protocol-owned money leaves only to `treasury`: four functions lose their free `to` argument, so four
    ///      selectors move. The `Defunded` / `Withdrawn` / `PositionWithdrawn` topics are unchanged and now always
    ///      report the treasury.
    function test_interfaceV8_treasuryOnlyExits() public pure {
        assertEq(IKeeperRewards.defund.selector, bytes4(keccak256("defund(uint256)")), "KeeperRewards.defund");
        assertEq(IKeeperRewards.defund.selector, bytes4(0x639ddaad), "defund 0xb3c6326b -> 0x639ddaad");
        assertEq(IKeeperRewards.treasury.selector, bytes4(0x61d027b3), "treasury() 0x61d027b3 (new)");
        assertEq(IRewardsDistributor.defund.selector, bytes4(0x639ddaad), "RewardsDistributor.defund, same signature");
        assertEq(IRewardsDistributor.treasury.selector, bytes4(0x61d027b3), "treasury() 0x61d027b3 (new)");
        assertEq(bytes4(keccak256("setTreasury(address)")), bytes4(0xf0f44260), "setTreasury 0xf0f44260 (new)");
        assertEq(bytes4(keccak256("withdraw(address,uint256)")), bytes4(0xf3fef3a3), "MakerVault.withdraw 0xf3fef3a3");
        assertEq(
            bytes4(keccak256("withdrawPosition(uint256,uint256)")),
            bytes4(0xd82b99d7),
            "MakerVault.withdrawPosition 0xd82b99d7"
        );
        // The v7 forms, deleted by C8-04 / C8-05.
        assertEq(bytes4(keccak256("defund(address,uint256)")), bytes4(0xb3c6326b), "v7 defund -- REMOVED in v8");
        assertEq(
            bytes4(keccak256("withdraw(address,uint256,address)")), bytes4(0x69328dec), "v7 withdraw -- REMOVED in v8"
        );
        assertEq(
            bytes4(keccak256("withdrawPosition(uint256,uint256,address)")),
            bytes4(0x1d8950f9),
            "v7 withdrawPosition -- REMOVED in v8"
        );
        assertEq(
            bytes32(0x3c864541ef71378c6229510ed90f376565ee42d9c5e0904a984a9e863e6db44f),
            keccak256("TreasurySet(address)"),
            "TreasurySet topic0 (new in v8, same on all four holders)"
        );
        assertEq(IKeeperRewards.TreasurySet.selector, keccak256("TreasurySet(address)"), "KeeperRewards.TreasurySet");
        assertEq(
            IRewardsDistributor.TreasurySet.selector,
            keccak256("TreasurySet(address)"),
            "RewardsDistributor's is the same"
        );
        assertEq(MakerVault.TreasurySet.selector, keccak256("TreasurySet(address)"), "MakerVault's is the same");
        // MakerVault.deposit becomes permissionless in C8-05; the selector does not move.
        assertEq(MakerVault.deposit.selector, bytes4(keccak256("deposit(address,uint256)")), "deposit unchanged");
    }

    /// @dev C8-05 grossed the vault's ask floor up by the book's seller fee, which ADDS one selector to a surface
    ///      F8-02 froze and changes what an existing one MEANS without moving it. Both halves are pinned here
    ///      because the second is the dangerous one: `askFloor(uint256)` keeps 0xbdde3986 and now returns the
    ///      grossed-up floor, so an off-chain mirror that applies its own seller-fee term on top double-counts it
    ///      (the MM bot's quote maths, K8-03). A selector that moves breaks loudly; one that keeps its shape and
    ///      changes its answer does not.
    function test_interfaceV8_makerVaultAskFloor() public pure {
        assertEq(
            bytes4(keccak256("askFloorOf(uint256,bool)")), bytes4(0x0bc241eb), "MakerVault.askFloorOf 0x0bc241eb (new)"
        );
        assertEq(MakerVault.askFloorOf.selector, bytes4(0x0bc241eb), "and the compiled contract agrees");
        assertEq(MakerVault.askFloor.selector, bytes4(0xbdde3986), "askFloor 0xbdde3986 UNCHANGED, meaning changed");
        assertEq(MakerVault.bidCap.selector, bytes4(0x7966664a), "bidCap 0x7966664a unchanged in both respects");
    }

    /// @dev The PayoutRouter (§2.8). `routes(address)` KEEPS ITS SELECTOR but answers a different tuple, which is the
    ///      dangerous kind of change: `web/lib/v2/conversion.ts` destructures it positionally. `RouteSet` gained two
    ///      fields and moved topic; the monitor decodes it.
    function test_interfaceV8_payoutRouter() public pure {
        assertEq(
            IPayoutRouter.setRouteV3.selector, bytes4(keccak256("setRouteV3(address,uint24)")), "setRouteV3 signature"
        );
        assertEq(IPayoutRouter.setRouteV3.selector, bytes4(0xb5b35c41), "setRouteV3 0xb5b35c41 (new)");
        assertEq(
            IPayoutRouter.setRouteV4.selector,
            bytes4(keccak256("setRouteV4(address,uint24,int24)")),
            "setRouteV4 signature"
        );
        assertEq(IPayoutRouter.setRouteV4.selector, bytes4(0xf0754711), "setRouteV4 0xf0754711 (new)");
        assertEq(IPayoutRouter.clearRoute.selector, bytes4(0x8ebd2d29), "clearRoute 0x8ebd2d29 (new, GUARDIAN)");
        assertEq(IPayoutRouter.refreshRouteFee.selector, bytes4(0xff1928eb), "refreshRouteFee 0xff1928eb (new)");
        assertEq(IPayoutRouter.routes.selector, bytes4(0xd7409659), "routes() keeps 0xd7409659 with a NEW tuple");
        // Collision: UniV3PayoutAdapter.routes is a public mapping, so `.selector` is not a type member.
        // The generated getter is still keccak256("routes(address)") = 0xd7409659 returning (address pool, uint24 fee).
        // Same selector, different return. A positional decoder cannot feature-detect. App V2_MODULES row is OWED.
        assertEq(
            bytes4(keccak256("routes(address)")),
            bytes4(0xd7409659),
            "adapter routes() getter is the SAME selector 0xd7409659"
        );
        assertEq(
            IPayoutRouter.routes.selector,
            bytes4(keccak256("routes(address)")),
            "collision: router (venue,fee,tickSpacing,v3Pool,feeBps) vs adapter (pool, fee)"
        );
        assertEq(bytes4(keccak256("setRoute(address,uint24)")), bytes4(0x3d16c0f8), "v7 setRoute -- REMOVED in v8");
        // IPayoutAdapter itself does not move, which is why the Clearinghouse needs no edit.
        assertEq(IPayoutAdapter.swapToUsdg.selector, bytes4(0x422160df), "swapToUsdg unchanged");
        assertEq(IPayoutAdapter.routeFeeBps.selector, bytes4(0xbd28dba2), "routeFeeBps unchanged");

        assertEq(
            IPayoutRouter.RouteSet.selector,
            keccak256("RouteSet(address,uint8,bytes32,uint24,uint16)"),
            "RouteSet signature"
        );
        assertEq(
            IPayoutRouter.RouteSet.selector,
            bytes32(0xadc0c7d7edaf45c70c9c1135c172efd179926c663b67dca1e2b568c73670d447),
            "RouteSet topic0: v7 RouteSet(address,address,uint24) was 0x041b8d05..."
        );
        assertEq(
            bytes32(0x041b8d05a4af4bfc3e0509038657aaa7f371c962a6ba586bc57caea9f1faecc2),
            keccak256("RouteSet(address,address,uint24)"),
            "the v7 topic the monitor decodes today"
        );
        assertEq(
            IPayoutRouter.RouteCleared.selector,
            bytes32(0xf13e05d9cb53ed68362bc7ee84fb0c6c651d6493c29a2a2847c4926aeed3258b),
            "RouteCleared topic0 (new in v8)"
        );

        // The Route tuple, field by field: the positional read in the web depends on this order.
        IPayoutRouter.Route memory r = IPayoutRouter.Route({
            venue: IPayoutRouter.Venue.V4, fee: 3000, tickSpacing: 60, v3Pool: address(0), feeBps: 30
        });
        assertEq(
            keccak256(abi.encode(r)),
            keccak256(abi.encode(uint8(2), uint24(3000), int24(60), address(0), uint16(30))),
            "Route is (uint8 venue, uint24 fee, int24 tickSpacing, address v3Pool, uint16 feeBps)"
        );
        assertEq(uint256(uint8(IPayoutRouter.Venue.None)), 0, "Venue.None is 0: no route, pay in kind");
        assertEq(uint256(uint8(IPayoutRouter.Venue.V3)), 1);
        assertEq(uint256(uint8(IPayoutRouter.Venue.V4)), 2);
    }

    /// @dev Compile-time pin of the v7 adapter getter shape. Unreachable body; a rename or retuple fails to compile.
    function test_interfaceV8_payoutAdapterRoutesShape() public view {
        if (block.timestamp == 0) {
            UniV3PayoutAdapter(address(0)).routes(address(0));
        }
    }

    /// @dev The flywheel (§2.9, §2.10). Both contracts are written by C8-07 / C8-08; the interfaces are frozen now so
    ///      the indexer's handlers, the cranker's steps and the monitor's health checks can be built in parallel.
    function test_interfaceV8_flywheel() public pure {
        assertEq(IFeeSplitter.claimOrderBookFees.selector, bytes4(0xfca54c09), "claimOrderBookFees 0xfca54c09");
        assertEq(IFeeSplitter.distribute.selector, bytes4(0x63453ae1), "distribute(address) 0x63453ae1");
        assertEq(IFeeSplitter.buyback.selector, bytes4(0x79a9fa1c), "buyback(uint256) 0x79a9fa1c");
        assertEq(IFeeSplitter.setTreasury.selector, bytes4(0xf0f44260), "setTreasury 0xf0f44260");
        assertEq(IFeeSplitter.setOrderBook.selector, bytes4(0x9a1598c8), "setOrderBook 0x9a1598c8");
        assertEq(IFeeSplitter.setRouter.selector, bytes4(0xc0d78655), "setRouter 0xc0d78655");
        assertEq(IFeeSplitter.setBuybackExecutor.selector, bytes4(0x9649adb3), "setBuybackExecutor 0x9649adb3");
        assertEq(IFeeSplitter.setBurnBps.selector, bytes4(0xf96681fa), "setBurnBps 0xf96681fa");
        assertEq(IFeeSplitter.setBuybackCap.selector, bytes4(0x364db0e2), "setBuybackCap 0x364db0e2");
        assertEq(
            IFeeSplitter.setConversionSlippageBps.selector, bytes4(0x500947c2), "setConversionSlippageBps 0x500947c2"
        );
        assertEq(IFeeSplitter.setPaused.selector, bytes4(0x16c38b3c), "setPaused 0x16c38b3c");
        assertEq(IFeeSplitter.treasury.selector, bytes4(0x61d027b3), "treasury 0x61d027b3");
        assertEq(IFeeSplitter.buybackBalance.selector, bytes4(0xa8b51fc8), "buybackBalance 0xa8b51fc8");
        assertEq(IFeeSplitter.lastBuybackAt.selector, bytes4(0xcba3f458), "lastBuybackAt 0xcba3f458");
        assertEq(IBuybackExecutor.execute.selector, bytes4(keccak256("execute(uint256,uint256)")), "execute signature");
        assertEq(IBuybackExecutor.execute.selector, bytes4(0x5601eaea), "execute 0x5601eaea");

        assertEq(
            IFeeSplitter.Distributed.selector,
            keccak256("Distributed(address,uint256,uint256,uint256,uint256)"),
            "Distributed signature"
        );
        assertEq(
            IFeeSplitter.Distributed.selector,
            bytes32(0xac34a64bfd07da55a58f5cdd4ef06f701da1d29b4164e748c52efa857fa4810a),
            "Distributed topic0"
        );
        assertEq(
            IFeeSplitter.DistributionSkipped.selector,
            bytes32(0x909c9a749e25b695e78c231c84211fe590416c4ad5904132283c15b2d911f10c),
            "DistributionSkipped topic0"
        );
        assertEq(
            IFeeSplitter.BoughtBack.selector,
            bytes32(0x15b90a6a755d5ed0f929f1f40375d58183388d8d9e2f8e9a2efa93043e70f6de),
            "BoughtBack topic0"
        );
        assertEq(
            IFeeSplitter.Burned.selector,
            bytes32(0xd83c63197e8e676d80ab0122beba9a9d20f3828839e9a1d6fe81d242e9cd7e6e),
            "Burned topic0"
        );
        assertEq(
            IFeeSplitter.BuybackSkipped.selector,
            bytes32(0x20de42a4e1510d6b75c00824b735333f68ed1d7638c6d77ff2a9552d7d923c27),
            "BuybackSkipped topic0"
        );
    }

    /// @dev The nine config views T-75 added to `IFeeSplitter`, and the ten admin events that came with them.
    ///      THE VIEWS ARE THE ONLY REASON THE INTERFACE ID MOVED: an ERC-165 id is the XOR of an interface's
    ///      FUNCTION selectors, so the ten events below contribute nothing to it -- which is why the interface
    ///      could carry five events all along at `0x51114c7f`. `test_interfaceV8_interfaceIds` pins the result.
    ///
    ///      Each view is named for the IMPLEMENTATION'S STORAGE, not for its setter, because these are the
    ///      getters solc already generates from `FeeSplitter`'s public variables and a name that does not match
    ///      the variable would need a hand-written getter that can drift from the slot. `executor()` beside
    ///      `setBuybackExecutor` is the one place that looks wrong and is not.
    function test_interfaceV8_feeSplitterObservability() public pure {
        assertEq(IFeeSplitter.orderBook.selector, bytes4(keccak256("orderBook()")), "orderBook signature");
        assertEq(IFeeSplitter.orderBook.selector, bytes4(0x776af5ba), "orderBook 0x776af5ba");
        assertEq(IFeeSplitter.router.selector, bytes4(0xf887ea40), "router 0xf887ea40");
        assertEq(IFeeSplitter.executor.selector, bytes4(keccak256("executor()")), "executor signature");
        assertEq(IFeeSplitter.executor.selector, bytes4(0xc34c08e5), "executor 0xc34c08e5 -- NOT buybackExecutor()");
        assertEq(IFeeSplitter.oracle.selector, bytes4(0x7dc0d1d0), "oracle 0x7dc0d1d0");
        assertEq(IFeeSplitter.stonkhouse.selector, bytes4(0xbf544ae6), "stonkhouse 0xbf544ae6");
        assertEq(IFeeSplitter.burnBps.selector, bytes4(0x53deb3d6), "burnBps 0x53deb3d6");
        assertEq(IFeeSplitter.conversionSlippageBps.selector, bytes4(0x28c7267a), "conversionSlippageBps 0x28c7267a");
        assertEq(IFeeSplitter.buybackCap.selector, bytes4(0x22086d21), "buybackCap 0x22086d21");
        assertEq(IFeeSplitter.paused.selector, bytes4(0x5c975abb), "paused 0x5c975abb");

        // The ten admin topics the monitor and the indexer will decode against.
        assertEq(
            IFeeSplitter.TreasurySet.selector,
            bytes32(0x3c864541ef71378c6229510ed90f376565ee42d9c5e0904a984a9e863e6db44f),
            "TreasurySet topic0 -- SAME as IKeeperRewards and IRewardsDistributor, one handler decodes all three"
        );
        assertEq(
            IFeeSplitter.OrderBookSet.selector,
            bytes32(0xc0d608a9d759eb771bacdfc74877244d268c439cfa7625a75c6c4f97ef670ae5),
            "OrderBookSet topic0"
        );
        assertEq(
            IFeeSplitter.RouterSet.selector,
            bytes32(0xc6b438e6a8a59579ce6a4406cbd203b740e0d47b458aae6596339bcd40c40d15),
            "RouterSet topic0"
        );
        assertEq(
            IFeeSplitter.BuybackExecutorSet.selector,
            bytes32(0xc0d315541d41633a4228797dba413ac62e2b4b0ebed9aab8a7fbf4000b2ab5d5),
            "BuybackExecutorSet topic0"
        );
        assertEq(
            IFeeSplitter.SettlementOracleSet.selector,
            keccak256("SettlementOracleSet(address)"),
            "SettlementOracleSet signature -- deliberately NOT OracleSet(address,bool)"
        );
        assertEq(
            IFeeSplitter.SettlementOracleSet.selector,
            bytes32(0x85bb296e37ff8afbfba27ae3a3070c831c10f97dbdeff65195383e6664a213ee),
            "SettlementOracleSet topic0"
        );
        assertTrue(
            IFeeSplitter.SettlementOracleSet.selector != keccak256("OracleSet(address,bool)"),
            "the sources' OracleSet is a different topic and a different meaning"
        );
        assertEq(
            IFeeSplitter.StonkhouseSet.selector,
            bytes32(0x3072b66a3abb442e06badfc3af535638078d1bad9f8989e3c8bfcea013a9ac66),
            "StonkhouseSet topic0"
        );
        assertEq(
            IFeeSplitter.BurnBpsSet.selector,
            bytes32(0xd949768ce9d1cd66220761a45b087d22bb87575cd05a1a61448cecd328a27649),
            "BurnBpsSet topic0"
        );
        assertEq(
            IFeeSplitter.BuybackCapSet.selector,
            bytes32(0xe03f8a57c79d933b3969aed14667c83cd2ed883cc5539ab45a9d212583b96b23),
            "BuybackCapSet topic0"
        );
        assertEq(
            IFeeSplitter.ConversionSlippageBpsSet.selector,
            bytes32(0x41950678e0922e403ff07a57331272e34b73af94895eac2e050eb187d0a8af35),
            "ConversionSlippageBpsSet topic0"
        );
        assertEq(
            IFeeSplitter.PausedSet.selector,
            keccak256("PausedSet(bool)"),
            "PausedSet signature -- the ONLY record a zero-delay guardian pause leaves anywhere"
        );
        assertEq(
            IFeeSplitter.PausedSet.selector,
            bytes32(0x40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b212),
            "PausedSet topic0"
        );
    }

    /// @dev P8-01 is a post-freeze interface with downstream indexer and web consumers. Pin the complete function
    ///      surface and both event topics here so ABI publication cannot silently move them.
    function test_interfaceV8_stockZap() public pure {
        assertEq(
            IStockZap.writeZap.selector,
            bytes4(keccak256("writeZap(address,uint256,uint256,address,uint40)")),
            "writeZap signature"
        );
        assertEq(IStockZap.writeZap.selector, bytes4(0x1b32d546), "writeZap 0x1b32d546");
        assertEq(
            IStockZap.exitZap.selector,
            bytes4(keccak256("exitZap(address,uint256,uint256,address,uint40)")),
            "exitZap signature"
        );
        assertEq(IStockZap.exitZap.selector, bytes4(0xd07b06b7), "exitZap 0xd07b06b7");
        assertEq(
            type(IStockZap).interfaceId,
            IStockZap.writeZap.selector ^ IStockZap.exitZap.selector,
            "two selectors XOR to the compiler's id"
        );
        assertEq(type(IStockZap).interfaceId, bytes4(0xcb49d3f1), "IStockZap 0xcb49d3f1");
        assertEq(
            IStockZap.WriteZapped.selector,
            keccak256("WriteZapped(address,address,address,uint256,uint256,uint8)"),
            "WriteZapped signature"
        );
        assertEq(
            IStockZap.WriteZapped.selector,
            bytes32(0x1ae8864a999d8eea7c577cc18ede6b54ec495033e500d35c7d0bf7983d8f5b8b),
            "WriteZapped topic0"
        );
        assertEq(
            IStockZap.ExitZapped.selector,
            keccak256("ExitZapped(address,address,address,uint256,uint256,uint8)"),
            "ExitZapped signature"
        );
        assertEq(
            IStockZap.ExitZapped.selector,
            bytes32(0x23fdd2820484cbab406be2291fedb6a8a27d14e277812685619e9bbfad0620a1),
            "ExitZapped topic0"
        );
    }

    /// @dev The id moved because functions were added, and ONLY because functions were added. This recomputes it
    ///      the way ERC-165 defines it -- XOR of every function selector -- from the 23 selectors pinned above, so
    ///      a future edit that adds a function without touching `test_interfaceV8_interfaceIds` fails here too.
    ///      Entry 2 of INTERFACE-CHANGES-V8.md exists because F8-02 published two selectors it never executed;
    ///      this is the second independent route for the number T-75 publishes.
    function test_interfaceV8_feeSplitterIdIsTheXorOfItsSelectors() public pure {
        bytes4 x = IFeeSplitter.claimOrderBookFees.selector ^ IFeeSplitter.distribute.selector
            ^ IFeeSplitter.buyback.selector ^ IFeeSplitter.setTreasury.selector ^ IFeeSplitter.setOrderBook.selector
            ^ IFeeSplitter.setRouter.selector ^ IFeeSplitter.setBuybackExecutor.selector
            ^ IFeeSplitter.setBurnBps.selector ^ IFeeSplitter.setBuybackCap.selector
            ^ IFeeSplitter.setConversionSlippageBps.selector ^ IFeeSplitter.setPaused.selector
            ^ IFeeSplitter.treasury.selector ^ IFeeSplitter.buybackBalance.selector
            ^ IFeeSplitter.lastBuybackAt.selector ^ IFeeSplitter.orderBook.selector ^ IFeeSplitter.router.selector
            ^ IFeeSplitter.executor.selector ^ IFeeSplitter.oracle.selector ^ IFeeSplitter.stonkhouse.selector
            ^ IFeeSplitter.burnBps.selector ^ IFeeSplitter.conversionSlippageBps.selector
            ^ IFeeSplitter.buybackCap.selector ^ IFeeSplitter.paused.selector;
        assertEq(x, type(IFeeSplitter).interfaceId, "23 selectors XOR to the compiler's id");
        assertEq(x, bytes4(0xdaa26260), "and that id is 0xdaa26260");
        // The nine views are exactly what moved it: undoing them returns the frozen v8 value.
        bytes4 withoutViews = x ^ IFeeSplitter.orderBook.selector ^ IFeeSplitter.router.selector
            ^ IFeeSplitter.executor.selector ^ IFeeSplitter.oracle.selector ^ IFeeSplitter.stonkhouse.selector
            ^ IFeeSplitter.burnBps.selector ^ IFeeSplitter.conversionSlippageBps.selector
            ^ IFeeSplitter.buybackCap.selector ^ IFeeSplitter.paused.selector;
        assertEq(withoutViews, bytes4(0x51114c7f), "the ten new EVENTS moved nothing; F8-02's id is still in there");
    }

    /// @dev The two default-off seams (§1.4). One function each; they are frozen so the Earn vault and any later
    ///      discount programme build against a surface that cannot move.
    function test_interfaceV8_seams() public pure {
        assertEq(IFeeDiscount.discountBps.selector, bytes4(keccak256("discountBps(address)")), "discountBps signature");
        assertEq(IFundingSource.fundable.selector, bytes4(keccak256("fundable(address)")), "fundable signature");
        assertEq(IFundingSource.fund.selector, bytes4(keccak256("fund(address,uint256)")), "fund signature");
        assertEq(IEarnVenueAdapter.asset.selector, bytes4(keccak256("asset()")), "IEarnVenueAdapter.asset");
        assertEq(IEarnVenueAdapter.deposit.selector, bytes4(keccak256("deposit(uint256)")), "IEarnVenueAdapter.deposit");
        assertEq(
            IEarnVenueAdapter.withdraw.selector,
            bytes4(keccak256("withdraw(uint256,address)")),
            "IEarnVenueAdapter.withdraw"
        );
        assertEq(
            IEarnVenueAdapter.withdrawable.selector,
            bytes4(keccak256("withdrawable()")),
            "IEarnVenueAdapter.withdrawable"
        );
        assertEq(
            IEarnVenueAdapter.totalAssets.selector, bytes4(keccak256("totalAssets()")), "IEarnVenueAdapter.totalAssets"
        );
    }

    /// @dev The five errors INTERFACE_VERSION 8 appends, with the selectors the keeper's, the web's and the MM bot's
    ///      revert decoders switch on. `NotAuthorized` stays 0xea8e4eb5 even though the access model changed
    ///      completely: that is exactly what the `Managed` base exists for.
    function test_interfaceV8_newErrors() public pure {
        assertEq(V2Errors.FeeAboveMax.selector, bytes4(keccak256("FeeAboveMax(uint256,uint256)")), "FeeAboveMax");
        assertEq(V2Errors.FeeAboveMax.selector, bytes4(0x7b7d1b03), "FeeAboveMax 0x7b7d1b03");
        assertEq(V2Errors.NotMinter.selector, bytes4(0xf8d2906c), "NotMinter 0xf8d2906c");
        assertEq(V2Errors.RouteRejected.selector, bytes4(0x6aca99f5), "RouteRejected 0x6aca99f5");
        assertEq(V2Errors.CooldownActive.selector, bytes4(0xc97f9297), "CooldownActive 0xc97f9297");
        assertEq(V2Errors.CapExceeded.selector, bytes4(0xf480e285), "CapExceeded 0xf480e285");
        assertEq(V2Errors.NotAuthorized.selector, bytes4(0xea8e4eb5), "NotAuthorized UNCHANGED under AccessManager");
        (string[37] memory sig,) = _errors();
        assertEq(sig[32], "FeeAboveMax(uint256,uint256)", "appended 33rd");
        assertEq(sig[33], "NotMinter()", "appended 34th");
        assertEq(sig[34], "RouteRejected(bytes32)", "appended 35th");
        assertEq(sig[35], "CooldownActive(uint40)", "appended 36th");
        assertEq(sig[36], "CapExceeded(uint256,uint256)", "appended 37th");
    }

    /// @dev Every ERC-165 id consumers feature-detect with, old -> new. Three moved because their tuples or their
    ///      function lists changed; six are new.
    function test_interfaceV8_interfaceIds() public pure {
        assertEq(type(IClearinghouse).interfaceId, bytes4(0x9b75eeed), "IClearinghouse 0xf9e1eb5d -> 0x9b75eeed");
        assertEq(type(IOrderBook).interfaceId, bytes4(0x288c3b84), "IOrderBook 0xb9044893 -> 0x288c3b84");
        assertEq(type(IKeeperRewards).interfaceId, bytes4(0xc65f30f8), "IKeeperRewards 0xc412cde6 -> 0xc65f30f8");
        assertEq(type(IRewardsDistributor).interfaceId, bytes4(0x8fa44ca4), "IRewardsDistributor (never pinned before)");
        assertEq(type(IPayoutRouter).interfaceId, bytes4(0xe32288cb), "IPayoutRouter (new in v8)");
        assertEq(type(IFeeSplitter).interfaceId, bytes4(0xdaa26260), "IFeeSplitter 0x51114c7f -> 0xdaa26260 (T-75)");
        assertEq(type(IBuybackExecutor).interfaceId, bytes4(0x5601eaea), "IBuybackExecutor (new in v8)");
        assertEq(type(IFeeDiscount).interfaceId, bytes4(0x78e5e5fe), "IFeeDiscount (new in v8)");
        assertEq(type(IFundingSource).interfaceId, bytes4(0x2b7c8ca4), "IFundingSource (new in v8)");
        assertEq(type(IEarnVenueAdapter).interfaceId, bytes4(0xdf6e37f1), "IEarnVenueAdapter (new in T-103)");
        // T-184 MOVED THIS PIN, and the new value was MEASURED from the compiled artifact rather than computed
        // by hand: the queueing ruling added `hasOpenShort()` and `escrowedAssets()` to the interface. `deposit`
        // KEPT its selector by owner ruling, so it is not part of why this moved. Old value 0x4ebdffdc.
        // T-OP-065 MOVED IT AGAIN: `indicativeTotalAssets()` (0x6166631c) and `indicativeAssetsPerShare()`
        // (0x2934a020) joined the interface. MEASURED from the compiled artifact (the old pin run against the new
        // interface printed 0x2c9acbed) AND re-derived by hand as 0x64c808d1 ^ 0x6166631c ^ 0x2934a020; both agree.
        // The T-184 value 0x64c808d1 is the previous pin.
        assertEq(type(IEarnVault).interfaceId, bytes4(0x2c9acbed), "IEarnVault (T-103, T-184, repinned by T-OP-065)");
    }

    /// @dev XOR of the five IEarnVenueAdapter functions must equal the compiler id. A sixth function that
    ///      nobody listed here would still move `type().interfaceId` and fail the pin above; this catches the
    ///      opposite, a listed selector that is not actually on the interface.
    function test_interfaceV8_earnVenueAdapterSelectorsXor() public pure {
        bytes4 x = IEarnVenueAdapter.asset.selector ^ IEarnVenueAdapter.deposit.selector
            ^ IEarnVenueAdapter.withdraw.selector ^ IEarnVenueAdapter.withdrawable.selector
            ^ IEarnVenueAdapter.totalAssets.selector;
        assertEq(x, type(IEarnVenueAdapter).interfaceId, "5 selectors XOR to the compiler's id");
        assertEq(x, bytes4(0xdf6e37f1), "and that id is 0xdf6e37f1");
    }

    function test_interfaceV8_earnVaultSelectorsXor() public pure {
        bytes4 x = IEarnVault.deposit.selector ^ IEarnVault.redeem.selector ^ IEarnVault.processQueue.selector
            ^ IEarnVault.cancelQueued.selector ^ IEarnVault.skim.selector ^ IEarnVault.asset.selector
            ^ IEarnVault.totalAssets.selector ^ IEarnVault.convertToShares.selector
            ^ IEarnVault.convertToAssets.selector ^ IEarnVault.highWaterMark.selector ^ IEarnVault.skimBps.selector
            ^ IEarnVault.adapter.selector ^ IEarnVault.queue.selector ^ IEarnVault.request.selector
            ^ IEarnVault.fundingBudget.selector
            // T-184: the flat boundary is observable, so these two are part of the interface and of its id.
            ^ IEarnVault.hasOpenShort.selector ^ IEarnVault.escrowedAssets.selector
            // T-OP-065: the display-only mark and its per-share form; convert* now revert while a position is open.
            ^ IEarnVault.indicativeTotalAssets.selector ^ IEarnVault.indicativeAssetsPerShare.selector;
        assertEq(x, type(IEarnVault).interfaceId, "19 selectors XOR to the compiler's id");
        assertEq(x, bytes4(0x2c9acbed), "and that id is 0x2c9acbed");
    }

    /*//////////////////////////////////////////////////////////////
                                   IDS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_longIdOf_matchesReference(address underlying, bool isPut, uint128 strike, uint40 expiry)
        public
        pure
    {
        uint256 longId = V2Ids.longIdOf(underlying, isPut, strike, expiry);
        assertEq(longId, _refLongId(underlying, isPut, strike, expiry), "longIdOf != reference");
        assertEq(longId & 1, 0, "long id low bit must be 0");
        assertFalse(V2Ids.isShortId(longId), "a long id is not a short id");

        uint256 shortId = V2Ids.shortIdOf(longId);
        assertEq(shortId, _refShortId(longId), "shortIdOf != reference");
        assertEq(shortId & 1, 1, "short id low bit must be 1");
        assertTrue(V2Ids.isShortId(shortId), "a short id is a short id");
        assertEq(V2Ids.shortIdOf(shortId), shortId, "shortIdOf is idempotent");
    }

    /// @dev The documented formula verbatim, so V2Ids cannot drift from what IClearinghouse.longIdOf promises.
    function testFuzz_longIdOf_isDocumentedFormula(address underlying, bool isPut, uint128 strike, uint40 expiry)
        public
        pure
    {
        assertEq(
            V2Ids.longIdOf(underlying, isPut, strike, expiry),
            uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))) & ~uint256(1)
        );
    }

    function testFuzz_isShortId_isLowBit(uint256 id) public pure {
        assertEq(V2Ids.isShortId(id), _refIsShort(id));
        assertTrue(V2Ids.isShortId(V2Ids.shortIdOf(id)), "shortIdOf always yields a short id");
    }

    function test_ids_putAndCallDiffer() public pure {
        address nvda = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
        uint256 callId = V2Ids.longIdOf(nvda, false, 215_000_000, 1_789_675_200);
        uint256 putId = V2Ids.longIdOf(nvda, true, 215_000_000, 1_789_675_200);
        assertTrue(callId != putId, "call and put of one strike/expiry are different series");
        assertTrue(V2Ids.shortIdOf(callId) != putId && V2Ids.shortIdOf(putId) != callId, "no long/short overlap");
    }

    /*//////////////////////////////////////////////////////////////
                           SERIES-ID VECTOR FILE
    //////////////////////////////////////////////////////////////*/

    function _vectorKey(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(i), "].", field);
    }

    /// @dev Every vector in the committed file matches V2Ids and the reference. uint256 fields are decimal strings.
    function test_seriesIdVectors_matchV2IdsAndReference() public view {
        string memory json = vm.readFile(VECTORS);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".vectors[", vm.toString(n), "]"))) {
            address underlying = vm.parseJsonAddress(json, _vectorKey(n, "underlying"));
            bool isPut = vm.parseJsonBool(json, _vectorKey(n, "isPut"));
            uint256 strikeRaw = vm.parseUint(vm.parseJsonString(json, _vectorKey(n, "strike")));
            uint256 expiryRaw = vm.parseJsonUint(json, _vectorKey(n, "expiry"));
            uint256 longId = vm.parseUint(vm.parseJsonString(json, _vectorKey(n, "longId")));
            uint256 shortId = vm.parseUint(vm.parseJsonString(json, _vectorKey(n, "shortId")));

            assertLe(strikeRaw, type(uint128).max, "strike fits uint128");
            assertLe(expiryRaw, type(uint40).max, "expiry fits uint40");
            // casting is safe: both bounds were asserted on the line above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 strike = uint128(strikeRaw);
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40 expiry = uint40(expiryRaw);

            string memory at = string.concat("vector ", vm.toString(n));
            assertEq(V2Ids.longIdOf(underlying, isPut, strike, expiry), longId, at);
            assertEq(_refLongId(underlying, isPut, strike, expiry), longId, at);
            assertEq(V2Ids.shortIdOf(longId), shortId, at);
            assertEq(_refShortId(longId), shortId, at);
            assertFalse(V2Ids.isShortId(longId), at);
            assertTrue(V2Ids.isShortId(shortId), at);
            ++n;
        }
        assertGe(n, 12, "series-ids.json holds the full vector set");
    }

    /// @dev The committed file is exactly what script/v2/EmitSeriesIds.s.sol emits today: same count, same inputs in
    ///      the same order. A vector added to the script without re-running it fails here.
    function test_seriesIdVectors_matchEmitter() public {
        EmitSeriesIds.Vector[] memory v = new EmitSeriesIds().vectors();
        string memory json = vm.readFile(VECTORS);
        for (uint256 i; i < v.length; ++i) {
            string memory at = string.concat("vector ", vm.toString(i));
            assertEq(vm.parseJsonAddress(json, _vectorKey(i, "underlying")), v[i].underlying, at);
            assertEq(vm.parseJsonBool(json, _vectorKey(i, "isPut")), v[i].isPut, at);
            assertEq(vm.parseJsonString(json, _vectorKey(i, "strike")), vm.toString(uint256(v[i].strike)), at);
            assertEq(vm.parseJsonUint(json, _vectorKey(i, "expiry")), v[i].expiry, at);
        }
        assertFalse(
            vm.keyExistsJson(json, string.concat(".vectors[", vm.toString(v.length), "]")),
            "file has vectors the script does not emit: re-run forge script script/v2/EmitSeriesIds.s.sol"
        );
    }

    /*//////////////////////////////////////////////////////////////
                               SHARED ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Signature and selector of every shared error, in declaration order. Decoders in the keeper, indexer and
    ///      web match on these selectors.
    function _errors() internal pure returns (string[37] memory sig, bytes4[37] memory sel) {
        sig = [
            "NotAuthorized()",
            "MarketDisabled()",
            "MintPaused()",
            "CreatePaused()",
            "TradingPaused()",
            "BadStrike()",
            "BadExpiry()",
            "BadPrice()",
            "BadUnits()",
            "UnknownSeries()",
            "PastCutoff()",
            "NotExpired()",
            "NotSettled()",
            "AlreadySettled()",
            "InsufficientCollateral(uint256,uint256)",
            "UnsupportedAsset()",
            "BelowMinUnits(uint64,uint64)",
            "DeadlinePassed()",
            "OrderNotLive(uint256)",
            "ThirdPartyRedeemDisabled()",
            "SeriesIdCollision()",
            "OutsideRegularSession()",
            "TooEarly(uint40)",
            "StaleSpot(uint256)",
            "NoSource()",
            "AlreadyFinal()",
            "ResolveOutOfBand(uint256,uint256)",
            "CeilingExceeded()",
            "PinMismatch()",
            "SourceNotPinned(address,bytes4)",
            "InTheMoney()",
            "OutflowCapExceeded(uint256,uint256)",
            // INTERFACE_VERSION 8, appended in this order (03-INTERFACES §1.3)
            "FeeAboveMax(uint256,uint256)",
            "NotMinter()",
            "RouteRejected(bytes32)",
            "CooldownActive(uint40)",
            "CapExceeded(uint256,uint256)"
        ];
        sel = [
            V2Errors.NotAuthorized.selector,
            V2Errors.MarketDisabled.selector,
            V2Errors.MintPaused.selector,
            V2Errors.CreatePaused.selector,
            V2Errors.TradingPaused.selector,
            V2Errors.BadStrike.selector,
            V2Errors.BadExpiry.selector,
            V2Errors.BadPrice.selector,
            V2Errors.BadUnits.selector,
            V2Errors.UnknownSeries.selector,
            V2Errors.PastCutoff.selector,
            V2Errors.NotExpired.selector,
            V2Errors.NotSettled.selector,
            V2Errors.AlreadySettled.selector,
            V2Errors.InsufficientCollateral.selector,
            V2Errors.UnsupportedAsset.selector,
            V2Errors.BelowMinUnits.selector,
            V2Errors.DeadlinePassed.selector,
            V2Errors.OrderNotLive.selector,
            V2Errors.ThirdPartyRedeemDisabled.selector,
            V2Errors.SeriesIdCollision.selector,
            V2Errors.OutsideRegularSession.selector,
            V2Errors.TooEarly.selector,
            V2Errors.StaleSpot.selector,
            V2Errors.NoSource.selector,
            V2Errors.AlreadyFinal.selector,
            V2Errors.ResolveOutOfBand.selector,
            V2Errors.CeilingExceeded.selector,
            V2Errors.PinMismatch.selector,
            V2Errors.SourceNotPinned.selector,
            V2Errors.InTheMoney.selector,
            V2Errors.OutflowCapExceeded.selector,
            V2Errors.FeeAboveMax.selector,
            V2Errors.NotMinter.selector,
            V2Errors.RouteRejected.selector,
            V2Errors.CooldownActive.selector,
            V2Errors.CapExceeded.selector
        ];
    }

    function test_errors_selectorsMatchSignatures() public pure {
        (string[37] memory sig, bytes4[37] memory sel) = _errors();
        for (uint256 i; i < 37; ++i) {
            assertEq(sel[i], bytes4(keccak256(bytes(sig[i]))), sig[i]);
        }
    }

    /// @dev export-abis.sh publishes this artifact's ABI as ops/abis/v2/V2Errors.json; it must carry every shared error
    ///      and nothing else, with exactly the signatures above.
    function test_errors_artifactAbiHasEveryError() public view {
        (string[37] memory sig,) = _errors();
        string memory json = vm.readFile(ERRORS_ARTIFACT);
        uint256 found;
        for (uint256 i; vm.keyExistsJson(json, string.concat(".abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(entry, ".type")), "error", "errors only in V2Errors");
            string memory s = string.concat(vm.parseJsonString(json, string.concat(entry, ".name")), "(");
            for (uint256 j; vm.keyExistsJson(json, string.concat(entry, ".inputs[", vm.toString(j), "]")); ++j) {
                if (j > 0) s = string.concat(s, ",");
                s = string.concat(
                    s, vm.parseJsonString(json, string.concat(entry, ".inputs[", vm.toString(j), "].type"))
                );
            }
            s = string.concat(s, ")");
            bool known;
            for (uint256 k; k < 37; ++k) {
                if (keccak256(bytes(sig[k])) == keccak256(bytes(s))) known = true;
            }
            assertTrue(known, string.concat("unexpected error in V2Errors ABI: ", s));
            ++found;
        }
        assertEq(found, 37, "V2Errors ABI must list all 37 shared errors");
    }
}
