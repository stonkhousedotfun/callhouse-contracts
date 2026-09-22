// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployV2Fixture, MockExternalTarget} from "./DeployV2Fixture.t.sol";
import {DeployV8} from "../../../script/v2/DeployV8.s.sol";
import {MapExternals} from "../../../script/v2/MapExternals.s.sol";
import {HandBack} from "../../../script/v2/HandBack.s.sol";
import {V2DeployBase} from "../../../script/v2/lib/V2DeployBase.sol";
import {RegisterMarkets} from "../../../script/v2/RegisterMarkets.s.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Clearinghouse} from "../../../src/v2/Clearinghouse.sol";

/// @notice T-OP-153. The deferred hand-back: `DeployV8` with `deferHandBack` leaves the deployer holding ADMIN and
///         the delay-0 working roles (steps 8 and 9 withheld, amendment #1), `MapExternals` maps the supplied
///         externals from that ADMIN, `RegisterMarkets` registers DIRECTLY from that deployer with no schedule,
///         `HandBack` drops the working roles and renounces ADMIN last, and `VerifyV8._handover` is red in between
///         and green after.
/// @dev On the in-test V8 fixture (`DeployV2Fixture`): the six externals are `MockExternalTarget`s that answer the
///      probes and take an authority pointer, so a mapping onto them is observable through `getTargetFunctionRole`.
///      THE OWNER'S ACCEPTED COST is what the middle of this file exercises on purpose: between the deferred deploy
///      and `HandBack` the deployer hot key IS ADMIN, and `VerifyV8` says so.
contract DeployV8HandBackTest is DeployV2Fixture {
    MapExternals internal mapScript;
    HandBack internal handBackScript;
    AccessManager internal mgr;
    uint64 internal adminRole;

    function setUp() public override {
        super.setUp();
        mapScript = new MapExternals();
        handBackScript = new HandBack();
    }

    /// @dev The fixture's `_deploy` with the flag on: steps 1-8, hand-back withheld.
    function _deployDeferred() internal returns (V2DeployBase.Contracts memory d) {
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.deferHandBack = true;
        (d,) = deployScript.runWith(in_, _signer(deployer));
        feeRecipient = d.feeSplitter;
        _pointExternalTargets(d.accessManager);
        mgr = AccessManager(d.accessManager);
        adminRole = mgr.ADMIN_ROLE();
    }

    /// @dev Inputs for the two follow-up scripts: the deployed set as `existing`, everything else as the deploy had.
    function _followUpInputs(V2DeployBase.Contracts memory d) internal view returns (DeployV8.Inputs memory in_) {
        in_ = _deployInputs();
        in_.existing = d;
        in_.deferHandBack = true;
    }

    function _holdsAnyRole(address who) internal view returns (bool) {
        uint64[] memory ids = _manifestRoleIds();
        for (uint256 i; i < ids.length; ++i) {
            (bool member,) = mgr.hasRole(ids[i], who);
            if (member) return true;
        }
        return false;
    }

    /// @dev Every role id `roles.v8.json` declares, read through the script's own parser (never typed here).
    function _manifestRoleIds() internal view returns (uint64[] memory ids) {
        string memory json = deployScript.rolesJson();
        string[] memory names = vm.parseJsonKeys(json, ".roles");
        ids = new uint64[](names.length);
        for (uint256 i; i < names.length; ++i) {
            ids[i] = deployScript.roleIdOf(json, names[i]);
        }
    }

    /// @dev True when every manifest selector of `targetName` is mapped to its manifest role on `target`.
    function _fullyMapped(string memory targetName, address target) internal view returns (bool) {
        string memory json = deployScript.rolesJson();
        string[] memory sigs = deployScript.targetSigs(json, targetName);
        for (uint256 i; i < sigs.length; ++i) {
            uint64 want = deployScript.roleIdOf(json, deployScript.roleNameOfSig(json, targetName, sigs[i]));
            if (mgr.getTargetFunctionRole(target, deployScript.selectorOf(sigs[i])) != want) return false;
        }
        return sigs.length != 0;
    }

    /*//////////////////////////////////////////////////////////////
                        1. THE DEFAULT IS UNCHANGED
    //////////////////////////////////////////////////////////////*/

    /// @dev PIN: an unset V2_DEFER_HANDBACK reads false, so the atomic deploy is what a plain run gets.
    function test_deferHandBack_defaultsToFalse() public view {
        assertFalse(deployScript.deferHandBackFromEnv(), "V2_DEFER_HANDBACK unset must read false");
        assertFalse(_deployInputs().deferHandBack, "the fixture's inputs do not defer");
    }

    /// @dev The default run: after it the deployer holds nothing, exactly as before this row.
    function test_defaultRun_deployerHoldsNothing() public {
        V2DeployBase.Contracts memory d = _deploy();
        mgr = AccessManager(d.accessManager);
        adminRole = mgr.ADMIN_ROLE();
        (bool isAdmin,) = mgr.hasRole(adminRole, deployer);
        assertFalse(isAdmin, "default run: the deployer renounced ADMIN");
        assertFalse(_holdsAnyRole(deployer), "default run: the deployer holds no manifest role");
        // The default set is a complete hand-over: a wiring check counts nothing pending (F-SCRIPTS-05 shape).
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.existing = d;
        assertEq(deployScript.checkWiring(in_), 0, "default run: nothing pending");
        (, uint256 handoverFails) = _handoverFailures(d);
        assertEq(handoverFails, 0, "default run: VerifyV8 has no hand-over failure");
    }

    /// @dev VerifyV8's failures on `d`, split into the market checks (which fail on an UNREGISTERED fixture -- 17 of
    ///      them at this base, all named `NVDA:`/`TSLA:` -- and are not this file's subject) and everything else.
    ///      Read from the verifier's own counter rather than assumed: `check` returns the totals, and the split is
    ///      the difference between a run over the registered set and one over the bare set.
    function _handoverFailures(V2DeployBase.Contracts memory d) internal returns (uint256 total, uint256 nonMarket) {
        (, total) = verifyScript.check(_verifyInputs(d, true));
        VerifyV8.Inputs memory bare = _verifyInputs(d, true);
        bare.markets = new V2DeployBase.MarketIn[](0);
        bare.mintFeePpm = new uint32[](0);
        (, nonMarket) = verifyScript.check(bare);
    }

    /*//////////////////////////////////////////////////////////////
                        2. THE DEFERRED RUN
    //////////////////////////////////////////////////////////////*/

    /// @dev The deferred run leaves the deployer ADMIN plus every `.targets` role at delay 0 (steps 8 and 9 both
    ///      withheld); the four hand-over batches are complete.
    function test_deferredRun_deployerKeepsAdminAndWorkingRoles() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        (bool isAdmin,) = mgr.hasRole(adminRole, deployer);
        assertTrue(isAdmin, "deferred run: the deployer STILL holds ADMIN");
        // LISTING and CONFIG_ADMIN are what RegisterMarkets needs, both at delay 0 -- read from the manifest.
        string memory json = deployScript.rolesJson();
        (bool listing, uint32 listingDelay) = mgr.hasRole(deployScript.roleIdOf(json, "LISTING"), deployer);
        (bool config, uint32 configDelay) = mgr.hasRole(deployScript.roleIdOf(json, "CONFIG_ADMIN"), deployer);
        assertTrue(listing && listingDelay == 0, "deferred run: the deployer holds LISTING at delay 0 (step 4 kept)");
        assertTrue(config && configDelay == 0, "deferred run: the deployer holds CONFIG_ADMIN at delay 0 (step 4 kept)");
        // The externals the fixture supplied were mapped by the deploy itself (step 3), as before.
        assertTrue(_fullyMapped("HouseVault", houseVault), "supplied externals are mapped by step 3");
        // THE CHECK PATH (DeployV2Batch.sh's wiring check): with the flag, a deferred set counts NO pending call --
        // the withheld drops and renounce are announced as DEFERRED, not counted, so the batch does not ask for
        // --resume. Without the flag the same set counts every held role as a pending hand-over call (F-SCRIPTS-05).
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        assertEq(deployScript.checkWiring(in_), 0, "deferred set, flag on: nothing pending but the announced hand-back");
        uint64[] memory ids = _manifestRoleIds();
        uint256 held;
        for (uint256 i; i < ids.length; ++i) {
            (bool member,) = mgr.hasRole(ids[i], deployer);
            if (member) ++held;
        }
        in_.deferHandBack = false;
        assertEq(deployScript.checkWiring(in_), held, "flag off: one pending renounce per role the deployer holds");
    }

    /// @dev THE RESUME PATH: a deferred re-run (--resume inside the window, a driver re-running the deploy step)
    ///      over the deferred set sends nothing and does not renounce -- 'complete set, hand-back pending', not a
    ///      partial run to redo. And the no-flag re-run over the same set is pinned as today's behaviour: it sends
    ///      the hand-back. The flag is the only thing that withholds it, and HandBack.s.sol the only script that
    ///      sends it under the flag.
    function test_deferredRun_resumeInsideTheWindowSendsNoHandBack() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        (, DeployV8.Outcome memory o) = deployScript.runWith(in_, _signer(deployer));
        assertEq(o.created, 0, "re-run creates nothing");
        assertEq(o.sent, 0, "re-run with the flag sends nothing: steps 8 and 9 are withheld");
        (bool isAdmin,) = mgr.hasRole(adminRole, deployer);
        assertTrue(isAdmin, "re-run with the flag keeps ADMIN with the deployer");
        string memory json = deployScript.rolesJson();
        (bool listing,) = mgr.hasRole(deployScript.roleIdOf(json, "LISTING"), deployer);
        assertTrue(listing, "re-run with the flag keeps the working roles too");

        // PINNED: the same re-run WITHOUT the flag is a repair run and sends the hand-back, as before this row.
        in_.deferHandBack = false;
        (, DeployV8.Outcome memory repair) = deployScript.runWith(in_, _signer(deployer));
        assertGt(repair.sent, 1, "no flag: the working roles are dropped and ADMIN renounced");
        assertFalse(_holdsAnyRole(deployer), "no flag: the deployer holds nothing afterwards");
    }

    /*//////////////////////////////////////////////////////////////
                        3. MAP EXTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev A supplied external is mapped; an unsupplied one is skipped BY NAME; nothing is mapped at address(0).
    function test_mapExternals_mapsSuppliedAndSkipsUnsuppliedByName() public {
        // Deploy WITHOUT the Hedger and EarnVault: on launch day the externals arrive after the deploy.
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.deferHandBack = true;
        in_.existing.hedger = address(0);
        in_.existing.earnVault = address(0);
        (V2DeployBase.Contracts memory d,) = deployScript.runWith(in_, _signer(deployer));
        feeRecipient = d.feeSplitter;
        _pointExternalTargets(d.accessManager);
        mgr = AccessManager(d.accessManager);
        adminRole = mgr.ADMIN_ROLE();
        assertFalse(_fullyMapped("Hedger", hedger), "the Hedger was not supplied to the deploy, so it is unmapped");

        // Now the Hedger exists; the EarnVault still does not (it stays in V2_SKIP_EXTERNALS' territory).
        DeployV8.Inputs memory later = _followUpInputs(d);
        later.existing.hedger = hedger;
        later.existing.earnVault = address(0);
        // The driver's list names EarnVault (manifest spelling, T-OP-161): the skip is expected and said so.
        string[] memory skip = new string[](1);
        skip[0] = "EarnVault";
        (uint256 mapped, string[] memory supplied, string[] memory skipped) =
            mapScript.mapWith(later, _signer(deployer), skip);

        assertTrue(_fullyMapped("Hedger", hedger), "MapExternals mapped the supplied Hedger");
        assertGt(mapped, 0, "the Hedger's selectors were sent");
        assertEq(skipped.length, 1, "exactly one external was skipped");
        assertEq(skipped[0], "EarnVault", "the skipped one is named");
        assertEq(supplied.length, 5, "the other five were supplied (four already mapped by step 3, re-planned to nothing)");
        // Nothing is mapped at address(0): the manager has no role for the EarnVault's selectors on the zero address.
        string memory json = deployScript.rolesJson();
        string[] memory sigs = deployScript.targetSigs(json, "EarnVault");
        for (uint256 i; i < sigs.length; ++i) {
            uint64 want = deployScript.roleIdOf(json, deployScript.roleNameOfSig(json, "EarnVault", sigs[i]));
            // `getTargetFunctionRole` answers 0 (== ADMIN_ROLE) for an unmapped pair, so the manifest role must be
            // non-zero for this to prove anything -- and every EarnVault role is.
            assertTrue(want != 0, "an EarnVault selector maps to a non-ADMIN role in the manifest");
            assertEq(mgr.getTargetFunctionRole(address(0), deployScript.selectorOf(sigs[i])), 0, "address(0) carries no mapping");
        }
        // Idempotent: a second run over the same inputs plans nothing -- and with NO skip list the unsupplied
        // EarnVault is still skipped (as a WARN), never mapped at address(0).
        (uint256 again,, string[] memory skippedAgain) = mapScript.mapWith(later, _signer(deployer), _noSkip());
        assertEq(again, 0, "second MapExternals run sends nothing");
        assertEq(skippedAgain.length, 1, "unlisted and unsupplied: still skipped, by name");
    }

    /// @dev The skip list fails closed exactly as VerifyV8's does: a name outside the six, a listed name that is
    ///      supplied, a duplicate.
    function test_mapExternals_skipListFailsClosed() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        string[] memory skip = new string[](1);
        skip[0] = "hedger"; // the registry-key spelling, not the manifest name
        vm.expectRevert();
        mapScript.mapWith(in_, _signer(deployer), skip);
        skip[0] = "Hedger"; // listed but supplied by the fixture
        vm.expectRevert(
            bytes(
                "V2_SKIP_EXTERNALS names Hedger but V2_HEDGER is supplied: a skip of a supplied target is a look-away;"
                " drop it from the list or unset the variable"
            )
        );
        mapScript.mapWith(in_, _signer(deployer), skip);
        in_.existing.hedger = address(0);
        string[] memory dup = new string[](2);
        dup[0] = "Hedger";
        dup[1] = "Hedger";
        vm.expectRevert(bytes("V2_SKIP_EXTERNALS lists Hedger twice"));
        mapScript.mapWith(in_, _signer(deployer), dup);
        // And the well-formed list is accepted, with the Hedger skipped by name.
        (,, string[] memory skipped) = mapScript.mapWith(in_, _signer(deployer), skip);
        assertEq(skipped.length, 1, "Hedger skipped");
        assertEq(skipped[0], "Hedger", "by its manifest name");
    }

    function _noSkip() internal pure returns (string[] memory) {
        return new string[](0);
    }

    /// @dev After HandBack the deployer is not ADMIN any more, and MapExternals refuses by name.
    function test_mapExternals_refusesAfterHandBack() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        handBackScript.handBackWith(in_, _signer(deployer));
        vm.expectRevert(
            bytes(
                string.concat(
                    "MapExternals: the deployer ",
                    vm.toString(deployer),
                    " does not hold ADMIN on ",
                    vm.toString(d.accessManager),
                    ": run before HandBack.s.sol. After the hand-back the externals can only be mapped by the Admin Safe"
                    " through its delayed ADMIN lane."
                )
            )
        );
        mapScript.mapWith(in_, _signer(deployer), _noSkip());
    }

    /*//////////////////////////////////////////////////////////////
                        4. HAND BACK
    //////////////////////////////////////////////////////////////*/

    /// @dev HandBack renounces exactly what the planner finds -- every held working role, then ADMIN -- and a
    ///      second run finds nothing, rc 0.
    function test_handBack_renouncesWorkingRolesThenAdminAndIsIdempotent() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        uint64[] memory ids = _manifestRoleIds();
        uint256 held;
        for (uint256 i; i < ids.length; ++i) {
            (bool member,) = mgr.hasRole(ids[i], deployer);
            if (member) ++held;
        }
        assertGt(held, 1, "before HandBack the deployer holds ADMIN and at least one working role");
        uint256 sent = handBackScript.handBackWith(in_, _signer(deployer));
        assertEq(sent, held, "one renounce per held role: the working roles (step 8), then ADMIN (step 9)");
        (bool isAdmin,) = mgr.hasRole(adminRole, deployer);
        assertFalse(isAdmin, "after HandBack the deployer holds no ADMIN");
        assertFalse(_holdsAnyRole(deployer), "after HandBack the deployer holds nothing");
        uint256 again = handBackScript.handBackWith(in_, _signer(deployer));
        assertEq(again, 0, "second HandBack run: nothing to renounce, no revert");
    }

    /// @dev HandBack refuses while a supplied external is still unmapped: the renounce would strand its selectors.
    function test_handBack_refusesWhileASuppliedExternalIsUnmapped() public {
        DeployV8.Inputs memory in_ = _deployInputs();
        in_.deferHandBack = true;
        in_.existing.hedger = address(0);
        (V2DeployBase.Contracts memory d,) = deployScript.runWith(in_, _signer(deployer));
        feeRecipient = d.feeSplitter;
        _pointExternalTargets(d.accessManager);
        mgr = AccessManager(d.accessManager);
        adminRole = mgr.ADMIN_ROLE();
        DeployV8.Inputs memory later = _followUpInputs(d);
        later.existing.hedger = hedger; // supplied now, but MapExternals has not run
        vm.expectRevert();
        handBackScript.handBackWith(later, _signer(deployer));
        (bool isAdmin,) = mgr.hasRole(adminRole, deployer);
        assertTrue(isAdmin, "the refusal sent nothing: the deployer still holds ADMIN");
        // After MapExternals the same HandBack goes through.
        mapScript.mapWith(later, _signer(deployer), _noSkip());
        assertGt(handBackScript.handBackWith(later, _signer(deployer)), 0, "HandBack after MapExternals");
        assertFalse(_holdsAnyRole(deployer), "and the deployer holds nothing after it");
    }

    /*//////////////////////////////////////////////////////////////
            5. REGISTER MARKETS DIRECTLY FROM THE DEPLOYER (AMENDMENT #1)
    //////////////////////////////////////////////////////////////*/

    /// @dev Inside the deferred window the deployer holds LISTING and CONFIG_ADMIN at delay 0, so
    ///      `RegisterMarkets.runWith` with the deployer as signer and NO schedule (V2_SCHEDULE unset, the script's
    ///      default seam) registers both fixture markets in ONE run: `_signerCanList` reads the zero delays and
    ///      asks for no schedule; `_executeScheduled` finds every call immediate and sends it directly. This is
    ///      the path VerifyV8.t.sol's fixture cannot take with the Safe (1 h / 24 h lanes, two runs and a warp).
    ///      RegisterMarkets.s.sol itself is unchanged by this row: the test proves the existing code takes the
    ///      direct branch for a delay-0 signer.
    function test_registerMarkets_directFromTheDeployerInsideTheWindow() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        RegisterMarkets.Inputs memory reg = _registerInputs(d);
        reg.admin = deployer; // V2_ADMIN=<deployer> is what the driver exports for this step
        (uint256 registered, uint256 sent) = registerScript.runWith(reg, _signer(deployer));
        assertEq(registered, 2, "NVDA and TSLA registered in one direct run, no schedule, no warp");
        assertGt(sent, registered, "the oracle/feed/pool/route calls went with them");
        // A registered market carries its strike tick and its oracle; an unregistered one is all zero.
        assertEq(Clearinghouse(d.clearinghouse).market(address(nvda)).strikeTick, TICK_2_50, "NVDA registered on chain");
        assertEq(Clearinghouse(d.clearinghouse).market(address(tsla)).strikeTick, TICK_2_50, "TSLA registered on chain");
        assertEq(Clearinghouse(d.clearinghouse).market(address(nvda)).oracle, d.settlementOracle, "NVDA oracle set");
        // The Safe's delayed lanes are untouched: it still holds LISTING at the manifest delay.
        string memory json = deployScript.rolesJson();
        (bool safeListing, uint32 safeDelay) = mgr.hasRole(deployScript.roleIdOf(json, "LISTING"), adminSafe);
        assertTrue(safeListing && safeDelay == deployScript.roleDelayOf(json, "LISTING"), "the Safe path is intact");
        // And the window closes as designed: HandBack drops the working roles and ADMIN, VerifyV8 goes green.
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        handBackScript.handBackWith(in_, _signer(deployer));
        assertFalse(_holdsAnyRole(deployer), "after HandBack the deployer holds nothing");
        (, uint256 failed) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failed, 0, "VerifyV8 clean with the markets registered by the deployer");
    }

    /*//////////////////////////////////////////////////////////////
                    6. VERIFYV8 IS RED IN BETWEEN, GREEN AFTER
    //////////////////////////////////////////////////////////////*/

    /// @dev THE WHOLE LAUNCH SEQUENCE AS VERIFYV8 SEES IT: DeployV8(deferred) -> MapExternals -> RegisterMarkets
    ///      (deployer, direct) -> red while the deployer still holds ADMIN -> HandBack -> clean. The market checks
    ///      are green from the registration on, so the only thing standing between red and green at the end is
    ///      the hand-over group (SEC-38-R `_handover`, `_principals`, `_noSurplusMemberships`).
    function test_verify_redBetweenDeferredDeployAndHandBack_greenAfter() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        (, uint256 bareBefore) = _handoverFailures(d);
        assertGt(bareBefore, 0, "VerifyV8 is RED while the deployer holds ADMIN, markets aside (SEC-38-R _handover)");

        DeployV8.Inputs memory in_ = _followUpInputs(d);
        mapScript.mapWith(in_, _signer(deployer), _noSkip());
        RegisterMarkets.Inputs memory reg = _registerInputs(d);
        reg.admin = deployer;
        registerScript.runWith(reg, _signer(deployer));
        (uint256 totalMapped,) = _handoverFailures(d);
        assertGt(totalMapped, 0, "still RED after MapExternals + registration: the hand-back has not happened");

        handBackScript.handBackWith(in_, _signer(deployer));
        (uint256 passed, uint256 failedAfter) = verifyScript.check(_verifyInputs(d, true));
        assertEq(failedAfter, 0, "GREEN after HandBack: hand-over AND markets");
        assertGt(passed, 100, "VerifyV8 ran the whole walk");
    }

    /*//////////////////////////////////////////////////////////////
            4. T-OP-196: EVERY LAUNCH TICKER'S VAULT, IN THE WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @dev A second HouseVault double (the fixture's TSLA), pointed at the manager, gated on the manifest rows and
    ///      answering TSLA's identity -- exactly the shape a `createVault` for the second launch ticker leaves behind
    ///      on launch night: a real vault, recorded at `markets[].v2.houseVault`, with NOTHING mapped on it yet.
    function _secondVault(V2DeployBase.Contracts memory d) internal returns (address v) {
        MockExternalTarget m = new MockExternalTarget(MockExternalTarget.Kind.HouseVault);
        m.point(d.accessManager, address(0));
        m.setVaultIdentity(address(tsla), d.clearinghouse, d.orderBook, d.feeSplitter);
        v = address(m);
        _gate(v, "HouseVault");
    }

    function _two(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }

    function _slots(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @dev THE RUN-4c LINE. Two launch vaults: NVDA's is the manifest's `HouseVault` (mapped by step 3, planned once
    ///      more to nothing), TSLA's is a second instance that step 3 never saw. `mapWith` maps it with the manifest's
    ///      HouseVault block -- exactly `targetSigs("HouseVault").length` calls, read from the manifest, never typed --
    ///      and VerifyV8's per-vault walk is green for BOTH tickers after RegisterMarkets + HandBack. The positive
    ///      control is the same walk BEFORE the mapping: the second vault's slot fails, so the green after is the
    ///      mapping's doing and not the walk looking away.
    function test_mapExternals_mapsEveryLaunchTickersVault_verifyPerVaultWalkGreen() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        address second = _secondVault(d);
        assertTrue(_fullyMapped("HouseVault", houseVault), "NVDA's vault: mapped by step 3 (the manifest target)");
        assertFalse(_fullyMapped("HouseVault", second), "TSLA's vault: a second instance, unmapped after the deploy");

        DeployV8.Inputs memory in_ = _followUpInputs(d);
        (uint256 mapped, string[] memory supplied,) =
            mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), _slots(houseVault, second));
        string memory json = deployScript.rolesJson();
        uint256 block_ = deployScript.targetSigs(json, "HouseVault").length;
        assertEq(mapped, block_, "exactly one HouseVault block was sent: the second vault's (the first planned to nothing)");
        assertEq(block_, 15, "the manifest's HouseVault block is 15 selectors at this base (the read-back count rises by this per vault)");
        assertEq(supplied.length, 6, "the six manifest externals are still the manifest loop's");
        assertTrue(_fullyMapped("HouseVault", second), "TSLA's vault carries every HouseVault selector at its manifest role");
        assertTrue(_fullyMapped("HouseVault", houseVault), "NVDA's vault is untouched");
        assertEq(mapScript.vaultTickersMapped(0), "NVDA");
        assertEq(mapScript.vaultTickersMapped(1), "TSLA");

        // Idempotent: the same call plans nothing for either vault.
        (uint256 again,,) = mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), _slots(houseVault, second));
        assertEq(again, 0, "second run: both vaults already mapped, nothing sent");

        // The whole sequence, as VerifyV8 sees it, with both slots supplied: register (deployer, direct), hand back,
        // walk. Positive control first: the walk with the second slot supplied BUT the mapping undone is red on it.
        RegisterMarkets.Inputs memory reg = _registerInputs(d);
        reg.admin = deployer;
        registerScript.runWith(reg, _signer(deployer));
        handBackScript.handBackWith(in_, _signer(deployer));
        VerifyV8.Inputs memory v = _verifyInputs(d, true);
        v.marketVaults = _slots(houseVault, second);
        (uint256 passed, uint256 failed) = verifyScript.check(v);
        assertEq(failed, 0, "GREEN: hand-over, markets, and BOTH per-ticker vault walks (run 4c's two FAILs are gone)");
        assertGt(passed, 100, "the whole walk ran");
    }

    /// @dev The positive control for the test above, isolated: a second vault that is SUPPLIED to VerifyV8 but never
    ///      mapped makes the per-vault walk red by ticker -- the exact two FAIL lines of run 4c. MapExternals without
    ///      the per-ticker slots (the pre-T-OP-196 call) leaves it that way.
    function test_verify_secondVaultUnmapped_isRedByTicker_theRun4cShape() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        MockExternalTarget(houseVault).setVaultIdentity(address(nvda), d.clearinghouse, d.orderBook, d.feeSplitter);
        address second = _secondVault(d);
        DeployV8.Inputs memory in_ = _followUpInputs(d);
        mapScript.mapWith(in_, _signer(deployer), _noSkip()); // the old shape: manifest externals only
        RegisterMarkets.Inputs memory reg = _registerInputs(d);
        reg.admin = deployer;
        registerScript.runWith(reg, _signer(deployer));
        handBackScript.handBackWith(in_, _signer(deployer));
        VerifyV8.Inputs memory v = _verifyInputs(d, true);
        v.marketVaults = _slots(houseVault, address(0));
        (, uint256 oneVault) = verifyScript.check(v);
        assertEq(oneVault, 0, "one supplied vault, one null slot: green (the null is NOT CHECKED, not a failure)");
        v.marketVaults = _slots(houseVault, second);
        (, uint256 unmapped) = verifyScript.check(v);
        assertGt(unmapped, 0, "the second vault supplied but unmapped: the per-vault walk is RED (run 4c)");
        assertFalse(_fullyMapped("HouseVault", second), "and it is indeed unmapped");
    }

    /// @dev One ticker's slot unset: skipped BY TICKER, the other still mapped; a code-less slot and two tickers on
    ///      one vault are refused by name; the first launch ticker's vault (== V2_HOUSE_VAULT) is planned once.
    function test_mapExternals_nullSlotSkippedByTicker_badSlotsRefused() public {
        V2DeployBase.Contracts memory d = _deployDeferred();
        address second = _secondVault(d);
        DeployV8.Inputs memory in_ = _followUpInputs(d);

        // NVDA supplied (the manifest vault), TSLA's slot null.
        (uint256 mapped,,) = mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), _slots(houseVault, address(0)));
        assertEq(mapped, 0, "the manifest vault was already mapped by step 3; the null slot maps nothing");
        assertEq(mapScript.vaultTickersMapped(0), "NVDA", "NVDA planned (to nothing: it is V2_HOUSE_VAULT)");
        assertEq(mapScript.vaultTickersSkipped(0), "TSLA", "TSLA skipped by ticker");
        assertFalse(_fullyMapped("HouseVault", second), "nothing was mapped onto the unsupplied second vault");

        // A slot that names an address with no code is refused by ticker.
        vm.expectRevert(
            bytes(
                string.concat("houseVault TSLA ", vm.toString(address(0xBEEF)), " has no code: markets[].v2.houseVault names nothing deployed")
            )
        );
        mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), _slots(houseVault, address(0xBEEF)));

        // Two tickers on one vault: refused (one vault per ticker, VerifyV8's rule).
        vm.expectRevert(
            bytes(string.concat("houseVault TSLA ", vm.toString(houseVault), " is also market NVDA's vault: one vault per ticker"))
        );
        mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), _slots(houseVault, houseVault));

        // Slot count must match the ticker count.
        vm.expectRevert(bytes("MapExternals: one vault slot per ticker"));
        mapScript.mapWith(in_, _signer(deployer), _noSkip(), _two("NVDA", "TSLA"), new address[](1));
    }

    /// @dev The env reader is VerifyV8's: V2_TICKERS and V2_MARKET_<T>_HOUSE_VAULT, unset = zero.
    function test_mapExternals_marketVaultsFromEnv_readsTheDriversProjection() public {
        vm.setEnv("V2_TICKERS", "NVDA,TSLA");
        vm.setEnv("V2_MARKET_NVDA_HOUSE_VAULT", vm.toString(houseVault));
        (string[] memory tickers, address[] memory vaults) = mapScript.marketVaultsFromEnv();
        assertEq(tickers.length, 2);
        assertEq(tickers[0], "NVDA");
        assertEq(tickers[1], "TSLA");
        assertEq(vaults[0], houseVault, "NVDA's slot read from V2_MARKET_NVDA_HOUSE_VAULT");
        assertEq(vaults[1], address(0), "TSLA's slot unset reads zero (VerifyV8's rule)");
        vm.setEnv("V2_TICKERS", "");
        (tickers, vaults) = mapScript.marketVaultsFromEnv();
        assertEq(tickers.length, 0, "no V2_TICKERS: no per-ticker pass");
    }
}
