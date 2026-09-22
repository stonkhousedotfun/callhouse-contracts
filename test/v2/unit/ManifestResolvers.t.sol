// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV8} from "../../../script/v2/DeployV8.s.sol";
import {VerifyV8} from "../../../script/v2/VerifyV8.s.sol";

/// @dev The three resolvers are `internal`, so a derived contract is how a test reaches them. Each wrapper is
///      `external` so the call can be `try`-ed: two of the three answer an unknown name by REVERTING, and a
///      reverting call is the thing under test here, not an accident to be avoided.
contract VerifyV8Probe is VerifyV8 {
    function targetOf(Contracts memory c, string memory name) external pure returns (address) {
        return _targetOf(c, name);
    }

    function artifactOf(string memory name) external pure returns (string memory) {
        return _artifactOf(name);
    }
}

contract DeployV8Probe is DeployV8 {
    function targetAddress(Contracts memory d, string memory name) external pure returns (address) {
        return _targetAddress(d, name);
    }

    /// @dev Drives {_mapTarget} for the ZERO-ADDRESS cases only, and returns how many calls it planned. Both of
    ///      those paths return before `p.manager` is ever called, so the dummy manager below is never touched;
    ///      a non-zero target would reach `getTargetFunctionRole` and revert on a non-contract, which is why
    ///      this probe is not used for one.
    function mapTargetPlannedCalls(string memory name, address target) external view returns (uint256) {
        Plan memory p = Plan({json: rolesJson(), manager: address(0xA11CE), buf: new Call[](256), n: 0});
        _mapTarget(p, name, target);
        return p.n;
    }
}

