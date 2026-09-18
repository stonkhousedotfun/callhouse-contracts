// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../src/v2/OrderBook.sol";
import {MakerRegistry} from "../../src/v2/mm/MakerRegistry.sol";
import {MakerVault} from "../../src/v2/mm/MakerVault.sol";
import {RewardsDistributor} from "../../src/v2/mm/RewardsDistributor.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../src/v2/oracle/UniV3TwapSource.sol";
import {IUniV3PoolFactory, IUniV3SwapRouter02} from "../../src/v2/periphery/PayoutDeps.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {BytecodeCheck} from "../lib/BytecodeCheck.sol";
import {PinDryRun} from "./lib/PinDryRun.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

interface IPoolFee {
    function token0() external view returns (address);
    function fee() external view returns (uint24);
    /// @dev Only `observationCardinality` is read (owner sign-off c10): the live length of the pool's observation ring.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @notice Read-only post-deploy check of the whole v2 set against the registry: bytecode, immutables, dependencies,
///         pointers, roles, fee parameters and ceilings, the calendar, and every market's config. Broadcasts nothing.
///         Prints one line per check and reverts at the end if any failed.
/// @dev Run from a checkout of the EXACT commit that was deployed, after `forge build` (the bytecode checks compare the
///      chain against `out/`). `script/v2/DeployV2Batch.sh --verify` exports the environment from the registry; by hand
///      export the `V2_*` variables of lib/V2DeployBase.sol and:
///        forge script script/v2/VerifyV2.s.sol --rpc-url $RH_RPC --no-storage-caching
///
///      WHAT IS CHECKED
///        1. chain id.
///        2. bytecode: each of the 13 contracts against its `out/` artifact, byte for byte outside the immutable slots
///           (the v2 contracts link no library). This is what proves the logic and every compiled ceiling are this
///           commit's.
///        3. immutables by value: every contract's USDG; OrderBook -> Clearinghouse; AutoRoller and MakerVault -> OrderBook
///           and its Clearinghouse; the adapter's router, and its factory == the router's == V2_UNIV3_FACTORY;
///           DataStreamsSource's VerifierProxy. A few public compiled constants (defaults the scripts rely on).
///        4. dependencies: USDG symbol and decimals, router, factory and VerifierProxy code.
///        5. pointers: Clearinghouse calendar, fee recipient, payout adapter, keeper rewards, base URI; oracle ->
///           Clearinghouse (the only caller of pin) and KeeperRewards; each of the three sources lists the oracle as
///           allowed to pin (and neither the admin nor the cranker); AutoRoller -> KeeperRewards; OrderBook maker
///           registry and fee recipient;
///           the three bounty callers registered and nothing else among the set; the OrderBook opted out of third-party
///           redemption (C2-06).
///        6. MakerVault (C2-11): Clearinghouse operator approval and ERC-1155 approval for the book, USDG allowance to the
///           book, limits -- six fields from INTERFACE_VERSION 7, `maxDailyOutflow` included, plus an `info` line with
///           `outflow()` used/available and a loud one when the cap is 0 (a spend freeze).
///        7. parameters: OrderBook fees == registry `v2.fees` (fee changes wait 24 h: while one is scheduled and not yet
///           in effect, the scheduled fees are compared, and an `info` line names them, the fees in effect and
///           effectiveAt); `premiumFeeBps <= resaleFeeBps`, in effect and scheduled (INTERFACE_VERSION 7, c05: a
///           premium fee above the resale fee is the dodge the collateral rent replaced); payout slippage, the SIX
///           bounties (CANCEL_STALE from INTERFACE_VERSION 7), daily cap, min redeem payout, min roll units, vault
///           limits == the launch values (V2_* overrides). With V2_EXPECT_FRESH=true (the
///           default, right after a deploy) a difference FAILs; with false it is an `info` line, because after launch
///           these are the admin's to tune (the registry says "launch values; the contracts hold the live ones"). Every
///           compiled ceiling FAILs either way.
///        8. calendar: every V2_HOLIDAYS day is a holiday.
///        9. roles: V2_ADMIN holds DEFAULT_ADMIN_ROLE on all 13; the guardian GUARDIAN_ROLE on Clearinghouse, OrderBook
///           and SettlementOracle; the pricer PRICER_ROLE on AutoRoller; the MM quoter QUOTER_ROLE on MakerVault; nobody
///           else of {admin, guardian, cranker, pricer, mmQuoter, V2_DEPLOYER} holds any of those roles; the five are
///           distinct; every role is administered by DEFAULT_ADMIN_ROLE.
///       10. markets (V2_TICKERS, the registry rows with registeredAt): token symbol and decimals, feed description and
///           decimals; Clearinghouse market {enabled, strikeTick, exerciseFeeBps, oracle, mintFeePpm} -- the rent rate
///           against the registry (a `_param`: a FAIL when fresh, an info line on a live set, because the admin may
///           raise it for NEW series) and against MINT_FEE_CEIL_PPM (always a FAIL); Chainlink feed with the
///           source defaults; the Uniswap pool config (or none) AND, whenever a pool is configured on the source or
///           listed in the registry, its `slot0().observationCardinality` at least
///           V2Constants.MIN_POOL_OBSERVATION_CARDINALITY (2401) -- owner sign-off c10, the refusal that keeps every
///           launch pool but NVDA's and SPCX's Chainlink-only; the oracle source list [chainlink] or [chainlink, univ3],
///           deviation, delay, spot age; no Data Streams feed; a dry run of the pin the next series makes (see PIN DRY
///           RUN); with a pool, its fee tier at most V2Constants.MAX_ROUTE_FEE_TIER (10000: a costlier payout route
///           would pay every conversion in kind) and the payout route == (pool, fee) and the factory's pool (C2-10); or
///           no route.
///       11. V2_UNREGISTERED_ASSETS (every other registry row): not registered on the Clearinghouse.
///       12. fresh state (V2_EXPECT_FRESH): no pause set, no order placed, the vault holds no exposure, no bounty paid.
///
///      PIN DRY RUN (INTERFACE_VERSION 6). Pinning fails closed, so a market whose first series of an expiry cannot pin
///      cannot create series at all. Per market, {PinDryRun} sends `settlementOracle.pin(asset, E)` AS the Clearinghouse
///      (a `vm.prank` in the simulation; nothing is broadcast) for E = the next calendar expiry at least MIN_SERIES_LEAD
///      ahead, and reverts with the outcome, so nothing it wrote stays. It fails on everything a real createSeries would
///      meet: the oracle not naming the Clearinghouse, a listed source not listing the oracle or without a configuration
///      for the asset, and a pin of E made outside a series creation that differs from the current configuration
///      (V2Errors.PinMismatch, or SourceNotPinned(source, PinMismatch)). The revert data is printed as an info line.
contract VerifyV2 is BytecodeCheck, V2DeployBase {
    struct Inputs {
        Contracts c;
        Roles roles;
        address deployer; // V2_DEPLOYER, optional: checked to hold no role when it is not the admin
        External ext;
        Params params;
        uint32[] holidays;
        MarketIn[] markets; // V2_TICKERS, optional
        /// @dev INTERFACE_VERSION 7: the rent rate the registry asks of each market, parallel to `markets`
        ///      (V2_MARKET_<T>_MINT_FEE_PPM over V2_MINT_FEE_PPM over 0), compared with MarketConfig.mintFeePpm.
        uint32[] mintFeePpm;
        /// @dev INTERFACE_VERSION 7 release blocker (DECISIONS-2026-09-17 §11): `V2_ALLOW_ZERO_RENT`. Without it a
        ///      live market whose `mintFeePpm` is 0 is a FAIL, not a drift info line. An opt-in asked for here is
        ///      only granted under the forge TEST runner ({V2DeployBase.zeroRentAllowed}), so a `forge script
        ///      VerifyV2 --rpc-url <live 4663>` FAILs such a market however it was invoked -- VerifyV2 broadcasts
        ///      nothing, so nothing keyed to `--broadcast` ever covered this path.
        bool allowZeroRent;
        address[] unregistered; // V2_UNREGISTERED_ASSETS, optional
        bool expectFresh; // V2_EXPECT_FRESH, default true
        uint256 expectChainId; // V2_EXPECT_CHAIN_ID, default 4663
    }

    uint256 internal failures;
    uint256 internal passes;

    function run() external {
        (uint256 passed, uint256 failed) = check(inputsFromEnv());
        console2.log("");
        if (failed != 0) {
            console2.log(
                string.concat(
                    "VERIFY FAILED: ", vm.toString(failed), " check(s) failed of ", vm.toString(passed + failed)
                )
            );
            revert("verify failed");
        }
        console2.log(string.concat("VERIFY PASSED: ", vm.toString(passed), " checks"));
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.c = contractsFromEnv();
        in_.roles = rolesFromEnv();
        in_.deployer = vm.envOr("V2_DEPLOYER", address(0));
        in_.ext = externalFromEnv();
        in_.params = paramsFromEnv();
        in_.holidays = holidaysFromEnv();
        if (vm.envExists("V2_TICKERS") && bytes(vm.envString("V2_TICKERS")).length != 0) {
            in_.markets = marketsFromEnv();
        }
        in_.allowZeroRent = allowZeroRentFromEnv();
        in_.mintFeePpm = mintFeePpmFromEnv(in_.markets);
        in_.unregistered = vm.envOr("V2_UNREGISTERED_ASSETS", ",", new address[](0));
        in_.expectFresh = vm.envOr("V2_EXPECT_FRESH", true);
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
    }

    /// @notice Every check, printed; returns the counts and never reverts on a failed check.
    function check(Inputs memory in_) public returns (uint256 passed, uint256 failed) {
        passes = 0;
        failures = 0;
        console2.log("chain");
        _check(block.chainid == in_.expectChainId, string.concat("chain id ", vm.toString(block.chainid)));
        if (!_haveCode(in_.c)) return (passes, failures);
        _bytecode(in_.c);
        _immutables(in_);
        _dependencies(in_);
        _pointers(in_);
        _vault(in_);
        _parameters(in_);
        _calendar(in_);
        _roles(in_);
        for (uint256 i; i < in_.markets.length; ++i) {
            _market(in_, in_.markets[i]);
        }
        _unregistered(in_);
        if (in_.expectFresh) _fresh(in_);
        return (passes, failures);
    }

    function _check(bool ok, string memory what) internal {
        if (ok) {
            ++passes;
            console2.log(string.concat("  ok    ", what));
        } else {
            ++failures;
            console2.log(string.concat("  FAIL  ", what));
        }
    }

    function _info(string memory what) internal pure {
        console2.log(string.concat("  info  ", what));
    }

    /*//////////////////////////////////////////////////////////////
                                 BYTECODE
    //////////////////////////////////////////////////////////////*/

    /// @dev Stops early (after counting the failures) when an address is missing: nothing below can be read.
    function _haveCode(Contracts memory c) internal returns (bool all) {
        console2.log("contracts have code");
        (address[] memory addrs, string[] memory names,) = _set(c);
        all = true;
        for (uint256 i; i < addrs.length; ++i) {
            bool ok = addrs[i] != address(0) && addrs[i].code.length != 0;
            _check(ok, string.concat(names[i], " ", vm.toString(addrs[i]), " has code"));
            all = all && ok;
        }
    }

    function _bytecode(Contracts memory c) internal {
        console2.log("bytecode (against out/ of this checkout)");
        (address[] memory addrs, string[] memory names, string[] memory artifacts) = _set(c);
        for (uint256 i; i < addrs.length; ++i) {
            string memory json = vm.readFile(artifacts[i]);
            bytes memory want = _artifactRuntime(json);
            bool[] memory mask = new bool[](want.length);
            if (vm.keyExistsJson(json, ".deployedBytecode.immutableReferences")) _maskImmutables(json, mask);
            _check(
                _equalMasked(addrs[i].code, want, mask),
                string.concat(names[i], ": runtime == compiled artifact, outside immutable slots")
            );
        }
    }

    /// @dev The 13 contracts with their registry names and artifacts, in deploy order.
    function _set(Contracts memory c)
        internal
        pure
        returns (address[] memory addrs, string[] memory names, string[] memory artifacts)
    {
        addrs = new address[](13);
        names = new string[](13);
        artifacts = new string[](13);
        (addrs[0], names[0], artifacts[0]) = (c.expiryCalendar, "expiryCalendar", ART_EXPIRY_CALENDAR);
        (addrs[1], names[1], artifacts[1]) = (c.chainlinkSource, "sources.chainlink", ART_CHAINLINK_SOURCE);
        (addrs[2], names[2], artifacts[2]) = (c.univ3Source, "sources.univ3", ART_UNIV3_SOURCE);
        (addrs[3], names[3], artifacts[3]) = (c.dataStreamsSource, "sources.dataStreams", ART_DATA_STREAMS_SOURCE);
        (addrs[4], names[4], artifacts[4]) = (c.settlementOracle, "settlementOracle", ART_SETTLEMENT_ORACLE);
        (addrs[5], names[5], artifacts[5]) = (c.clearinghouse, "clearinghouse", ART_CLEARINGHOUSE);
        (addrs[6], names[6], artifacts[6]) = (c.orderBook, "orderBook", ART_ORDER_BOOK);
        (addrs[7], names[7], artifacts[7]) = (c.keeperRewards, "keeperRewards", ART_KEEPER_REWARDS);
        (addrs[8], names[8], artifacts[8]) = (c.autoRoller, "autoRoller", ART_AUTO_ROLLER);
        (addrs[9], names[9], artifacts[9]) = (c.payoutAdapter, "payoutAdapter", ART_PAYOUT_ADAPTER);
        (addrs[10], names[10], artifacts[10]) = (c.makerRegistry, "makerRegistry", ART_MAKER_REGISTRY);
        (addrs[11], names[11], artifacts[11]) = (c.makerVault, "makerVault", ART_MAKER_VAULT);
        (addrs[12], names[12], artifacts[12]) = (c.rewardsDistributor, "rewardsDistributor", ART_REWARDS_DISTRIBUTOR);
    }

    /*//////////////////////////////////////////////////////////////
                           IMMUTABLES, DEPENDENCIES
    //////////////////////////////////////////////////////////////*/

    function _immutables(Inputs memory in_) internal {
        console2.log("immutables");
        Contracts memory c = in_.c;
        address usdg = in_.ext.usdg;
        _check(Clearinghouse(c.clearinghouse).usdg() == usdg, "clearinghouse.usdg == V2_USDG");
        _check(OrderBook(c.orderBook).clearinghouse() == c.clearinghouse, "orderBook.clearinghouse == clearinghouse");
        _check(address(OrderBook(c.orderBook).usdg()) == usdg, "orderBook.usdg == V2_USDG");
        _check(UniV3TwapSource(c.univ3Source).usdg() == usdg, "sources.univ3.usdg == V2_USDG");
        _check(
            DataStreamsSource(c.dataStreamsSource).verifierProxy() == in_.ext.dataStreamsVerifier,
            "sources.dataStreams.verifierProxy == V2_DATA_STREAMS_VERIFIER"
        );
        _check(address(KeeperRewards(c.keeperRewards).usdg()) == usdg, "keeperRewards.usdg == V2_USDG");
        AutoRoller roller = AutoRoller(c.autoRoller);
        _check(address(roller.orderBook()) == c.orderBook, "autoRoller.orderBook == orderBook");
        _check(address(roller.clearinghouse()) == c.clearinghouse, "autoRoller.clearinghouse == clearinghouse");
        _check(roller.usdg() == usdg, "autoRoller.usdg == V2_USDG");
        UniV3PayoutAdapter adapter = UniV3PayoutAdapter(c.payoutAdapter);
        _check(adapter.usdg() == usdg, "payoutAdapter.usdg == V2_USDG");
        _check(adapter.router() == in_.ext.swapRouter02, "payoutAdapter.router == V2_SWAP_ROUTER02");
        _check(
            adapter.factory() == in_.ext.univ3Factory
                && IUniV3SwapRouter02(in_.ext.swapRouter02).factory() == in_.ext.univ3Factory,
            "payoutAdapter.factory == swapRouter02.factory() == V2_UNIV3_FACTORY"
        );
        MakerVault vault = MakerVault(c.makerVault);
        _check(address(vault.orderBook()) == c.orderBook, "makerVault.orderBook == orderBook");
        _check(address(vault.clearinghouse()) == c.clearinghouse, "makerVault.clearinghouse == clearinghouse");
        _check(address(vault.usdg()) == usdg, "makerVault.usdg == V2_USDG");
        _check(address(RewardsDistributor(c.rewardsDistributor).usdg()) == usdg, "rewardsDistributor.usdg == V2_USDG");

        console2.log("compiled constants");
        ChainlinkFeedSource chainlink = ChainlinkFeedSource(c.chainlinkSource);
        _check(
            chainlink.DEFAULT_MAX_STALE() == 26 hours && chainlink.DEFAULT_MAX_ROUND_JUMP_BPS() == 2000,
            "chainlink source defaults 26 h / 2000 bps"
        );
        _check(UniV3TwapSource(c.univ3Source).DEFAULT_WINDOW() == 300, "univ3 source default window 300 s");
        SettlementOracle oracle = SettlementOracle(c.settlementOracle);
        _check(
            oracle.SETTLEMENT_WINDOW() == V2Constants.SETTLEMENT_WINDOW && oracle.MAX_SOURCES() == 8
                && oracle.MAX_DEVIATION_CEIL_BPS() == 1000 && oracle.MAX_UNCORROBORATED_DELAY() == 24 hours
                && oracle.MIN_UNCORROBORATED_DELAY() == 30 minutes && oracle.MAX_SPOT_MAX_AGE() == 4 days,
            "settlementOracle window 1800 s, 8 sources, deviation <= 1000 bps, delay 30 min..24 h, spot age <= 4 d"
        );
        _check(
            Clearinghouse(c.clearinghouse).DEFAULT_MIN_REDEEM_PAYOUT() == 1_000_000,
            "clearinghouse DEFAULT_MIN_REDEEM_PAYOUT 1 USDG"
        );
        _check(
            roller.MIN_OTM_BPS() == 100 && roller.MAX_OTM_BPS() == 2500 && roller.MIN_ASK_BPS() == 5
                && roller.MAX_ASK_BPS() == 1000,
            "autoRoller strategy bounds otm 100..2500, ask 5..1000 bps"
        );
        _check(vault.MAX_LIVE_ORDERS_PER_SERIES() == 16, "makerVault MAX_LIVE_ORDERS_PER_SERIES 16");
    }

    function _dependencies(Inputs memory in_) internal {
        console2.log("dependencies");
        address usdg = in_.ext.usdg;
        _check(_eq(IERC20Metadata(usdg).symbol(), "USDG") && IERC20Metadata(usdg).decimals() == 6, "usdg: USDG, 6 dp");
        _check(in_.ext.swapRouter02.code.length != 0, "swapRouter02 has code");
        _check(in_.ext.univ3Factory.code.length != 0, "uniswap v3 factory has code");
        _check(in_.ext.dataStreamsVerifier.code.length != 0, "Data Streams VerifierProxy has code");
    }

    /*//////////////////////////////////////////////////////////////
                                 POINTERS
    //////////////////////////////////////////////////////////////*/

    function _pointers(Inputs memory in_) internal {
        console2.log("pointers");
        Contracts memory c = in_.c;
        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        _check(ch.calendar() == c.expiryCalendar, "clearinghouse.calendar == expiryCalendar");
        _check(ch.feeRecipient() == in_.roles.feeRecipient, "clearinghouse.feeRecipient == V2_FEE_RECIPIENT");
        _check(ch.payoutAdapter() == c.payoutAdapter, "clearinghouse.payoutAdapter == payoutAdapter");
        _check(address(ch.keeperRewards()) == c.keeperRewards, "clearinghouse.keeperRewards == keeperRewards");
        _check(_eq(ch.baseUri(), in_.params.baseUri), string.concat("clearinghouse.baseUri == ", in_.params.baseUri));
        _check(!ch.thirdPartyRedeemAllowed(c.orderBook), "orderBook opted out of third-party redemption");
        SettlementOracle oracle = SettlementOracle(c.settlementOracle);
        _check(oracle.clearinghouse() == c.clearinghouse, "settlementOracle.clearinghouse == clearinghouse");
        _check(oracle.keeperRewards() == c.keeperRewards, "settlementOracle.keeperRewards == keeperRewards");
        _check(
            ChainlinkFeedSource(c.chainlinkSource).isOracle(c.settlementOracle)
                && UniV3TwapSource(c.univ3Source).isOracle(c.settlementOracle)
                && DataStreamsSource(c.dataStreamsSource).isOracle(c.settlementOracle),
            "sources.chainlink, sources.univ3, sources.dataStreams: isOracle(settlementOracle)"
        );
        _check(
            !ChainlinkFeedSource(c.chainlinkSource).isOracle(in_.roles.admin)
                && !UniV3TwapSource(c.univ3Source).isOracle(in_.roles.admin)
                && !DataStreamsSource(c.dataStreamsSource).isOracle(in_.roles.admin)
                && !ChainlinkFeedSource(c.chainlinkSource).isOracle(in_.roles.cranker)
                && !UniV3TwapSource(c.univ3Source).isOracle(in_.roles.cranker)
                && !DataStreamsSource(c.dataStreamsSource).isOracle(in_.roles.cranker),
            "sources: neither the admin nor the cranker may pin"
        );
        _check(
            address(AutoRoller(c.autoRoller).keeperRewards()) == c.keeperRewards,
            "autoRoller.keeperRewards == keeperRewards"
        );
        OrderBook book = OrderBook(c.orderBook);
        _check(address(book.makerRegistry()) == c.makerRegistry, "orderBook.makerRegistry == makerRegistry");
        _check(book.feeRecipient() == in_.roles.feeRecipient, "orderBook.feeRecipient == V2_FEE_RECIPIENT");
        KeeperRewards kr = KeeperRewards(c.keeperRewards);
        _check(
            kr.isCaller(c.settlementOracle) && kr.isCaller(c.clearinghouse) && kr.isCaller(c.autoRoller),
            "keeperRewards callers: settlementOracle, clearinghouse, autoRoller"
        );
        (address[] memory addrs,,) = _set(c);
        bool others;
        for (uint256 i; i < addrs.length; ++i) {
            if (addrs[i] == c.settlementOracle || addrs[i] == c.clearinghouse || addrs[i] == c.autoRoller) continue;
            others = others || kr.isCaller(addrs[i]);
        }
        others = others || kr.isCaller(in_.roles.admin) || kr.isCaller(in_.roles.cranker);
        _check(!others, "keeperRewards: no other contract of the set, the admin or the cranker is a caller");
    }

    function _vault(Inputs memory in_) internal {
        console2.log("maker vault (C2-11)");
        Contracts memory c = in_.c;
        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        _check(ch.isOperator(c.makerVault, c.orderBook), "clearinghouse.isOperator(makerVault, orderBook)");
        _check(ch.isApprovedForAll(c.makerVault, c.orderBook), "clearinghouse.isApprovedForAll(makerVault, orderBook)");
        _check(
            IERC20(in_.ext.usdg).allowance(c.makerVault, c.orderBook) >= type(uint128).max,
            "usdg.allowance(makerVault, orderBook) unlimited"
        );
        _check(
            !ch.isOperator(c.makerVault, in_.roles.mmQuoter),
            "the MM quoter is not a Clearinghouse operator of the vault"
        );
        _info(
            string.concat(
                "makerVault holds ",
                vm.toString(IERC20(in_.ext.usdg).balanceOf(c.makerVault)),
                " USDG base units in its wallet, ",
                vm.toString(ch.free(c.makerVault, in_.ext.usdg)),
                " in its Clearinghouse ledger (funding is an owner step)"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _underCeilings(V2Types.FeeParams memory f) internal pure returns (bool) {
        return f.premiumFeeBps <= V2Constants.PREMIUM_FEE_CEIL_BPS && f.resaleFeeBps <= V2Constants.PREMIUM_FEE_CEIL_BPS
            && f.takerFeeFlat <= V2Constants.TAKER_FEE_FLAT_CEIL
            && f.takerFeeCapBps <= V2Constants.TAKER_FEE_CAP_CEIL_BPS && f.makerRebateBps <= V2Constants.BPS;
    }

    /// @dev INTERFACE_VERSION 7 (c05): a premium fee above the resale fee is the dodge itself. Writing into a one-tick
    ///      bid of your own second address and reselling the long pays the smaller of the two, so the writer fee has to
    ///      be the rent at mint and `premiumFeeBps <= resaleFeeBps` must hold whatever the two are tuned to. Launch is
    ///      premium 0 / resale 0, which satisfies it.
    function _premiumUnderResale(V2Types.FeeParams memory f) internal pure returns (bool) {
        return f.premiumFeeBps <= f.resaleFeeBps;
    }

    function _feesText(V2Types.FeeParams memory f) internal pure returns (string memory) {
        return string.concat(
            "premium ",
            vm.toString(f.premiumFeeBps),
            " bps, resale ",
            vm.toString(f.resaleFeeBps),
            " bps, taker flat ",
            vm.toString(f.takerFeeFlat),
            ", taker cap ",
            vm.toString(f.takerFeeCapBps),
            " bps, maker rebate ",
            vm.toString(f.makerRebateBps),
            " bps"
        );
    }

    /// @dev Equal to the launch value: a check when fresh, an info line otherwise.
    function _param(bool fresh, bool equal, string memory what, string memory live) internal {
        if (fresh) _check(equal, what);
        else if (equal) _check(true, what);
        else _info(string.concat(what, ": differs (live ", live, "), admin-tuned after launch"));
    }

    function _parameters(Inputs memory in_) internal {
        console2.log(
            in_.expectFresh ? "parameters (fresh: launch values)" : "parameters (live: ceilings, launch values as info)"
        );
        Contracts memory c = in_.c;
        Params memory p = in_.params;
        bool fresh = in_.expectFresh;

        // Fee changes wait OrderBook's FEE_CHANGE_DELAY. The registry holds the fees the book should charge, so each
        // is compared with where the book is heading: a scheduled change not in effect yet when there is one (it is
        // printed with its effectiveAt), else the fees in effect.
        OrderBook book = OrderBook(c.orderBook);
        V2Types.FeeParams memory f = book.feeParams();
        (V2Types.FeeParams memory q, uint40 effectiveAt) = book.pendingFeeParams();
        bool pending = effectiveAt != 0;
        if (pending) {
            _info(
                string.concat(
                    "orderBook fee change scheduled, in effect from unix ",
                    vm.toString(effectiveAt),
                    " (block.timestamp >= it): ",
                    _feesText(q),
                    "; until then ",
                    _feesText(f)
                )
            );
        }
        _check(
            _underCeilings(f) && (!pending || _underCeilings(q)),
            pending
                ? "orderBook fees under their ceilings (in effect and scheduled)"
                : "orderBook fees under their ceilings"
        );
        _check(
            _premiumUnderResale(f) && (!pending || _premiumUnderResale(q)),
            pending
                ? "orderBook premiumFeeBps <= resaleFeeBps (in effect and scheduled; v7 c05)"
                : "orderBook premiumFeeBps <= resaleFeeBps (v7 c05)"
        );
        V2Types.FeeParams memory t = pending ? q : f;
        string memory tag = pending ? string.concat(" (scheduled, from unix ", vm.toString(effectiveAt), ")") : "";
        _param(
            fresh,
            t.premiumFeeBps == p.fees.premiumFeeBps,
            string.concat("orderBook premiumFeeBps == ", vm.toString(p.fees.premiumFeeBps), tag),
            vm.toString(t.premiumFeeBps)
        );
        _param(
            fresh,
            t.resaleFeeBps == p.fees.resaleFeeBps,
            string.concat("orderBook resaleFeeBps == ", vm.toString(p.fees.resaleFeeBps), tag),
            vm.toString(t.resaleFeeBps)
        );
        _param(
            fresh,
            t.takerFeeFlat == p.fees.takerFeeFlat,
            string.concat("orderBook takerFeeFlat == ", vm.toString(p.fees.takerFeeFlat), tag),
            vm.toString(t.takerFeeFlat)
        );
        _param(
            fresh,
            t.takerFeeCapBps == p.fees.takerFeeCapBps,
            string.concat("orderBook takerFeeCapBps == ", vm.toString(p.fees.takerFeeCapBps), tag),
            vm.toString(t.takerFeeCapBps)
        );
        _param(
            fresh,
            t.makerRebateBps == p.fees.makerRebateBps,
            string.concat("orderBook makerRebateBps == ", vm.toString(p.fees.makerRebateBps), tag),
            vm.toString(t.makerRebateBps)
        );

        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        _check(
            ch.maxPayoutSlippageBps() <= V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS,
            "clearinghouse payout slippage <= 300 bps"
        );
        _param(
            fresh,
            ch.maxPayoutSlippageBps() == p.payoutSlippageBps,
            string.concat("clearinghouse maxPayoutSlippageBps == ", vm.toString(p.payoutSlippageBps)),
            vm.toString(ch.maxPayoutSlippageBps())
        );
        _param(
            fresh,
            ch.minRedeemPayout() == ch.DEFAULT_MIN_REDEEM_PAYOUT(),
            "clearinghouse minRedeemPayout == 1 USDG",
            vm.toString(ch.minRedeemPayout())
        );

        KeeperRewards kr = KeeperRewards(c.keeperRewards);
        // Six actions from INTERFACE_VERSION 7: CANCEL_STALE joined the five of v6 (c16).
        uint256[6] memory want =
            [p.bountySnapshot, p.bountyFinalize, p.bountySettle, p.bountyRedeem, p.bountyRoll, p.bountyCancelStale];
        bytes32[6] memory actions = [
            V2Constants.ACTION_SNAPSHOT,
            V2Constants.ACTION_FINALIZE,
            V2Constants.ACTION_SETTLE,
            V2Constants.ACTION_REDEEM,
            V2Constants.ACTION_ROLL,
            V2Constants.ACTION_CANCEL_STALE
        ];
        string[6] memory names = ["SNAPSHOT", "FINALIZE", "SETTLE", "REDEEM", "ROLL", "CANCEL_STALE"];
        bool underMax = true;
        for (uint256 i; i < 6; ++i) {
            uint256 live = kr.bounty(actions[i]);
            underMax = underMax && live <= V2Constants.MAX_BOUNTY;
            _param(
                fresh,
                live == want[i],
                string.concat("keeperRewards bounty ", names[i], " == ", vm.toString(want[i])),
                vm.toString(live)
            );
        }
        _check(underMax, "keeperRewards bounties <= MAX_BOUNTY");
        _param(
            fresh,
            kr.dailyCap() == p.dailyCap,
            string.concat("keeperRewards dailyCap == ", vm.toString(p.dailyCap)),
            vm.toString(kr.dailyCap())
        );
        _info(
            string.concat(
                "keeperRewards USDG balance ",
                vm.toString(IERC20(in_.ext.usdg).balanceOf(c.keeperRewards)),
                " base units (funding is an owner step)"
            )
        );

        AutoRoller roller = AutoRoller(c.autoRoller);
        _param(
            fresh,
            roller.minRollUnits() == roller.DEFAULT_MIN_ROLL_UNITS(),
            "autoRoller minRollUnits == 100",
            vm.toString(roller.minRollUnits())
        );

        MakerVault.Limits memory l = MakerVault(c.makerVault).limits();
        MakerVault.Limits memory w = p.vaultLimits;
        _check(
            l.askToleranceBps <= V2Constants.BPS && l.maxBidBpsOfSpot <= V2Constants.BPS,
            "makerVault limit bps <= 10000"
        );
        _param(
            fresh,
            l.maxSeriesUnits == w.maxSeriesUnits && l.maxTotalNotional == w.maxTotalNotional
                && l.askToleranceBps == w.askToleranceBps && l.maxBidBpsOfSpot == w.maxBidBpsOfSpot
                && l.maxOrderLifetime == w.maxOrderLifetime && l.maxDailyOutflow == w.maxDailyOutflow,
            string.concat(
                "makerVault limits == (",
                vm.toString(w.maxSeriesUnits),
                ", ",
                vm.toString(w.maxTotalNotional),
                ", ",
                vm.toString(w.askToleranceBps),
                ", ",
                vm.toString(w.maxBidBpsOfSpot),
                ", ",
                vm.toString(w.maxOrderLifetime),
                ", ",
                vm.toString(w.maxDailyOutflow),
                ")"
            ),
            string.concat(
                vm.toString(l.maxSeriesUnits),
                ", ",
                vm.toString(l.maxTotalNotional),
                ", maxDailyOutflow ",
                vm.toString(l.maxDailyOutflow)
            )
        );
        // INTERFACE_VERSION 7 (c21): 0 is a spend freeze -- the quoter may still cancel, close, move the ledger and
        // place asks, but no bid, take or replace upwards. Never a deploy value; flagged loudly if it is live.
        if (l.maxDailyOutflow == 0) {
            _info("makerVault maxDailyOutflow is 0: the quoter is frozen for spending (unwinding still works)");
        }
        (uint256 used, uint256 available) = MakerVault(c.makerVault).outflow();
        _info(
            string.concat(
                "makerVault outflow: used ",
                vm.toString(used),
                ", available ",
                vm.toString(available),
                " of ",
                vm.toString(l.maxDailyOutflow),
                " USDG base units, refilling over OUTFLOW_WINDOW ",
                vm.toString(MakerVault(c.makerVault).OUTFLOW_WINDOW()),
                " s"
            )
        );
    }

    function _calendar(Inputs memory in_) internal {
        console2.log("calendar");
        ExpiryCalendar cal = ExpiryCalendar(in_.c.expiryCalendar);
        uint256 missing;
        for (uint256 i; i < in_.holidays.length; ++i) {
            if (!cal.holiday(in_.holidays[i])) {
                ++missing;
                _info(string.concat("day index ", vm.toString(in_.holidays[i]), " is not a holiday on the calendar"));
            }
        }
        _check(
            in_.holidays.length != 0 && missing == 0,
            string.concat("expiryCalendar: all ", vm.toString(in_.holidays.length), " V2_HOLIDAYS are holidays")
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  ROLES
    //////////////////////////////////////////////////////////////*/

    function _roles(Inputs memory in_) internal {
        console2.log("roles");
        _roleAdmins(in_);
        Roles memory r = in_.roles;
        Contracts memory c = in_.c;
        _check(
            _holders(c.clearinghouse, V2Constants.GUARDIAN_ROLE, r.guardian, r, in_.deployer)
                && _holders(c.orderBook, V2Constants.GUARDIAN_ROLE, r.guardian, r, in_.deployer)
                && _holders(c.settlementOracle, V2Constants.GUARDIAN_ROLE, r.guardian, r, in_.deployer),
            "GUARDIAN_ROLE on clearinghouse, orderBook, settlementOracle: the guardian and nobody else checked"
        );
        _check(
            _holders(c.autoRoller, V2Constants.PRICER_ROLE, r.pricer, r, in_.deployer),
            "PRICER_ROLE on autoRoller: the pricer and nobody else checked"
        );
        _check(
            _holders(c.makerVault, V2Constants.QUOTER_ROLE, r.mmQuoter, r, in_.deployer),
            "QUOTER_ROLE on makerVault: the MM quoter and nobody else checked"
        );
        _check(
            _noStrayRoles(in_),
            "guardian, cranker, pricer, mmQuoter and the deployer hold no DEFAULT_ADMIN_ROLE; no stray GUARDIAN_ROLE"
        );

        address[5] memory keys = [r.admin, r.guardian, r.cranker, r.pricer, r.mmQuoter];
        bool distinct = true;
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                distinct = distinct && keys[i] != keys[j];
            }
        }
        _check(distinct, "admin, guardian, cranker, pricer, mmQuoter are five distinct addresses");
    }

    /// @dev The admin holds DEFAULT_ADMIN_ROLE everywhere, and every role is administered by it.
    function _roleAdmins(Inputs memory in_) internal {
        (address[] memory addrs, string[] memory names,) = _set(in_.c);
        bool adminEverywhere = true;
        bool administered = true;
        for (uint256 i; i < addrs.length; ++i) {
            IAccessControl ac = IAccessControl(addrs[i]);
            if (!ac.hasRole(V2Constants.DEFAULT_ADMIN_ROLE, in_.roles.admin)) {
                adminEverywhere = false;
                _info(string.concat("V2_ADMIN lacks DEFAULT_ADMIN_ROLE on ", names[i]));
            }
            administered = administered && _administered(ac);
        }
        _check(adminEverywhere, "V2_ADMIN holds DEFAULT_ADMIN_ROLE on all 13 contracts");
        _check(administered, "every role on every contract is administered by DEFAULT_ADMIN_ROLE");
        if (in_.roles.admin.code.length == 0) _info("V2_ADMIN is a plain key, not a Safe");
    }

    function _administered(IAccessControl ac) internal view returns (bool) {
        bytes32 admin = V2Constants.DEFAULT_ADMIN_ROLE;
        return ac.getRoleAdmin(admin) == admin && ac.getRoleAdmin(V2Constants.GUARDIAN_ROLE) == admin
            && ac.getRoleAdmin(V2Constants.PRICER_ROLE) == admin && ac.getRoleAdmin(V2Constants.QUOTER_ROLE) == admin;
    }

    /// @dev No key but the admin holds DEFAULT_ADMIN_ROLE anywhere; the guardian holds GUARDIAN_ROLE only where assigned.
    function _noStrayRoles(Inputs memory in_) internal view returns (bool clean) {
        (address[] memory addrs, string[] memory names,) = _set(in_.c);
        clean = true;
        for (uint256 i; i < addrs.length; ++i) {
            clean = _noStrayAdmin(in_, addrs[i], names[i]) && clean;
            bool home =
                addrs[i] == in_.c.clearinghouse || addrs[i] == in_.c.orderBook || addrs[i] == in_.c.settlementOracle;
            if (!home && IAccessControl(addrs[i]).hasRole(V2Constants.GUARDIAN_ROLE, in_.roles.guardian)) {
                clean = false;
                _info(string.concat("the guardian holds GUARDIAN_ROLE on ", names[i]));
            }
        }
    }

    function _noStrayAdmin(Inputs memory in_, address target, string memory name) internal view returns (bool clean) {
        Roles memory r = in_.roles;
        address[5] memory others = [r.guardian, r.cranker, r.pricer, r.mmQuoter, in_.deployer];
        clean = true;
        for (uint256 k; k < others.length; ++k) {
            if (others[k] == address(0) || others[k] == r.admin) continue;
            if (IAccessControl(target).hasRole(V2Constants.DEFAULT_ADMIN_ROLE, others[k])) {
                clean = false;
                _info(string.concat(vm.toString(others[k]), " holds DEFAULT_ADMIN_ROLE on ", name));
            }
        }
    }

    /// @dev `holder` has `role` on `target` and none of the other known keys does.
    function _holders(address target, bytes32 role, address holder, Roles memory r, address deployer)
        internal
        view
        returns (bool)
    {
        IAccessControl ac = IAccessControl(target);
        if (!ac.hasRole(role, holder)) return false;
        address[6] memory keys = [r.admin, r.guardian, r.cranker, r.pricer, r.mmQuoter, deployer];
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == address(0) || keys[i] == holder) continue;
            if (ac.hasRole(role, keys[i])) return false;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                 MARKETS
    //////////////////////////////////////////////////////////////*/

    /// @dev The rent rate the registry asks of `m`: `in_.mintFeePpm` is parallel to `in_.markets`, and an Inputs built
    ///      by hand may leave it empty, which means 0 for every market (the v6 behaviour).
    function _mintFeePpmOf(Inputs memory in_, MarketIn memory m) internal pure returns (uint32) {
        for (uint256 i; i < in_.markets.length && i < in_.mintFeePpm.length; ++i) {
            if (_eq(in_.markets[i].ticker, m.ticker)) return in_.mintFeePpm[i];
        }
        return 0;
    }

    /// @dev Owner sign-off c10 (DECISIONS-2026-09-17 §7): a market may only carry a UniV3 TWAP source when the pool's
    ///      observation ring outlasts a flood through the snapshot grace, `V2Constants.MIN_POOL_OBSERVATION_CARDINALITY`
    ///      (2401 = SETTLEMENT_WINDOW + SNAPSHOT_GRACE + 1). `UniV3TwapSource.setPool` refuses a shallower pool and
    ///      `RegisterMarkets`' preflight refuses it before anything is broadcast; this is the same refusal after the
    ///      fact, so a pool whose ring was raised for the deploy and let shrink cannot pass a verify. Every launch pool
    ///      but NVDA's and SPCX's is below it and is registered CHAINLINK-ONLY at launch.
    function _poolRing(string memory t, address pool) internal {
        uint256 want = V2Constants.MIN_POOL_OBSERVATION_CARDINALITY;
        (,,, uint16 cardinality,,,) = IPoolFee(pool).slot0();
        _check(
            uint256(cardinality) >= want,
            string.concat(
                t,
                "pool observationCardinality ",
                vm.toString(uint256(cardinality)),
                " >= ",
                vm.toString(want),
                " (a shallower ring can be flooded past an expiry's window before the snapshot grace ends;",
                " register the market Chainlink-only or raise the ring)"
            )
        );
    }

    function _market(Inputs memory in_, MarketIn memory m) internal {
        console2.log(string.concat("market ", m.ticker));
        Contracts memory c = in_.c;
        string memory t = string.concat(m.ticker, ": ");

        bool tokenOk = m.asset.code.length != 0;
        if (tokenOk) {
            tokenOk = _eq(IERC20Metadata(m.asset).symbol(), m.ticker) && IERC20Metadata(m.asset).decimals() == 18;
        }
        _check(tokenOk, string.concat(t, "asset symbol == ticker, 18 dp"));
        bool feedOk = m.feed.code.length != 0;
        if (feedOk) {
            feedOk = _contains(IChainlinkFeed(m.feed).description(), m.ticker) && IChainlinkFeed(m.feed).decimals() == 8;
        }
        _check(feedOk, string.concat(t, "feed description contains the ticker, 8 dp"));

        V2Types.MarketConfig memory cfg = Clearinghouse(c.clearinghouse).market(m.asset);
        _check(cfg.strikeTick != 0, string.concat(t, "registered on the Clearinghouse"));
        _check(cfg.enabled, string.concat(t, "enabled"));
        _check(cfg.strikeTick == m.strikeTick, string.concat(t, "strikeTick == ", vm.toString(m.strikeTick)));
        _check(
            cfg.exerciseFeeBps == in_.params.exerciseFeeBps,
            string.concat(t, "exerciseFeeBps == ", vm.toString(in_.params.exerciseFeeBps))
        );
        _check(cfg.oracle == c.settlementOracle, string.concat(t, "oracle == settlementOracle"));
        if (in_.expectFresh) _check(!cfg.mintPaused, string.concat(t, "mint not paused"));
        // INTERFACE_VERSION 7 (c05): the rent rate the registry asks for, pinned into every series created after it.
        // It is admin-tunable for NEW series, so a live deploy that differs is an info line, like every other
        // `_param` parameter; a fresh one must match.
        uint32 wantPpm = _mintFeePpmOf(in_, m);
        _check(
            cfg.mintFeePpm <= V2Constants.MINT_FEE_CEIL_PPM, string.concat(t, "mintFeePpm <= MINT_FEE_CEIL_PPM (5000)")
        );
        // Release blocker (DECISIONS-2026-09-17 §11): the rate is a tuned parameter ABOVE 0 and a floor AT 0. With
        // `premiumFeeBps` 0 at launch, a live market at 0 charges its writers nothing, so this FAILs however the
        // registry reads and whether the set is fresh or live. The `V2_ALLOW_ZERO_RENT` opt-out runs through
        // `zeroRentAllowed` and is honoured only under the forge test runner, so a read-only verify of live 4663
        // cannot sign off a zero-rent market with an environment variable.
        _check(
            cfg.mintFeePpm != 0 || zeroRentAllowed(in_.allowZeroRent),
            string.concat(
                t,
                "mintFeePpm != 0 (premiumFeeBps is 0 at launch, so a market at 0 charges its writers nothing;",
                " setMarketConfig reaches NEW series only)"
            )
        );
        _param(
            in_.expectFresh,
            cfg.mintFeePpm == wantPpm,
            string.concat(t, "mintFeePpm == ", vm.toString(uint256(wantPpm))),
            vm.toString(uint256(cfg.mintFeePpm))
        );

        ChainlinkFeedSource chainlink = ChainlinkFeedSource(c.chainlinkSource);
        (address feed, uint32 stale, uint16 jump) = chainlink.feeds(m.asset);
        _check(
            feed == m.feed && stale == chainlink.DEFAULT_MAX_STALE() && jump == chainlink.DEFAULT_MAX_ROUND_JUMP_BPS(),
            string.concat(t, "sources.chainlink feed == registry feed, 26 h, 2000 bps")
        );

        UniV3TwapSource univ3 = UniV3TwapSource(c.univ3Source);
        (address pool, bool usdgIsToken0, uint8 dec, uint32 window, uint128 floor) = univ3.pools(m.asset);
        if (m.pool != address(0)) {
            _check(
                pool == m.pool && usdgIsToken0 == (IPoolFee(m.pool).token0() == in_.ext.usdg) && dec == 18
                    && window == univ3.DEFAULT_WINDOW() && floor == m.minLiquidity,
                string.concat(
                    t, "sources.univ3 pool == registry pool, floor ", vm.toString(m.minLiquidity), " L, 300 s"
                )
            );
        } else {
            _check(pool == address(0), string.concat(t, "sources.univ3 has no pool (Chainlink only)"));
        }
        // The ring is checked on whatever pool the SOURCE actually holds (that is the one a TWAP would read), falling
        // back to the registry's when the source was never configured. A Chainlink-only market with no pool on either
        // side skips it -- there is nothing to flood.
        address ringPool = pool != address(0) ? pool : m.pool;
        if (ringPool != address(0)) _poolRing(t, ringPool);

        (address[] memory sources, uint16 dev, uint32 delay, uint32 age) =
            SettlementOracle(c.settlementOracle).marketConfig(m.asset);
        bool listOk = m.pool == address(0)
            ? sources.length == 1 && sources[0] == c.chainlinkSource
            : sources.length == 2 && sources[0] == c.chainlinkSource && sources[1] == c.univ3Source;
        _check(
            listOk,
            string.concat(
                t, m.pool == address(0) ? "oracle sources == [chainlink]" : "oracle sources == [chainlink, univ3]"
            )
        );
        _check(
            dev == m.maxDeviationBps && delay == m.uncorroboratedDelay && age == m.spotMaxAge,
            string.concat(
                t,
                "oracle deviation ",
                vm.toString(m.maxDeviationBps),
                " bps, delay ",
                vm.toString(m.uncorroboratedDelay),
                " s, spot age ",
                vm.toString(m.spotMaxAge),
                " s"
            )
        );
        _check(
            DataStreamsSource(c.dataStreamsSource).feedIdOf(m.asset) == bytes32(0),
            string.concat(t, "sources.dataStreams not configured (C2-12: owner-gated)")
        );
        (bool pinOk, uint40 probeExpiry, bytes memory pinResult) = _probePin(c, m.asset);
        _check(
            pinOk,
            string.concat(
                t,
                "the next series can pin: oracle.pin(asset, ",
                vm.toString(uint256(probeExpiry)),
                ") as the Clearinghouse succeeds (dry run)"
            )
        );
        if (!pinOk) _info(string.concat(t, "the dry-run pin reverted with ", vm.toString(pinResult)));

        UniV3PayoutAdapter adapter = UniV3PayoutAdapter(c.payoutAdapter);
        (address routePool, uint24 routeFee) = adapter.routes(m.asset);
        if (m.pool != address(0)) {
            uint24 fee = m.poolFee != 0 ? m.poolFee : IPoolFee(m.pool).fee();
            _check(
                fee <= V2Constants.MAX_ROUTE_FEE_TIER,
                string.concat(
                    t,
                    "pool fee tier ",
                    vm.toString(uint256(fee)),
                    " <= 10000 (above 1 % the Clearinghouse's floor would pay every conversion in kind)"
                )
            );
            _check(
                routePool == m.pool && routeFee == fee
                    && IUniV3PoolFactory(adapter.factory()).getPool(m.asset, in_.ext.usdg, fee) == m.pool,
                string.concat(
                    t, "payout route == (registry pool, fee ", vm.toString(uint256(fee)), "), the factory's pool"
                )
            );
        } else {
            _check(routePool == address(0) && routeFee == 0, string.concat(t, "no payout route (paid in kind)"));
        }

        (bool ok, uint256 price, uint256 updatedAt) = SettlementOracle(c.settlementOracle).trySpot(m.asset);
        _info(
            string.concat(
                t, "oracle trySpot ", ok ? "ok " : "not ok ", vm.toString(price), " updated ", vm.toString(updatedAt)
            )
        );
    }

    /// @dev The next calendar expiry a series could be created for (MIN_SERIES_LEAD ahead or more) and whether the
    ///      Clearinghouse's pin of it succeeds now; `result` is the revert data when it does not.
    function _probePin(Contracts memory c, address asset)
        internal
        returns (bool ok, uint40 expiry, bytes memory result)
    {
        // casting to 'uint40' is safe because a unix time plus an hour stays far below 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 after_ = uint40(block.timestamp + V2Constants.MIN_SERIES_LEAD - 1);
        try ExpiryCalendar(c.expiryCalendar).nextExpiry(after_, false) returns (uint40 e) {
            expiry = e;
        } catch {
            return (false, 0, bytes("expiryCalendar.nextExpiry reverted"));
        }
        try new PinDryRun().run(c.settlementOracle, c.clearinghouse, asset, expiry) {
            return (false, expiry, bytes("PinDryRun.run returned"));
        } catch (bytes memory err) {
            if (err.length < 4 || bytes4(err) != PinDryRun.PinDryRunResult.selector) return (false, expiry, err);
            bytes memory args = new bytes(err.length - 4);
            for (uint256 i; i < args.length; ++i) {
                args[i] = err[i + 4];
            }
            (ok, result) = abi.decode(args, (bool, bytes));
        }
    }

    function _unregistered(Inputs memory in_) internal {
        if (in_.unregistered.length == 0) return;
        console2.log("registry rows not registered");
        Clearinghouse ch = Clearinghouse(in_.c.clearinghouse);
        uint256 registered;
        for (uint256 i; i < in_.unregistered.length; ++i) {
            if (ch.market(in_.unregistered[i]).strikeTick != 0) {
                ++registered;
                _info(
                    string.concat(
                        vm.toString(in_.unregistered[i]), " IS registered but the registry has no registeredAt"
                    )
                );
            }
        }
        _check(
            registered == 0,
            string.concat(
                "none of the ",
                vm.toString(in_.unregistered.length),
                " registry markets without registeredAt is registered on the Clearinghouse"
            )
        );
    }

    function _fresh(Inputs memory in_) internal {
        console2.log("fresh state");
        Contracts memory c = in_.c;
        _check(!Clearinghouse(c.clearinghouse).createPaused(), "clearinghouse: series creation not paused");
        OrderBook book = OrderBook(c.orderBook);
        _check(!book.tradingPaused(), "orderBook: trading not paused");
        _check(book.lastOrderId() == 0, "orderBook: no order placed yet");
        MakerVault vault = MakerVault(c.makerVault);
        _check(vault.totalNotional() == 0 && vault.trackedSeries().length == 0, "makerVault: no exposure");
        _check(KeeperRewards(c.keeperRewards).spentToday() == 0, "keeperRewards: no bounty paid");
        _check(
            MakerRegistry(c.makerRegistry).rebateBps(in_.c.makerVault) == 0,
            "makerRegistry: no tier set (vault included)"
        );
    }
}
