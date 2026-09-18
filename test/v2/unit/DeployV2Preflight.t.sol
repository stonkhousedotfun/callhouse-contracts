// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture} from "./DeployV2Fixture.t.sol";
import {DeployV2} from "../../../script/v2/DeployV2.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {AutoRoller} from "../../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";
import {ExpiryCalendar} from "../../../src/v2/ExpiryCalendar.sol";
import {KeeperRewards} from "../../../src/v2/KeeperRewards.sol";
import {OrderBook} from "../../../src/v2/OrderBook.sol";
import {MakerVault} from "../../../src/v2/mm/MakerVault.sol";
import {ChainlinkFeedSource} from "../../../src/v2/oracle/ChainlinkFeedSource.sol";
import {DataStreamsSource} from "../../../src/v2/oracle/DataStreamsSource.sol";
import {SettlementOracle} from "../../../src/v2/oracle/SettlementOracle.sol";
import {UniV3TwapSource} from "../../../src/v2/oracle/UniV3TwapSource.sol";
import {UniV3PayoutAdapter} from "../../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice `script/v2/DeployV2.s.sol` over the mocks: the whole set deployed and wired (every role, pointer, bounty and
///         caller), a re-run that sends nothing, a resume that deploys only what is missing and sends only the missing
///         wiring without overwriting a tuned parameter, the wiring check, and each preflight refusal with its message.
/// @dev The refusals run in ONE function, in order, the way test/unit/DeploySoloPreflight.t.sol drives DeploySolo's.
contract DeployV2PreflightTest is DeployV2Fixture {
    function test_deploy_wiresTheWholeSet() public {
        (V2DeployBase.Contracts memory d, DeployV2.Outcome memory o) =
            deployScript.runWith(_deployInputs(), _signer(deployer), _signer(admin));
        assertEq(o.created, 13, "13 contracts created");
        // grants: clearinghouse guardian, roller pricer; pointers: oracle x2, the three sources' setOracle,
        // clearinghouse x2, roller, book registry; 3 bounty callers, 6 bounties (CANCEL_STALE from v7), the daily cap
        assertEq(o.sent, 21, "21 admin calls (20 through v6, + the v7 CANCEL_STALE bounty)");
        assertEq(o.skipped, 3, "guardian on book and oracle, quoter on vault: granted by their constructors");

        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        AutoRoller roller = AutoRoller(d.autoRoller);
        OrderBook book = OrderBook(d.orderBook);
        MakerVault vault = MakerVault(d.makerVault);

        address[13] memory set = [
            d.expiryCalendar,
            d.chainlinkSource,
            d.univ3Source,
            d.dataStreamsSource,
            d.settlementOracle,
            d.clearinghouse,
            d.orderBook,
            d.keeperRewards,
            d.autoRoller,
            d.payoutAdapter,
            d.makerRegistry,
            d.makerVault,
            d.rewardsDistributor
        ];
        for (uint256 i; i < set.length; ++i) {
            assertGt(set[i].code.length, 0, "code");
            assertTrue(IAccessControl(set[i]).hasRole(V2Constants.DEFAULT_ADMIN_ROLE, admin), "admin everywhere");
            assertFalse(
                IAccessControl(set[i]).hasRole(V2Constants.DEFAULT_ADMIN_ROLE, deployer), "deployer holds nothing"
            );
        }
        assertTrue(ch.hasRole(V2Constants.GUARDIAN_ROLE, guardian), "clearinghouse guardian");
        assertTrue(book.hasRole(V2Constants.GUARDIAN_ROLE, guardian), "book guardian");
        assertTrue(oracle.hasRole(V2Constants.GUARDIAN_ROLE, guardian), "oracle guardian");
        assertTrue(roller.hasRole(V2Constants.PRICER_ROLE, pricer), "pricer");
        assertTrue(vault.hasRole(V2Constants.QUOTER_ROLE, mmQuoter), "quoter");

        assertEq(ch.calendar(), d.expiryCalendar, "calendar");
        assertEq(ch.usdg(), address(usdg), "usdg");
        assertEq(ch.feeRecipient(), feeRecipient, "clearinghouse fee recipient");
        assertEq(ch.baseUri(), "https://app.stonkhouse.fun/api/token/", "base uri");
        assertEq(ch.payoutAdapter(), d.payoutAdapter, "adapter");
        assertEq(ch.maxPayoutSlippageBps(), 30, "slippage");
        assertEq(address(ch.keeperRewards()), d.keeperRewards, "clearinghouse rewards");
        assertEq(oracle.clearinghouse(), d.clearinghouse, "oracle clearinghouse");
        assertEq(oracle.keeperRewards(), d.keeperRewards, "oracle rewards");
        assertTrue(ChainlinkFeedSource(d.chainlinkSource).isOracle(d.settlementOracle), "chainlink accepts pins");
        assertTrue(UniV3TwapSource(d.univ3Source).isOracle(d.settlementOracle), "pool source accepts pins");
        assertTrue(DataStreamsSource(d.dataStreamsSource).isOracle(d.settlementOracle), "data streams accepts pins");
        assertEq(address(roller.keeperRewards()), d.keeperRewards, "roller rewards");
        assertEq(address(book.makerRegistry()), d.makerRegistry, "maker registry");
        assertEq(book.feeRecipient(), feeRecipient, "book fee recipient");
        V2Types.FeeParams memory f = book.feeParams();
        assertEq(f.premiumFeeBps, 0, "v7 c05: the premium fee is 0 at launch, the writer fee is rent at mint");
        assertEq(f.takerFeeFlat, 100_000);
        assertEq(f.makerRebateBps, 5000);
        assertTrue(
            kr.isCaller(d.settlementOracle) && kr.isCaller(d.clearinghouse) && kr.isCaller(d.autoRoller), "callers"
        );
        assertEq(kr.bounty(V2Constants.ACTION_SNAPSHOT), 50_000);
        assertEq(kr.bounty(V2Constants.ACTION_FINALIZE), 50_000);
        assertEq(kr.bounty(V2Constants.ACTION_SETTLE), 50_000);
        assertEq(kr.bounty(V2Constants.ACTION_REDEEM), 20_000);
        assertEq(kr.bounty(V2Constants.ACTION_ROLL), 50_000);
        assertEq(kr.bounty(V2Constants.ACTION_CANCEL_STALE), 20_000, "v7 c16: the sixth bounty");
        assertEq(kr.dailyCap(), 100e6);
        assertEq(address(vault.orderBook()), d.orderBook, "vault book");
        assertTrue(ch.isOperator(d.makerVault, d.orderBook), "vault operator approval");
        assertEq(UniV3PayoutAdapter(d.payoutAdapter).router(), address(router), "router");
        assertEq(UniV3PayoutAdapter(d.payoutAdapter).factory(), address(factory), "factory");
        assertEq(DataStreamsSource(d.dataStreamsSource).verifierProxy(), address(verifier), "verifier");
        assertEq(DataStreamsSource(d.dataStreamsSource).feedIdOf(address(nvda)), bytes32(0), "data streams disabled");
        assertTrue(ExpiryCalendar(d.expiryCalendar).holiday(20703) && ExpiryCalendar(d.expiryCalendar).holiday(20783));
        assertEq(ch.market(address(nvda)).strikeTick, 0, "no market registered by the deploy");

        // JSON in the registry's v2.contracts shape
        string memory json = deployScript.toJson(d);
        assertEq(vm.parseJsonAddress(json, ".clearinghouse"), d.clearinghouse);
        assertEq(vm.parseJsonAddress(json, ".sources.dataStreams"), d.dataStreamsSource);
        assertEq(vm.parseJsonAddress(json, ".rewardsDistributor"), d.rewardsDistributor);
    }

    function test_resume_deploysAndSendsOnlyWhatIsMissing() public {
        V2DeployBase.Contracts memory d = _deploy();
        DeployV2.Inputs memory in_ = _deployInputs();
        in_.existing = d;

        // a second run against the complete set: nothing created, nothing sent
        (V2DeployBase.Contracts memory again, DeployV2.Outcome memory o) =
            deployScript.runWith(in_, _signer(deployer), _signer(admin));
        assertEq(o.created, 0, "nothing created");
        assertEq(o.sent, 0, "nothing sent");
        assertEq(again.clearinghouse, d.clearinghouse, "same set");
        assertEq(deployScript.checkWiring(in_), 0, "wiring complete");

        // a lost pointer, a source that stopped accepting the oracle's pins and a tuned bounty: the resume restores
        // the pointer, the allow-list entry and the role, and keeps the tuned value
        vm.startPrank(admin);
        SettlementOracle(d.settlementOracle).setKeeperRewards(address(0));
        UniV3TwapSource(d.univ3Source).setOracle(d.settlementOracle, false);
        KeeperRewards(d.keeperRewards).setBounty(V2Constants.ACTION_SNAPSHOT, 30_000);
        AutoRoller(d.autoRoller).revokeRole(V2Constants.PRICER_ROLE, pricer);
        vm.stopPrank();
        assertEq(deployScript.checkWiring(in_), 3, "three structural calls pending");
        (, o) = deployScript.runWith(in_, _signer(deployer), _signer(admin));
        assertEq(o.sent, 3, "only the pointer, the allow-list entry and the role");
        assertEq(SettlementOracle(d.settlementOracle).keeperRewards(), d.keeperRewards, "pointer restored");
        assertTrue(UniV3TwapSource(d.univ3Source).isOracle(d.settlementOracle), "allow-list entry restored");
        assertTrue(AutoRoller(d.autoRoller).hasRole(V2Constants.PRICER_ROLE, pricer), "role restored");
        assertEq(KeeperRewards(d.keeperRewards).bounty(V2Constants.ACTION_SNAPSHOT), 30_000, "tuned bounty kept");
        assertEq(deployScript.checkWiring(in_), 0, "complete again");

        // a run that died after five creates: the rest is created and linked to them
        DeployV2.Inputs memory half = _deployInputs();
        half.existing.expiryCalendar = d.expiryCalendar;
        half.existing.chainlinkSource = d.chainlinkSource;
        half.existing.univ3Source = d.univ3Source;
        half.existing.dataStreamsSource = d.dataStreamsSource;
        half.existing.settlementOracle = d.settlementOracle;
        V2DeployBase.Contracts memory d2;
        (d2, o) = deployScript.runWith(half, _signer(deployer), _signer(admin));
        assertEq(o.created, 8, "eight created");
        assertEq(d2.expiryCalendar, d.expiryCalendar, "calendar reused");
        assertEq(d2.settlementOracle, d.settlementOracle, "oracle reused");
        assertTrue(d2.clearinghouse != d.clearinghouse, "a new clearinghouse");
        assertEq(
            Clearinghouse(d2.clearinghouse).calendar(), d.expiryCalendar, "new clearinghouse on the reused calendar"
        );
        assertEq(SettlementOracle(d2.settlementOracle).clearinghouse(), d2.clearinghouse, "reused oracle repointed");
    }

    function test_preflight_everyRefusalInOrder() public {
        DeployV2.Inputs memory in_;

        // ---------------------------------------------------------------- roles
        in_ = _deployInputs();
        in_.roles.admin = address(0);
        _refused(in_, "V2_ADMIN is zero");

        in_ = _deployInputs();
        in_.roles.feeRecipient = address(0);
        _refused(in_, "V2_FEE_RECIPIENT is zero");

        in_ = _deployInputs();
        in_.roles.guardian = admin;
        _refused(in_, "V2_ADMIN and V2_GUARDIAN must be different addresses");

        in_ = _deployInputs();
        in_.roles.pricer = cranker;
        _refused(
            in_,
            "admin, guardian, cranker, pricer and mmQuoter must be five different addresses (a bot key never holds admin or guardian powers)"
        );

        in_ = _deployInputs();
        in_.roles.mmQuoter = admin;
        _refused(
            in_,
            "admin, guardian, cranker, pricer and mmQuoter must be five different addresses (a bot key never holds admin or guardian powers)"
        );

        // ---------------------------------------------------------------- USDG
        address nothing = makeAddr("nothing");
        in_ = _deployInputs();
        in_.ext.usdg = nothing;
        _refused(in_, string.concat("V2_USDG ", vm.toString(nothing), " has no code"));

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        in_ = _deployInputs();
        in_.ext.usdg = address(usdc);
        _refused(
            in_,
            string.concat(
                "usdg symbol mismatch: V2_USDG ", vm.toString(address(usdc)), " is \"USDC\", expected \"USDG\""
            )
        );

        MockERC20 usdg18 = new MockERC20("Global Dollar", "USDG", 18);
        in_ = _deployInputs();
        in_.ext.usdg = address(usdg18);
        _refused(in_, "usdg decimals != 6");

        // ---------------------------------------------------------------- Uniswap periphery, Data Streams
        MockPayoutV3Factory otherFactory = new MockPayoutV3Factory();
        MockPayoutSwapRouter otherRouter = new MockPayoutSwapRouter(address(otherFactory));
        in_ = _deployInputs();
        in_.ext.swapRouter02 = address(otherRouter);
        _refused(
            in_,
            string.concat(
                "swapRouter02.factory() ",
                vm.toString(address(otherFactory)),
                " is not V2_UNIV3_FACTORY ",
                vm.toString(address(factory))
            )
        );

        in_ = _deployInputs();
        in_.ext.dataStreamsVerifier = nothing;
        _refused(in_, string.concat("V2_DATA_STREAMS_VERIFIER ", vm.toString(nothing), " has no code"));

        // ---------------------------------------------------------------- holidays
        in_ = _deployInputs();
        in_.holidays = new uint32[](0);
        _refused(in_, "V2_HOLIDAYS is empty");

        in_ = _deployInputs();
        in_.holidays[1] = in_.holidays[0];
        _refused(in_, "V2_HOLIDAYS must be strictly increasing day indexes");

        // ---------------------------------------------------------------- fees and ceilings
        in_ = _deployInputs();
        in_.params.fees.premiumFeeBps = 1001;
        _refused(in_, "premiumFeeBps above PREMIUM_FEE_CEIL_BPS (1000)");

        // INTERFACE_VERSION 7 (c05): a premium fee above the resale fee is the dodge the rent replaces -- write into
        // a one-tick bid of a second address of your own and resell the long to pay the smaller of the two. Both are
        // under PREMIUM_FEE_CEIL_BPS here, so only the new require can fire.
        in_ = _deployInputs();
        in_.params.fees.premiumFeeBps = 500;
        in_.params.fees.resaleFeeBps = 400;
        _refused(in_, "premiumFeeBps above resaleFeeBps (v7: the c05 resale dodge)");

        in_ = _deployInputs();
        in_.params.fees.takerFeeFlat = 1_000_001;
        _refused(in_, "takerFeeFlat above TAKER_FEE_FLAT_CEIL (1000000)");

        in_ = _deployInputs();
        in_.params.fees.makerRebateBps = 10_001;
        _refused(in_, "makerRebateBps above 10000");

        in_ = _deployInputs();
        in_.params.payoutSlippageBps = 301;
        _refused(in_, "V2_PAYOUT_SLIPPAGE_BPS above MAX_PAYOUT_SLIPPAGE_CEIL_BPS (300)");

        in_ = _deployInputs();
        in_.params.bountySettle = 1_000_001;
        _refused(in_, "V2_BOUNTY_SETTLE above MAX_BOUNTY (1000000)");

        // INTERFACE_VERSION 7 (c16): the sixth bounty is under the same ceiling as the other five.
        in_ = _deployInputs();
        in_.params.bountyCancelStale = 1_000_001;
        _refused(in_, "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY (1000000)");

        in_ = _deployInputs();
        in_.params.vaultLimits.maxSeriesUnits = 0;
        _refused(in_, "V2_VAULT_MAX_SERIES_UNITS must be > 0");

        in_ = _deployInputs();
        in_.params.vaultLimits.maxBidBpsOfSpot = 10_001;
        _refused(in_, "V2_VAULT_MAX_BID_BPS_OF_SPOT above 10000");

        // INTERFACE_VERSION 7 (c21): 0 is the incident spend freeze (`setLimits`), never a deploy value -- a vault
        // deployed with it could cancel, close, move its ledger and place asks but never bid, take or replace up.
        in_ = _deployInputs();
        in_.params.vaultLimits.maxDailyOutflow = 0;
        _refused(in_, "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0 (0 deploys the vault frozen: no bid, take or replace-up)");

        in_ = _deployInputs();
        in_.params.baseUri = "https://app.stonkhouse.fun/api/token";
        _refused(in_, "V2_BASE_URI must be non-empty and end with \"/\"");

        // ---------------------------------------------------------------- resume addresses
        in_ = _deployInputs();
        in_.existing.clearinghouse = nothing;
        _refused(in_, string.concat("V2_CLEARINGHOUSE ", vm.toString(nothing), " has no code (resume)"));

        // ---------------------------------------------------------------- a resumed set that does not link
        V2DeployBase.Contracts memory d = _deploy();
        in_ = _deployInputs();
        in_.existing = d;
        MockERC20 otherUsdg = new MockERC20("Global Dollar", "USDG", 6);
        in_.ext.usdg = address(otherUsdg);
        vm.expectRevert(bytes("clearinghouse.usdg() is not V2_USDG"));
        deployScript.runWith(in_, _signer(deployer), _signer(admin));

        // ---------------------------------------------------------------- the wiring check needs the whole set
        in_ = _deployInputs();
        in_.existing = d;
        in_.existing.makerVault = address(0);
        vm.expectRevert(bytes("V2_MAKER_VAULT is zero"));
        deployScript.checkWiring(in_);

        // nothing above created a second set: the accepted inputs still deploy
        (, DeployV2.Outcome memory o) = deployScript.runWith(_deployInputs(), _signer(deployer), _signer(admin));
        assertEq(o.created, 13, "the unmodified inputs deploy");
    }

    /// @dev Expect `runWith` to revert with exactly `reason` (the preflight runs before any create or call).
    function _refused(DeployV2.Inputs memory in_, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        deployScript.runWith(in_, _signer(deployer), _signer(admin));
    }
}