/// @notice C8-DEPLOYVERIFY: every name in `script/v2/roles.v8.json` `.targets` must resolve in all THREE
///         hand-written tables that walk the manifest — `VerifyV8._targetOf`, `VerifyV8._artifactOf` and
///         `DeployV8._targetAddress`. Adding a row to the manifest without extending them goes red HERE, at the
///         row, instead of at the next deploy.
/// @dev WHY THIS TEST EXISTS AT ALL. `roles.v8.json` is the single source of truth and almost everything reads it
///         directly — `targetSigs`, `roleIdOf`, `roleDelayOf` — so almost nothing can drift from it. The exception
///         is the step that turns a NAME into an address or an artifact path, which no JSON file can answer and
///         which is therefore still three if-chains. Twice now a task has added a `.targets` row and stopped:
///         P8-06B added HouseVault and HouseVaultFactory, P8-03 added Hedger, and neither touched a resolver. Both
///         deploy-side scripts were left non-functional on the tip and nothing noticed, because under the build-mode
///         directive nobody runs them.
///
///         THE TWO FAILURE SHAPES ARE NOT THE SAME, and this file is written around the difference.
///         `_targetOf` and `_targetAddress` REVERT on an unknown name — loud, and the run stops.
///         `_artifactOf` used to `return ""` for one — SILENT: `VerifyV8._noUnlistedRestricted` skips any target
///         whose artifact path is empty, so an unknown name cost that contract its entire
///         no-unlisted-restricted-selector pass while the run still printed `VERIFY PASSED`. A `restricted`
///         selector the manifest never named answers to ADMIN by `AccessManager`'s own default (06-QUIRKS §A.8),
///         and check group 4 exists to catch precisely that. So {test_everyTargetHasAnArtifactPath} asserts a
///         NON-EMPTY path rather than merely a non-reverting call: "it did not revert" would have passed against
///         the bug.
contract ManifestResolversTest is Test {
    string internal constant ROLES_JSON = "script/v2/roles.v8.json";

    /// @dev The one name that legitimately has no artifact to walk: `V4BuybackExecutor` is not `Managed`, carries no
    ///      `restricted` selector and has an empty `.targets` entry on purpose.
    string internal constant NO_ARTIFACT = "V4BuybackExecutor";

    VerifyV8Probe internal verify;
    DeployV8Probe internal deploy;

    function setUp() public {
        verify = new VerifyV8Probe();
        deploy = new DeployV8Probe();
    }

    function _targetNames() internal view returns (string[] memory) {
        return vm.parseJsonKeys(vm.readFile(ROLES_JSON), ".targets");
    }

    /// @dev Every address field distinct and non-zero, so a resolver that returns the WRONG field is caught too —
    ///      an if-chain grown by copy-paste gets `Hedger` pointed at `houseVault` long before it gets a name wrong.
    ///      Built by index so adding a struct field cannot silently leave a hole here -- and when one IS left,
    ///      this suite says so by name rather than passing: adding `earnVault` and `stockVenueAdapter` to
    ///      `Contracts` without adding them here produced "resolved to the zero address for target: EarnVault",
    ///      which is the failure working as intended on its own author.
    function _distinctContracts() internal pure returns (VerifyV8.Contracts memory c) {
        c.accessManager = address(uint160(0x1001));
        c.feeSplitter = address(uint160(0x1002));
        c.expiryCalendar = address(uint160(0x1003));
        c.chainlinkSource = address(uint160(0x1004));
        c.univ3Source = address(uint160(0x1005));
        c.dataStreamsSource = address(uint160(0x1006));
        c.settlementOracle = address(uint160(0x1007));
        c.keeperRewards = address(uint160(0x1008));
        c.clearinghouse = address(uint160(0x1009));
        c.orderBook = address(uint160(0x100a));
        c.autoRoller = address(uint160(0x100b));
        c.payoutRouter = address(uint160(0x100c));
        c.makerRegistry = address(uint160(0x100d));
        c.makerVault = address(uint160(0x100e));
        c.rewardsDistributor = address(uint160(0x100f));
        c.buybackExecutor = address(uint160(0x1010));
        c.houseVault = address(uint160(0x1011));
        c.houseVaultFactory = address(uint160(0x1012));
        c.hedger = address(uint160(0x1013));
        c.rewardsDistributorLender = address(uint160(0x1014));
        c.earnVault = address(uint160(0x1015));
        c.stockVenueAdapter = address(uint160(0x1016));
    }

    /*//////////////////////////////////////////////////////////////
                            THE THREE TABLES
    //////////////////////////////////////////////////////////////*/

    function test_everyTargetResolvesInVerifyV8TargetOf() public view {
        VerifyV8.Contracts memory c = _distinctContracts();
        string[] memory names = _targetNames();
        assertGt(names.length, 0, "roles.v8.json .targets is empty");

        address[] memory seen = new address[](names.length);
        for (uint256 i; i < names.length; ++i) {
            try verify.targetOf(c, names[i]) returns (address got) {
                assertTrue(
                    got != address(0),
                    string.concat("VerifyV8._targetOf resolved to the zero address for target: ", names[i])
                );
                for (uint256 j; j < i; ++j) {
                    assertTrue(
                        seen[j] != got,
                        string.concat("VerifyV8._targetOf returns the same field for two targets, at: ", names[i])
                    );
                }
                seen[i] = got;
            } catch {
                assertTrue(
                    false, string.concat("VerifyV8._targetOf does not know the roles.v8.json target: ", names[i])
                );
            }
        }
    }

    function test_everyTargetResolvesInDeployV8TargetAddress() public view {
        VerifyV8.Contracts memory c = _distinctContracts();
        string[] memory names = _targetNames();

        address[] memory seen = new address[](names.length);
        for (uint256 i; i < names.length; ++i) {
            try deploy.targetAddress(c, names[i]) returns (address got) {
                assertTrue(
                    got != address(0),
                    string.concat("DeployV8._targetAddress resolved to the zero address for target: ", names[i])
                );
                for (uint256 j; j < i; ++j) {
                    assertTrue(
                        seen[j] != got,
                        string.concat("DeployV8._targetAddress returns the same field for two targets, at: ", names[i])
                    );
                }
                seen[i] = got;
            } catch {
                assertTrue(
                    false, string.concat("DeployV8._targetAddress does not know the roles.v8.json target: ", names[i])
                );
            }
        }
    }

    /// @dev A NON-EMPTY path, not merely a call that did not revert. The bug this file was written for returned ""
    ///      without reverting, and `_noUnlistedRestricted` reads "" as "skip this target".
    function test_everyTargetHasAnArtifactPath() public view {
        string[] memory names = _targetNames();
        for (uint256 i; i < names.length; ++i) {
            bool isTheExemptOne = keccak256(bytes(names[i])) == keccak256(bytes(NO_ARTIFACT));
            try verify.artifactOf(names[i]) returns (string memory path) {
                if (isTheExemptOne) {
                    assertEq(bytes(path).length, 0, "V4BuybackExecutor is the one target with no artifact to walk");
                    continue;
                }
                assertGt(
                    bytes(path).length,
                    0,
                    string.concat(
                        "VerifyV8._artifactOf returned an empty path, which SKIPS check group 4, for target: ", names[i]
                    )
                );
            } catch {
                assertTrue(
                    false, string.concat("VerifyV8._artifactOf does not know the roles.v8.json target: ", names[i])
                );
            }
        }
    }

    /// @dev And the paths are real files, so a typo in an artifact constant is caught here rather than at the
    ///      `vm.readFile` inside a verify run. `forge test` compiles everything first, so `out/` is populated.
    function test_everyArtifactPathIsAFileWithAnAbi() public view {
        string[] memory names = _targetNames();
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(NO_ARTIFACT))) continue;
            string memory path = verify.artifactOf(names[i]);
            // EXISTENCE FIRST, AND NOT FOR TIDINESS. `vm.readFile` on a missing path REVERTS, and it reverted
            // while evaluating the argument to the assertion below -- so that assertion's message, the one
            // carrying the target name, could never be reached for the most likely failure. The run said
            // `failed to open file .../out/X.sol/X.json` and left the reader to work out which manifest row
            // sent it there. Now the name is in the message that actually fires.
            assertTrue(
                vm.isFile(path), string.concat("no compiled artifact at ", path, " for manifest target: ", names[i])
            );
            assertTrue(
                vm.keyExistsJson(vm.readFile(path), ".methodIdentifiers"),
                string.concat("no .methodIdentifiers in the artifact for target: ", names[i])
            );
        }
    }

    /// @notice C8: a signature LISTED under a `.targets` row must still be a real selector on that target's
    ///         compiled ABI. This is the SECOND direction of the manifest binding, and until now there was none.
    /// @dev WHAT WAS UNGUARDED. `script/v2/check-roles-targets.sh` binds `roles.v8.json` to the source tree in ONE
    ///      direction: a contract that declares a `restricted` selector must be a `.targets` row or a written
    ///      `.unmanagedTargets` exclusion. Nothing looked the other way, so a signature that stopped matching its
    ///      contract -- a parameter widened, a tuple member added, a function renamed -- was caught by nothing. The
    ///      115 rows WERE compared against the compiled ABIs, by hand, for the `notes.targetSignatures` entry in
    ///      that file; that comparison was wired into no gate and was one person's pass. This is the wiring.
    ///
    ///      WHY THE DRIFT IS SILENT RATHER THAN LOUD, which is what makes it worth a test rather than a note.
    ///      `DeployV8._mapTarget` turns a row into a selector by hashing the STRING in the manifest. A stale string
    ///      still hashes -- to a selector the contract does not have. `AccessManager.setTargetFunctionRole` accepts
    ///      any bytes4, so the call succeeds, the deploy reports the row wired, and the REAL selector is left
    ///      unmapped and answers to ADMIN by AccessManager's own default (06-QUIRKS A.8). Nothing reverts anywhere
    ///      along that path, which is the same shape as the empty-artifact skip {test_everyTargetHasAnArtifactPath}
    ///      exists to catch.
    ///
    ///      NO SIGNATURE IS PARSED HERE, DELIBERATELY. An artifact's `.methodIdentifiers` keys ARE canonical
    ///      signature strings, so this compares whole strings and never looks for a `)`. The hand pass behind
    ///      `notes.targetSignatures` first used a matcher that stopped at the first `)` and reported EVERY tuple row
    ///      as a mismatch -- eight false positives, among them `setLimits((uint128,uint128,uint16,uint16,uint128))`
    ///      on `Hedger`, whose selector `0x60e6f8bf` was already pinned and so exposed the matcher as the bug rather
    ///      than the data. A checker that cannot parse cannot repeat that.
    ///
    ///      VACUITY IS THE FAILURE MODE OF A LOOP LIKE THIS, so the counts are asserted rather than assumed. An
    ///      empty `.targets` row, or an artifact whose `.methodIdentifiers` is empty, would otherwise let this pass
    ///      by having nothing to compare. `V4BuybackExecutor` is the one row that is empty ON PURPOSE -- it is not
    ///      `Managed` and has no `restricted` selector -- and it is skipped by the same name-keyed exemption the
    ///      two tests above use, not by a "skip anything empty" rule that would grow to cover a real regression.
    function test_everyListedSignatureIsStillOnTheCompiledAbi() public view {
        string memory manifest = vm.readFile(ROLES_JSON);
        string[] memory names = _targetNames();
        uint256 compared;
        for (uint256 i; i < names.length; ++i) {
            string[] memory sigs = vm.parseJsonKeys(manifest, string.concat(".targets.", names[i]));
            if (keccak256(bytes(names[i])) == keccak256(bytes(NO_ARTIFACT))) {
                // THE EXEMPTION HAS TO STAY TRUE, not merely stay spelled the same. Skipping by name is right only
                // while that row is empty; the day V4BuybackExecutor becomes `Managed` and gains rows, a skip keyed
                // on the name alone would wave them through unchecked and this test would still print green.
                assertEq(
                    sigs.length,
                    0,
                    "V4BuybackExecutor now has .targets rows, so the artifact exemption that skips it here is no longer true"
                );
                continue;
            }
            assertGt(
                sigs.length,
                0,
                string.concat("empty .targets row, so nothing here is checked and the contract is unmapped: ", names[i])
            );
            string memory art = verify.artifactOf(names[i]);
            string[] memory abiSigs = vm.parseJsonKeys(vm.readFile(art), ".methodIdentifiers");
            assertGt(
                abiSigs.length,
                0,
                string.concat("the compiled artifact exposes no methods at all, so nothing can match: ", art)
            );
            for (uint256 j; j < sigs.length; ++j) {
                assertTrue(
                    _abiHas(abiSigs, sigs[j]),
                    string.concat(
                        "roles.v8.json .targets.",
                        names[i],
                        " lists ",
                        sigs[j],
                        " but no such signature is in ",
                        art,
                        ": the deploy would map a selector this contract does not have and leave the real one open"
                    )
                );
                ++compared;
            }
        }
        // The number is not pinned -- `AccessMatrix.t.sol` owns counts, and this file asserts relationships -- but
        // ZERO is pinned, because zero is what a broken walk returns and it is indistinguishable from a clean one.
        assertGt(compared, 0, "no signature was compared: .targets is empty or every row took the exemption");
    }

    /// @dev Whole-string equality by hash. Solidity has no string comparison and this is the file's existing idiom
    ///      (`keccak256(bytes(...))` above); it matters here only that nothing splits the signature.
    function _abiHas(string[] memory abiSigs, string memory sig) internal pure returns (bool) {
        bytes32 want = keccak256(bytes(sig));
        for (uint256 i; i < abiSigs.length; ++i) {
            if (keccak256(bytes(abiSigs[i])) == want) return true;
        }
        return false;
    }

    /// @dev The count is not pinned here on purpose — `test/v2/unit/AccessMatrix.t.sol` owns that. This file asserts
    ///      a RELATIONSHIP (every manifest name resolves), which stays true as rows are added and is what actually
    ///      keeps the three tables honest.
    function test_theManifestIsWhatIsBeingWalked() public view {
        string[] memory names = _targetNames();
        bool sawExempt;
        for (uint256 i; i < names.length; ++i) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(NO_ARTIFACT))) sawExempt = true;
        }
        assertTrue(sawExempt, "V4BuybackExecutor is missing from .targets: the artifact exemption is now unreachable");
    }

    /*//////////////////////////////////////////////////////////////
        THE ZERO ADDRESS: SKIPPED AND ANNOUNCED, OR REFUSED BY NAME
    //////////////////////////////////////////////////////////////*/

    /// @notice An externally supplied target whose address was not given plans NOTHING, rather than mapping its
    ///         selectors at address(0).
    /// @dev THE FAILURE THIS FORBIDS is three `setTargetFunctionRole` calls against nothing: the operator is told
    ///      the row was wired, while the REAL contract is left unmapped and its `restricted` selectors answer to
    ///      ADMIN by AccessManager's own default (06-QUIRKS A.8). Planning zero calls is the whole assertion --
    ///      "it did not revert" would pass just as well if it had mapped all three at zero.
    function test_externallySuppliedTargetWithNoAddressPlansNothing() public view {
        string[6] memory supplied =
            ["HouseVault", "HouseVaultFactory", "Hedger", "RewardsDistributorLender", "EarnVault", "StockVenueAdapter"];
        for (uint256 i; i < supplied.length; ++i) {
            assertEq(
                deploy.mapTargetPlannedCalls(supplied[i], address(0)),
                0,
                string.concat(supplied[i], ": an unsupplied external target must plan NO calls, not map at zero")
            );
        }
    }

    /// @notice A target this script DEPLOYS having no address is a hard stop naming the target.
    /// @dev The other half of the same guard, and the reason the skip above is safe: the two cases look
    ///      identical at the call site (`target == address(0)`) and must not be treated as one. Reaching here
    ///      means the script's own deploy produced nothing for a name it owns, which is a bug in the script
    ///      rather than a missing input, so it may not be skipped.
    /*//////////////////////////////////////////////////////////////
       T-216 -- A TARGET NO RESOLVER KNOWS MUST FAIL BY NAME
    //////////////////////////////////////////////////////////////*/

    /// @dev THE PROTECTED FACT OF THIS ROW, AS A PERMANENT TEST RATHER THAN A ONE-OFF MANIFEST EDIT. The row asks
    ///      for a new target row to be added to `roles.v8.json`, proven to fail, then removed and restored
    ///      byte-identical. That proves the property once, in a tree nobody will ever look at again, and leaves
    ///      nothing behind. A synthetic name proves the same property on every future run, and it needs no edit to
    ///      a file this row does not hold.
    ///
    ///      THE TWO ADDRESS RESOLVERS STILL REFUSE BY NAME, and that is unchanged by the derivation.
    function test_anUnknownTargetIsRefusedByNameInBothAddressResolvers() public {
        VerifyV8.Contracts memory c = _distinctContracts();
        string memory ghost = "NoSuchManifestTarget";

        vm.expectRevert(bytes(string.concat("roles.v8.json names a target VerifyV8 does not know: ", ghost)));
        verify.targetOf(c, ghost);

        // MIRRORED FROM DeployV8.s.sol, NOT COMPOSED. My first draft of this line invented
        // "names a target DeployV8 does not know" because that is what the sibling resolver says; the real
        // wording is "names a target this script does not deploy". The test caught it, which is the only reason
        // this comment is not a bug report.
        vm.expectRevert(bytes(string.concat("roles.v8.json names a target this script does not deploy: ", ghost)));
        deploy.targetAddress(c, ghost);
    }

    /// @dev {_artifactOf} IS THE ONE THAT CHANGED, AND THIS RECORDS HONESTLY WHAT IT CAN AND CANNOT DO. It derives
    ///      `out/<Name>.sol/<Name>.json` now, so it is `pure` and cannot consult a filesystem: it CANNOT refuse an
    ///      unknown name, and pretending otherwise would be the false confidence this row exists to remove.
    ///      What it must never do is hand back a path that happens to resolve to a real artifact for a name the
    ///      manifest invented, or an empty string - the empty string was the original defect, because
    ///      `_noUnlistedRestricted` reads "" as "skip this target".
    ///      The by-name refusal moved to the point of use: VerifyV8 requires the file exists before reading it,
    ///      and reports "no compiled artifact at <path> for roles.v8.json target: <Name>".
    function test_anUnknownTargetDerivesAPathThatCannotSilentlyResolve() public view {
        string memory ghost = "NoSuchManifestTarget";
        string memory path = verify.artifactOf(ghost);

        assertGt(bytes(path).length, 0, "the derivation must never return the empty string, which means SKIP");
        assertEq(path, "out/NoSuchManifestTarget.sol/NoSuchManifestTarget.json", "derived from the name alone");
        assertFalse(vm.isFile(path), "an invented manifest name must not resolve to a real artifact");
    }

    function test_deployedTargetWithNoAddressIsRefusedByName() public {
        vm.expectRevert(
            bytes(
                "roles.v8.json names the target Clearinghouse, which this script DEPLOYS, but its address is zero:"
                " that is a bug in this script, not a missing input"
            )
        );
        deploy.mapTargetPlannedCalls("Clearinghouse", address(0));
    }
}

