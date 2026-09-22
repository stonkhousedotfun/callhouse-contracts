// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {IMakerRegistry} from "../../src/v2/interfaces/IMakerRegistry.sol";
import {AutoRoller} from "../../src/v2/AutoRoller.sol";
import {Clearinghouse} from "../../src/v2/Clearinghouse.sol";
import {KeeperRewards} from "../../src/v2/KeeperRewards.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {OrderBook} from "../../src/v2/OrderBook.sol";
import {MakerVault} from "../../src/v2/mm/MakerVault.sol";
import {ChainlinkFeedSource} from "../../src/v2/oracle/ChainlinkFeedSource.sol";
import {SettlementOracle} from "../../src/v2/oracle/SettlementOracle.sol";
import {FeeSplitter} from "../../src/v2/periphery/FeeSplitter.sol";
import {PayoutRouter} from "../../src/v2/periphery/PayoutRouter.sol";
import {V4BuybackConfig} from "../../src/v2/periphery/V4BuybackExecutor.sol";
import {IUniV3SwapRouter02} from "../../src/v2/periphery/PayoutDeps.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @notice Deploys the Stonkhouse INTERFACE_VERSION 8 contract set on chain 4663 and hands it over: one OpenZeppelin
///         `AccessManager` and the fifteen other contracts of this script's deploy set, none of which hold roles
///         of their own, every selector mapped from
///         `script/v2/roles.v8.json`, every role granted to the Safe or bot key the manifest names, and the deployer
///         holding nothing at all when the run ends. Markets are NOT registered here:
///         `script/v2/RegisterMarkets.s.sol` does that, one market at a time.
/// @dev Driven by `script/v2/DeployV2Batch.sh`, which reads the registry with jq and exports the `V2_*` environment
///      (lib/V2DeployBase.sol lists it). By hand:
///        DEPLOYER_PK=... V2_ADMIN_SAFE=0x... V2_TREASURY_SAFE=0x... <the rest of V2_*> \
///          forge script script/v2/DeployV8.s.sol --rpc-url $RH_RPC --broadcast --slow --no-storage-caching \
///          --non-interactive
///      Add `--verify --verifier sourcify --chain 4663` only when the explorer credential is configured;
///      the batch handles source publication separately from its read-only on-chain check.
///
///      ONE SIGNER. v7 had two (DEPLOYER_PK created, ADMIN_PK wired, because every constructor granted
///      DEFAULT_ADMIN_ROLE to V2_ADMIN). v8 has one: the deployer is the manager's initial ADMIN, maps the selectors,
///      grants ITSELF the working roles at delay 0, wires, grants the real holders, sets the role tree and renounces.
///      `ADMIN_PK` is not read here at all. With no key the script broadcasts from `V2_DEPLOYER`, which only a node
///      with that account unlocked accepts (`--unlocked --sender`, the batch's --rehearse).
///
///      WHY THE ORDER IS WHAT IT IS -- the single most expensive thing to get wrong in this file.
///      `AccessManager.canCall` (lib/openzeppelin-contracts/contracts/access/manager/AccessManager.sol:140-160)
///      resolves `roleId = getTargetFunctionRole(target, selector)` and then `hasRole(roleId, caller)`. It special
///      cases only `setAuthority`. ADMIN therefore has NO implicit access to any target function: a deployer holding
///      nothing but ADMIN cannot send `clearinghouse.setMinter(...)`, not directly and not through `manager.execute`,
///      which runs the same check. The order below is the one that works:
///        1. `AccessManager(deployer)` -- deployer is initial ADMIN at delay 0.
///        2. the other fifteen contracts, each taking the manager as `authority`.
///        3. `setTargetFunctionRole` for EVERY signature in the manifest (`_pendingMapping`).
///        4. the deployer grants ITSELF every role that appears as a value in `.targets`, at delay 0
///           (`_pendingSelfGrants`). This works only while `_roles[roleId].admin` is still 0 -- see 7.
///        5. every pointer and parameter call, sent DIRECTLY to its target (`_pendingWiring`).
///        6. `grantRole(role, holder, delaysS[role])` for every pair in `.holders` (`_pendingHolders`).
///        7. `setRoleAdmin` and `setRoleGuardian` (`_pendingRoleTree`). AFTER 4 AND 6: `_getAdminRestrictions`
///           (AccessManager.sol:657-662) routes grantRole/revokeRole through `getRoleAdmin(roleId)`, so once
///           GUARDIAN / PRICER / QUOTER / BUYBACK are parented to OPS_ADMIN a bare `grantRole(GUARDIAN, ...)` from an
///           ADMIN-only deployer reverts `AccessManagerUnauthorizedAccount(deployer, OPS_ADMIN)`.
///           test/v2/lib/V8Access.sol:84-95 documents the same trap and works around it; this script sidesteps it by
///           ordering instead.
///        8. the deployer drops its own transient memberships, and
///        9. renounces ADMIN. Last call of the batch (`_pendingHandBack`).
///
///      RESUME. Any V2_<CONTRACT> address in the environment is used instead of deploying that contract (it must have
///      code and link to the others). The batch passes the registry's recorded addresses with --resume, so a run that
///      died half way deploys only what is missing and sends only the steps still missing. A run that already reached
///      step 9 cannot be resumed by the deployer at all -- it holds nothing -- and the script says so rather than
///      reverting deep inside the manager.
///
///      CHECK MODE. V2_WIRING_CHECK=true sends nothing: every contract must be given, and the script reverts naming
///      each call a hand-over pass would still send ("hand-over incomplete").
///
///      DEFERRED HAND-BACK (T-OP-153, owner decision 2026-09-22 05:35Z: no 48 h Safe gap at launch). The six
///      manifest targets this script does not deploy (`_externallySupplied`) are created by their own scripts AFTER
///      this one, so on launch day their selectors cannot be mapped here -- and once step 9 has run, mapping them
///      means scheduling `setTargetFunctionRole` through the Admin Safe's 172800 s ADMIN lane. The owner chose to
///      extend the deployer's ADMIN window across the externals instead:
///        V2_DEFER_HANDBACK=true   steps 1-7 run exactly as above; steps 8 AND 9 (the transient drops and
///                                 `renounceRole(ADMIN, deployer)`) are NOT sent (amendment #1, owner 05:50Z). The
///                                 run ends with the deployer holding ADMIN and every `.targets` role at delay 0,
///                                 prints exactly that, and names the scripts that finish the job.
///        externals                deployed by their own scripts (T-OP-116's driver), addresses exported as V2_*.
///        MapExternals.s.sol       maps every SUPPLIED external's selectors at delay 0 from the deployer's ADMIN,
///                                 through THIS file's `_mapTarget` (no second selector loop). Refuses after step 9.
///        RegisterMarkets.s.sol    run by the DEPLOYER (V2_ADMIN=<deployer>, ADMIN_PK its key, V2_SCHEDULE unset):
///                                 it holds LISTING and CONFIG_ADMIN at delay 0 from step 4, so `_signerCanList`
///                                 needs no schedule and `_executeScheduled` sends every call directly (no 1 h /
///                                 24 h wait). `createVault` (HouseVaultFactory, LISTING) runs in the same window
///                                 by the same rule (T-OP-141). The Safe path is untouched for post-launch.
///        HandBack.s.sol           the deferred steps 8 + 9: `_pendingHandBack` for whatever the deployer holds --
///                                 the transient roles first, ADMIN last -- with `_assertAdminSafeCanTakeOver`
///                                 first; idempotent. Last call before VerifyV8.
///        VerifyV8                 unchanged: `_handover` (SEC-38-R) FAILS until HandBack has run.
///      ACCEPTED COST, stated by the coordinator and accepted by the owner: the deployer hot key holds ADMIN and the
///      delay-0 working roles for the minutes between this script and HandBack, across several transactions; a
///      driver that dies in between leaves it holding them until HandBack runs, and VerifyV8 stays red until then.
///      The default (unset / false) keeps the atomic behaviour above byte-for-byte; the deferral is never the
///      default. On a RESUME with the flag set, a complete set whose deployer still holds ADMIN is reported as
///      "complete set, hand-back pending" and nothing is sent; without the flag the same set gets its hand-back
///      sent, as before.
///
///      OUTPUT. `V2_ADDRESS <registry key> <address>` log lines, plus two OPTIONAL JSON artifacts, deliberately
///      separate (T-456), each written only when its env var names a path under ./broadcast:
///        V2_DEPLOY_OUT         {toJson} -- ADDRESSES ONLY, shaped like the registry's `v2.contracts` plus
///                              `v2.flywheel`. `script/v2/DeployV2Batch.sh` sets it and refuses any top-level key
///                              that is not an address or one of the two known groups.
///        V2_DEPLOY_RECORD_OUT  {toDeploymentRecord} -- the write-back record: the same addresses plus
///                              `deployBlock`, `safes`, `wallets` and `bots`. This is the `--deployment` file
///                              `ops/markets/write-back-v8.mjs` (callhouse) reads.
///      Both are written while forge runs the script, BEFORE it broadcasts; the batch checks each address has code
///      before it records it.
/// @notice The three Safe reads {DeployV8._assertAdminSafeIsARealSafe} needs.
/// @dev DECLARED HERE, NOT IMPORTED, for the same reason `VerifyV8.s.sol:144` declares an identical one: importing
///      either of the other two scripts would compile it as a dependency of this one. The signatures are Safe's,
///      fixed by the deployed singleton, and a local declaration cannot drift from something it does not own.
interface ISafeTopology {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 pageSize) external view returns (address[] memory, address);
}

/// @dev The number of FeeSplitter pointers {DeployV8._splitterCalls} wires, and the reason it is a named constant
///      rather than five loose calls. T-222 recorded the gap: `VerifyV8._flywheelSubjects` is a hand-sized list of
///      five that mirrors THIS list by hand, so a sixth pointer added here would ship unverified while the verifier
///      still printed "all 5 flywheel pointers are wired". The pointers below are built into a FIXED-SIZE array of
///      this length, so adding one is a compile error until this constant grows -- and
///      `VerifyV8.t.sol:test_flywheelPointerCountsAgree` then fails until `VERIFY_V8_FLYWHEEL_POINTERS` grows with
///      it. Neither file can drift silently from the other any more.
uint256 constant DEPLOY_V8_SPLITTER_POINTERS = 5;

