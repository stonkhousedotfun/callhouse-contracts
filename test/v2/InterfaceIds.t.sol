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
import {IClearinghouse} from "../../src/v2/interfaces/IClearinghouse.sol";
import {IKeeperRewards} from "../../src/v2/interfaces/IKeeperRewards.sol";
import {IMakerRegistry} from "../../src/v2/interfaces/IMakerRegistry.sol";
import {IOrderBook} from "../../src/v2/interfaces/IOrderBook.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
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
        assertEq(uint256(V2Constants.FEE_CHANGE_DELAY), 24 hours, "an OrderBook fee change takes effect 24 h later");
        assertEq(uint256(V2Constants.FEE_CHANGE_DELAY), 86_400);
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
        assertEq(uint256(feesFrom), 1_789_848_000, "a fee change scheduled at t applies from t + FEE_CHANGE_DELAY");

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
        assertEq(
            Clearinghouse.registerMarket.selector,
            bytes4(keccak256("registerMarket(address,(bool,bool,uint64,uint16,address,uint32))")),
            "registerMarket signature"
        );
        assertEq(Clearinghouse.registerMarket.selector, bytes4(0xfb2a821f), "registerMarket 0x45baaccb -> 0xfb2a821f");
        assertEq(
            Clearinghouse.setMarketConfig.selector,
            bytes4(keccak256("setMarketConfig(address,(bool,bool,uint64,uint16,address,uint32))")),
            "setMarketConfig signature"
        );
        assertEq(Clearinghouse.setMarketConfig.selector, bytes4(0x8a8e5070), "setMarketConfig 0x05aa2668 -> 0x8a8e5070");
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
        (string[32] memory sig,) = _errors();
        assertEq(sig[30], "InTheMoney()", "InTheMoney is appended 31st");
        assertEq(sig[31], "OutflowCapExceeded(uint256,uint256)", "OutflowCapExceeded is appended 32nd");
    }

    /// @dev `supportsInterface` answers and the `ERC165` ids every consumer feature-detects with. `IOrderBook`,
    ///      `ISettlementOracle`, `IPriceSource`, `IPayoutAdapter`, `IKeeperRewards` and `IMakerRegistry` are unchanged
    ///      by v7 and are pinned here so a later edit to a shared struct cannot move them unnoticed.
    function test_interfaceV7_interfaceIds() public pure {
        assertEq(type(IClearinghouse).interfaceId, bytes4(0xf9e1eb5d), "IClearinghouse 0xb4b9d26c -> 0xf9e1eb5d");
        assertEq(type(IAutoRoller).interfaceId, bytes4(0xaea42a0d), "IAutoRoller 0x13be4d4a -> 0xaea42a0d");
        assertEq(type(IOrderBook).interfaceId, bytes4(0xb9044893), "IOrderBook unchanged");
        assertEq(type(ISettlementOracle).interfaceId, bytes4(0x1c16c97f), "ISettlementOracle unchanged");
        assertEq(type(IPriceSource).interfaceId, bytes4(0x3682e305), "IPriceSource unchanged");
        assertEq(type(IPayoutAdapter).interfaceId, bytes4(0xff09bb7d), "IPayoutAdapter unchanged");
        assertEq(type(IKeeperRewards).interfaceId, bytes4(0xc412cde6), "IKeeperRewards unchanged");
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
    function _errors() internal pure returns (string[32] memory sig, bytes4[32] memory sel) {
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
            "OutflowCapExceeded(uint256,uint256)"
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
            V2Errors.OutflowCapExceeded.selector
        ];
    }

    function test_errors_selectorsMatchSignatures() public pure {
        (string[32] memory sig, bytes4[32] memory sel) = _errors();
        for (uint256 i; i < 32; ++i) {
            assertEq(sel[i], bytes4(keccak256(bytes(sig[i]))), sig[i]);
        }
    }

    /// @dev export-abis.sh publishes this artifact's ABI as ops/abis/v2/V2Errors.json; it must carry every shared error
    ///      and nothing else, with exactly the signatures above.
    function test_errors_artifactAbiHasEveryError() public view {
        (string[32] memory sig,) = _errors();
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
            for (uint256 k; k < 32; ++k) {
                if (keccak256(bytes(sig[k])) == keccak256(bytes(s))) known = true;
            }
            assertTrue(known, string.concat("unexpected error in V2Errors ABI: ", s));
            ++found;
        }
        assertEq(found, 32, "V2Errors ABI must list all 32 shared errors");
    }
}