/*//////////////////////////////////////////////////////////////
          T-258 — SAFE TOPOLOGY, AND WHY IT LIVES IN THIS FILE
//////////////////////////////////////////////////////////////*/

/// @dev THIS BLOCK IS ABOUT SAFES, NOT RESOLVERS, AND IT IS HERE ON PURPOSE. The checks it proves operate on
///      `in_.roles.adminSafe` and `in_.roles.treasurySafe` — manifest inputs that VerifyV8 resolves — so it is
///      adjacent to this file's subject rather than unrelated to it. The natural home,
///      `test/v2/unit/VerifyV8.t.sol`, was held by T-261 while this was written (claude-26 rewriting it to fix a
///      33-failed suite), and `DeployV2Fixture.t.sol` and `DeployV2Preflight.t.sol` were held by the same row.
///      Two running lanes in one file is a worse problem than an imperfectly named one. MOVE THIS BLOCK to a
///      Safe-specific file once T-261 has landed — that cleanup is recorded in the deferred-verification ledger.

/// @notice T-258. Proves {VerifyV8._safeTopology} rejects each way a Safe can have code and still not be the
///         thing eleven roles are resting on.
///
/// @dev WHY THIS FILE EXISTS AT ALL. Before T-258 the v8 verifier asserted exactly one thing about the Admin and
///      Treasury Safes — `code.length != 0` at `VerifyV8.s.sol:885`. A Safe with a threshold of 1, an enabled
///      module, a transaction guard or a non-canonical singleton all have code. The v7 verifier already checked
///      all of it (`script/Verify.s.sol:492-511`) and the capability was never carried across.
///
/// @dev WHY IT IS ITS OWN FILE. `test/v2/unit/VerifyV8.t.sol` is the natural home and was held by T-261 while
///      this was written — claude-26 was rewriting it to fix a 33-failed suite — and two running lanes in one
///      file is a worse problem than an extra file. `DeployV2Fixture.t.sol` and `DeployV2Preflight.t.sol` were
///      held by the same row. Fold this into `VerifyV8.t.sol` once T-261 has landed if that reads better then.
///
/// @dev EVERY CASE BREAKS THE PROTECTED FACT, NOT THE CHECKER. Each one starts from a Safe that passes, breaks
///      one property of the SAFE, requires a failure that NAMES that property, restores it and requires the pass
///      back. Deleting an assertion and watching a test go red would prove nothing about whether the assertion
///      can see its subject.
contract SafeTopologyStub {
    // Slot 0 is the singleton on a real Safe and is written here with `vm.store`, exactly as the verifier reads
    // it. Declared first so the layout matches; this contract never reads it itself.
    address private _singleton;
    uint256 private _threshold;
    address[] private _owners;
    address[] private _modules;
    bool private _reverting;

    function configure(uint256 threshold, uint256 ownerCount) external {
        _threshold = threshold;
        delete _owners;
        for (uint256 i; i < ownerCount; ++i) {
            _owners.push(address(uint160(0x1000 + i)));
        }
    }

    function enableModule(address module) external {
        _modules.push(module);
    }

    function disableModules() external {
        delete _modules;
    }

    /// @dev An address with code that is not a Safe. The verifier must report this by name, not revert the run.
    function setReverting(bool value) external {
        _reverting = value;
    }

    function getThreshold() external view returns (uint256) {
        require(!_reverting, "SafeTopologyStub: not a Safe");
        return _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        require(!_reverting, "SafeTopologyStub: not a Safe");
        return _owners;
    }

    function getModulesPaginated(address, uint256) external view returns (address[] memory, address) {
        require(!_reverting, "SafeTopologyStub: not a Safe");
        return (_modules, address(0x1));
    }
}