contract DeployV8 is V2DeployBase {
    struct Inputs {
        Roles roles;
        External ext;
        Params params;
        Flywheel flywheel;
        uint32[] holidays;
        Contracts existing;
        uint256 expectChainId;
        /// @dev T-OP-153. True: steps 1-7 only, steps 8-9 left to `HandBack.s.sol`. Read from V2_DEFER_HANDBACK, default false.
        bool deferHandBack;
    }

    /// @notice What one run did: contracts created, calls sent, calls skipped because the chain already held them.
    struct Outcome {
        uint256 created;
        uint256 sent;
        uint256 skipped;
    }

    /// @notice The two start blocks the write-back record carries, `deployBlock` (the core) and
    ///         `flywheel.deployBlock`. ZERO means this run cannot vouch for one, and {toDeploymentRecord} writes it
    ///         as JSON null. See {recordBlocks}.
    struct RecordBlocks {
        uint256 core;
        uint256 flywheel;
    }

    /// @notice One batch under construction: the manifest, the manager it is sent to, and the buffer being filled.
    /// @dev It exists for a compiler reason, and it is worth stating so nobody "simplifies" it back. Planning a
    ///      batch means holding the manifest string, a list of manifest keys, a second list per key, the call
    ///      buffer, the running count and two loop indexes at the same time; via-IR cannot lay that many live
    ///      memory pointers out in one frame and fails the build with "too deep in the stack". Bundling the four
    ///      that every planner needs into ONE pointer buys back the room, and splitting the loops into helpers does
    ///      not, because the optimiser inlines them straight back.
    struct Plan {
        string json;
        address manager;
        Call[] buf;
        uint256 n;
    }

    /*//////////////////////////////////////////////////////////////
                                  ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external virtual returns (Contracts memory d) {
        Inputs memory in_ = inputsFromEnv();
        Signer memory deployer = _deployerFromEnv(in_);
        in_.roles.deployer = deployer.addr;
        require(
            block.chainid == in_.expectChainId,
            string.concat("chain id ", vm.toString(block.chainid), ", expected ", vm.toString(in_.expectChainId))
        );
        _logInputs(in_);

        Outcome memory o;
        // Left at zero in check mode, which creates nothing and so can vouch for no block.
        RecordBlocks memory blocks;
        if (vm.envOr("V2_WIRING_CHECK", false)) {
            preflight(in_);
            d = in_.existing;
            uint256 pending = checkWiring(in_);
            require(pending == 0, string.concat("hand-over incomplete: ", vm.toString(pending), " call(s) pending"));
            // T-OP-166 F4 / T-OP-171. Under V2_DEFER_HANDBACK the count above excludes steps 8-9 on purpose
            // ({checkWiring}), so "complete" would be false: the deployer still holds ADMIN until HandBack.s.sol.
            console2.log(
                in_.deferHandBack
                    ? "HAND-BACK DEFERRED: deployer holds ADMIN until HandBack.s.sol (V2_DEFER_HANDBACK=true); nothing else to send"
                    : "HAND-OVER COMPLETE: nothing to send"
            );
        } else {
            // T-456. READ BEFORE `runWith`, NOT AFTER. `_deploy` does `d = in_.existing`, which is a memory ALIAS,
            // so once it has run `in_.existing` holds every address and a contract that was given can no longer be
            // told from one created here.
            blocks = recordBlocks(in_.existing);
            (d, o) = runWith(in_, deployer);
            console2.log("");
            console2.log(
                string.concat(
                    "DEPLOY DONE: ",
                    vm.toString(o.created),
                    " contract(s) created, ",
                    vm.toString(o.sent),
                    " call(s) sent, ",
                    vm.toString(o.skipped),
                    " already in place"
                )
            );
        }
        _logAddresses(d);
        string memory out = vm.envOr("V2_DEPLOY_OUT", string(""));
        if (bytes(out).length != 0) {
            vm.writeFile(out, toJson(d));
            console2.log("addresses written to", out);
        }
        // T-456. TWO ARTIFACTS, NOT ONE. The address file above has a consumer that refuses a non-string top-level
        // key (`DeployV2Batch.sh` `mined_addresses()`), so the write-back's own fields go to their own path. Both
        // are optional and independent: a run that sets neither writes neither, and the log lines say which.
        string memory recordOut = vm.envOr("V2_DEPLOY_RECORD_OUT", string(""));
        if (bytes(recordOut).length != 0) {
            vm.writeFile(recordOut, toDeploymentRecord(in_.roles, d, blocks));
            console2.log("write-back record written to", recordOut);
        }
    }

    /// @notice Deploy what `in_.existing` lacks, then send the six hand-over batches in order.
    /// @dev Each batch is PLANNED after the previous one was sent, because each reads the state the previous wrote:
    ///      the self-grants of step 4 are what make the wiring of step 5 authorised, and the role tree of step 7 is
    ///      what makes a bare `grantRole` from the deployer stop working, so step 6 has to be behind it.
    function runWith(Inputs memory in_, Signer memory deployer) public returns (Contracts memory d, Outcome memory o) {
        preflight(in_);
        (d, o.created) = _deploy(in_, deployer);
        _linkage(in_, d);

        // The five batches are PLANNED first and SENT after, in the documented order. Planning them together is
        // safe because none of them reads what another writes -- the mapping is per (target, selector), the wiring
        // is per target pointer, the grants are per (role, holder) and the tree is per role -- and it is what makes
        // the emptiness test below possible before anything is sent.
        Call[] memory maps = _pendingMapping(d);
        Call[] memory selfGrants = _pendingSelfGrants(d, deployer.addr);
        (Call[] memory wiring, uint256 skipped) = _pendingWiring(in_, d);
        Call[] memory holders = _pendingHolders(in_, d);
        Call[] memory tree = _pendingRoleTree(d);
        o.skipped = skipped;

        // T-182 / F-SCRIPTS-05. THE HAND-BACK IS PART OF THE EMPTINESS TEST, and leaving it out is what made a
        // half-finished set unrepairable. A run that died AFTER the role-tree batch and BEFORE the hand-back
        // leaves all four sums at zero while the deployer still holds ADMIN -- so the re-run took the branch
        // below, printed "hand-over already complete: nothing to send", sent nothing, and then reverted in
        // {_postCheck} on "the deployer still holds a role". For ever: every subsequent re-run did the same.
        //
        // IT IS ASKED INSIDE THE BRANCH, NOT IN THE CONDITION, and that placement is load-bearing.
        // {_pendingHandBack} calls {_assertAdminSafeCanTakeOver} when the deployer holds ADMIN, and on a FRESH
        // deploy the Admin Safe does not hold ADMIN yet -- step 6 (`holders`) is what grants it. Adding this
        // call to the `if` evaluated it before that batch was sent and killed every fresh run on "REFUSING TO
        // RENOUNCE ADMIN". Here the four sums are already known to be zero, so nothing is left to grant and the
        // Safe either can take over or the run must stop.
        if (maps.length + wiring.length + holders.length + tree.length == 0) {
            Call[] memory handBack = _pendingHandBack(in_, d, deployer.addr);
            if (handBack.length == 0) {
                // A COMPLETE SET. The deployer renounced everything at the end of the run that built it, so there
                // is nothing it could send even if it wanted to -- and the transient self-grants of step 4 would
                // be the first thing to revert. "Nothing to do" is honest and keeps a re-run idempotent.
                _skip("hand-over already complete: nothing to send");
            } else if (in_.deferHandBack) {
                // T-OP-153. A COMPLETE SET WHOSE HAND-BACK IS PENDING BY REQUEST. This is the deferred deployment
                // seen again -- by the batch's wiring check, by a --resume, by a driver that re-runs the deploy
                // step after a death -- and it is NOT a partial run to redo: the four batches above are empty and
                // the deployer is meant to keep what it holds until HandBack.s.sol, the only script that sends
                // steps 8 and 9.
                _skip("complete set, hand-back pending by request (V2_DEFER_HANDBACK=true): HandBack.s.sol sends it");
            } else {
                o.sent += _send(deployer, handBack, "hand back");
            }
        } else {
            o.sent += _send(deployer, maps, "map selectors");
            o.sent += _send(deployer, selfGrants, "deployer self-grants (transient)");
            o.sent += _send(deployer, wiring, "wiring");
            o.sent += _send(deployer, holders, "grant roles to their holders");
            o.sent += _send(deployer, tree, "role admins and guardians");
            if (in_.deferHandBack) {
                // T-OP-153 (amendment #1). Steps 8 and 9 are HandBack.s.sol's: the deployer keeps ADMIN for
                // MapExternals.s.sol and the delay-0 working roles for RegisterMarkets.s.sol.
                _skip("hand back: DEFERRED by request (V2_DEFER_HANDBACK=true); HandBack.s.sol sends steps 8 and 9");
            } else {
                // Planned only now: it renounces whatever the deployer actually ended up holding.
                o.sent += _send(deployer, _pendingHandBack(in_, d, deployer.addr), "hand back");
            }
        }

        // T-OP-153. Which post-check applies is decided by what the chain says the deployer holds, not by the flag
        // alone: a deferred run that sees a set ALREADY handed back (re-run after HandBack.s.sol) is a complete
        // hand-over and is checked as one; a deferred run that withheld the renounce is checked as deferred.
        (bool stillAdmin,) = AccessManager(d.accessManager).hasRole(roleIdOf(rolesJson(), "ADMIN"), deployer.addr);
        if (in_.deferHandBack && stillAdmin) _postCheckDeferred(in_, d, deployer.addr);
        else _postCheck(in_, d, deployer.addr);
    }

    /// @notice The number of hand-over calls a pass would still send to the complete set `in_.existing`. Read-only.
    /// @dev The deployer's transient self-grants are deliberately NOT counted: on a finished set the deployer holds
    ///      nothing, which is the goal, not a gap. {_postCheck} is what asserts that.
    /// @dev T-182 / F-SCRIPTS-05. The hand-back IS counted, for the same reason the emptiness test in {runWith}
    ///      counts it: a deployer that has not renounced is the one outstanding hand-over call that the four
    ///      batches below cannot represent, and `--check` reporting 0 pending for that set is the answer that
    ///      sends an operator away from a deployment nothing can finish.
    function checkWiring(Inputs memory in_) public view returns (uint256 pending) {
        Contracts memory c = in_.existing;
        // T-182 / F-SCRIPTS-05. The hand-back count below asks `hasRole(role, in_.roles.deployer)`, and
        // `hasRole(role, address(0))` is FALSE for every role -- so an unset deployer would count zero pending
        // hand-back calls and report a half-finished set as complete. `run()` cannot reach here with a zero
        // deployer ({preflight} calls `_nonZero(r.deployer, "V2_DEPLOYER")` first), but this entry is public and
        // a direct caller can. Refusing is the difference between "nothing pending" and "nothing asked".
        require(in_.roles.deployer != address(0), "checkWiring needs V2_DEPLOYER: the hand-back count is about it");
        _wholeSet(c);
        _linkage(in_, c);
        (Call[] memory wiring,) = _pendingWiring(in_, c);
        // T-OP-153. With the hand-back deferred by request, steps 8 and 9 are not pending calls of THIS script:
        // they are HandBack.s.sol's, and they are announced below, one per line, so a check still says out loud
        // exactly what the deployer holds. Without the flag the hand-back counts, as F-SCRIPTS-05 requires.
        Call[][5] memory batches = [
            _pendingMapping(c),
            wiring,
            _pendingHolders(in_, c),
            _pendingRoleTree(c),
            in_.deferHandBack ? new Call[](0) : _pendingHandBack(in_, c, in_.roles.deployer)
        ];
        for (uint256 b; b < batches.length; ++b) {
            for (uint256 i; i < batches[b].length; ++i) {
                console2.log(string.concat("  PENDING  ", batches[b][i].what));
            }
            pending += batches[b].length;
        }
        if (in_.deferHandBack) {
            Call[] memory deferred = _pendingHandBack(in_, c, in_.roles.deployer);
            for (uint256 i; i < deferred.length; ++i) {
                console2.log(string.concat("  DEFERRED ", deferred[i].what, " -- HandBack.s.sol sends it"));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  INPUTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The signer: DEPLOYER_PK if given, else the unlocked V2_DEPLOYER address. Shared with the two T-OP-153
    ///      scripts so all three resolve the deployer the same way.
    ///      A key and an explicit V2_DEPLOYER that disagree is the v7 `ADMIN_PK is not V2_ADMIN's key` mistake in its
    ///      v8 shape, and it is worse here: the address in the environment is the one the preflight checks for
    ///      distinctness and the one VerifyV8 later proves holds nothing, while the key is the one that actually
    ///      becomes the manager's initial ADMIN.
    function _deployerFromEnv(Inputs memory in_) internal view returns (Signer memory deployer) {
        uint256 deployerPk = vm.envOr("DEPLOYER_PK", uint256(0));
        deployer = deployerPk != 0 ? Signer(deployerPk, vm.addr(deployerPk)) : Signer(0, in_.roles.deployer);
        require(
            in_.roles.deployer == address(0) || in_.roles.deployer == deployer.addr,
            string.concat(
                "DEPLOYER_PK is not V2_DEPLOYER's key: it signs as ",
                vm.toString(deployer.addr),
                ", V2_DEPLOYER is ",
                vm.toString(in_.roles.deployer)
            )
        );
    }

    function inputsFromEnv() public view returns (Inputs memory in_) {
        in_.roles = rolesFromEnv();
        in_.ext = externalFromEnv();
        in_.params = paramsFromEnv();
        in_.flywheel = flywheelFromEnv();
        in_.holidays = holidaysFromEnv();
        in_.existing = contractsFromEnv();
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
        in_.deferHandBack = deferHandBackFromEnv();
    }

    /// @notice T-OP-153. Whether this run withholds step 9. FALSE UNLESS THE ENVIRONMENT SAYS `true`: the deferral is
    ///         an operator's explicit request for launch day, never the default, and `DeployV8HandBack.t.sol` pins
    ///         that an unset variable reads false.
    function deferHandBackFromEnv() public view returns (bool) {
        return vm.envOr("V2_DEFER_HANDBACK", false);
    }

    /*//////////////////////////////////////////////////////////////
                                PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /// @notice Refuses inputs the contracts would accept but the launch must not: each line prints `ok` as it passes and
    ///         the first failure reverts with the values involved, before anything is created or sent.
    function preflight(Inputs memory in_) public view {
        console2.log("preflight (deploy)");
        _principals(in_.roles, in_.expectChainId);
        _externals(in_.ext);

        require(in_.holidays.length != 0, "V2_HOLIDAYS is empty");
        for (uint256 i = 1; i < in_.holidays.length; ++i) {
            require(in_.holidays[i] > in_.holidays[i - 1], "V2_HOLIDAYS must be strictly increasing day indexes");
        }
        _ok(string.concat("holidays: ", vm.toString(in_.holidays.length), " increasing day indexes"));

        _paramCeilings(in_.params);
        _flywheelCeilings(in_.flywheel);
        // On a RESUME the splitter is given, so the fee recipient can be compared here, before anything is created.
        // On a fresh run it cannot be, and {_deploy} makes the same comparison the moment the splitter exists.
        require(
            in_.roles.feeRecipient == address(0) || in_.existing.feeSplitter == address(0)
                || in_.roles.feeRecipient == in_.existing.feeSplitter,
            "V2_FEE_RECIPIENT is not V2_FEE_SPLITTER"
        );
        _existing(in_.existing);
        console2.log("preflight OK");
    }

    /// @dev The seven principals of INTERFACE_VERSION 8, plus the fee recipient.
    ///      v7 required five distinct addresses and only WARNED when the admin was a plain key
    ///      (v7's deploy script, which no longer exists in this checkout). v8 REFUSES that on chain 4663: the whole
    ///      point of the AccessManager rollout is
    ///      that ADMIN is a 2-of-3 Safe with a 48 h execution delay, and an EOA there would keep every power the
    ///      manager centralises in one hot key. `code.length != 0` is the most a script can check -- it does not
    ///      prove the contract is a Safe, only that it is not a bare key.
    function _principals(Roles memory r, uint256 expectChainId) internal view {
        // V2_FEE_RECIPIENT is not an eighth principal: it IS the FeeSplitter this run deploys (registry
        // `shared.feeRecipient`). On a FRESH deploy nobody can know that address yet, so leaving it unset means
        // "whatever this run creates" and {_deploy} fills it in. On a RESUME the splitter is given and the two must
        // agree; {_linkage} makes the same comparison against the deployed set, which is the exact one.
        if (r.feeRecipient != address(0)) _ok(string.concat("V2_FEE_RECIPIENT given: ", vm.toString(r.feeRecipient)));
        _nonZero(r.adminSafe, "V2_ADMIN_SAFE");
        _nonZero(r.treasurySafe, "V2_TREASURY_SAFE");
        _nonZero(r.guardianKey, "V2_GUARDIAN");
        _nonZero(r.pricerKey, "V2_PRICER");
        _nonZero(r.quoterKey, "V2_MM_QUOTER");
        _nonZero(r.crankerKey, "V2_CRANKER");
        _nonZero(r.deployer, "V2_DEPLOYER");
        address[7] memory keys =
            [r.adminSafe, r.treasurySafe, r.guardianKey, r.pricerKey, r.quoterKey, r.crankerKey, r.deployer];
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                require(
                    keys[i] != keys[j],
                    "adminSafe, treasurySafe, guardian, pricer, quoter, cranker and deployer must be seven different addresses (a bot key never holds admin, treasury or deploy powers)"
                );
            }
        }
        _ok("adminSafe, treasurySafe, guardian, pricer, quoter, cranker, deployer: seven distinct non-zero addresses");
        if (expectChainId == CHAIN_ID_4663) {
            require(
                r.adminSafe.code.length != 0,
                "V2_ADMIN_SAFE has no code: on chain 4663 the ADMIN principal must be the Safe, not a plain key (it holds ADMIN, the five delayed lanes and OPS_ADMIN, which apply on every roles.v8.json target -- not only the sixteen this script creates)"
            );
            require(
                r.treasurySafe.code.length != 0,
                "V2_TREASURY_SAFE has no code: on chain 4663 the treasury must be the Safe, not a plain key (it is the only address KeeperRewards, MakerVault, RewardsDistributor and FeeSplitter can ever pay)"
            );
            _ok("adminSafe and treasurySafe both have code (Safes, not plain keys)");
        } else {
            _warn("not chain 4663: the Safe-has-code requirement is skipped (devnet, anvil or a rehearsal fork)");
        }
    }

    function _externals(External memory e) internal view {
        _code(e.usdg, "V2_USDG");
        string memory symbol = IERC20Metadata(e.usdg).symbol();
        require(
            _eq(symbol, "USDG"),
            string.concat(
                "usdg symbol mismatch: V2_USDG ", vm.toString(e.usdg), " is \"", symbol, "\", expected \"USDG\""
            )
        );
        require(IERC20Metadata(e.usdg).decimals() == 6, "usdg decimals != 6");
        _ok("usdg: symbol USDG, 6 decimals");

        _code(e.swapRouter02, "V2_SWAP_ROUTER02");
        address factory = IUniV3SwapRouter02(e.swapRouter02).factory();
        require(
            factory == e.univ3Factory,
            string.concat(
                "swapRouter02.factory() ",
                vm.toString(factory),
                " is not V2_UNIV3_FACTORY ",
                vm.toString(e.univ3Factory)
            )
        );
        _code(factory, "swapRouter02.factory()");
        _ok("swapRouter02 has code, its factory() is V2_UNIV3_FACTORY and has code");
        _code(e.dataStreamsVerifier, "V2_DATA_STREAMS_VERIFIER");
        _ok("Data Streams VerifierProxy has code (DataStreamsSource is deployed disabled)");
        _code(e.v4PoolManager, "V2_V4_POOL_MANAGER");
        _code(e.v4StateView, "V2_V4_STATE_VIEW");
        _ok("Uniswap v4 PoolManager and StateView have code");
    }

    function _paramCeilings(Params memory p) internal pure {
        _checkFees(p.fees);
        _ok("fee parameters under their compiled ceilings");
        require(
            p.payoutSlippageBps <= V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS,
            "V2_PAYOUT_SLIPPAGE_BPS above MAX_PAYOUT_SLIPPAGE_CEIL_BPS (300)"
        );
        _ok(string.concat("payout slippage ", vm.toString(p.payoutSlippageBps), " bps <= 300"));
        require(p.bountySnapshot <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_SNAPSHOT above MAX_BOUNTY (1000000)");
        require(p.bountyFinalize <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_FINALIZE above MAX_BOUNTY (1000000)");
        require(p.bountySettle <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_SETTLE above MAX_BOUNTY (1000000)");
        require(p.bountyRedeem <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_REDEEM above MAX_BOUNTY (1000000)");
        require(p.bountyRoll <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_ROLL above MAX_BOUNTY (1000000)");
        require(p.bountyCancelStale <= V2Constants.MAX_BOUNTY, "V2_BOUNTY_CANCEL_STALE above MAX_BOUNTY (1000000)");
        _ok("bounties <= MAX_BOUNTY (six actions from INTERFACE_VERSION 7)");
        if (p.dailyCap == 0) {
            _warn("V2_KEEPER_DAILY_CAP is 0: KeeperRewards will pay no bounty until FEE_MANAGER sets one");
        } else {
            _ok(string.concat("keeper daily cap ", vm.toString(p.dailyCap), " USDG base units"));
        }
        require(p.vaultLimits.maxSeriesUnits != 0, "V2_VAULT_MAX_SERIES_UNITS must be > 0");
        require(p.vaultLimits.maxTotalNotional != 0, "V2_VAULT_MAX_TOTAL_NOTIONAL must be > 0");
        require(p.vaultLimits.askToleranceBps <= V2Constants.BPS, "V2_VAULT_ASK_TOLERANCE_BPS above 10000");
        require(p.vaultLimits.maxBidBpsOfSpot <= V2Constants.BPS, "V2_VAULT_MAX_BID_BPS_OF_SPOT above 10000");
        // INTERFACE_VERSION 7 (c21): 0 is a spend freeze -- the quoter can unwind but cannot place a bid, take or
        // replace upwards. That is a deliberate incident lever (`setLimits`), never a deploy value.
        require(
            p.vaultLimits.maxDailyOutflow != 0,
            "V2_VAULT_MAX_DAILY_OUTFLOW must be > 0 (0 deploys the vault frozen: no bid, take or replace-up)"
        );
        _ok(
            string.concat(
                "maker vault limits: non-zero sizes, bps <= 10000, maxDailyOutflow ",
                vm.toString(uint256(p.vaultLimits.maxDailyOutflow)),
                " USDG base units per 24 h window"
            )
        );
        bytes memory uri = bytes(p.baseUri);
        require(uri.length != 0 && uri[uri.length - 1] == "/", "V2_BASE_URI must be non-empty and end with \"/\"");
        _ok(string.concat("base URI ", p.baseUri));
    }

    /// @dev The flywheel's own bounds. Each mirrors a compiled check so the refusal names the variable rather than
    ///      arriving as a bare `CeilingExceeded` from a constructor half way through the deploy.
    function _flywheelCeilings(Flywheel memory f) internal view {
        require(f.burnBps <= V2Constants.BPS, "V2_BURN_BPS above 10000");
        require(
            f.conversionSlippageBps <= V2Constants.MAX_PAYOUT_SLIPPAGE_CEIL_BPS,
            "V2_CONVERSION_SLIPPAGE_BPS above MAX_PAYOUT_SLIPPAGE_CEIL_BPS (300)"
        );
        _ok(string.concat("flywheel split: ", vm.toString(f.burnBps), " bps burned, the rest to the Treasury Safe"));
        _code(f.weth, "V2_WETH");
        _code(f.v3UsdgWethPool, "V2_BUYBACK_V3_POOL");
        // V4BuybackExecutor.sol:235 reverts UnsupportedAsset unless `currency0` is native ETH. Saying it here names
        // the variable; saying it there costs a deploy that already created fifteen contracts.
        require(
            f.poolKey.currency0 == address(0),
            "V2_TOKEN_POOL_CURRENCY0 must be native ETH (the zero address): the buyback's v4 leg spends ETH"
        );
        _code(f.poolKey.currency1, "V2_TOKEN_POOL_CURRENCY1 (the STONKHOUSE token)");
        _code(f.poolKey.hooks, "V2_TOKEN_POOL_HOOKS");
        require(f.minLiquidity != 0, "V2_BUYBACK_MIN_LIQUIDITY must be > 0 (0 would accept an empty v3 leg)");
        _ok("buyback venue: WETH, v3 USDG/WETH pool, v4 ETH/token key with a hook, all with code");
    }

    /// @dev Every address given for resume must hold code.
    function _existing(Contracts memory c) internal view {
        _codeIfSet(c.accessManager, "V2_ACCESS_MANAGER");
        _codeIfSet(c.feeSplitter, "V2_FEE_SPLITTER");
        _codeIfSet(c.expiryCalendar, "V2_EXPIRY_CALENDAR");
        _codeIfSet(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _codeIfSet(c.univ3Source, "V2_SOURCE_UNIV3");
        _codeIfSet(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _codeIfSet(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _codeIfSet(c.keeperRewards, "V2_KEEPER_REWARDS");
        _codeIfSet(c.clearinghouse, "V2_CLEARINGHOUSE");
        _codeIfSet(c.orderBook, "V2_ORDER_BOOK");
        _codeIfSet(c.autoRoller, "V2_AUTO_ROLLER");
        _codeIfSet(c.payoutRouter, "V2_PAYOUT_ROUTER");
        _codeIfSet(c.makerRegistry, "V2_MAKER_REGISTRY");
        _codeIfSet(c.makerVault, "V2_MAKER_VAULT");
        _codeIfSet(c.rewardsDistributor, "V2_REWARDS_DISTRIBUTOR");
        _codeIfSet(c.buybackExecutor, "V2_BUYBACK_EXECUTOR");
        _assertNoAliasedTargets(c);
        _assertSuppliedTargetsAreWhatTheirNameClaims(c);
    }

    /// @dev The check-mode variant: every one of the sixteen must be given AND have code.
    function _wholeSet(Contracts memory c) internal view {
        _code(c.accessManager, "V2_ACCESS_MANAGER");
        _code(c.feeSplitter, "V2_FEE_SPLITTER");
        _code(c.expiryCalendar, "V2_EXPIRY_CALENDAR");
        _code(c.chainlinkSource, "V2_SOURCE_CHAINLINK");
        _code(c.univ3Source, "V2_SOURCE_UNIV3");
        _code(c.dataStreamsSource, "V2_SOURCE_DATA_STREAMS");
        _code(c.settlementOracle, "V2_SETTLEMENT_ORACLE");
        _code(c.keeperRewards, "V2_KEEPER_REWARDS");
        _code(c.clearinghouse, "V2_CLEARINGHOUSE");
        _code(c.orderBook, "V2_ORDER_BOOK");
        _code(c.autoRoller, "V2_AUTO_ROLLER");
        _code(c.payoutRouter, "V2_PAYOUT_ROUTER");
        _code(c.makerRegistry, "V2_MAKER_REGISTRY");
        _code(c.makerVault, "V2_MAKER_VAULT");
        _code(c.rewardsDistributor, "V2_REWARDS_DISTRIBUTOR");
        _code(c.buybackExecutor, "V2_BUYBACK_EXECUTOR");
        _assertNoAliasedTargets(c);
        _assertSuppliedTargetsAreWhatTheirNameClaims(c);
    }

    function _codeIfSet(address a, string memory name) internal view {
        if (a == address(0)) return;
        require(a.code.length != 0, string.concat(name, " ", vm.toString(a), " has no code (resume)"));
        _skip(string.concat(name, " ", vm.toString(a), ": already deployed, reused"));
    }

    /*//////////////////////////////////////////////////////////////
                                  DEPLOY
    //////////////////////////////////////////////////////////////*/

    /// @dev The sixteen creates, in the order {V2DeployBase.Contracts} declares. Every `authority` argument is the
    ///      manager created in step 1, so no target ever holds a role of its own.
    function _deploy(Inputs memory in_, Signer memory deployer) internal returns (Contracts memory d, uint256 created) {
        d = in_.existing;
        _startBroadcast(deployer);
        if (d.accessManager == address(0)) {
            // The deployer is the INITIAL ADMIN at delay 0. That is the whole reason the rest of this script can send
            // anything at all, and step 9 is what takes it away again.
            d.accessManager = _create(ART_ACCESS_MANAGER, abi.encode(deployer.addr));
            ++created;
        }
        created += _deployCore(in_, d);
        created += _deployTrading(in_, d);
        created += _deployFlywheel(in_, d);
        vm.stopBroadcast();
    }

    /// @dev Splitter, calendar, the three price sources, the oracle and the keeper budget.
    function _deployCore(Inputs memory in_, Contracts memory d) internal returns (uint256 created) {
        address mgr = d.accessManager;
        address usdg = in_.ext.usdg;
        if (d.feeSplitter == address(0)) {
            // BEFORE the Clearinghouse: the splitter IS `feeRecipient_`, which the Clearinghouse constructor refuses
            // to leave zero (src/v2/Clearinghouse.sol:205).
            d.feeSplitter =
                _create(ART_FEE_SPLITTER, abi.encode(mgr, usdg, in_.roles.treasurySafe, in_.flywheel.burnBps));
            ++created;
        }
        // The fee recipient is settled HERE, before the two contracts that take it as a constructor argument, and
        // never guessed: a mismatch is refused rather than quietly overridden, because an operator who exported a
        // fee recipient meant something by it.
        require(
            in_.roles.feeRecipient == address(0) || in_.roles.feeRecipient == d.feeSplitter,
            string.concat(
                "V2_FEE_RECIPIENT ",
                vm.toString(in_.roles.feeRecipient),
                " is not the FeeSplitter of this set ",
                vm.toString(d.feeSplitter),
                ": every premium and taker fee would land where the flywheel cannot reach it"
            )
        );
        in_.roles.feeRecipient = d.feeSplitter;
        if (d.expiryCalendar == address(0)) {
            d.expiryCalendar = _create(ART_EXPIRY_CALENDAR, abi.encode(mgr, in_.holidays));
            ++created;
        }
        if (d.chainlinkSource == address(0)) {
            d.chainlinkSource = _create(ART_CHAINLINK_SOURCE, abi.encode(mgr));
            ++created;
        }
        if (d.univ3Source == address(0)) {
            d.univ3Source = _create(ART_UNIV3_SOURCE, abi.encode(mgr, usdg));
            ++created;
        }
        if (d.dataStreamsSource == address(0)) {
            d.dataStreamsSource = _create(ART_DATA_STREAMS_SOURCE, abi.encode(mgr, in_.ext.dataStreamsVerifier));
            ++created;
        }
        if (d.settlementOracle == address(0)) {
            // INTERFACE_VERSION 8: one argument. v7 took (admin, guardian) and granted GUARDIAN_ROLE in the
            // constructor; the guardian relationship lives on the manager now (src/v2/oracle/SettlementOracle.sol:267).
            d.settlementOracle = _create(ART_SETTLEMENT_ORACLE, abi.encode(mgr));
            ++created;
        }
        if (d.keeperRewards == address(0)) {
            // INTERFACE_VERSION 8 added `treasury_`: bounty money can only ever leave to the Treasury Safe
            // (src/v2/KeeperRewards.sol:121).
            d.keeperRewards = _create(ART_KEEPER_REWARDS, abi.encode(usdg, mgr, in_.roles.treasurySafe));
            ++created;
        }
    }

    /// @dev Clearinghouse, book, roller, payout router, maker registry, vault and the rewards distributor.
    function _deployTrading(Inputs memory in_, Contracts memory d) internal returns (uint256 created) {
        address mgr = d.accessManager;
        address usdg = in_.ext.usdg;
        if (d.clearinghouse == address(0)) {
            d.clearinghouse = _create(
                ART_CLEARINGHOUSE, abi.encode(mgr, usdg, d.expiryCalendar, in_.roles.feeRecipient, in_.params.baseUri)
            );
            ++created;
        }
        if (d.orderBook == address(0)) {
            // Four arguments, and the shape is taken from the COMPILED ARTIFACT the deploy creates from --
            // `out/OrderBook.sol/OrderBook.json` constructor inputs: (address clearinghouse_, address
            // authority_, address feeRecipient_, (uint16,uint16,uint128,uint16,uint16) fees) -- not from the
            // source text and not from a comment. A comment is what let the previous five-argument encode
            // survive C8-03: it asserted the book was still on v7 AccessControl and that only this `abi.encode`
            // had to change when C8-03 landed. C8-03 landed, the encode did not, and every later reader
            // believed the comment. The whole block is deleted rather than corrected, because the wiring detour
            // it described -- routing the book's admin calls through `manager.execute` so no EOA held
            // DEFAULT_ADMIN_ROLE -- is obsolete: the book is `Managed`, so the manager IS its authority and the
            // detour has nothing left to work around.
            d.orderBook =
                _create(ART_ORDER_BOOK, abi.encode(d.clearinghouse, mgr, in_.roles.feeRecipient, in_.params.fees));
            ++created;
        }
        if (d.autoRoller == address(0)) {
            d.autoRoller = _create(ART_AUTO_ROLLER, abi.encode(d.orderBook, mgr));
            ++created;
        }
        if (d.payoutRouter == address(0)) {
            d.payoutRouter = _create(
                ART_PAYOUT_ROUTER,
                abi.encode(mgr, usdg, in_.ext.swapRouter02, in_.ext.v4PoolManager, in_.ext.v4StateView)
            );
            ++created;
        }
        if (d.makerRegistry == address(0)) {
            d.makerRegistry = _create(ART_MAKER_REGISTRY, abi.encode(mgr));
            ++created;
        }
        if (d.makerVault == address(0)) {
            // INTERFACE_VERSION 8: `(book, authority, treasury, limits)`. v7's third argument was the quoter key; the
            // quoter is a manager role now and the third argument is the only address money can leave to
            // (src/v2/mm/MakerVault.sol:270).
            d.makerVault =
                _create(ART_MAKER_VAULT, abi.encode(d.orderBook, mgr, in_.roles.treasurySafe, in_.params.vaultLimits));
            ++created;
        }
        if (d.rewardsDistributor == address(0)) {
            d.rewardsDistributor = _create(ART_REWARDS_DISTRIBUTOR, abi.encode(usdg, mgr, in_.roles.treasurySafe));
            ++created;
        }
    }

    /// @dev The buyback executor, last: it pins the splitter and takes no admin at all, so nothing can be changed on
    ///      it afterwards (src/v2/periphery/V4BuybackExecutor.sol:233-234).
    function _deployFlywheel(Inputs memory in_, Contracts memory d) internal returns (uint256 created) {
        if (d.buybackExecutor != address(0)) return 0;
        Flywheel memory f = in_.flywheel;
        d.buybackExecutor = _create(
            ART_BUYBACK_EXECUTOR,
            abi.encode(
                V4BuybackConfig({
                    splitter: d.feeSplitter,
                    usdg: in_.ext.usdg,
                    weth: f.weth,
                    v3Pool: f.v3UsdgWethPool,
                    poolManager: in_.ext.v4PoolManager,
                    stateView: in_.ext.v4StateView,
                    key: f.poolKey,
                    maxTotalFeeBps: f.maxTotalFeeBps,
                    maxSlippageBps: f.maxSlippageBps,
                    twapWindow: f.twapWindow,
                    minLiquidity: f.minLiquidity
                })
            )
        );
        return 1;
    }

    /// @dev CREATE from the artifact's init code: the set is well over what a script contract holding it as `new`
    ///      expressions could itself be (98,304 B). forge records each as a CREATE from the broadcaster.
    ///
    ///      F-WIRE01-03. EVERY CONTRACT IN THIS SET IS DEPLOYED THROUGH HERE, AND NONE WITH `new <Contract>`.
    ///      A reader grepping this repository for `new Clearinghouse`, `new OrderBook` or any other member of the
    ///      set finds NOTHING and can reasonably conclude the contract is never deployed. It is: the constructor
    ///      arguments are ABI-encoded and appended to `vm.getCode(<artifact>)`, so the contract name appears only
    ///      as the artifact string passed to this function (the `ART_*` constants). Grep for `_create(ART_` to
    ///      find the deployment of anything in the set.
    function _create(string memory artifact, bytes memory args) internal returns (address a) {
        bytes memory initCode = abi.encodePacked(vm.getCode(artifact), args);
        assembly {
            a := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(a != address(0) && a.code.length != 0, string.concat("deploy failed: ", artifact));
    }

    /// @dev The immutable links between the contracts, for a set that mixes reused and new contracts.
    function _linkage(Inputs memory in_, Contracts memory d) internal view {
        require(Clearinghouse(d.clearinghouse).usdg() == in_.ext.usdg, "clearinghouse.usdg() is not V2_USDG");
        require(
            OrderBook(d.orderBook).clearinghouse() == d.clearinghouse,
            "orderBook.clearinghouse() is not the clearinghouse"
        );
        require(
            address(AutoRoller(d.autoRoller).orderBook()) == d.orderBook, "autoRoller.orderBook() is not the order book"
        );
        require(
            address(MakerVault(d.makerVault).orderBook()) == d.orderBook, "makerVault.orderBook() is not the order book"
        );
        require(address(KeeperRewards(d.keeperRewards).usdg()) == in_.ext.usdg, "keeperRewards.usdg() is not V2_USDG");
        // The fee recipient the registry names IS the splitter this run deploys or resumes. A mismatch would send
        // every premium and taker fee somewhere the flywheel cannot reach, and `FeeSplitter.claimOrderBookFees`
        // would quietly return 0 for ever. In check mode this is the only place it is compared, because nothing was
        // deployed to settle it against.
        require(
            in_.roles.feeRecipient == address(0) || in_.roles.feeRecipient == d.feeSplitter,
            string.concat(
                "V2_FEE_RECIPIENT ",
                vm.toString(in_.roles.feeRecipient),
                " is not the FeeSplitter of this set ",
                vm.toString(d.feeSplitter)
            )
        );
        require(
            Clearinghouse(d.clearinghouse).feeRecipient() == d.feeSplitter,
            "clearinghouse.feeRecipient() is not the FeeSplitter"
        );
        require(FeeSplitter(payable(d.feeSplitter)).usdg() == in_.ext.usdg, "feeSplitter.usdg() is not V2_USDG");
        require(PayoutRouter(payable(d.payoutRouter)).usdg() == in_.ext.usdg, "payoutRouter.usdg() is not V2_USDG");
        require(
            IBuybackExecutorView(d.buybackExecutor).splitter() == d.feeSplitter,
            "buybackExecutor.splitter() is not the FeeSplitter"
        );
        // THE BOOK'S CONSTRUCTOR ARGUMENTS, READ BACK OFF THE BOOK. This is the assertion that would have caught
        // C8-03. The encode in {_deploy} passed FIVE arguments to a constructor whose artifact declares FOUR
        // (`out/OrderBook.sol/OrderBook.json`: clearinghouse_, authority_, feeRecipient_, fees), and nothing
        // downstream compared the deployed book against what was meant to go in -- so the drift surfaced at
        // CREATE, on a live chain, as a bare revert with no argument in it.
        //
        // Comparing here makes the NEXT constructor change fail at planning instead: these two reads are the
        // last two arguments, and a book built with a shifted argument list cannot satisfy them by accident.
        require(
            OrderBook(d.orderBook).feeRecipient() == d.feeSplitter, "orderBook.feeRecipient() is not the FeeSplitter"
        );
        V2Types.FeeParams memory bookFees = OrderBook(d.orderBook).feeParams();
        require(
            bookFees.premiumFeeBps == in_.params.fees.premiumFeeBps
                && bookFees.resaleFeeBps == in_.params.fees.resaleFeeBps
                && bookFees.takerFeeFlat == in_.params.fees.takerFeeFlat
                && bookFees.takerFeeCapBps == in_.params.fees.takerFeeCapBps
                && bookFees.makerRebateBps == in_.params.fees.makerRebateBps,
            "orderBook.feeParams() is not the V2_*_FEE_* set this run was given"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    STEP 3: THE SELECTOR MAP (roles.v8.json)
    //////////////////////////////////////////////////////////////*/

    /// @dev One `setTargetFunctionRole` per signature in `.targets`, in manifest order, skipping those the manager
    ///      already holds. Nothing here types a signature: the keys ARE the signatures and {selectorOf} hashes them.
    ///      A hand-written `_map(mgr, target, "sig", ROLE)` list (script/v2/DevDeploy.s.sol:410-433 still has one) is
    ///      a second copy of a frozen table and therefore a drift source; this loop cannot drift.
    function _pendingMapping(Contracts memory d) internal view returns (Call[] memory) {
        Plan memory p = Plan(rolesJson(), d.accessManager, new Call[](128), 0);
        string[] memory targets = targetNames(p.json);
        for (uint256 t; t < targets.length; ++t) {
            _mapTarget(p, targets[t], _targetAddress(d, targets[t]));
        }
        return _trim(p.buf, p.n);
    }

    /// @dev One target's signatures. The keys ARE the signatures, so {selectorOf} hashes them and nothing in this
    ///      file ever types a selector.
    function _mapTarget(Plan memory p, string memory targetName, address target) internal view {
        string[] memory sigs = targetSigs(p.json, targetName);
        require(
            sigs.length != 0 || _eq(targetName, "V4BuybackExecutor"), "roles.v8.json lists a target with no selectors"
        );
        // TWO DIFFERENT THINGS LOOK THE SAME HERE, and the first version of this guard (C8-DEVDEPLOY-FLYWHEEL,
        // mine) treated them as one and blocked the launch.
        //
        //   "this run does not DEPLOY that contract"  -- a fact about the run. HouseVault, HouseVaultFactory,
        //      Hedger and RewardsDistributorLender are deployed by their own tasks and arrive by environment. A
        //      core deploy that was never given them is not broken; it simply is not the run that wires them.
        //   "this script does not KNOW that name"     -- a bug in the table. That is `_targetAddress`'s revert
        //      and it stays exactly as it is.
        //
        // Mapping either case at address(0) is what must never happen: three `setTargetFunctionRole` calls
        // against nothing, an operator told the row was wired, and the REAL contract left unmapped -- so its
        // `restricted` selectors answer to ADMIN by default (06-QUIRKS §A.8). So an externally supplied target
        // with no address is SKIPPED AND ANNOUNCED, never silently mapped and never fatal; a target this script
        // does deploy having no address is still a hard stop, because that one really is a bug.
        //
        // The skip is safe because it is not the only guard: VerifyV8's manifest check reads
        // `getTargetFunctionRole` for every manifest selector and FAILS on any that is not mapped to its role,
        // so an operator who meant to supply one of these four and forgot gets a red verify rather than a green
        // deploy. Announcing it here is what turns "silently less wired" into "told you, twice".
        if (sigs.length != 0 && target == address(0)) {
            require(
                _externallySupplied(targetName),
                string.concat(
                    "roles.v8.json names the target ",
                    targetName,
                    ", which this script DEPLOYS, but its address is zero: that is a bug in this script, not a"
                    " missing input"
                )
            );
            _warn(
                string.concat(
                    targetName,
                    " is not wired by this run: it is deployed elsewhere and its address was not supplied (set ",
                    _envNameFor(targetName),
                    "). Its ",
                    vm.toString(sigs.length),
                    " selector(s) stay unmapped and VerifyV8 will FAIL on them until they are."
                )
            );
            return;
        }
        for (uint256 i; i < sigs.length; ++i) {
            bytes4 sel = selectorOf(sigs[i]);
            uint64 role = roleIdOf(p.json, roleNameOfSig(p.json, targetName, sigs[i]));
            if (AccessManager(p.manager).getTargetFunctionRole(target, sel) == role) continue;
            bytes4[] memory one = new bytes4[](1);
            one[0] = sel;
            require(p.n < p.buf.length, "selector map buffer too small for roles.v8.json");
            p.buf[p.n++] = Call(
                p.manager,
                abi.encodeCall(IAccessManager.setTargetFunctionRole, (target, one, role)),
                string.concat("setTargetFunctionRole(", targetName, ".", sigs[i], ")")
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                  STEP 4: THE DEPLOYER'S TRANSIENT MEMBERSHIPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every role that appears as a VALUE in `.targets`, granted to the deployer at delay 0.
    ///      This is what makes step 5 possible: ADMIN alone can send nothing to a target. It works only while
    ///      `_roles[roleId].admin` is still 0 for all of them, which is why step 7 comes after, and every membership
    ///      created here is dropped again in step 8.
    function _pendingSelfGrants(Contracts memory d, address deployer) internal view returns (Call[] memory) {
        string memory json = rolesJson();
        uint64[] memory roles = _workingRoles(json);
        Call[] memory buf = new Call[](roles.length);
        uint256 n;
        AccessManager mgr = AccessManager(d.accessManager);
        for (uint256 i; i < roles.length; ++i) {
            (bool member,) = mgr.hasRole(roles[i], deployer);
            if (member) continue;
            buf[n++] = Call(
                d.accessManager,
                abi.encodeCall(IAccessManager.grantRole, (roles[i], deployer, 0)),
                string.concat("grantRole(", vm.toString(uint256(roles[i])), ", deployer, delay 0): TRANSIENT")
            );
        }
        return _trim(buf, n);
    }

    /// @notice Every role id `roles.v8.json` declares, in manifest order.
    /// @dev T-436. DERIVED FROM THE MANIFEST, NEVER WRITTEN AS `0..10`. The literal range is the forbidden fix: it
    ///      is correct today and silently wrong the day an eleventh role is added, which is the same shape as the
    ///      defect this replaces -- a check whose subject can grow outside what the check can see. `.roles` is the
    ///      declaration of what a role id IS in this deployment, so a role that exists is in this list by
    ///      construction.
    function _allRoleIds(string memory json) internal pure returns (uint64[] memory ids) {
        string[] memory names = vm.parseJsonKeys(json, ".roles");
        ids = new uint64[](names.length);
        for (uint256 i; i < names.length; ++i) {
            ids[i] = roleIdOf(json, names[i]);
        }
    }

    /// @dev The distinct role ids used by any target function, in manifest order. ADMIN and OPS_ADMIN are not among
    ///      them by construction (`roles.v8.json` `notes.adminHasNoTarget` and `notes.opsAdmin`): both are
    ///      manager-only, which is exactly why the deployer has to give itself the others.
    function _workingRoles(string memory json) internal pure returns (uint64[] memory) {
        string[] memory targets = targetNames(json);
        uint64[] memory buf = new uint64[](32);
        uint256 n;
        for (uint256 t; t < targets.length; ++t) {
            string[] memory sigs = targetSigs(json, targets[t]);
            for (uint256 i; i < sigs.length; ++i) {
                uint64 role = roleIdOf(json, roleNameOfSig(json, targets[t], sigs[i]));
                bool seen;
                for (uint256 k; k < n; ++k) {
                    if (buf[k] == role) seen = true;
                }
                if (seen) continue;
                require(n < buf.length, "working-role buffer too small for roles.v8.json");
                buf[n++] = role;
            }
        }
        uint64[] memory out = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
        return out;
    }

    /*//////////////////////////////////////////////////////////////
                        STEP 5: POINTERS AND PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The calls the chain does not hold yet, in dependency order, and how many are already in place. Every one
    ///      goes DIRECTLY to its target, because the deployer holds the manifest role for it at delay 0 -- except the
    ///      OrderBook's, which is wrapped in `manager.execute` for the reason {_deployTrading} gives.
    function _pendingWiring(Inputs memory in_, Contracts memory d)
        internal
        view
        returns (Call[] memory calls, uint256 skipped)
    {
        // 9 pointers + 3 bounty callers + 6 bounties + 1 daily cap + 5 splitter pointers + 1 splitter slippage = 25.
        // Sized above that with an explicit assertion, because a silent overflow here would drop a wiring call and
        // the post-check is the only thing that would ever notice.
        Call[] memory buf = new Call[](40);
        uint256 n;
        (n, skipped) = _pointerCalls(in_, d, buf, n, skipped);
        (n, skipped) = _keeperCalls(in_, d, buf, n, skipped);
        (n, skipped) = _splitterCalls(in_, d, buf, n, skipped);
        require(n <= buf.length, "wiring buffer too small");
        calls = _trim(buf, n);
    }

    function _pointerCalls(Inputs memory in_, Contracts memory d, Call[] memory buf, uint256 n, uint256 skipped)
        internal
        view
        returns (uint256, uint256)
    {
        SettlementOracle oracle = SettlementOracle(d.settlementOracle);
        Clearinghouse ch = Clearinghouse(d.clearinghouse);
        AutoRoller roller = AutoRoller(d.autoRoller);
        console2.log("wiring (deployer, through its transient roles)");

        if (oracle.clearinghouse() != d.clearinghouse) {
            buf[n++] = Call(
                d.settlementOracle,
                abi.encodeCall(oracle.setClearinghouse, (d.clearinghouse)),
                "settlementOracle.setClearinghouse(clearinghouse)"
            );
        } else {
            _skip("settlementOracle.clearinghouse() already the clearinghouse");
            ++skipped;
        }
        // The three sources accept the oracle's pins (INTERFACE_VERSION 6). Part of the deploy, so it lands before
        // RegisterMarkets and before any series can exist: pinning fails closed, so while a listed source does not list
        // the oracle every first series of an expiry reverts (V2Errors.SourceNotPinned(source, NotAuthorized)).
        (n, skipped) = _sourceOracle(buf, n, skipped, d.chainlinkSource, d.settlementOracle, "chainlinkSource");
        (n, skipped) = _sourceOracle(buf, n, skipped, d.univ3Source, d.settlementOracle, "univ3Source");
        (n, skipped) = _sourceOracle(buf, n, skipped, d.dataStreamsSource, d.settlementOracle, "dataStreamsSource");
        if (oracle.keeperRewards() != d.keeperRewards) {
            buf[n++] = Call(
                d.settlementOracle,
                abi.encodeCall(oracle.setKeeperRewards, (d.keeperRewards)),
                "settlementOracle.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("settlementOracle.keeperRewards() already set");
            ++skipped;
        }
        if (address(ch.keeperRewards()) != d.keeperRewards) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setKeeperRewards, (d.keeperRewards)),
                "clearinghouse.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("clearinghouse.keeperRewards() already set");
            ++skipped;
        }
        if (ch.payoutAdapter() != d.payoutRouter) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setPayoutAdapter, (d.payoutRouter, in_.params.payoutSlippageBps)),
                string.concat(
                    "clearinghouse.setPayoutAdapter(payoutRouter, ", vm.toString(in_.params.payoutSlippageBps), " bps)"
                )
            );
        } else {
            _skip("clearinghouse.payoutAdapter() already the router (slippage bound left as set)");
            ++skipped;
        }
        // WITHOUT THESE TWO NO MARKET CAN EVER BE REGISTERED. INTERFACE_VERSION 8 split the v7 one-tuple
        // `registerMarket` into `registerMarket(underlying, strikeTick, enabled)` plus three setters, and the new
        // form composes the rest of the config FROM THE CONTRACT DEFAULTS (src/v2/Clearinghouse.sol:233-241):
        // `_defaultExerciseFeeBps`, `defaultOracle` and `_defaultMintFeePpm`. `_checkConfigMemory` then reverts
        // NoSource() when `defaultOracle` has no code, so on a fresh Clearinghouse the FIRST registerMarket fails
        // until this pointer is set. RegisterMarkets corrects any per-market difference afterwards.
        if (ch.defaultOracle() != d.settlementOracle) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setDefaultOracle, (d.settlementOracle)),
                "clearinghouse.setDefaultOracle(settlementOracle)"
            );
        } else {
            _skip("clearinghouse.defaultOracle() already the settlement oracle");
            ++skipped;
        }
        (uint16 defFee, uint32 defPpm) = ch.defaultMarketFees();
        // The rent default is 0 and is written as 0 here on purpose: V8-DESIGN.md §4.3 launches collateral rent at 0
        // on every market, and turning it on is a 72 h MARKET_FEE_MANAGER operation, never a deploy value. This is
        // the same rule {V2DeployBase.mintFeePpmFromEnv} enforces for the per-market rates.
        if (defFee != in_.params.exerciseFeeBps || defPpm != 0) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setDefaultMarketFees, (in_.params.exerciseFeeBps, uint32(0))),
                string.concat(
                    "clearinghouse.setDefaultMarketFees(", vm.toString(in_.params.exerciseFeeBps), " bps, 0 ppm)"
                )
            );
        } else {
            _skip("clearinghouse.defaultMarketFees() already the registry exercise fee at 0 rent");
            ++skipped;
        }
        // WITHOUT THIS THE BOOK CANNOT WRITE. `Clearinghouse.mint` reverts NotMinter() unless
        // `isMinter[msg.sender]` (src/v2/Clearinghouse.sol:564), and the OrderBook's two mint calls sit inside
        // try/gas, so a missing entry does not revert a fill -- it turns it into a SILENT SKIP after quoteTake had
        // already promised it. That is why this is a deploy call and not an operator step.
        if (!ch.isMinter(d.orderBook)) {
            buf[n++] = Call(
                d.clearinghouse,
                abi.encodeCall(ch.setMinter, (d.orderBook, true)),
                "clearinghouse.setMinter(orderBook, true)"
            );
        } else {
            _skip("clearinghouse.isMinter(orderBook) already true");
            ++skipped;
        }
        if (address(roller.keeperRewards()) != d.keeperRewards) {
            buf[n++] = Call(
                d.autoRoller,
                abi.encodeCall(roller.setKeeperRewards, (d.keeperRewards)),
                "autoRoller.setKeeperRewards(keeperRewards)"
            );
        } else {
            _skip("autoRoller.keeperRewards() already set");
            ++skipped;
        }
        if (address(OrderBook(d.orderBook).makerRegistry()) != d.makerRegistry) {
            buf[n++] = _viaManager(
                d.accessManager,
                d.orderBook,
                abi.encodeCall(OrderBook.setMakerRegistry, (IMakerRegistry(d.makerRegistry))),
                "orderBook.setMakerRegistry(makerRegistry)"
            );
        } else {
            _skip("orderBook.makerRegistry() already set");
            ++skipped;
        }
        return (n, skipped);
    }

    function _keeperCalls(Inputs memory in_, Contracts memory d, Call[] memory buf, uint256 n, uint256 skipped)
        internal
        view
        returns (uint256, uint256)
    {
        KeeperRewards kr = KeeperRewards(d.keeperRewards);
        Params memory p = in_.params;
        (n, skipped) = _caller(buf, n, skipped, kr, d.settlementOracle, "settlementOracle");
        (n, skipped) = _caller(buf, n, skipped, kr, d.clearinghouse, "clearinghouse");
        (n, skipped) = _caller(buf, n, skipped, kr, d.autoRoller, "autoRoller");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_SNAPSHOT, p.bountySnapshot, "SNAPSHOT");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_FINALIZE, p.bountyFinalize, "FINALIZE");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_SETTLE, p.bountySettle, "SETTLE");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_REDEEM, p.bountyRedeem, "REDEEM");
        (n, skipped) = _bounty(buf, n, skipped, kr, V2Constants.ACTION_ROLL, p.bountyRoll, "ROLL");
        // INTERFACE_VERSION 7 (c16): the permissionless stale-ask cancel. Paid at most once per ROLL, so the
        // dailyCap model is unchanged.
        (n, skipped) =
            _bounty(buf, n, skipped, kr, V2Constants.ACTION_CANCEL_STALE, p.bountyCancelStale, "CANCEL_STALE");
        // T-182 / F-SCRIPTS-09, second half. Same defect and same refusal as {_bounty}: the old `else` arm printed
        // "already <cap>" for ANY non-zero chain cap, including one that is not the cap this run was given.
        uint256 cap = kr.dailyCap();
        require(
            p.dailyCap == 0 || cap == 0 || cap == p.dailyCap,
            string.concat(
                "keeperRewards.dailyCap() on chain is ",
                vm.toString(cap),
                " but V2_KEEPER_DAILY_CAP is ",
                vm.toString(p.dailyCap),
                ": resume would report success with the chain and the environment disagreeing"
            )
        );
        if (cap == 0 && p.dailyCap != 0) {
            buf[n++] = Call(
                d.keeperRewards,
                abi.encodeCall(kr.setDailyCap, (p.dailyCap)),
                string.concat("keeperRewards.setDailyCap(", vm.toString(p.dailyCap), ")")
            );
        } else {
            _skip(string.concat("keeperRewards.dailyCap() already ", vm.toString(cap)));
            ++skipped;
        }
        return (n, skipped);
    }

    /// @dev The flywheel's five pointers and its conversion floor (V8-DESIGN §6). `setTreasury` and `setBurnBps` are
    ///      not here: both are constructor arguments of the splitter, which is where a value that must never be zero
    ///      belongs. `setToken` is given the v4 key's `currency1`, so the token the buyback burns and the token the
    ///      executor buys are read from ONE place.
    function _splitterCalls(Inputs memory in_, Contracts memory d, Call[] memory buf, uint256 n, uint256 skipped)
        internal
        view
        returns (uint256, uint256)
    {
        FeeSplitter s = FeeSplitter(payable(d.feeSplitter));
        // The five pointers, as DATA of a fixed length rather than five calls. Same order, same sources, same skip
        // behaviour as before; what changed is that the count is now a constant `VerifyV8` is pinned against.
        address[DEPLOY_V8_SPLITTER_POINTERS] memory have;
        address[DEPLOY_V8_SPLITTER_POINTERS] memory want;
        string[DEPLOY_V8_SPLITTER_POINTERS] memory fields;
        (have[0], want[0], fields[0]) = (s.orderBook(), d.orderBook, "OrderBook");
        (have[1], want[1], fields[1]) = (s.router(), d.payoutRouter, "Router");
        (have[2], want[2], fields[2]) = (s.executor(), d.buybackExecutor, "BuybackExecutor");
        (have[3], want[3], fields[3]) = (s.oracle(), d.settlementOracle, "Oracle");
        (have[4], want[4], fields[4]) = (s.stonkhouse(), in_.flywheel.poolKey.currency1, "Token");
        for (uint256 i; i < DEPLOY_V8_SPLITTER_POINTERS; ++i) {
            (n, skipped) = _splitterPointer(buf, n, skipped, d, have[i], want[i], fields[i]);
        }
        uint16 slip = in_.flywheel.conversionSlippageBps;
        if (s.conversionSlippageBps() != slip) {
            buf[n++] = Call(
                d.feeSplitter,
                abi.encodeCall(FeeSplitter.setConversionSlippageBps, (slip)),
                string.concat("feeSplitter.setConversionSlippageBps(", vm.toString(slip), ")")
            );
        } else {
            _skip("feeSplitter.conversionSlippageBps() already set");
            ++skipped;
        }
        return (n, skipped);
    }

    /// @dev One splitter pointer. The five setters share a `(address)` shape, so the selector is built from the
    ///      field name rather than five near-identical branches; `what` names the setter it will call.
    function _splitterPointer(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        Contracts memory d,
        address current,
        address want,
        string memory field
    ) internal pure returns (uint256, uint256) {
        if (current == want) {
            _skip(string.concat("feeSplitter.set", field, " already set"));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            d.feeSplitter,
            abi.encodeWithSelector(selectorOf(string.concat("set", field, "(address)")), want),
            string.concat("feeSplitter.set", field, "(", field, ")")
        );
        return (n + 1, skipped);
    }

    /// @dev `source.setOracle(oracle, true)` unless the source already lists the oracle. The three sources share the
    ///      `isOracle` / `setOracle` surface, so one ChainlinkFeedSource-typed encoding serves all of them.
    function _sourceOracle(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        address source,
        address oracle,
        string memory name
    ) internal view returns (uint256, uint256) {
        if (ChainlinkFeedSource(source).isOracle(oracle)) {
            _skip(string.concat(name, ".isOracle(settlementOracle) already true"));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            source,
            abi.encodeCall(ChainlinkFeedSource.setOracle, (oracle, true)),
            string.concat(name, ".setOracle(settlementOracle, true)")
        );
        return (n + 1, skipped);
    }

    function _caller(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        KeeperRewards kr,
        address caller,
        string memory name
    ) internal view returns (uint256, uint256) {
        if (kr.isCaller(caller)) {
            _skip(string.concat("keeperRewards caller ", name, ": already registered"));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            address(kr),
            abi.encodeCall(kr.setCaller, (caller, true)),
            string.concat("keeperRewards.setCaller(", name, ", true)")
        );
        return (n + 1, skipped);
    }

    function _bounty(
        Call[] memory buf,
        uint256 n,
        uint256 skipped,
        KeeperRewards kr,
        bytes32 action,
        uint256 amount,
        string memory name
    ) internal view returns (uint256, uint256) {
        uint256 current = kr.bounty(action);
        // T-182 / F-SCRIPTS-09. COMPARE, THEN SKIP -- in that order, and refuse on a mismatch. This used to skip any
        // non-zero `current` with "already <current>" WITHOUT ever comparing it to `amount`, so a resume against a
        // chain whose bounty differs from the operator's environment reported success and left the two disagreeing.
        // {_postCheck} could not catch it either: it asks THIS planner whether anything is left to send, so it is
        // structurally blind to whatever the planner has just chosen to skip. The comparison has to happen here.
        //
        // The shape is the fee-recipient refusal's, deliberately: an UNSET side is allowed (`amount == 0` means the
        // environment named no bounty for this action, `current == 0` means the chain holds none yet), and two set
        // sides that disagree are REFUSED naming both values rather than silently preferring either.
        require(
            amount == 0 || current == 0 || current == amount,
            string.concat(
                "keeperRewards bounty ",
                name,
                " on chain is ",
                vm.toString(current),
                " but this run was given ",
                vm.toString(amount),
                ": resume would report success with the chain and the environment disagreeing"
            )
        );
        if (current != 0 || amount == 0) {
            _skip(string.concat("keeperRewards bounty ", name, " already ", vm.toString(current)));
            return (n, skipped + 1);
        }
        buf[n] = Call(
            address(kr),
            abi.encodeCall(kr.setBounty, (action, amount)),
            string.concat("keeperRewards.setBounty(", name, ", ", vm.toString(amount), ")")
        );
        return (n + 1, skipped);
    }

    /// @dev Wraps a target call in `manager.execute`. The manager checks `canCall(deployer, target, selector)` exactly
    ///      as a direct call would, then calls the target with `msg.sender == manager`.
    function _viaManager(address manager, address target, bytes memory data, string memory what)
        internal
        pure
        returns (Call memory)
    {
        return Call(
            manager, abi.encodeCall(IAccessManager.execute, (target, data)), string.concat("manager.execute -> ", what)
        );
    }

    /*//////////////////////////////////////////////////////////////
                   STEP 6: THE ROLES GO TO THEIR HOLDERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `grantRole(role, holder, delaysS[role])` for every pair in `.holders`, in manifest order. The delay is
    ///      read from the manifest, never typed: ADMIN's 48 h is what makes every later role change visible on chain
    ///      for two days, and a 0 typed here by hand would remove that silently.
    function _pendingHolders(Inputs memory in_, Contracts memory d) internal view returns (Call[] memory) {
        Plan memory p = Plan(rolesJson(), d.accessManager, new Call[](32), 0);
        string[] memory holders = holderNames(p.json);
        for (uint256 h; h < holders.length; ++h) {
            _grantsFor(p, holders[h], _holderAddress(in_.roles, holders[h]));
        }
        return _trim(p.buf, p.n);
    }

    /// @dev The grants one principal is still missing, at the delay the manifest gives each role.
    function _grantsFor(Plan memory p, string memory holderName, address who) internal view {
        string[] memory names = holderRoles(p.json, holderName);
        for (uint256 i; i < names.length; ++i) {
            uint64 role = roleIdOf(p.json, names[i]);
            uint32 delay = roleDelayOf(p.json, names[i]);
            // T-436 P1-a. `hasRole` DISCARDS THE PENDING HALF. It calls `getAccess` and returns only `since` and
            // `currentDelay` (AccessManager.sol:217-227), so a scheduled REDUCTION of this holder's execution delay
            // -- to 0, say -- is invisible here: the pair looks correct, no call is planned, and at `effect` the
            // lane silently becomes instant. The manifest delay has to hold NOW and at every future effect time,
            // so the pending value is read and judged too.
            //
            // The repair is the SAME call this planner already emits. `grantRole` at a delay that is not lower than
            // the current one applies immediately (`Time.Delay.withUpdate`), which overwrites the scheduled change,
            // so re-granting at the manifest delay is what cancels a pending reduction.
            (uint48 since, uint32 have, uint32 pendingDelay, uint48 effect) =
                AccessManager(p.manager).getAccess(role, who);
            bool member = since != 0 && since <= block.timestamp;
            bool pendingIsFine = effect == 0 || pendingDelay == delay;
            if (member && have == delay && pendingIsFine) continue;
            require(p.n < p.buf.length, "holder-grant buffer too small for roles.v8.json");
            p.buf[p.n++] = Call(
                p.manager,
                abi.encodeCall(IAccessManager.grantRole, (role, who, delay)),
                string.concat("grantRole(", names[i], ", ", holderName, ", ", vm.toString(uint256(delay)), " s)")
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                  STEP 7: ROLE ADMINS AND ROLE GUARDIANS
    //////////////////////////////////////////////////////////////*/

    /// @dev `.roleAdmin` then `.roleGuardian`, both read from the manifest. THIS IS AFTER STEPS 4 AND 6 ON PURPOSE.
    ///      `_getAdminRestrictions` (AccessManager.sol:657-662) routes grantRole and revokeRole through
    ///      `getRoleAdmin(roleId)`, so the moment GUARDIAN, PRICER, QUOTER and BUYBACK are parented to OPS_ADMIN a
    ///      deployer that holds only ADMIN can no longer grant them: it would revert
    ///      `AccessManagerUnauthorizedAccount(deployer, OPS_ADMIN)`.
    function _pendingRoleTree(Contracts memory d) internal view returns (Call[] memory) {
        Plan memory p = Plan(rolesJson(), d.accessManager, new Call[](64), 0);
        string[] memory admins = roleAdminNames(p.json);
        for (uint256 i; i < admins.length; ++i) {
            _roleAdmin(p, admins[i]);
        }
        string[] memory guardians = roleGuardianNames(p.json);
        for (uint256 i; i < guardians.length; ++i) {
            _roleGuardian(p, guardians[i]);
        }
        // T-436 P2-d. THE TWO LOOPS ABOVE WALK THE MANIFEST'S KEYS; THE VERIFIER WALKS THE ROLES. That difference
        // is the finding: a role the manifest does NOT list under `.roleAdmin` is expected to be administered by
        // ADMIN (0), because that is AccessManager's own default and what the omission means -- and `VerifyV8`
        // enforces exactly that (its `_roleRefOr0`). A chain where such a role has a non-ADMIN admin is a state
        // the verifier FAILS and this planner could not even describe, so `checkWiring` reported a complete
        // hand-over for a deployment the launch gate refuses. The three sweeps below close that gap by checking
        // every state Verify checks, against the same expectation, and planning the call that repairs it.
        _roleDefaults(p);
        _grantDelays(p);
        _targetState(p, d);
        return _trim(p.buf, p.n);
    }

    /// @dev Every role's admin and guardian, INCLUDING the ones the manifest omits (expected: ADMIN). Mirrors
    ///      `VerifyV8._roleRefOr0`; the expectation is read from the file and never from the chain.
    function _roleDefaults(Plan memory p) internal view {
        string[] memory names = vm.parseJsonKeys(p.json, ".roles");
        for (uint256 i; i < names.length; ++i) {
            uint64 id = roleIdOf(p.json, names[i]);
            uint64 wantAdmin = _roleRefOr0(p.json, true, names[i]);
            uint64 wantGuardian = _roleRefOr0(p.json, false, names[i]);
            if (AccessManager(p.manager).getRoleAdmin(id) != wantAdmin) {
                require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
                p.buf[p.n++] = Call(
                    p.manager,
                    abi.encodeCall(IAccessManager.setRoleAdmin, (id, wantAdmin)),
                    string.concat("setRoleAdmin(", names[i], " -> role id ", vm.toString(uint256(wantAdmin)), ")")
                );
            }
            if (AccessManager(p.manager).getRoleGuardian(id) != wantGuardian) {
                require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
                p.buf[p.n++] = Call(
                    p.manager,
                    abi.encodeCall(IAccessManager.setRoleGuardian, (id, wantGuardian)),
                    string.concat("setRoleGuardian(", names[i], " -> role id ", vm.toString(uint256(wantGuardian)), ")")
                );
            }
        }
    }

    /// @dev `VerifyV8` requires every role's GRANT delay to be 0 (`notes.grantDelays`: the minSetback is 5 days, so
    ///      a non-zero one is five days of being unable to hand a role over). Nothing on the deploy side asked.
    function _grantDelays(Plan memory p) internal view {
        string[] memory names = vm.parseJsonKeys(p.json, ".roles");
        for (uint256 i; i < names.length; ++i) {
            uint64 id = roleIdOf(p.json, names[i]);
            if (AccessManager(p.manager).getRoleGrantDelay(id) == 0) continue;
            require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
            p.buf[p.n++] = Call(
                p.manager,
                abi.encodeCall(IAccessManager.setGrantDelay, (id, 0)),
                string.concat("setGrantDelay(", names[i], ", 0)")
            );
        }
    }

    /// @dev `VerifyV8._targetsOpen` fails on a closed target or a non-zero target admin delay, and for a reason that
    ///      is not cosmetic: a closed target makes EVERY restricted selector on it answer to nobody -- including the
    ///      manager's own recovery calls. The deploy side never read either field.
    ///      V4BuybackExecutor is skipped BY MANIFEST NAME, the same exemption and the same reason as the verifier.
    function _targetState(Plan memory p, Contracts memory d) internal view {
        string[] memory names = targetNames(p.json);
        for (uint256 i; i < names.length; ++i) {
            if (_eq(names[i], "V4BuybackExecutor")) continue;
            address target = _targetAddress(d, names[i]);
            if (target == address(0)) continue;
            if (AccessManager(p.manager).getTargetAdminDelay(target) != 0) {
                require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
                p.buf[p.n++] = Call(
                    p.manager,
                    abi.encodeCall(IAccessManager.setTargetAdminDelay, (target, 0)),
                    string.concat("setTargetAdminDelay(", names[i], ", 0)")
                );
            }
            if (AccessManager(p.manager).isTargetClosed(target)) {
                require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
                p.buf[p.n++] = Call(
                    p.manager,
                    abi.encodeCall(IAccessManager.setTargetClosed, (target, false)),
                    string.concat("setTargetClosed(", names[i], ", false)")
                );
            }
        }
    }

    /// @dev The manifest's admin/guardian for a role, or ADMIN (0) when the manifest omits it. MIRRORED from
    ///      `VerifyV8._roleRefOr0` so the two scripts cannot disagree about what an omission means.
    function _roleRefOr0(string memory json, bool admin, string memory roleName) internal pure returns (uint64) {
        string[] memory listed = admin ? roleAdminNames(json) : roleGuardianNames(json);
        for (uint256 i; i < listed.length; ++i) {
            if (_eq(listed[i], roleName)) {
                return roleIdOf(json, admin ? roleAdminOf(json, roleName) : roleGuardianOf(json, roleName));
            }
        }
        return 0;
    }

    function _roleAdmin(Plan memory p, string memory roleName) internal view {
        uint64 role = roleIdOf(p.json, roleName);
        string memory parent = roleAdminOf(p.json, roleName);
        uint64 adminRole = roleIdOf(p.json, parent);
        if (AccessManager(p.manager).getRoleAdmin(role) == adminRole) return;
        require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
        p.buf[p.n++] = Call(
            p.manager,
            abi.encodeCall(IAccessManager.setRoleAdmin, (role, adminRole)),
            string.concat("setRoleAdmin(", roleName, " -> ", parent, ")")
        );
    }

    function _roleGuardian(Plan memory p, string memory roleName) internal view {
        uint64 role = roleIdOf(p.json, roleName);
        string memory guard = roleGuardianOf(p.json, roleName);
        uint64 guardRole = roleIdOf(p.json, guard);
        if (AccessManager(p.manager).getRoleGuardian(role) == guardRole) return;
        require(p.n < p.buf.length, "role-tree buffer too small for roles.v8.json");
        p.buf[p.n++] = Call(
            p.manager,
            abi.encodeCall(IAccessManager.setRoleGuardian, (role, guardRole)),
            string.concat("setRoleGuardian(", roleName, " -> ", guard, ")")
        );
    }

    /*//////////////////////////////////////////////////////////////
                 STEPS 8 AND 9: THE DEPLOYER LETS GO OF EVERYTHING
    //////////////////////////////////////////////////////////////*/

    /// @dev The deployer drops the transient memberships of step 4 and then renounces ADMIN, which is the LAST call
    ///      of the whole batch.
    ///
    ///      WHY `renounceRole` AND NOT `revokeRole` FOR THE TRANSIENT ONES. `revokeRole` is admin-restricted through
    ///      `getRoleAdmin(roleId)` (AccessManager.sol:657-662), and step 7 has just parented GUARDIAN, PRICER, QUOTER
    ///      and BUYBACK to OPS_ADMIN -- which the deployer was never granted, because no target function maps to it.
    ///      A `revokeRole(GUARDIAN, deployer)` here would revert. `renounceRole(roleId, callerConfirmation)`
    ///      (AccessManager.sol:249-254) has no admin check at all -- it only requires the confirmation to equal
    ///      `msg.sender` -- and calls the same `_revokeRole`, so it deletes the same membership and emits the same
    ///      `RoleRevoked(roleId, account)`. Nothing downstream can tell the two apart.
    ///
    ///      THE `require` BELOW IS THE MOST IMPORTANT LINE IN THIS FILE. `_revokeRole`
    ///      (AccessManager.sol:311-324) has NO last-admin guard: it checks PUBLIC_ROLE, checks the member exists,
    ///      deletes it and returns. Renouncing ADMIN while nobody else holds it therefore leaves a manager whose
    ///      `grantRole`, `setTargetFunctionRole`, `setRoleAdmin` and `setRoleGuardian` can never be called again by
    ///      anyone, and EVERY `roles.v8.json` TARGET reads that manager for every privileged call -- not only the
    ///      sixteen contracts this script creates, but the periphery ones it is merely given, and every vault the
    ///      HouseVaultFactory mints afterwards. There is no
    ///      recovery: `setAuthority` on a target is callable only by the authority itself, and the authority can no
    ///      longer be instructed to call it.
    function _pendingHandBack(Inputs memory in_, Contracts memory d, address deployer)
        internal
        view
        returns (Call[] memory)
    {
        string memory json = rolesJson();
        // T-436 P1-c. EVERY ROLE ID IN THE MANIFEST, not `_workingRoles`. `_workingRoles` is derived from the roles
        // that appear as VALUES in `.targets`, so a role that maps no target function is not in it -- and OPS_ADMIN
        // (6) is exactly that: it maps no selector and exists only to PARENT GUARDIAN, PRICER, QUOTER and BUYBACK.
        // A deployer that ended up holding OPS_ADMIN was therefore never asked about it, never renounced it, and
        // the run still logged "the deployer holds nothing". Enumerating the manifest means the next manager-only
        // role is covered on the day it is added, which is why this is not a named special case for OPS_ADMIN.
        uint64[] memory roles = _allRoleIds(json);
        AccessManager mgr = AccessManager(d.accessManager);
        Call[] memory buf = new Call[](roles.length + 1);
        uint256 n;
        uint64 adminRole = roleIdOf(json, "ADMIN");
        for (uint256 i; i < roles.length; ++i) {
            // ADMIN is handled below because it must be the LAST call of the whole batch.
            if (roles[i] == adminRole) continue;
            (bool member,) = mgr.hasRole(roles[i], deployer);
            if (!member) continue;
            buf[n++] = Call(
                d.accessManager,
                abi.encodeCall(IAccessManager.renounceRole, (roles[i], deployer)),
                string.concat("renounceRole(", vm.toString(uint256(roles[i])), ", deployer): transient role dropped")
            );
        }
        (bool deployerIsAdmin,) = mgr.hasRole(adminRole, deployer);
        if (deployerIsAdmin) {
            _assertAdminSafeCanTakeOver(mgr, in_.roles.adminSafe, roleDelayOf(json, "ADMIN"), adminRole);
            buf[n++] = Call(
                d.accessManager,
                abi.encodeCall(IAccessManager.renounceRole, (adminRole, deployer)),
                "renounceRole(ADMIN, deployer): LAST CALL -- the deployer now holds nothing"
            );
        }
        require(n <= buf.length, "hand-back buffer too small");
        return _trim(buf, n);
    }

    /// @dev The pre-renounce assertion, kept in its own function so the message is quotable and the check cannot be
    ///      reordered behind the call it guards. All three parts matter: a Safe that does not hold ADMIN means
    ///      nobody does, an ADMIN that is a plain key means one leaked key owns every manifest target with no delay
    ///      to react in, and an ADMIN that has code but is not a 2-of-3 Safe means the delay protects nothing. The
    ///      delay is compared against the manifest's own `delaysS.ADMIN`, not a typed 172800.
    ///
    ///      T-426 F-05-01. `code.length != 0` WAS THE WHOLE SAFE CHECK, and it cannot tell a Safe from an inert
    ///      contract or from a public forwarder that anyone can make execute a call. The real topology probes
    ///      existed only in `VerifyV8`, which runs AFTER this renounce -- and this renounce is irreversible
    ///      (`AccessManager._revokeRole` has no last-admin guard). A verifier that runs after the irreversible step
    ///      is not a precondition, so the probes are performed HERE, in the same run, before the renounce call is
    ///      even appended to the batch.
    function _assertAdminSafeCanTakeOver(AccessManager mgr, address adminSafe, uint32 wantDelay, uint64 adminRole)
        internal
        view
    {
        _assertAdminSafeIsARealSafe(adminSafe);
        // T-436 P1-a. Read all four fields, not `hasRole`'s two. A pending reduction of the Admin Safe's ADMIN
        // execution delay is the one thing that can make this renounce wrong AFTER it has already succeeded: the
        // Safe holds ADMIN at 48 h today, the deployer lets go, and at `effect` the Safe's ADMIN lane becomes
        // instant with nobody left who could put the delay back.
        (uint48 safeSince, uint32 safeDelay, uint32 safePendingDelay, uint48 safeEffect) =
            mgr.getAccess(adminRole, adminSafe);
        bool safeIsAdmin = safeSince != 0 && safeSince <= block.timestamp;
        require(
            safeEffect == 0 || safePendingDelay == wantDelay,
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(adminSafe),
                " has a PENDING ADMIN execution-delay change to ",
                vm.toString(uint256(safePendingDelay)),
                " s taking effect at ",
                vm.toString(uint256(safeEffect)),
                ". hasRole() cannot see it. Renouncing now hands ADMIN to a lane that becomes ",
                vm.toString(uint256(safePendingDelay)),
                " s later, and after the renounce nobody can put it back."
            )
        );
        require(
            safeIsAdmin && safeDelay == wantDelay && adminSafe.code.length != 0,
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(adminSafe),
                " must already hold ADMIN with a ",
                vm.toString(uint256(wantDelay)),
                " s execution delay and must have code. AccessManager._revokeRole has NO last-admin guard, so",
                " renouncing the last ADMIN BRICKS ALL SIXTEEN CONTRACTS PERMANENTLY: no role, no selector map and no",
                " authority could ever be changed again, on any of them, by anyone."
            )
        );
        _ok("Admin Safe holds ADMIN at the manifest delay and has code: the renounce is safe");
    }

    /*//////////////////////////////////////////////////////////////
                    THE ADMIN SAFE IS A REAL 2-OF-3 SAFE
    //////////////////////////////////////////////////////////////*/

    /// @dev MIRRORED, NOT RE-DERIVED, from `script/v2/VerifyV8.s.sol` (`SAFE_L2_141` .. `SAFE_FALLBACK_SLOT`),
    ///      which mirrors `script/Verify.s.sol:75-82`. These are Safe's own deployed singletons and its two hashed
    ///      storage slots; typing an address or a slot from memory is how a pin ships wrong.
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2_130 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant SAFE_FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    /// @dev NOT READ FROM THE ENVIRONMENT, on purpose. `VerifyV8` takes its minimums from
    ///      `V2_EXPECT_SAFE_THRESHOLD`/`V2_EXPECT_SAFE_OWNERS` because a verifier may legitimately be pointed at a
    ///      differently-shaped Safe. This is a refusal in front of an irreversible call, and an environment
    ///      variable in front of an irreversible call is a way to turn it off: `V2_EXPECT_SAFE_THRESHOLD=1` would
    ///      hand every power this manager centralises to a single signature and the run would still print ok. The
    ///      v8 design is a 2-of-3 Admin Safe; that is what this file refuses to renounce to anything less than.
    uint256 internal constant SAFE_MIN_THRESHOLD = 2;
    uint256 internal constant SAFE_MIN_OWNERS = 3;

    /// @notice Refuses to proceed unless `safe` is a canonical Safe deployment that can actually act as a 2-of-3
    ///         authority: canonical singleton, a threshold and owner set that answer and meet the minimums, no
    ///         enabled module, no transaction guard, and a canonical (or absent) fallback handler.
    /// @dev EVERY FAILURE PATH REVERTS AND NAMES ITSELF. There is no branch here that returns quietly, and there is
    ///      deliberately no "skip when we cannot read it": an address that does not answer `getThreshold()` is the
    ///      exact case this function exists for, so a caught revert is a REFUSAL, never a pass. That is the
    ///      difference between this and a check that passes because it cannot see its subject.
    ///
    ///      WHAT EACH PROBE KILLS:
    ///        singleton slot  -- an inert contract (slot 0 is zero) and a forwarder (slot 0 is not a Safe build).
    ///        threshold/owners-- a 1-of-1 Safe, and a threshold above the owner count, which is a bricked Safe.
    ///        modules         -- an enabled module executes transactions with NO signatures at all.
    ///        guard           -- a transaction guard can veto or rewrite what the owners agreed to.
    ///        fallback handler-- a non-canonical handler answers arbitrary calldata as the Safe.
    ///      A single-selector probe such as `isSafe()` kills NONE of them, which is why it is not used.
    function _assertAdminSafeIsARealSafe(address safe) internal view {
        require(
            safe.code.length != 0,
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ", vm.toString(safe), " has no code (it is a plain key)"
            )
        );
        address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
        require(
            singleton == SAFE_L2_141 || singleton == SAFE_141 || singleton == SAFE_L2_130,
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(safe),
                " has code but its singleton slot holds ",
                vm.toString(singleton),
                ", which is not a canonical Safe 1.4.1 / 1.3.0 build. An inert contract and a public forwarder both",
                " have code; neither can produce a 2-of-3 signature."
            )
        );
        uint256 threshold;
        try ISafeTopology(safe).getThreshold() returns (uint256 t) {
            threshold = t;
        } catch {
            revert(
                string.concat(
                    "REFUSING TO RENOUNCE ADMIN: the Admin Safe ", vm.toString(safe), " did not answer getThreshold()"
                )
            );
        }
        uint256 owners;
        try ISafeTopology(safe).getOwners() returns (address[] memory o) {
            owners = o.length;
        } catch {
            revert(
                string.concat(
                    "REFUSING TO RENOUNCE ADMIN: the Admin Safe ", vm.toString(safe), " did not answer getOwners()"
                )
            );
        }
        // The upper bound is not decoration: a threshold above the owner count can never be met, so the Safe is
        // bricked rather than merely weak, and renouncing to a bricked Safe is the same outcome as renouncing to
        // nobody.
        require(
            threshold >= SAFE_MIN_THRESHOLD && threshold <= owners && owners >= SAFE_MIN_OWNERS,
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(safe),
                " is ",
                vm.toString(threshold),
                "-of-",
                vm.toString(owners),
                "; v8 requires at least ",
                vm.toString(SAFE_MIN_THRESHOLD),
                "-of-",
                vm.toString(SAFE_MIN_OWNERS),
                " and a threshold no larger than the owner count"
            )
        );
        try ISafeTopology(safe).getModulesPaginated(SAFE_MODULE_SENTINEL, 10) returns (
            address[] memory modules, address
        ) {
            require(
                modules.length == 0,
                string.concat(
                    "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                    vm.toString(safe),
                    " has ",
                    vm.toString(modules.length),
                    " enabled module(s). A module executes Safe transactions with no owner signatures at all, so the",
                    " 2-of-3 is advisory."
                )
            );
        } catch {
            revert(
                string.concat(
                    "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                    vm.toString(safe),
                    " did not answer getModulesPaginated()"
                )
            );
        }
        require(
            vm.load(safe, SAFE_GUARD_SLOT) == bytes32(0),
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(safe),
                " has a transaction guard, which can veto or rewrite what the owners agreed to"
            )
        );
        address fallbackHandler = address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_SLOT))));
        require(
            fallbackHandler == SAFE_FALLBACK_141 || fallbackHandler == address(0),
            string.concat(
                "REFUSING TO RENOUNCE ADMIN: the Admin Safe ",
                vm.toString(safe),
                " has the non-canonical fallback handler ",
                vm.toString(fallbackHandler),
                ", which answers arbitrary calldata as the Safe"
            )
        );
        _ok(
            string.concat(
                "Admin Safe is a canonical Safe: ",
                vm.toString(threshold),
                "-of-",
                vm.toString(owners),
                ", no modules, no guard, canonical fallback handler"
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                             MANIFEST -> SET
    //////////////////////////////////////////////////////////////*/

    /// @dev The address of a `.targets` entry. FAILS CLOSED on an unknown name: a manifest that grew a target this
    ///      script does not deploy must stop the run, not leave that target unmapped and therefore ADMIN-only.
    /// @dev The manifest targets this script does NOT deploy. They are created by their own tasks and supplied
    ///      by address, so "no address" means "not this run's job", not "broken". Kept as an explicit list rather
    ///      than inferred from a zero address, because inferring it is exactly how a target this script DOES
    ///      deploy would get silently skipped after a refactor.
    function _externallySupplied(string memory name) internal pure returns (bool) {
        return _eq(name, "HouseVault") || _eq(name, "HouseVaultFactory") || _eq(name, "Hedger")
            || _eq(name, "RewardsDistributorLender") || _eq(name, "EarnVault") || _eq(name, "StockVenueAdapter");
    }

    /// @dev The environment variable that supplies an externally deployed target, named in the skip message so
    ///      the operator is told what to set rather than what is missing.
    function _envNameFor(string memory name) internal pure returns (string memory) {
        if (_eq(name, "HouseVault")) return "V2_HOUSE_VAULT";
        if (_eq(name, "HouseVaultFactory")) return "V2_HOUSE_VAULT_FACTORY";
        if (_eq(name, "Hedger")) return "V2_HEDGER";
        if (_eq(name, "RewardsDistributorLender")) return "V2_LENDER_REWARDS";
        if (_eq(name, "EarnVault")) return "V2_EARN_VAULT";
        if (_eq(name, "StockVenueAdapter")) return "V2_STOCK_VENUE_ADAPTER";
        return "its V2_* variable";
    }

    /*//////////////////////////////////////////////////////////////
                    T-426: A TARGET IS WHAT ITS NAME CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Refuses one address supplied under two different `roles.v8.json` target names.
    /// @dev F-05-03. Nothing downstream can see this. {_mapTarget} maps selectors onto any nonzero address it is
    ///      given, {_postCheck} proves only that the mappings EXIST, and `VerifyV8` exempts the buyback executor by
    ///      ADDRESS EQUALITY -- so `V2_HOUSE_VAULT = V2_BUYBACK_EXECUTOR` makes the HouseVault checks skip
    ///      themselves and BOTH scripts report a clean run. An alias is therefore invisible after this point, which
    ///      is why the refusal is here, before anything is created or sent.
    ///
    ///      Zero is skipped and is not an alias: "no address" means "not this run's job" for the six external
    ///      targets ({_mapTarget} says the same thing at more length), and several of them are unset in most runs.
    ///
    ///      THE NAMES COME FROM THE MANIFEST, not from a list typed here: a target added to `roles.v8.json` is
    ///      covered by this check the moment it is added, and {_targetAddress} refuses a name it does not know.
    function _assertNoAliasedTargets(Contracts memory c) internal view {
        string[] memory names = targetNames(rolesJson());
        for (uint256 i; i < names.length; ++i) {
            address a = _targetAddress(c, names[i]);
            if (a == address(0)) continue;
            for (uint256 j = i + 1; j < names.length; ++j) {
                require(
                    a != _targetAddress(c, names[j]),
                    string.concat(
                        "two roles.v8.json targets are the same address: ",
                        names[i],
                        " and ",
                        names[j],
                        " are both ",
                        vm.toString(a),
                        ". One contract cannot carry two targets' selector maps, and a verifier that exempts a",
                        " target by address would skip the other one silently."
                    )
                );
            }
        }
        _ok(string.concat("all ", vm.toString(names.length), " roles.v8.json targets are distinct addresses"));
    }

    /// @notice Refuses an externally supplied target that does not answer the interface its manifest name claims.
    /// @dev F-05-03, the other half. The six targets this script does not deploy arrive as raw addresses from the
    ///      environment, and until now the only thing asserted about them was `code.length != 0` -- so
    ///      `V2_EARN_VAULT` pointing at the Hedger, or at last week's HouseVault, wires that contract's selectors
    ///      under the wrong name and every later check agrees with the mistake.
    ///
    ///      WHY AN INTERFACE PROBE AND NOT A CODEHASH. A codehash pin would be stronger, but these six are
    ///      deployed by their own tasks with their own constructor arguments and are expected to be redeployed
    ///      between now and launch; a pin would have to be re-pinned on every one of those and the pressure would
    ///      be to delete it. The probe asks each contract for two public getters that its own source declares and
    ///      that the other five do not share, so it survives a redeploy and still refuses a different contract.
    ///      The pairs are read off the sources, not remembered:
    ///        HouseVault               underlying() + clearinghouse()   src/v2/periphery/house/HouseVault.sol:173,169
    ///        HouseVaultFactory        vaults()                         src/v2/periphery/house/HouseVaultFactory.sol:90
    ///        Hedger                   notional() + loan()              src/v2/periphery/Hedger.sol {notional}, {loan}
    ///        EarnVault                queue() + adapter()              src/v2/periphery/earn/EarnVault.sol:936,919
    ///        StockVenueAdapter        venue() + enabled()              adapters/Erc4626VenueAdapter.sol:76, StockVenueAdapter.sol:32
    ///        RewardsDistributorLender usdg() + treasury()              src/v2/mm/RewardsDistributor.sol:63,78
    ///      RewardsDistributorLender is the weak one and it is weak for a real reason: it is the SAME contract as
    ///      the maker `RewardsDistributor`, so no probe can tell the two instances apart. What catches a swap there
    ///      is {_assertNoAliasedTargets}, which refuses the same address under both names.
    function _assertSuppliedTargetsAreWhatTheirNameClaims(Contracts memory c) internal view {
        _probe(c.houseVault, "HouseVault", "underlying()", "clearinghouse()");
        _probe(c.houseVaultFactory, "HouseVaultFactory", "vaults()", "");
        _probe(c.hedger, "Hedger", "notional()", "loan()");
        _probe(c.earnVault, "EarnVault", "queue()", "adapter()");
        _probe(c.stockVenueAdapter, "StockVenueAdapter", "venue()", "enabled()");
        _probe(c.rewardsDistributorLender, "RewardsDistributorLender", "usdg()", "treasury()");
    }

    /// @dev One target, one or two reads. An UNSET address is skipped -- that is {_mapTarget}'s "not this run's
    ///      job" -- but an address WITH code that does not answer is a hard stop, never a warning: the whole point
    ///      is that the wrong contract must not be wired under this name.
    function _probe(address target, string memory name, string memory first, string memory second) internal view {
        if (target == address(0)) return;
        _answers(target, name, first);
        if (bytes(second).length != 0) _answers(target, name, second);
        _ok(string.concat(name, " answers the interface its manifest name claims"));
    }

    function _answers(address target, string memory name, string memory sig) internal view {
        require(
            target.code.length != 0,
            string.concat("V2_* gave ", name, " the address ", vm.toString(target), ", which has no code")
        );
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(
            ok && ret.length != 0,
            string.concat(
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
            )
        );
    }

    function _targetAddress(Contracts memory d, string memory name) internal pure returns (address) {
        if (_eq(name, "Clearinghouse")) return d.clearinghouse;
        if (_eq(name, "OrderBook")) return d.orderBook;
        if (_eq(name, "SettlementOracle")) return d.settlementOracle;
        if (_eq(name, "ChainlinkFeedSource")) return d.chainlinkSource;
        if (_eq(name, "UniV3TwapSource")) return d.univ3Source;
        if (_eq(name, "DataStreamsSource")) return d.dataStreamsSource;
        if (_eq(name, "ExpiryCalendar")) return d.expiryCalendar;
        if (_eq(name, "KeeperRewards")) return d.keeperRewards;
        if (_eq(name, "AutoRoller")) return d.autoRoller;
        if (_eq(name, "MakerVault")) return d.makerVault;
        if (_eq(name, "MakerRegistry")) return d.makerRegistry;
        if (_eq(name, "RewardsDistributor")) return d.rewardsDistributor;
        if (_eq(name, "RewardsDistributorLender")) return d.rewardsDistributorLender;
        if (_eq(name, "PayoutRouter")) return d.payoutRouter;
        if (_eq(name, "FeeSplitter")) return d.feeSplitter;
        if (_eq(name, "V4BuybackExecutor")) return d.buybackExecutor;
        if (_eq(name, "HouseVault")) return d.houseVault;
        if (_eq(name, "HouseVaultFactory")) return d.houseVaultFactory;
        if (_eq(name, "Hedger")) return d.hedger;
        if (_eq(name, "EarnVault")) return d.earnVault;
        if (_eq(name, "StockVenueAdapter")) return d.stockVenueAdapter;
        // KEEP THIS REVERT, and read the next four lines before weakening it. These last four names are NOT deployed
        // by this script -- they arrive by address, from `V2_HOUSE_VAULT`, `V2_HOUSE_VAULT_FACTORY`, `V2_HEDGER` and
        // `V2_LENDER_REWARDS`. "Not deployed here" is a fact about the run; "not known here" is a bug in this table,
        // and the two must not be allowed to look the same. {_mapTarget} refuses the first; this refuses the second.
        revert(string.concat("roles.v8.json names a target this script does not deploy: ", name));
    }

    /// @dev The address of a `.holders` entry. Fails closed for the same reason: an unknown principal must not be
    ///      silently skipped, or its role would end up held by nobody.
    function _holderAddress(Roles memory r, string memory name) internal pure returns (address) {
        if (_eq(name, "adminSafe")) return r.adminSafe;
        if (_eq(name, "treasurySafe")) return r.treasurySafe;
        if (_eq(name, "guardianKey")) return r.guardianKey;
        if (_eq(name, "pricerKey")) return r.pricerKey;
        if (_eq(name, "quoterKey")) return r.quoterKey;
        if (_eq(name, "crankerKey")) return r.crankerKey;
        revert(string.concat("roles.v8.json names a holder this script does not know: ", name));
    }

    /*//////////////////////////////////////////////////////////////
                              SEND AND CHECK
    //////////////////////////////////////////////////////////////*/

    /// @dev Logs and sends one batch, and answers how many calls it was.
    function _send(Signer memory signer, Call[] memory calls, string memory label) internal returns (uint256) {
        if (calls.length == 0) {
            _skip(string.concat(label, ": nothing to send"));
            return 0;
        }
        console2.log(string.concat(label, " (", vm.toString(calls.length), " call(s))"));
        for (uint256 i; i < calls.length; ++i) {
            console2.log(string.concat("  call  ", calls[i].what));
        }
        _execute(signer, calls);
        return calls.length;
    }

    /// @dev Re-reads the whole hand-over after the calls (under `forge script` this is the simulation; VerifyV8 is
    ///      the gate). The last line is the one that matters: after a complete run the deployer holds NOTHING, and a
    ///      run that left it holding anything is a run that did not finish.
    function _postCheck(Inputs memory in_, Contracts memory d, address deployer) internal view {
        (Call[] memory wiring,) = _pendingWiring(in_, d);
        require(_pendingMapping(d).length == 0, "post-check: selectors still unmapped after the hand-over");
        require(wiring.length == 0, "post-check: wiring still incomplete after the hand-over");
        require(_pendingHolders(in_, d).length == 0, "post-check: roles still ungranted after the hand-over");
        require(_pendingRoleTree(d).length == 0, "post-check: role admins/guardians still unset after the hand-over");
        string memory json = rolesJson();
        AccessManager mgr = AccessManager(d.accessManager);
        // T-436 P1-c. THE LOG LINE SAYS "holds nothing" AND IT IS NOW GATED ON EXACTLY THAT. This loop used to walk
        // `_workingRoles`, which cannot contain a role that maps no target function, so OPS_ADMIN could be held by
        // the deployer while this printed a clean hand-over. Enumerating every manifest role id is the difference
        // between "holds none of the roles we thought to ask about" and "holds nothing".
        uint64[] memory roles = _allRoleIds(json);
        for (uint256 i; i < roles.length; ++i) {
            (bool member,) = mgr.hasRole(roles[i], deployer);
            require(
                !member,
                string.concat(
                    "post-check: the deployer still holds role id ",
                    vm.toString(uint256(roles[i])),
                    " -- the hand-over is NOT complete"
                )
            );
        }
        console2.log(
            string.concat(
                "post-check: hand-over complete, the deployer holds none of the ",
                vm.toString(roles.length),
                " roles.v8.json role ids"
            )
        );
    }

    /// @dev T-OP-153. The post-check of a run that withheld steps 8 and 9 by request: the four batches are complete,
    ///      the deployer holds ADMIN -- it MUST, or nothing was deferred and the flag lied -- and the last lines
    ///      list every other manifest role it still holds (the delay-0 working roles of step 4, which is what lets
    ///      it run RegisterMarkets directly) and which scripts finish the hand-over.
    function _postCheckDeferred(Inputs memory in_, Contracts memory d, address deployer) internal view {
        (Call[] memory wiring,) = _pendingWiring(in_, d);
        require(_pendingMapping(d).length == 0, "post-check: selectors still unmapped after the hand-over");
        require(wiring.length == 0, "post-check: wiring still incomplete after the hand-over");
        require(_pendingHolders(in_, d).length == 0, "post-check: roles still ungranted after the hand-over");
        require(_pendingRoleTree(d).length == 0, "post-check: role admins/guardians still unset after the hand-over");
        string memory json = rolesJson();
        AccessManager mgr = AccessManager(d.accessManager);
        uint64 adminRole = roleIdOf(json, "ADMIN");
        (bool deployerIsAdmin,) = mgr.hasRole(adminRole, deployer);
        require(
            deployerIsAdmin,
            "post-check (deferred): V2_DEFER_HANDBACK=true but the deployer does NOT hold ADMIN -- nothing was deferred;"
            " this set already had its hand-back and HandBack.s.sol has nothing to do"
        );
        uint64[] memory roles = _allRoleIds(json);
        string memory held = "";
        uint256 nHeld;
        for (uint256 i; i < roles.length; ++i) {
            if (roles[i] == adminRole) continue;
            (bool member,) = mgr.hasRole(roles[i], deployer);
            if (!member) continue;
            held = string.concat(held, nHeld == 0 ? "" : ", ", vm.toString(uint256(roles[i])));
            ++nHeld;
        }
        console2.log("");
        console2.log(
            string.concat(
                "DEFERRED HAND-BACK (V2_DEFER_HANDBACK=true): the deployer ",
                vm.toString(deployer),
                " HOLDS ADMIN (role 0) and ",
                vm.toString(nHeld),
                " other roles.v8.json role id(s) at delay 0 [",
                held,
                "]. This set is complete; its hand-back (steps 8 and 9) is pending."
            )
        );
        console2.log(
            "  next: deploy the externals; `forge script script/v2/MapExternals.s.sol` (maps them at delay 0);"
            " RegisterMarkets.s.sol as the deployer (V2_ADMIN=<deployer>, ADMIN_PK its key, V2_SCHEDULE unset:"
            " direct, no wait); `forge script script/v2/HandBack.s.sol` (drops the working roles, renounces ADMIN);"
            " then VerifyV8. VerifyV8 FAILS until HandBack has run."
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  OUTPUT
    //////////////////////////////////////////////////////////////*/

    function _logInputs(Inputs memory in_) internal view {
        console2.log(
            string.concat("inputs (chain ", vm.toString(block.chainid), ", block ", vm.toString(block.number), ")")
        );
        console2.log("  V2_DEPLOYER         ", in_.roles.deployer);
        console2.log("  V2_ADMIN_SAFE       ", in_.roles.adminSafe);
        console2.log("  V2_TREASURY_SAFE    ", in_.roles.treasurySafe);
        console2.log("  V2_GUARDIAN         ", in_.roles.guardianKey);
        console2.log("  V2_PRICER           ", in_.roles.pricerKey);
        console2.log("  V2_MM_QUOTER        ", in_.roles.quoterKey);
        console2.log("  V2_CRANKER          ", in_.roles.crankerKey);
        console2.log("  V2_FEE_RECIPIENT    ", in_.roles.feeRecipient);
        console2.log("  V2_USDG             ", in_.ext.usdg);
        console2.log("  V2_SWAP_ROUTER02    ", in_.ext.swapRouter02);
        console2.log("  V2_UNIV3_FACTORY    ", in_.ext.univ3Factory);
        console2.log("  V2_DATA_STREAMS_VERIFIER", in_.ext.dataStreamsVerifier);
        console2.log("  V2_V4_POOL_MANAGER  ", in_.ext.v4PoolManager);
        console2.log("  V2_V4_STATE_VIEW    ", in_.ext.v4StateView);
        console2.log("  V2_TOKEN_POOL_CURRENCY1", in_.flywheel.poolKey.currency1);
    }

    function _logAddresses(Contracts memory d) internal pure {
        console2.log("V2_ADDRESS accessManager", d.accessManager);
        console2.log("V2_ADDRESS flywheel.feeSplitter", d.feeSplitter);
        console2.log("V2_ADDRESS expiryCalendar", d.expiryCalendar);
        console2.log("V2_ADDRESS sources.chainlink", d.chainlinkSource);
        console2.log("V2_ADDRESS sources.univ3", d.univ3Source);
        console2.log("V2_ADDRESS sources.dataStreams", d.dataStreamsSource);
        console2.log("V2_ADDRESS settlementOracle", d.settlementOracle);
        console2.log("V2_ADDRESS keeperRewards", d.keeperRewards);
        console2.log("V2_ADDRESS clearinghouse", d.clearinghouse);
        console2.log("V2_ADDRESS orderBook", d.orderBook);
        console2.log("V2_ADDRESS autoRoller", d.autoRoller);
        console2.log("V2_ADDRESS payoutAdapter", d.payoutRouter);
        console2.log("V2_ADDRESS makerRegistry", d.makerRegistry);
        console2.log("V2_ADDRESS makerVault", d.makerVault);
        console2.log("V2_ADDRESS rewardsDistributor", d.rewardsDistributor);
        console2.log("V2_ADDRESS flywheel.buybackExecutor", d.buybackExecutor);
    }

    /// @notice The ADDRESS artifact, written to `V2_DEPLOY_OUT`: the set as JSON in the shape of the registry's
    ///         `v2.contracts` plus `v2.flywheel` -- one key per contract, `sources` nested, `flywheel` beside them,
    ///         and NOTHING ELSE.
    /// @dev 03-INTERFACES §4: the registry key `payoutAdapter` is KEPT and now names the PayoutRouter, so the batch's
    ///      jq write-back does not have to learn a new key.
    ///
    ///      T-456. THIS SHAPE IS A CONSUMER CONTRACT, NOT A PREFERENCE, and T-436 broke it by adding four
    ///      top-level keys here. `script/v2/DeployV2Batch.sh` `mined_addresses()` walks `Object.keys` of this file
    ///      and, for any key outside `GROUPS = ["sources","flywheel"]`, throws
    ///      `<k> is neither an address nor a known group ... refusing to guess where it is recorded` on anything
    ///      that is not a string; `write_back contracts` repeats the same assumption one step later through
    ///      `put()`. A number and three objects hit both. The launch script therefore died AT THE MINED STEP,
    ///      immediately after the contracts were created -- the worst moment in the sequence to fail.
    ///
    ///      THAT STRICTNESS IS THE GUARD AND IT STAYS. Making the batch tolerant would have traded a loud
    ///      launch-time failure for a silent mis-write, so the fix is here: this artifact is restored byte for
    ///      byte and the write-back's own fields moved to {toDeploymentRecord}. `DeployV2Batch.sh` is unchanged.
    function toJson(Contracts memory d) public pure returns (string memory) {
        // Built in three pieces on purpose: one `string.concat` over all sixteen addresses is more arguments than
        // the via-IR pipeline will lay out in a single stack frame ("too deep in the stack"), and splitting it is
        // cheaper to read than a builder loop.
        return string.concat(_jsonCore(d), _jsonTrading(d), _jsonFlywheel(d));
    }

    function _jsonCore(Contracts memory d) internal pure returns (string memory) {
        return string.concat(
            "{\n  \"accessManager\": ",
            _q(d.accessManager),
            ",\n  \"clearinghouse\": ",
            _q(d.clearinghouse),
            ",\n  \"orderBook\": ",
            _q(d.orderBook),
            ",\n  \"settlementOracle\": ",
            _q(d.settlementOracle),
            ",\n  \"expiryCalendar\": ",
            _q(d.expiryCalendar),
            ",\n  \"keeperRewards\": ",
            _q(d.keeperRewards)
        );
    }

    function _jsonTrading(Contracts memory d) internal pure returns (string memory) {
        return string.concat(
            ",\n  \"autoRoller\": ",
            _q(d.autoRoller),
            ",\n  \"payoutAdapter\": ",
            _q(d.payoutRouter),
            ",\n  \"makerVault\": ",
            _q(d.makerVault),
            ",\n  \"makerRegistry\": ",
            _q(d.makerRegistry),
            ",\n  \"rewardsDistributor\": ",
            _q(d.rewardsDistributor)
        );
    }

    function _jsonFlywheel(Contracts memory d) internal pure returns (string memory) {
        return string.concat(
            ",\n  \"sources\": {\"chainlink\": ",
            _q(d.chainlinkSource),
            ", \"univ3\": ",
            _q(d.univ3Source),
            ", \"dataStreams\": ",
            _q(d.dataStreamsSource),
            "},\n  \"flywheel\": {\"feeSplitter\": ",
            _q(d.feeSplitter),
            ", \"buybackExecutor\": ",
            _q(d.buybackExecutor),
            "}\n}\n"
        );
    }

    /// @notice The WRITE-BACK RECORD, written to the path in env var `V2_DEPLOY_RECORD_OUT`: a SECOND, SEPARATE
    ///         artifact carrying the addresses plus `deployBlock`, `safes`, `wallets` and `bots`.
    /// @dev T-456 moved these four blocks OUT of `V2_DEPLOY_OUT`, where T-436 put them. They belong in a record of
    ///      their own because the address artifact has a consumer that refuses anything but strings and the two
    ///      known groups -- see {toJson}. Consumer note for callhouse `ops/markets/write-back-v8.mjs`: the file
    ///      this writes is its `--deployment <file>` argument, and every field name here is one `plannedWrites`
    ///      reads. `V2_DEPLOY_OUT` is NOT that file and never carries these fields again.
    ///
    ///      `deployBlock` and `flywheel.deployBlock` are JSON NUMBERS. Do not stringify them to get this record
    ///      past a string-only reader: the address artifact exists so that no string-only reader sees them.
    ///
    ///      F-WIRE-10 P1-5. THE FOUR BLOCKS THE WRITE-BACK READS AND THIS FILE NEVER EMITTED.
    ///      `ops/markets/write-back-v8.mjs` `plannedWrites` reads `record.deployBlock`, `record.safes.{admin,
    ///      treasury}`, `record.wallets.{guardian,opsWallet}` and `record.bots.{cranker,pricer,quoter,guardian}`,
    ///      and its `put` helper SKIPS an undefined value silently. So every one of those slots was simply never
    ///      written, no error was raised, and `validateDeployedCompleteness` then opened with an early return on a
    ///      null `v2.deployBlock` -- the very field this script did not emit -- which switched the completeness
    ///      check OFF for exactly the registry it was written to catch.
    ///
    ///      THE TWO BLOCKS COME FROM {recordBlocks}, and each is emitted ONLY for a group this run created. The
    ///      version T-436 landed stamped `block.number` unconditionally, which is the block of THIS run -- so a
    ///      resumed run (it "deploys only what is missing"), a check-mode run (it creates nothing) and a set whose
    ///      splitter was deployed earlier each recorded a start block AFTER the contracts existed, and the indexer
    ///      would silently skip their first events. A block this run cannot vouch for is JSON null instead: the
    ///      write-back skips a null and refuses a record with no top-level `deployBlock` (T-444), which is loud.
    ///      Both stay JSON NUMBERS when present. Neither is ever a string.
    ///
    ///      WHAT THIS DOES NOT DO, stated rather than left to be discovered: `wallets.opsWallet` IS NOT EMITTED
    ///      because this script has no such input. `Roles` carries the two Safes, the four bot keys, the fee
    ///      recipient and the deployer, and inventing a value for the ops wallet would be worse than the omission
    ///      it replaces. The write-back leaves that slot null and the completeness rule is what must report it.
    ///
    ///      THE ADDRESSES ARE AT THE TOP LEVEL HERE, NOT UNDER A `contracts` WRAPPER, AND THAT WAS MEASURED
    ///      RATHER THAN CHOSEN. `ops/markets/write-back-v8.mjs` at callhouse `6d10752c` loops its `CONTRACTS`
    ///      list and reads `record[k]`, and its `KNOWN_RECORD_KEYS` is `[...CONTRACTS, sources, flywheel,
    ///      deployBlock, safes, wallets, bots]` -- no `contracts` member -- so `refuseUnknownKeys` throws on a
    ///      wrapped record before a single address is written. A wrapped version of this function was built
    ///      first, on a coordinator amendment that said to match what the write-back reads; that instruction was
    ///      correct when it was written and went stale when T-453 landed and moved the reader to the top level.
    ///      Both halves of this file's record therefore use ONE layout, the same one {toJson} emits, which is
    ///      also what `script/v2/DeployV2Batch.sh` and `script/v2/batch-refusals.sh` read with jq.
    ///
    ///      IF THE READER EVER MOVES BACK, this is the function to change, and the way to find out is to read
    ///      `plannedWrites` and `KNOWN_RECORD_KEYS` rather than a row description -- three rows on this seam in
    ///      one day were each written against a different snapshot of that one consumer.
    function toDeploymentRecord(Roles memory r, Contracts memory d, RecordBlocks memory b)
        public
        pure
        returns (string memory)
    {
        // The address half is the SAME builders {toJson} uses, so the two artifacts cannot drift into two
        // layouts. {_jsonFlywheel} closes the object, so this uses the open variant and closes it itself.
        return string.concat(
            _jsonCore(d), _jsonTrading(d), _recordSourcesAndFlywheel(d, b.flywheel), _recordPrincipals(r, b.core)
        );
    }

    /// @notice Which start blocks a run that was GIVEN `given` can vouch for: `block.number` for a group it will
    ///         create in full, zero (emitted as null) for a group any member of which already existed.
    /// @dev Two groups because the registry has two blocks. `deployBlock` starts the indexer on `v2.contracts.*`
    ///      (sources included), `flywheel.deployBlock` on the splitter and the buyback executor --
    ///      `build-markets.mjs` says the splitter may be deployed BEFORE the core, so the two can differ. A contract
    ///      that was given was created in some earlier block this script never saw, so a group with one is unknown.
    ///
    ///      `block.number` is the block forge SIMULATES at; the creates are mined after it. It is therefore a LOWER
    ///      bound on the creation block, which is the safe direction for a start block: the indexer reads a few
    ///      blocks it did not need rather than missing the ones it did. Block 0 cannot be told from "unknown" and
    ///      is not a block the write-back accepts anyway, so it is emitted as null too.
    ///
    ///      The contracts `DeployV8` does NOT deploy (the house vaults, hedger, lender distributor, earn vault and
    ///      stock-venue adapter) are supplied by address on every run and are not in either group.
    function recordBlocks(Contracts memory given) public view returns (RecordBlocks memory b) {
        if (!_anyCoreGiven(given)) b.core = block.number;
        if (given.feeSplitter == address(0) && given.buybackExecutor == address(0)) b.flywheel = block.number;
    }

    /// @dev Every contract `DeployV8` creates outside the flywheel pair, in {V2DeployBase.Contracts} order.
    function _anyCoreGiven(Contracts memory e) internal pure returns (bool) {
        return e.accessManager != address(0) || e.expiryCalendar != address(0) || e.chainlinkSource != address(0)
            || e.univ3Source != address(0) || e.dataStreamsSource != address(0) || e.settlementOracle != address(0)
            || e.keeperRewards != address(0) || e.clearinghouse != address(0) || e.orderBook != address(0)
            || e.autoRoller != address(0) || e.payoutRouter != address(0) || e.makerRegistry != address(0)
            || e.makerVault != address(0) || e.rewardsDistributor != address(0);
    }

    /// @dev A start block, or JSON null when this run cannot vouch for one. A NUMBER when present, never a string.
    function _blockOrNull(uint256 n) internal pure returns (string memory) {
        return n == 0 ? "null" : vm.toString(n);
    }

    /// @dev `sources` and `flywheel`, in the record's variant: same members as {_jsonFlywheel} plus the
    ///      flywheel's own `deployBlock`, and NOT closing the object because the principals follow.
    ///
    ///      WHY `flywheel.deployBlock` IS HERE. `ops/markets/build-markets.mjs` refuses a registry whose
    ///      `v2.flywheel.feeSplitter` is set while `v2.flywheel.deployBlock` is null -- "the indexer has no block
    ///      to start the flywheel from". The run that creates the splitter is the only place that value can
    ///      honestly come from, so a run that was GIVEN the splitter emits null here ({recordBlocks}).
    function _recordSourcesAndFlywheel(Contracts memory d, uint256 flywheelBlock)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            ",\n  \"sources\": {\"chainlink\": ",
            _q(d.chainlinkSource),
            ", \"univ3\": ",
            _q(d.univ3Source),
            ", \"dataStreams\": ",
            _q(d.dataStreamsSource),
            "},\n  \"flywheel\": {\"feeSplitter\": ",
            _q(d.feeSplitter),
            ", \"buybackExecutor\": ",
            _q(d.buybackExecutor),
            ", \"deployBlock\": ",
            _blockOrNull(flywheelBlock),
            "}"
        );
    }

    function _recordPrincipals(Roles memory r, uint256 coreBlock) internal pure returns (string memory) {
        return string.concat(
            ",\n  \"deployBlock\": ",
            _blockOrNull(coreBlock),
            ",\n  \"safes\": {\"admin\": ",
            _q(r.adminSafe),
            ", \"treasury\": ",
            _q(r.treasurySafe),
            "},\n  \"wallets\": {\"guardian\": ",
            _q(r.guardianKey),
            "},\n  \"bots\": {\"cranker\": ",
            _q(r.crankerKey),
            ", \"pricer\": ",
            _q(r.pricerKey),
            ", \"quoter\": ",
            _q(r.quoterKey),
            ", \"guardian\": ",
            _q(r.guardianKey),
            "}\n}\n"
        );
    }

    function _q(address a) internal pure returns (string memory) {
        return a == address(0) ? "null" : string.concat("\"", vm.toString(a), "\"");
    }
}

/// @notice The one view `DeployV8` needs from the buyback executor, so the linkage check does not have to import the
///         whole contract (and with it the Uniswap v4 dependency graph) into the deploy script.
/// @dev Mirrors `src/v2/periphery/V4BuybackExecutor.sol:162` `address public immutable splitter`.
interface IBuybackExecutorView {
    function splitter() external view returns (address);
}
