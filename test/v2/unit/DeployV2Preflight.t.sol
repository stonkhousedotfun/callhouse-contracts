// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    DeployV2Fixture,
    MockNotASafe,
    MockSafe,
    MockExternalTarget,
    MockSafeForwarder,
    MockTweakableSafe
} from "./DeployV2Fixture.t.sol";
import {DeployV8} from "../../../script/v2/DeployV8.s.sol";
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
import {FeeSplitter} from "../../../src/v2/periphery/FeeSplitter.sol";
import {PayoutRouter} from "../../../src/v2/periphery/PayoutRouter.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockPayoutV3Factory} from "../../../src/v2/mocks/MockPayoutV3Factory.sol";
import {MockPayoutSwapRouter} from "../../../src/v2/mocks/MockPayoutSwapRouter.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";

/// @notice `script/v2/DeployV8.s.sol` over the mocks: the whole sixteen-contract set deployed, every selector of
///         `script/v2/roles.v8.json` mapped, every role granted to the Safe or bot key the manifest names, every
///         pointer and parameter wired, and the deployer holding NOTHING when the run ends. Then a re-run that sends
///         nothing, a resume that deploys only what is missing, the hand-over check, and each preflight refusal with
///         its message.
/// @dev The refusals run in ONE function, in order, the way test/unit/DeploySoloPreflight.t.sol drives DeploySolo's.
contract DeployV2PreflightTest is DeployV2Fixture {
    function test_deploy_handsOverTheWholeSet() public {
        (V2DeployBase.Contracts memory d, DeployV8.Outcome memory o) =
            deployScript.runWith(_deployInputs(), _signer(deployer));
        assertEq(o.created, 16, "16 contracts created");
        assertEq(o.skipped, 0, "a fresh set holds none of the wiring yet");

        address[16] memory set = [
            d.accessManager,
            d.feeSplitter,
            d.expiryCalendar,
            d.chainlinkSource,
            d.univ3Source,
            d.dataStreamsSource,
            d.settlementOracle,
            d.keeperRewards,
            d.clearinghouse,
            d.orderBook,
            d.autoRoller,
            d.payoutRouter,
            d.makerRegistry,
            d.makerVault,
            d.rewardsDistributor,
            d.buybackExecutor
        ];
        for (uint256 i; i < set.length; ++i) {
            assertGt(set[i].code.length, 0, "code");
        }
        _assertRolesHandedOver(d);
        _assertSelectorsMapped(d);
        _assertWiring(d);
    }

    /*//////////////////////////////////////////////////////////////
                              THE HAND-OVER
    //////////////////////////////////////////////////////////////*/

    /// @dev The whole point of C8-10: the manager holds the roles, the Safes and the bot keys hold the memberships
    ///      the manifest names at the delays the manifest names, and the deployer is left with nothing at all.
    function _assertRolesHandedOver(V2DeployBase.Contracts memory d) internal view {
        AccessManager mgr = AccessManager(d.accessManager);

        // ADMIN and the five delayed lanes, plus OPS_ADMIN and GUARDIAN and QUOTER: roles.v8.json .holders.adminSafe
        _assertRole(mgr, V8Roles.ADMIN, adminSafe, V8Roles.ADMIN_DELAY, "adminSafe ADMIN");
        _assertRole(mgr, V8Roles.FEE_MANAGER, adminSafe, V8Roles.FEE_MANAGER_DELAY, "adminSafe FEE_MANAGER");
        _assertRole(
            mgr, V8Roles.MARKET_FEE_MANAGER, adminSafe, V8Roles.MARKET_FEE_MANAGER_DELAY, "adminSafe MARKET_FEE_MANAGER"
        );
        _assertRole(mgr, V8Roles.CONFIG_ADMIN, adminSafe, V8Roles.CONFIG_ADMIN_DELAY, "adminSafe CONFIG_ADMIN");
        _assertRole(mgr, V8Roles.TREASURY_ADMIN, adminSafe, V8Roles.TREASURY_ADMIN_DELAY, "adminSafe TREASURY_ADMIN");
        _assertRole(mgr, V8Roles.LISTING, adminSafe, V8Roles.LISTING_DELAY, "adminSafe LISTING");
        _assertRole(mgr, V8Roles.OPS_ADMIN, adminSafe, 0, "adminSafe OPS_ADMIN");
        _assertRole(mgr, V8Roles.GUARDIAN, adminSafe, 0, "adminSafe GUARDIAN");
        _assertRole(mgr, V8Roles.QUOTER, adminSafe, 0, "adminSafe QUOTER");

        _assertRole(mgr, V8Roles.GUARDIAN, guardianKey, 0, "guardianKey GUARDIAN");
        _assertRole(mgr, V8Roles.PRICER, pricerKey, 0, "pricerKey PRICER");
        _assertRole(mgr, V8Roles.QUOTER, quoterKey, 0, "quoterKey QUOTER");
        // v7 gave the cranker no role at all (ADR-06). v8 gives it BUYBACK and nothing else.
        _assertRole(mgr, V8Roles.BUYBACK, crankerKey, 0, "crankerKey BUYBACK");

        // The role tree. Parenting the four hot-key roles to OPS_ADMIN is what lets two Safe signatures rotate a
        // compromised key with no delay, and it is also what makes the ORDER of the hand-over load-bearing: after
        // this point a deployer holding only ADMIN can no longer grant or revoke any of the four.
        assertEq(mgr.getRoleAdmin(V8Roles.GUARDIAN), V8Roles.OPS_ADMIN, "GUARDIAN under OPS_ADMIN");
        assertEq(mgr.getRoleAdmin(V8Roles.PRICER), V8Roles.OPS_ADMIN, "PRICER under OPS_ADMIN");
        assertEq(mgr.getRoleAdmin(V8Roles.QUOTER), V8Roles.OPS_ADMIN, "QUOTER under OPS_ADMIN");
        assertEq(mgr.getRoleAdmin(V8Roles.BUYBACK), V8Roles.OPS_ADMIN, "BUYBACK under OPS_ADMIN");
        assertEq(mgr.getRoleGuardian(V8Roles.FEE_MANAGER), V8Roles.GUARDIAN, "FEE_MANAGER guarded");
        assertEq(mgr.getRoleGuardian(V8Roles.MARKET_FEE_MANAGER), V8Roles.GUARDIAN, "MARKET_FEE_MANAGER guarded");
        assertEq(mgr.getRoleGuardian(V8Roles.CONFIG_ADMIN), V8Roles.GUARDIAN, "CONFIG_ADMIN guarded");
        assertEq(mgr.getRoleGuardian(V8Roles.TREASURY_ADMIN), V8Roles.GUARDIAN, "TREASURY_ADMIN guarded");
        assertEq(mgr.getRoleGuardian(V8Roles.LISTING), V8Roles.GUARDIAN, "LISTING guarded");

        // THE DEPLOYER HOLDS NOTHING. It held ADMIN and nine working roles a moment ago; all eleven are gone.
        for (uint64 role; role < V8Roles.COUNT; ++role) {
            (bool member,) = mgr.hasRole(role, deployer);
            assertFalse(member, "the deployer holds no role at all");
        }
        // And the bot keys hold nothing beyond their one role: a cranker that could pause the book, or a pricer that
        // could move the treasury, is the failure this whole rollout exists to prevent.
        (bool crankerIsGuardian,) = mgr.hasRole(V8Roles.GUARDIAN, crankerKey);
        assertFalse(crankerIsGuardian, "the cranker is not a guardian");
        (bool pricerIsTreasury,) = mgr.hasRole(V8Roles.TREASURY_ADMIN, pricerKey);
        assertFalse(pricerIsTreasury, "the pricer is not a treasury admin");
    }

    function _assertRole(AccessManager mgr, uint64 role, address who, uint32 delay, string memory what) internal view {
        (bool member, uint32 have) = mgr.hasRole(role, who);
        assertTrue(member, what);
        assertEq(have, delay, string.concat(what, ": execution delay"));
    }

    /// @dev A spot check of the selector map, one signature per role lane, each with the role `roles.v8.json` gives
    ///      it. The exhaustive comparison is `test/v2/unit/AccessMatrix.t.sol`'s job; what matters here is that the
    ///      deploy loop actually ran over the manifest rather than over a hand-typed list.
    function _assertSelectorsMapped(V2DeployBase.Contracts memory d) internal view {
        AccessManager mgr = AccessManager(d.accessManager);
        assertEq(
            mgr.getTargetFunctionRole(d.clearinghouse, bytes4(keccak256("registerMarket(address,uint64,bool)"))),
            V8Roles.LISTING,
            "Clearinghouse.registerMarket -> LISTING"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.clearinghouse, bytes4(keccak256("setMarketFees(address,uint16,uint32)"))),
            V8Roles.MARKET_FEE_MANAGER,
            "Clearinghouse.setMarketFees -> MARKET_FEE_MANAGER"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.clearinghouse, bytes4(keccak256("setMinter(address,bool)"))),
            V8Roles.CONFIG_ADMIN,
            "Clearinghouse.setMinter -> CONFIG_ADMIN"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.orderBook, bytes4(keccak256("setTradingPaused(bool)"))),
            V8Roles.GUARDIAN,
            "OrderBook.setTradingPaused -> GUARDIAN"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.autoRoller, bytes4(keccak256("reprice(address,address,uint128)"))),
            V8Roles.PRICER,
            "AutoRoller.reprice -> PRICER"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.makerVault, bytes4(keccak256("cancel(uint256[])"))),
            V8Roles.QUOTER,
            "MakerVault.cancel -> QUOTER"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.feeSplitter, bytes4(keccak256("buyback(uint256)"))),
            V8Roles.BUYBACK,
            "FeeSplitter.buyback -> BUYBACK"
        );
        assertEq(
            mgr.getTargetFunctionRole(d.makerRegistry, bytes4(keccak256("setTier(address,uint16)"))),
            V8Roles.FEE_MANAGER,
            "MakerRegistry.setTier -> FEE_MANAGER"
        );
        // roles.v8.json `notes.adminHasNoTarget`: an UNMAPPED restricted selector falls to ADMIN by default, which
        // is exactly the mistake the map must not make. `mint` is deliberately unrestricted, so it maps to 0 and
        // that is correct; `sweepFees` likewise.
        assertEq(
            mgr.getTargetFunctionRole(d.clearinghouse, bytes4(keccak256("mint(uint256,uint64,address,address)"))),
            V8Roles.ADMIN,
            "Clearinghouse.mint is unmapped (unrestricted in the contract, not gated here)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                THE WIRING
    //////////////////////////////////////////////////////////////*/

    function _assertWiring(V2DeployBase.Contracts memory d) internal view {
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        AutoRoller roller = AutoRoller(d.autoRoller);
        OrderBook book = OrderBook(d.orderBook);

        // T-525 checked the C8-03 suspicion here and it no longer applies. The doubt was that this line used to be
        // `assertTrue(book.authority().code.length > 0)`, which `Managed`'s constructor guarantees, so a deploy
        // wired to the WRONG BUT REAL manager passed it - and its author could not strengthen it, because the suite
        // failed in setUp with "deploy failed: out/ExpiryCalendar.sol/ExpiryCalendar.json". BOTH halves are settled:
        // the identity checks below replaced the code-length idiom, and the suite RUNS at
        // 35dbf2658ce5f47e15fd935b24d2af31bd5dd29f - 23 passed, 0 failed. Control: pointing this assertion at a
        // wrong-but-real contract (`d.orderBook`) fails it cleanly, naming both addresses, where the old check would
        // have passed. See also test_preflight_refusesASuppliedTargetThatIsADifferentContract below, which goes
        // further still - a stand-in that satisfies code.length AND authority() and is caught only by its interface.
        assertEq(ch.authority(), d.accessManager, "every target points at the one manager");
        assertEq(oracle.authority(), d.accessManager, "oracle authority");
        assertEq(MakerVault(d.makerVault).authority(), d.accessManager, "vault authority");
        assertEq(ch.calendar(), d.expiryCalendar, "calendar");
        assertEq(ch.usdg(), address(usdg), "usdg");
        assertEq(ch.feeRecipient(), d.feeSplitter, "the Clearinghouse pays the FeeSplitter, not an EOA");
        assertEq(book.feeRecipient(), d.feeSplitter, "and so does the book");
        assertEq(ch.baseUri(), "https://app.stonkhouse.fun/api/token/", "base uri");
        assertEq(ch.payoutAdapter(), d.payoutRouter, "the payout route is the v8 PayoutRouter");
        assertEq(ch.maxPayoutSlippageBps(), 30, "slippage");
        assertEq(address(ch.keeperRewards()), d.keeperRewards, "clearinghouse rewards");
        // Without this the book's two mint calls fail inside try/gas and a promised fill becomes a silent skip.
        assertTrue(ch.isMinter(d.orderBook), "the OrderBook is a minter");
        // INTERFACE_VERSION 8 composes a registration from these two, so a market cannot be registered without them.
        assertEq(ch.defaultOracle(), d.settlementOracle, "default oracle");
        (uint16 defFee, uint32 defPpm) = ch.defaultMarketFees();
        assertEq(defFee, 25, "default exercise fee from the registry");
        assertEq(defPpm, 0, "default collateral rent is 0 at launch (V8-DESIGN 4.3)");

        assertEq(oracle.clearinghouse(), d.clearinghouse, "oracle clearinghouse");
        assertEq(oracle.keeperRewards(), d.keeperRewards, "oracle rewards");
        assertTrue(ChainlinkFeedSource(d.chainlinkSource).isOracle(d.settlementOracle), "chainlink accepts pins");
        assertTrue(UniV3TwapSource(d.univ3Source).isOracle(d.settlementOracle), "pool source accepts pins");
        assertTrue(DataStreamsSource(d.dataStreamsSource).isOracle(d.settlementOracle), "data streams accepts pins");
        assertEq(address(roller.keeperRewards()), d.keeperRewards, "roller rewards");
        assertEq(address(book.makerRegistry()), d.makerRegistry, "maker registry, sent through manager.execute");

        V2Types.FeeParams memory f = book.feeParams();
        assertEq(f.premiumFeeBps, 500, "v8: 5% of the premium on first sale");
        assertEq(f.resaleFeeBps, 0, "and nothing on a true resale");
        assertEq(f.takerFeeFlat, 100_000);
        assertEq(f.makerRebateBps, 5000);

        assertTrue(
            kr.isCaller(d.settlementOracle) && kr.isCaller(d.clearinghouse) && kr.isCaller(d.autoRoller), "callers"
        );
        assertEq(kr.treasury(), treasurySafe, "keeper budget can only leave to the Treasury Safe");
        assertEq(kr.bounty(V2Constants.ACTION_SNAPSHOT), 50_000);
        assertEq(kr.bounty(V2Constants.ACTION_CANCEL_STALE), 20_000, "v7 c16: the sixth bounty");
        assertEq(kr.dailyCap(), 100e6);

        assertEq(MakerVault(d.makerVault).treasury(), treasurySafe, "vault treasury");
        assertEq(address(MakerVault(d.makerVault).orderBook()), d.orderBook, "vault book");
        assertTrue(ch.isOperator(d.makerVault, d.orderBook), "vault operator approval");
        assertEq(PayoutRouter(payable(d.payoutRouter)).usdg(), address(usdg), "router usdg");
        assertEq(DataStreamsSource(d.dataStreamsSource).verifierProxy(), address(verifier), "verifier");
        assertEq(DataStreamsSource(d.dataStreamsSource).feedIdOf(address(nvda)), bytes32(0), "data streams disabled");
        assertTrue(ExpiryCalendar(d.expiryCalendar).holiday(20703) && ExpiryCalendar(d.expiryCalendar).holiday(20783));
        assertEq(ch.market(address(nvda)).strikeTick, 0, "no market registered by the deploy");

        _assertFlywheel(d);
    }

    /// @dev The flywheel is wired as one loop: the book pays the splitter, the splitter sells through the router,
    ///      buys through the executor, prices against the oracle and burns the token the executor buys.
    function _assertFlywheel(V2DeployBase.Contracts memory d) internal view {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        assertEq(s.authority(), d.accessManager, "splitter authority");
        assertEq(s.treasury(), treasurySafe, "splitter treasury");
        assertEq(s.burnBps(), 5000, "50/50 burn and treasury");
        assertEq(s.orderBook(), d.orderBook, "splitter claims from the book");
        assertEq(s.router(), d.payoutRouter, "splitter sells Stock Tokens through the router");
        assertEq(s.executor(), d.buybackExecutor, "splitter buys through the executor");
        assertEq(s.oracle(), d.settlementOracle, "splitter prices against the settlement oracle");
        assertEq(s.stonkhouse(), address(stonk), "the token the splitter burns");
        assertEq(s.conversionSlippageBps(), 30, "conversion floor");
        assertEq(s.buybackCap(), 50_000_000, "50 USDG per call, the constructor's launch value");
    }

    /*//////////////////////////////////////////////////////////////
                              RESUME AND CHECK
    //////////////////////////////////////////////////////////////*/

    function test_resume_deploysOnlyWhatIsMissing() public {
        V2DeployBase.Contracts memory d = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = d;

        // A second run against the complete set: nothing created, nothing sent. The deployer holds nothing by then,
        // so a run that DID want to send something could not -- which is why "nothing to send" is the only safe
        // answer a resume can give, and why the hand-over check exists as a read-only mode.
        (V2DeployBase.Contracts memory again, DeployV8.Outcome memory o) = deployScript.runWith(in_, _signer(deployer));
        assertEq(o.created, 0, "nothing created");
        assertEq(o.sent, 0, "nothing sent");
        assertEq(again.clearinghouse, d.clearinghouse, "same set");
        assertEq(deployScript.checkWiring(in_), 0, "hand-over complete");

        // A run that died after the manager and the first six: the rest is created and linked to them.
        DeployV8.Inputs memory half = _deployInputs();
        half.existing.accessManager = d.accessManager;
        half.existing.feeSplitter = d.feeSplitter;
        half.existing.expiryCalendar = d.expiryCalendar;
        half.existing.chainlinkSource = d.chainlinkSource;
        half.existing.univ3Source = d.univ3Source;
        half.existing.dataStreamsSource = d.dataStreamsSource;
        half.existing.settlementOracle = d.settlementOracle;
        half.roles.feeRecipient = d.feeSplitter;
        // The manager of the first run has already had its ADMIN renounced, so a resume onto it can send nothing:
        // the very first `setTargetFunctionRole` of the new Clearinghouse reverts inside `_execute`. That is the
        // honest shape of a half-finished v8 deploy, and it is why the deployer must not renounce until the whole
        // set is up: the recovery from here is a NEW manager, not a second run. The message names whichever
        // selector the manifest happens to list first, so only the revert itself is asserted.
        vm.expectRevert();
        deployScript.runWith(half, _signer(deployer));
    }

    /*//////////////////////////////////////////////////////////////
       T-182 / F-SCRIPTS-09: THE PLANNER COMPARES BEFORE IT SKIPS
    //////////////////////////////////////////////////////////////*/

    /// @notice A resume whose chain bounty differs from the environment's is REFUSED, naming both values.
    /// @dev THE DEFECT. `_bounty` read `kr.bounty(action)`, saw a non-zero value, printed "already <current>" and
    ///      returned -- without ever comparing it to the `amount` this run was given. `_postCheck` cannot catch
    ///      that either: it asks THAT SAME PLANNER whether anything is left to send, so it is structurally blind
    ///      to whatever the planner has just chosen to skip. The run reported success with the chain and the
    ///      operator's environment holding different bounties. No fresh-deploy impact; reachable on any resume,
    ///      which is exactly the launch-window operation.
    ///
    ///      THE SHAPE IS THE FEE-RECIPIENT REFUSAL'S, deliberately: an UNSET side is allowed (`amount == 0` means
    ///      the environment named no bounty, `current == 0` means the chain holds none yet) and two SET sides
    ///      that disagree are refused rather than silently preferring either.
    ///
    ///      THE DRIFT IS REAL, NOT FORGED. The chain keeps what the first run actually wrote; the second run is
    ///      handed a different number in its inputs, which is precisely an operator resuming with an edited
    ///      environment. The positive control is the second half: restore the value and the same resume is silent.
    function test_resume_refusesABountyThatDiffersFromTheEnvironment() public {
        V2DeployBase.Contracts memory d = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = d;
        in_.roles.feeRecipient = d.feeSplitter;

        uint256 onChain = KeeperRewards(d.keeperRewards).bounty(V2Constants.ACTION_SNAPSHOT);
        assertGt(onChain, 0, "the fixture's first run set a snapshot bounty");

        in_.params.bountySnapshot = onChain + 1;
        vm.expectRevert(
            bytes(
                string.concat(
                    "keeperRewards bounty SNAPSHOT on chain is ",
                    vm.toString(onChain),
                    " but this run was given ",
                    vm.toString(onChain + 1),
                    ": resume would report success with the chain and the environment disagreeing"
                )
            )
        );
        deployScript.runWith(in_, _signer(deployer));

        // POSITIVE CONTROL: agreement is still silent. Without this the refusal could be coming from anywhere.
        in_.params.bountySnapshot = onChain;
        (, DeployV8.Outcome memory o) = deployScript.runWith(in_, _signer(deployer));
        assertEq(o.sent, 0, "nothing to send once the chain and the environment agree");
    }

    /// @notice The daily cap half of the same defect, which had its own `else` arm printing "already <cap>".
    function test_resume_refusesADailyCapThatDiffersFromTheEnvironment() public {
        V2DeployBase.Contracts memory d = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = d;
        in_.roles.feeRecipient = d.feeSplitter;

        uint256 onChain = KeeperRewards(d.keeperRewards).dailyCap();
        assertGt(onChain, 0, "the fixture's first run set a daily cap");

        in_.params.dailyCap = onChain + 1;
        vm.expectRevert(
            bytes(
                string.concat(
                    "keeperRewards.dailyCap() on chain is ",
                    vm.toString(onChain),
                    " but V2_KEEPER_DAILY_CAP is ",
                    vm.toString(onChain + 1),
                    ": resume would report success with the chain and the environment disagreeing"
                )
            )
        );
        deployScript.runWith(in_, _signer(deployer));

        in_.params.dailyCap = onChain;
        (, DeployV8.Outcome memory o) = deployScript.runWith(in_, _signer(deployer));
        assertEq(o.sent, 0, "nothing to send once the chain and the environment agree");
    }

    function test_checkWiring_needsTheWholeSet() public {
        V2DeployBase.Contracts memory d = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = d;
        in_.roles.feeRecipient = d.feeSplitter;
        in_.existing.makerVault = address(0);
        vm.expectRevert(bytes("V2_MAKER_VAULT is zero"));
        deployScript.checkWiring(in_);
    }

    /*//////////////////////////////////////////////////////////////
                       THE RENOUNCE IS GUARDED
    //////////////////////////////////////////////////////////////*/

    /// @notice The script refuses to renounce ADMIN unless the Admin Safe already holds it, at the manifest delay,
    ///         AND has code.
    /// @dev THE MOST IMPORTANT ASSERTION IN THIS SUITE. `AccessManager._revokeRole`
    ///      (lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol:311-324) checks PUBLIC_ROLE,
    ///      checks the member exists, deletes it and returns -- there is NO last-admin guard anywhere in
    ///      OpenZeppelin's manager. Renouncing the last ADMIN therefore leaves all sixteen contracts with an
    ///      authority nobody can ever instruct again, and `setAuthority` on a target is callable only by that same
    ///      authority, so there is no recovery at all. Here the Admin Safe is a plain key, which is the shape an
    ///      operator would most plausibly produce by exporting the wrong `V2_ADMIN_SAFE`.
    function test_renounce_refusedWhenTheAdminSafeIsAPlainKey() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        address eoa = makeAddr("anEoaThatIsNotASafe");
        in_.roles.adminSafe = eoa;
        // T-426. The sentence MOVED and the move is the point: the no-code case is now caught by
        // `_assertAdminSafeIsARealSafe`, which runs FIRST, so the operator is told the one thing that is wrong
        // instead of a compound sentence about ADMIN, the delay and code together. {_renounceRefusal} still exists
        // and still guards the hasRole/delay half, which no longer has a reachable no-code case.
        vm.expectRevert(bytes(_safeRefusal(eoa, "has no code (it is a plain key)")));
        deployScript.runWith(in_, _signer(deployer));
    }

    /*//////////////////////////////////////////////////////////////
              T-426 F-05-01: THE ADMIN SAFE IS A REAL SAFE
    //////////////////////////////////////////////////////////////*/

    /// @notice A contract with code that is not a Safe cannot receive ADMIN, however plausibly it answers.
    /// @dev THIS IS THE TEST THAT FAILS IF THE PROBE IS WEAKENED TO `isSafe()`, which is forbidden fix (a):
    ///      `MockNotASafe` answers `isSafe() == true` and nothing else, so a single-selector probe passes it and
    ///      this case goes green on a broken script. The property being asserted is Safe IDENTITY -- the singleton
    ///      slot -- and not the presence of code, which the previous check already had.
    function test_renounce_refusedWhenTheAdminSafeIsACodefulNonSafe() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        address notASafe = address(new MockNotASafe());
        in_.roles.adminSafe = notASafe;
        vm.expectRevert(bytes(_singletonRefusal(notASafe, address(0))));
        deployScript.runWith(in_, _signer(deployer));
    }

    /// @notice A public forwarder answers all three Safe reads correctly and is still refused.
    /// @dev The forwarder relays `getThreshold`, `getOwners` and `getModulesPaginated` to the fixture's real Safe
    ///      double, so a probe built only from those three reads passes it -- and anyone can then make it execute a
    ///      call, which is the opposite of a 2-of-3. What it cannot forward is its own slot 0, because `vm.load`
    ///      reads the forwarder's storage and not the contract it delegates its reads to.
    function test_renounce_refusedWhenTheAdminSafeIsAPublicForwarder() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        address forwarder = address(new MockSafeForwarder(adminSafe));
        in_.roles.adminSafe = forwarder;
        assertEq(MockSafeForwarder(forwarder).getThreshold(), 2, "the forwarder answers the Safe reads");
        assertEq(MockSafeForwarder(forwarder).getOwners().length, 3, "the forwarder answers the Safe reads");
        vm.expectRevert(bytes(_singletonRefusal(forwarder, address(0))));
        deployScript.runWith(in_, _signer(deployer));
    }

    /// @notice A canonical Safe that needs only one signature is refused: v8's ADMIN is 2-of-3.
    /// @dev A 1-of-3 Safe has code, a canonical singleton and three owners. Every check except the threshold passes,
    ///      so if `SAFE_MIN_THRESHOLD` were deleted this case is the only thing that goes red.
    function test_renounce_refusedWhenTheAdminSafeIsOneOfThree() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        MockTweakableSafe weak = new MockTweakableSafe();
        weak.setThreshold(1);
        in_.roles.adminSafe = address(weak);
        vm.expectRevert(bytes(_topologyRefusal(address(weak), 1, 3)));
        deployScript.runWith(in_, _signer(deployer));
    }

    /// @notice A threshold above the owner count is refused: that Safe is bricked, not merely weak.
    /// @dev Renouncing to a Safe whose threshold can never be met has the same outcome as renouncing to nobody,
    ///      which is the whole reason this precondition exists.
    function test_renounce_refusedWhenTheAdminSafeThresholdExceedsItsOwners() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        MockTweakableSafe bricked = new MockTweakableSafe();
        bricked.setThreshold(4);
        in_.roles.adminSafe = address(bricked);
        vm.expectRevert(bytes(_topologyRefusal(address(bricked), 4, 3)));
        deployScript.runWith(in_, _signer(deployer));
    }

    /// @notice An enabled module makes the 2-of-3 advisory, so it is refused.
    /// @dev A Safe module executes transactions with NO owner signatures. Threshold and owner count are untouched
    ///      here and still read 2-of-3, which is exactly why a topology probe that stops at them is not enough.
    function test_renounce_refusedWhenTheAdminSafeHasAnEnabledModule() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        MockTweakableSafe withModule = new MockTweakableSafe();
        withModule.enableModule(makeAddr("aModuleThatNeedsNoSignatures"));
        in_.roles.adminSafe = address(withModule);
        vm.expectRevert(bytes(_moduleRefusal(address(withModule), 1)));
        deployScript.runWith(in_, _signer(deployer));
    }

    /// @notice The happy path still reaches the renounce, and it does so because the double models a real Safe.
    /// @dev THE POINT OF THIS CASE IS THAT THE PROBE IS NOT VACUOUS. Every case above asserts a refusal; without
    ///      this one a probe that refused EVERYTHING would pass the whole group. `DeployV2Fixture`'s `MockSafe` is
    ///      a canonical singleton, 2-of-3, no module, no guard, no fallback handler -- so the deployer renouncing
    ///      here is a statement about Safe topology and not about having code.
    function test_renounce_allowedWhenTheAdminSafeIsACanonicalTwoOfThree() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        (V2DeployBase.Contracts memory d,) = deployScript.runWith(in_, _signer(deployer));
        AccessManager mgr = AccessManager(d.accessManager);
        (bool deployerStillAdmin,) = mgr.hasRole(V8Roles.ADMIN, deployer);
        assertFalse(deployerStillAdmin, "the deployer renounced ADMIN");
        (bool safeIsAdmin, uint32 delay) = mgr.hasRole(V8Roles.ADMIN, adminSafe);
        assertTrue(safeIsAdmin, "the Admin Safe holds ADMIN");
        assertEq(delay, V8Roles.ADMIN_DELAY, "at the manifest delay");
    }

    /*//////////////////////////////////////////////////////////////
      F-WIRE-10 P1-5: THE RECORD CARRIES WHAT THE WRITE-BACK READS
    //////////////////////////////////////////////////////////////*/

    /// @notice The deployment record names the block, both Safes, the guardian wallet and the four bot keys.
    /// @dev THE FIELD LIST IS RE-DERIVED FROM THE CONSUMER, not from the row's prose: `plannedWrites` in
    ///      `ops/markets/write-back-v8.mjs` reads `record.deployBlock`, `record.safes.{admin,treasury}`,
    ///      `record.wallets.{guardian,opsWallet}` and `record.bots.{cranker,pricer,quoter,guardian}` -- and its
    ///      `put` drops an undefined value SILENTLY, so a record missing them produces a registry with null slots
    ///      and no error. `opsWallet` is deliberately absent here: this script has no such input and a value it
    ///      invented would be worse than the null.
    ///
    ///      WHAT THIS TEST CANNOT DO: run the write-back. That tool is in the callhouse repository, not this one,
    ///      and driving it needs node. T-456 ran `plannedWrites` once, out of band, against this function's output
    ///      (callhouse dc7b02f4); this suite does not repeat that.
    function test_deploymentRecord_carriesTheBlockSafesWalletAndBots() public {
        V2DeployBase.Contracts memory set = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.roles.feeRecipient = set.feeSplitter;
        string memory json = deployScript.toDeploymentRecord(in_.roles, set, deployScript.recordBlocks(in_.existing));

        assertEq(vm.parseJsonUint(json, ".deployBlock"), block.number, "deployBlock");
        // T-456. BOTH `deployBlock`s ARE JSON NUMBERS, and this reads the raw text because `parseJsonUint` is not
        // the check for that: it is a value read, not a type read. Quoting the block to get a record past a
        // string-only reader is a named wrong fix -- it keeps the letter of that reader and corrupts the field,
        // and `write-back-v8.mjs` refuses a `deployBlock` that is not an integer.
        assertFalse(vm.contains(json, "\"deployBlock\": \""), "deployBlock is emitted as a string");
        assertTrue(
            vm.contains(json, string.concat("\"deployBlock\": ", vm.toString(block.number))),
            "deployBlock is a bare number"
        );
        assertEq(vm.parseJsonAddress(json, ".safes.admin"), adminSafe, "safes.admin");
        assertEq(vm.parseJsonAddress(json, ".safes.treasury"), treasurySafe, "safes.treasury");
        assertEq(vm.parseJsonAddress(json, ".wallets.guardian"), guardianKey, "wallets.guardian");
        assertEq(vm.parseJsonAddress(json, ".bots.cranker"), crankerKey, "bots.cranker");
        assertEq(vm.parseJsonAddress(json, ".bots.pricer"), pricerKey, "bots.pricer");
        assertEq(vm.parseJsonAddress(json, ".bots.quoter"), quoterKey, "bots.quoter");
        assertEq(vm.parseJsonAddress(json, ".bots.guardian"), guardianKey, "bots.guardian: one key, two homes");

        // T-456. THE ADDRESSES ARE AT THE TOP LEVEL, WHERE THE CONSUMER READS THEM, AND THIS IS THE ASSERTION
        // THAT PINS IT. `write-back-v8.mjs` at 6d10752c loops its CONTRACTS list reading `record[k]`, and its
        // KNOWN_RECORD_KEYS has no `contracts` member, so a wrapped record is refused outright before a single
        // address is written. A wrapped version was built first on an amendment that had gone stale; this keeps
        // the shape from drifting back without anyone noticing.
        assertEq(vm.parseJsonAddress(json, ".accessManager"), set.accessManager, "accessManager is top level");
        assertEq(vm.parseJsonAddress(json, ".clearinghouse"), set.clearinghouse, "clearinghouse is top level");
        assertEq(vm.parseJsonAddress(json, ".sources.chainlink"), set.chainlinkSource, "sources stays nested");
        assertEq(vm.parseJsonAddress(json, ".flywheel.feeSplitter"), set.feeSplitter, "flywheel stays nested");
        assertEq(vm.parseJsonUint(json, ".flywheel.deployBlock"), block.number, "flywheel.deployBlock is emitted");

        // And nothing the consumer does not know: its KNOWN_RECORD_KEYS is the eleven contract names plus
        // sources, flywheel, deployBlock, safes, wallets and bots. A `contracts` key here is the failure mode.
        string[] memory keys = vm.parseJsonKeys(json, "$");
        for (uint256 i; i < keys.length; ++i) {
            assertTrue(!_eqStr(keys[i], "contracts"), "a contracts wrapper is refused by write-back-v8.mjs");
        }
    }

    /// @notice T-456. A RUN VOUCHES ONLY FOR THE START BLOCK OF A GROUP IT CREATED.
    /// @dev A resumed run ("deploys only what is missing"), and a set whose splitter was deployed first, both run in
    ///      a block AFTER some of their contracts already existed. Stamping that block gives the indexer a start
    ///      block that is too late, and it skips those contracts' first events without a word. The record says null
    ///      instead: the write-back skips a null, and refuses a record whose top-level `deployBlock` is null.
    ///      Each case below builds its `given` from a FRESH `_deployInputs()`, because assigning a memory struct
    ///      aliases it and one case would leak into the next.
    function test_recordBlocks_nullForAGroupThisRunWasGiven() public {
        V2DeployBase.Contracts memory set = _deploy();
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.roles.feeRecipient = set.feeSplitter;

        DeployV8.RecordBlocks memory b = deployScript.recordBlocks(_deployInputs().existing);
        assertEq(b.core, block.number, "fresh set: the core block is this run's");
        assertEq(b.flywheel, block.number, "fresh set: the flywheel block is this run's");

        // The splitter was deployed earlier, the core is created here: only the core block is known.
        V2DeployBase.Contracts memory given = _deployInputs().existing;
        given.feeSplitter = set.feeSplitter;
        b = deployScript.recordBlocks(given);
        assertEq(b.core, block.number, "splitter given: the core is still created here");
        assertEq(b.flywheel, 0, "splitter given: its block is not this run's");

        // Resumed: one core contract already existed, the flywheel pair is created here.
        given = _deployInputs().existing;
        given.clearinghouse = set.clearinghouse;
        b = deployScript.recordBlocks(given);
        assertEq(b.core, 0, "one core contract given: the core block is not this run's");
        assertEq(b.flywheel, block.number, "one core contract given: the flywheel pair is still created here");

        // Everything given, as on a re-run of a finished deploy: no block is vouched for, and the record carries
        // both keys as JSON null -- not a number, not a string, and not dropped.
        b = deployScript.recordBlocks(set);
        assertEq(b.core, 0, "all given: core");
        assertEq(b.flywheel, 0, "all given: flywheel");
        string memory json = deployScript.toDeploymentRecord(in_.roles, set, b);
        assertTrue(vm.contains(json, "\"deployBlock\": null,"), "the top-level deployBlock is null");
        assertTrue(vm.contains(json, "\"deployBlock\": null}"), "flywheel.deployBlock is null");
        assertFalse(
            vm.contains(json, string.concat("\"deployBlock\": ", vm.toString(block.number))),
            "the record claims no block it did not see"
        );
    }

    /// @notice T-456. THE ADDRESS ARTIFACT CARRIES ADDRESSES AND NOTHING ELSE.
    /// @dev THIS IS THE ASSERTION THE BREAKAGE NEEDED AND DID NOT HAVE. T-436 added `deployBlock`, `safes`,
    ///      `wallets` and `bots` to `toJson` and no test here objected, because every assertion was a
    ///      `parseJson` of a key that WAS present -- nothing walked the key set, so an ADDED key was invisible.
    ///      A check that only ever looks at what it expects to find cannot see an extra. This walks the top
    ///      level and requires every member to be an address string or one of the two groups
    ///      `DeployV2Batch.sh` `mined_addresses()` knows, which is the consumer's own rule.
    function test_toJson_topLevelIsAddressesAndTheTwoGroupsOnly() public {
        V2DeployBase.Contracts memory set = _deploy();
        string memory json = deployScript.toJson(set);

        string[] memory keys = vm.parseJsonKeys(json, "$");
        assertGt(keys.length, 0, "the artifact has keys at all");
        for (uint256 i; i < keys.length; ++i) {
            if (_eqStr(keys[i], "sources") || _eqStr(keys[i], "flywheel")) continue;
            // The consumer's rule is `typeof j[k] === "string"`, so the SAME helper the positive control uses
            // decides it here. One rule, two call sites: a change to it cannot pass here and fail there.
            assertTrue(_isAddressString(json, keys[i]), string.concat(keys[i], " is not an address string"));
        }

        // The shape the bash path consumes is unchanged: DeployV2Batch.sh and batch-refusals.sh read the contract
        // addresses at the top level with jq, and breaking that would break the launch script this row does not own.
        assertEq(vm.parseJsonAddress(json, ".accessManager"), set.accessManager, "the address block is unmoved");
        assertEq(vm.parseJsonAddress(json, ".flywheel.feeSplitter"), set.feeSplitter, "flywheel is still beside it");
        assertEq(vm.parseJsonAddress(json, ".sources.chainlink"), set.chainlinkSource, "sources is still nested");
    }

    /// @notice T-456. THE POSITIVE CONTROL FOR THE TEST ABOVE: the same rule, aimed at a shape that MUST fail.
    /// @dev WITHOUT THIS, THE TEST ABOVE IS THE DEFECT IT IS CHECKING FOR. T-436's extra keys survived because
    ///      every assertion in this file read a key it expected to be there, so nothing could see an ADDED one.
    ///      Replacing that with a key-set walk is only worth something if the walk can go red, so here the walk
    ///      is run against a hand-built artifact carrying exactly what broke the launch script -- a NUMBER and an
    ///      OBJECT at the top level -- and is required to reject both. `mined_addresses()` in
    ///      `script/v2/DeployV2Batch.sh` applies the same rule with `typeof j[k] !== "string"`, so this is the
    ///      consumer's guard replicated here rather than a restatement of it.
    function test_launchShapeRule_rejectsTheKeysThatBrokeTheLaunchScript() public {
        // The T-436 shape, minimally: one address, one number, one object.
        string memory broken =
            '{"accessManager": "0x0000000000000000000000000000000000000001", "deployBlock": 123, "safes": {"admin": null}}';

        string[] memory keys = vm.parseJsonKeys(broken, "$");
        uint256 rejected;
        for (uint256 i; i < keys.length; ++i) {
            if (_eqStr(keys[i], "sources") || _eqStr(keys[i], "flywheel")) continue;
            if (!_isAddressString(broken, keys[i])) ++rejected;
        }
        assertEq(rejected, 2, "the rule must reject the number AND the object, and nothing else");

        // CONTROL ON THE CONTROL: the real artifact passes the same walk with zero rejections, so the rule is
        // not simply refusing everything it is shown.
        V2DeployBase.Contracts memory set = _deploy();
        string memory good = deployScript.toJson(set);
        string[] memory goodKeys = vm.parseJsonKeys(good, "$");
        uint256 rejectedGood;
        for (uint256 i; i < goodKeys.length; ++i) {
            if (_eqStr(goodKeys[i], "sources") || _eqStr(goodKeys[i], "flywheel")) continue;
            if (!_isAddressString(good, goodKeys[i])) ++rejectedGood;
        }
        assertEq(rejectedGood, 0, "the real address artifact passes the rule it is judged by");
    }

    /// @dev `typeof j[k] === "string"` and 42 characters, which is `mined_addresses()`'s test spelled in Solidity.
    ///      `parseJsonString` reverts on a non-string, so the failure is caught rather than propagated.
    function _isAddressString(string memory json, string memory key) private view returns (bool) {
        try this.parseStringAt(json, string.concat(".", key)) returns (string memory raw) {
            return bytes(raw).length == 42;
        } catch {
            return false;
        }
    }

    /// @dev Public only so `_isAddressString` can `try` it: an internal call cannot be caught.
    function parseStringAt(string memory json, string memory path) public pure returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _eqStr(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /*//////////////////////////////////////////////////////////////
       T-436: THE PENDING HALF OF ROLE STATE, AND EVERY ROLE ID
    //////////////////////////////////////////////////////////////*/

    /// @notice A pending reduction of the Admin Safe's ADMIN execution delay refuses the renounce.
    /// @dev THE DEFECT IN ONE SENTENCE: `hasRole` returns `since` and `currentDelay` and throws away `pendingDelay`
    ///      and `effect` (AccessManager.sol:217-227), so a scheduled reduction to 0 reads as a correct 48 h lane
    ///      until the moment it becomes instant -- and after the renounce nobody is left who could put it back.
    ///      The scheduled change is made the way a real one would be: `grantRole` at a LOWER execution delay, which
    ///      `Time.Delay.withUpdate` schedules with a setback equal to the reduction rather than applying at once.
    function test_renounce_refusedWhenTheAdminSafeHasAPendingAdminDelayReduction() public {
        V2DeployBase.Contracts memory set = _deploy();
        AccessManager mgr = AccessManager(set.accessManager);
        // The hand-back path is only reached while the deployer still holds ADMIN, so give it back first.
        _asAdminSafe(mgr, abi.encodeCall(IAccessManager.grantRole, (V8Roles.ADMIN, deployer, 0)));
        _asAdminSafe(mgr, abi.encodeCall(IAccessManager.grantRole, (V8Roles.ADMIN, adminSafe, 0)));

        // The break is real and INVISIBLE to the old check: hasRole still answers 172800.
        (, uint32 stillReads) = mgr.hasRole(V8Roles.ADMIN, adminSafe);
        assertEq(stillReads, V8Roles.ADMIN_DELAY, "hasRole still reports the manifest delay");
        (,, uint32 pendingDelay, uint48 effect) = mgr.getAccess(V8Roles.ADMIN, adminSafe);
        assertEq(pendingDelay, 0, "and a reduction to 0 is pending");
        assertGt(effect, block.timestamp, "with a future effect time");

        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = set;
        in_.roles.feeRecipient = set.feeSplitter;
        vm.expectRevert(bytes(_pendingAdminDelayRefusal(adminSafe, pendingDelay, effect)));
        deployScript.checkWiring(in_);
    }

    /// @notice OPS_ADMIN left on the deployer is a pending hand-back call, not a silent pass.
    /// @dev `_workingRoles` is derived from the roles that appear as VALUES in `roles.v8.json` `.targets`, and
    ///      OPS_ADMIN maps no selector -- it exists to PARENT the four instant lanes. So the hand-back never asked
    ///      about it, `_postCheck` never asked about it, and a run that left it on the deployer still logged a
    ///      complete hand-over. The fix enumerates every role id the manifest declares, which is why this test
    ///      grants a role that no target function uses.
    function test_checkWiring_seesOpsAdminLeftOnTheDeployer() public {
        V2DeployBase.Contracts memory set = _deploy();
        AccessManager mgr = AccessManager(set.accessManager);
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = set;
        in_.roles.feeRecipient = set.feeSplitter;
        assertEq(deployScript.checkWiring(in_), 0, "the hand-over is complete before the break");

        _asAdminSafe(mgr, abi.encodeCall(IAccessManager.grantRole, (V8Roles.OPS_ADMIN, deployer, 0)));
        (bool member,) = mgr.hasRole(V8Roles.OPS_ADMIN, deployer);
        assertTrue(member, "the break landed: the deployer holds OPS_ADMIN");

        assertEq(deployScript.checkWiring(in_), 1, "one pending call: renounce OPS_ADMIN");
    }

    /// @notice A pending reduction of a HOLDER's execution delay is a pending grant, not a satisfied one.
    /// @dev The same defect one level down from the renounce: `_grantsFor` compared `hasRole`'s current delay to the
    ///      manifest and planned nothing, so a scheduled reduction of, say, the Admin Safe's LISTING delay survived
    ///      a run that reported the wiring complete. Re-granting at the manifest delay is what cancels it, and that
    ///      is exactly the call this planner emits.
    function test_checkWiring_seesAPendingHolderDelayReduction() public {
        V2DeployBase.Contracts memory set = _deploy();
        AccessManager mgr = AccessManager(set.accessManager);
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = set;
        in_.roles.feeRecipient = set.feeSplitter;
        assertEq(deployScript.checkWiring(in_), 0, "complete before the break");

        _asAdminSafe(mgr, abi.encodeCall(IAccessManager.grantRole, (V8Roles.LISTING, adminSafe, 0)));
        (, uint32 current) = mgr.hasRole(V8Roles.LISTING, adminSafe);
        assertEq(current, V8Roles.LISTING_DELAY, "hasRole still reports the manifest delay");

        assertEq(deployScript.checkWiring(in_), 1, "one pending call: re-grant LISTING at the manifest delay");
    }

    /// @dev Schedule a manager self-call as the Admin Safe, wait out ADMIN's manifest delay and send it. Mirrors
    ///      `test/v2/unit/VerifyV8.t.sol`'s `_adminSchedule`: the call is made DIRECTLY after the wait so
    ///      `msg.sender` is still the member, which is how `AccessManager` consumes a scheduled operation.
    function _asAdminSafe(AccessManager mgr, bytes memory data) internal {
        vm.prank(adminSafe);
        mgr.schedule(address(mgr), data, 0);
        vm.warp(block.timestamp + V8Roles.ADMIN_DELAY);
        vm.prank(adminSafe);
        (bool ok,) = address(mgr).call(data);
        require(ok, "scheduled admin call reverted");
    }

    function _pendingAdminDelayRefusal(address safe, uint32 pendingDelay, uint48 effect)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
            vm.toString(safe),
            " has a PENDING ADMIN execution-delay change to ",
            vm.toString(uint256(pendingDelay)),
            " s taking effect at ",
            vm.toString(uint256(effect)),
            ". hasRole() cannot see it. Renouncing now hands ADMIN to a lane that becomes ",
            vm.toString(uint256(pendingDelay)),
            " s later, and after the renounce nobody can put it back."
        );
    }

    /*//////////////////////////////////////////////////////////////
          T-426 F-05-03: A TARGET IS WHAT ITS MANIFEST NAME CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice One address supplied under two manifest target names is refused before anything is created.
    /// @dev THE SHAPE THE FINDING NAMES. `V2_HOUSE_VAULT = V2_BUYBACK_EXECUTOR` is the specific case: `VerifyV8`
    ///      exempts the buyback executor from two of its walks by ADDRESS EQUALITY, so an alias there does not make
    ///      the verifier fail -- it makes the HouseVault checks skip themselves and the run report clean. This uses
    ///      two of the six external names, which reaches the same guard by the same route and does not need the
    ///      executor to exist yet.
    function test_preflight_refusesOneAddressUnderTwoTargetNames() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing.earnVault = in_.existing.houseVault;
        vm.expectRevert(bytes(_aliasRefusal("HouseVault", "EarnVault", in_.existing.houseVault)));
        deployScript.preflight(in_);
    }

    /// @notice A supplied target that does not answer its name's interface is refused, even though it has code.
    /// @dev The double here is a real, correctly-wired stand-in for a DIFFERENT one of the six -- so `code.length`,
    ///      `authority()` and every other property the old guard asked about are all satisfied. Only the interface
    ///      says it is the wrong contract, which is the whole finding: six raw addresses were being mapped to six
    ///      names with nothing asserting the correspondence.
    function test_preflight_refusesASuppliedTargetThatIsADifferentContract() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        address theWrongOne = address(new MockExternalTarget(MockExternalTarget.Kind.Hedger));
        in_.existing.houseVault = theWrongOne;
        assertGt(theWrongOne.code.length, 0, "the wrong contract still has code, which was the whole old check");
        vm.expectRevert(bytes(_identityRefusal("HouseVault", theWrongOne, "underlying()")));
        deployScript.preflight(in_);
    }

    /// @notice The happy path still passes preflight, so the two refusals above are not a guard that refuses
    ///         everything.
    function test_preflight_acceptsTheSixCorrectlyShapedExternalTargets() public view {
        deployScript.preflight(_deployInputs());
    }

    function _aliasRefusal(string memory first, string memory second, address shared)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "two roles.v8.json targets are the same address: ",
            first,
            " and ",
            second,
            " are both ",
            vm.toString(shared),
            ". One contract cannot carry two targets' selector maps, and a verifier that exempts a",
            " target by address would skip the other one silently."
        );
    }

    function _identityRefusal(string memory name, address target, string memory sig)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "the address supplied for the roles.v8.json target ",
            name,
            " (",
            vm.toString(target),
            ") does not answer ",
            sig,
            ", so it is not a ",
            name,
            ". Wiring it under this name would map ",
            name,
            "'s selectors onto a different contract."
        );
    }

    /// @dev Mirrors the four refusal sentences of `DeployV8._assertAdminSafeIsARealSafe`. Built here as strings so
    ///      a reviewer reads what the operator would actually see, and so a change to a message fails a test
    ///      instead of silently changing an operator-facing sentence.
    function _safeRefusal(address safe, string memory tail) internal pure returns (string memory) {
        return string.concat("REFUSING TO RENOUNCE ADMIN: the Admin Safe ", vm.toString(safe), " ", tail);
    }

    function _singletonRefusal(address safe, address singleton) internal pure returns (string memory) {
        return _safeRefusal(
            safe,
            string.concat(
                "has code but its singleton slot holds ",
                vm.toString(singleton),
                ", which is not a canonical Safe 1.4.1 / 1.3.0 build. An inert contract and a public forwarder both",
                " have code; neither can produce a 2-of-3 signature."
            )
        );
    }

    function _topologyRefusal(address safe, uint256 threshold, uint256 owners) internal pure returns (string memory) {
        return _safeRefusal(
            safe,
            string.concat(
                "is ",
                vm.toString(threshold),
                "-of-",
                vm.toString(owners),
                "; v8 requires at least 2-of-3 and a threshold no larger than the owner count"
            )
        );
    }

    function _moduleRefusal(address safe, uint256 count) internal pure returns (string memory) {
        return _safeRefusal(
            safe,
            string.concat(
                "has ",
                vm.toString(count),
                " enabled module(s). A module executes Safe transactions with no owner signatures at all, so the",
                " 2-of-3 is advisory."
            )
        );
    }

    /// @dev Mirrors `DeployV8._assertAdminSafeCanTakeOver`. Kept as one string so a reviewer can read the sentence
    ///      the operator would actually see.
    function _renounceRefusal(address safe) internal pure returns (string memory) {
        return string.concat(
            "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
            vm.toString(safe),
            " must already hold ADMIN with a 172800 s execution delay and must have code.",
            " AccessManager._revokeRole has NO last-admin guard, so",
            " renouncing the last ADMIN BRICKS ALL SIXTEEN CONTRACTS PERMANENTLY: no role, no selector map and no",
            " authority could ever be changed again, on any of them, by anyone."
        );
    }

    /*//////////////////////////////////////////////////////////////
                            PREFLIGHT REFUSALS
    //////////////////////////////////////////////////////////////*/

    function test_preflight_everyRefusalInOrder() public {
        DeployV8.Inputs memory in_;

        // ---------------------------------------------------------------- principals
        in_ = _deployInputs();
        in_.roles.adminSafe = address(0);
        _refused(in_, "V2_ADMIN_SAFE is zero");

        in_ = _deployInputs();
        in_.roles.treasurySafe = address(0);
        _refused(in_, "V2_TREASURY_SAFE is zero");

        in_ = _deployInputs();
        in_.roles.deployer = address(0);
        _refused(in_, "V2_DEPLOYER is zero");

        in_ = _deployInputs();
        in_.roles.pricerKey = crankerKey;
        _refused(
            in_,
            "adminSafe, treasurySafe, guardian, pricer, quoter, cranker and deployer must be seven different addresses (a bot key never holds admin, treasury or deploy powers)"
        );

        // v7 let the deployer be the admin; v8 refuses it, because the deployer is the one principal that is meant
        // to end the run holding nothing.
        in_ = _deployInputs();
        in_.roles.deployer = adminSafe;
        _refused(
            in_,
            "adminSafe, treasurySafe, guardian, pricer, quoter, cranker and deployer must be seven different addresses (a bot key never holds admin, treasury or deploy powers)"
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

        // ---------------------------------------------------------------- Uniswap periphery, Data Streams, v4
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

        in_ = _deployInputs();
        in_.ext.v4PoolManager = nothing;
        _refused(in_, string.concat("V2_V4_POOL_MANAGER ", vm.toString(nothing), " has no code"));

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

        in_ = _deployInputs();
        in_.params.bountyCancelStale = 1_000_001;
        _refused(in_, "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY (1000000)");

        in_ = _deployInputs();
        in_.params.vaultLimits.maxSeriesUnits = 0;
        _refused(in_, "V2_VAULT_MAX_SERIES_UNITS must be > 0");

        // INTERFACE_VERSION 7 (c21): 0 is the incident spend freeze (`setLimits`), never a deploy value.
        in_ = _deployInputs();
        in_.params.vaultLimits.maxDailyOutflow = 0;
        _refused(in_, "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0 (0 deploys the vault frozen: no bid, take or replace-up)");

        in_ = _deployInputs();
        in_.params.baseUri = "https://app.stonkhouse.fun/api/token";
        _refused(in_, "V2_BASE_URI must be non-empty and end with \"/\"");

        // ---------------------------------------------------------------- the flywheel
        in_ = _deployInputs();
        in_.flywheel.burnBps = 10_001;
        _refused(in_, "V2_BURN_BPS above 10000");

        in_ = _deployInputs();
        in_.flywheel.conversionSlippageBps = 301;
        _refused(in_, "V2_CONVERSION_SLIPPAGE_BPS above MAX_PAYOUT_SLIPPAGE_CEIL_BPS (300)");

        // V4BuybackExecutor's constructor refuses this too, but only after fifteen contracts already exist.
        in_ = _deployInputs();
        in_.flywheel.poolKey.currency0 = address(usdg);
        _refused(in_, "V2_TOKEN_POOL_CURRENCY0 must be native ETH (the zero address): the buyback's v4 leg spends ETH");

        in_ = _deployInputs();
        in_.flywheel.minLiquidity = 0;
        _refused(in_, "V2_BUYBACK_MIN_LIQUIDITY must be > 0 (0 would accept an empty v3 leg)");

        // ---------------------------------------------------------------- resume addresses
        in_ = _deployInputs();
        in_.existing.clearinghouse = nothing;
        _refused(in_, string.concat("V2_CLEARINGHOUSE ", vm.toString(nothing), " has no code (resume)"));

        // ---------------------------------------------------------------- a fee recipient that is not the splitter
        V2DeployBase.Contracts memory d = _deploy();
        in_ = _deployInputs();
        in_.existing = d;
        in_.roles.feeRecipient = address(new MockSafe());
        vm.expectRevert(bytes("V2_FEE_RECIPIENT is not V2_FEE_SPLITTER"));
        deployScript.runWith(in_, _signer(deployer));

        // nothing above created a second set: the accepted inputs still deploy
        DeployV8.Inputs memory fresh = _deployInputs();
        fresh.roles.feeRecipient = address(0);
        (, DeployV8.Outcome memory o) = deployScript.runWith(fresh, _signer(deployer));
        assertEq(o.created, 16, "the unmodified inputs deploy");
    }

    /// @dev Expect `runWith` to revert with exactly `reason` (the preflight runs before any create or call).
    function _refused(DeployV8.Inputs memory in_, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        deployScript.runWith(in_, _signer(deployer));
    }
}