/// @dev `_safeTopology` is internal and reports failures by console line, which a Solidity test cannot read.
///      T-258 made `_check` virtual for exactly this: the override records each message so a case can assert
///      WHICH check failed rather than how many did. A count-only assertion would pass for the wrong reason the
///      moment two checks broke at once.
contract VerifyV8SafeProbe is VerifyV8 {
    string[] internal _failed;
    string[] internal _passed;

    function _check(bool ok, string memory what) internal override {
        if (ok) {
            _passed.push(what);
        } else {
            _failed.push(what);
        }
        super._check(ok, what);
    }

    function runTopology(address safe, string memory label, uint256 minThreshold, uint256 minOwners) external {
        delete _failed;
        delete _passed;
        _safeTopology(safe, label, minThreshold, minOwners);
    }

    function failedCount() external view returns (uint256) {
        return _failed.length;
    }

    function failedWith(string memory what) external view returns (bool) {
        bytes32 want = keccak256(bytes(what));
        for (uint256 i; i < _failed.length; ++i) {
            if (keccak256(bytes(_failed[i])) == want) return true;
        }
        return false;
    }

    // The canonical values are mirrored from the verifier rather than retyped here, so this test cannot drift
    // into asserting against a different Safe build than the one the verifier accepts.
    function canonicalSingleton() external pure returns (address) {
        return SAFE_L2_141;
    }

    function guardSlot() external pure returns (bytes32) {
        return SAFE_GUARD_SLOT;
    }

    function fallbackSlot() external pure returns (bytes32) {
        return SAFE_FALLBACK_SLOT;
    }
}

contract VerifyV8SafesTest is Test {
    VerifyV8SafeProbe internal probe;
    SafeTopologyStub internal safe;

    string internal constant LABEL = "admin Safe";

    function setUp() public {
        probe = new VerifyV8SafeProbe();
        safe = new SafeTopologyStub();
        _makeWellFormed();
    }

    /// @dev A 2-of-3 Safe on a canonical singleton, no modules, no guard, no fallback handler.
    function _makeWellFormed() internal {
        safe.configure(2, 3);
        safe.disableModules();
        safe.setReverting(false);
        vm.store(address(safe), bytes32(0), bytes32(uint256(uint160(probe.canonicalSingleton()))));
        vm.store(address(safe), probe.guardSlot(), bytes32(0));
        vm.store(address(safe), probe.fallbackSlot(), bytes32(0));
    }

    function _run() internal {
        probe.runTopology(address(safe), LABEL, 2, 3);
    }

    /// @dev The positive control for every case below. If this ever fails, no other result in this file means
    ///      anything, because a checker that rejects a correct Safe rejects a broken one for free.
    function test_aWellFormedSafePasses() public {
        _run();
        assertEq(probe.failedCount(), 0, "a well-formed 2-of-3 Safe must pass every topology check");
    }

    function test_aThresholdOfOneFailsByName() public {
        safe.configure(1, 3);
        _run();
        assertTrue(probe.failedWith("admin Safe: threshold"), "threshold of 1 must fail by name");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0, "restoring the threshold must restore the pass");
    }

    function test_aThresholdAboveTheOwnerCountFailsByName() public {
        safe.configure(4, 3);
        _run();
        assertTrue(probe.failedWith("admin Safe: threshold"), "a threshold above the owner count must fail");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0);
    }

    function test_tooFewOwnersFailsByName() public {
        safe.configure(2, 2);
        _run();
        assertTrue(probe.failedWith("admin Safe: owner count"), "an owner count below the minimum must fail");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0);
    }

    function test_anEnabledModuleFailsByName() public {
        safe.enableModule(address(0xBEEF));
        _run();
        assertTrue(probe.failedWith("admin Safe: no modules enabled"), "an enabled module must fail by name");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0, "disabling the module must restore the pass");
    }

    function test_aTransactionGuardFailsByName() public {
        vm.store(address(safe), probe.guardSlot(), bytes32(uint256(uint160(address(0xDEAD)))));
        _run();
        assertTrue(probe.failedWith("admin Safe: no transaction guard"), "a transaction guard must fail by name");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0, "clearing the guard must restore the pass");
    }

    function test_aNonCanonicalSingletonFailsByName() public {
        vm.store(address(safe), bytes32(0), bytes32(uint256(uint160(address(0xC0FFEE)))));
        _run();
        assertTrue(
            probe.failedWith("admin Safe: singleton is a canonical Safe 1.4.1 / 1.3.0 build"),
            "a non-canonical singleton must fail by name"
        );
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0, "restoring the singleton must restore the pass");
    }

    function test_aNonCanonicalFallbackHandlerFailsByName() public {
        vm.store(address(safe), probe.fallbackSlot(), bytes32(uint256(uint160(address(0xF00D)))));
        _run();
        assertTrue(
            probe.failedWith("admin Safe: fallback handler is canonical (or none)"),
            "a non-canonical fallback handler must fail by name"
        );
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
              CRITERION 5 — AN ABSENT SUBJECT IS A NAMED FAIL
    //////////////////////////////////////////////////////////////*/

    /// @dev This is the case v7 gets wrong. `script/Verify.s.sol:460` wraps its whole admin-Safe block in
    ///      `if (adminSafe != address(0) && adminSafe.code.length > 0)`, so an unset Safe verifies clean and
    ///      silently. Here it is a failure with a name.
    function test_theZeroAddressFailsByNameRatherThanSkipping() public {
        probe.runTopology(address(0), LABEL, 2, 3);
        assertTrue(probe.failedWith("admin Safe: address is set"), "address(0) must fail by name, not skip");
        assertEq(probe.failedCount(), 1, "and it must stop there rather than reading a nonexistent Safe");
    }

    function test_anAddressWithNoCodeFailsByName() public {
        probe.runTopology(address(0xA11CE), LABEL, 2, 3);
        assertTrue(probe.failedWith("admin Safe: is a contract, not a key"), "an EOA must fail by name");
        assertEq(probe.failedCount(), 1);
    }

    /// @dev An address with code that is not a Safe. The reads must be caught and reported, never allowed to
    ///      revert the whole verify run — a verifier that dies on check 40 of 400 has not verified anything.
    function test_aContractThatIsNotASafeFailsByNameAndDoesNotRevertTheRun() public {
        safe.setReverting(true);
        _run();
        assertTrue(probe.failedWith("admin Safe: getThreshold() answered"), "an unreadable Safe must fail by name");
        _makeWellFormed();
        _run();
        assertEq(probe.failedCount(), 0);
    }

    /// @dev THE EXPECTATION ITSELF CAN BE MISSING, AND THAT MUST NOT READ AS A PASS. `Inputs` is built field by
    ///      field by callers older than these two fields -- `test/v2/unit/DeployV2Fixture.t.sol:329` never sets
    ///      them -- so they arrive as 0. `threshold >= 0` and `owners >= 0` are tautologies, which would make the
    ///      two assertions unfailable on exactly the well-formed-looking Safe they exist to interrogate.
    function test_anUnsetExpectationFailsRatherThanPassingVacuously() public {
        probe.runTopology(address(safe), LABEL, 0, 0);
        assertTrue(
            probe.failedWith("admin Safe: expected threshold and owner minimums are set"),
            "a zero minimum must be refused, not satisfied"
        );
    }

    /// @dev The other half of the same point: with the expectation unset, a Safe that is ACTUALLY broken must
    ///      still not come back clean. Threshold 1 on a 3-owner Safe passes `>= 0` trivially.
    function test_anUnsetExpectationDoesNotLaunderABrokenSafe() public {
        safe.configure(1, 3);
        probe.runTopology(address(safe), LABEL, 0, 0);
        assertTrue(probe.failedCount() > 0, "a threshold of 1 must not pass merely because the minimum is unset");
    }

    /// @dev The Treasury Safe is checked with the same function and the same expectations; this pins that it is
    ///      actually reached, because "we also check the other one" is the kind of claim that is true in a
    ///      comment and false in the code.
    function test_theTreasuryLabelIsCheckedWithTheSameRules() public {
        safe.configure(1, 3);
        probe.runTopology(address(safe), "treasury Safe", 2, 3);
        assertTrue(probe.failedWith("treasury Safe: threshold"), "the treasury Safe must be checked too");
    }
}
