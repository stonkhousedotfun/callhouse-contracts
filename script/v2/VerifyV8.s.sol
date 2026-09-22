// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {CommonBase} from "forge-std/Base.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {V2Constants} from "../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../src/v2/interfaces/V2Types.sol";
import {V2Errors} from "../../src/v2/interfaces/V2Errors.sol";
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
import {V4Currency} from "../../src/v2/periphery/v4/V4Types.sol";
import {IPayoutRouter} from "../../src/v2/interfaces/IPayoutRouter.sol";
import {FeeSplitter} from "../../src/v2/periphery/FeeSplitter.sol";
import {V4BuybackExecutor} from "../../src/v2/periphery/V4BuybackExecutor.sol";
import {PayoutRouter} from "../../src/v2/periphery/PayoutRouter.sol";
import {UniV3PayoutAdapter} from "../../src/v2/periphery/UniV3PayoutAdapter.sol";
import {BytecodeCheck} from "../lib/BytecodeCheck.sol";
import {PinDryRun} from "./lib/PinDryRun.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @dev `Managed` exposes `authority()` through OpenZeppelin's `AccessManaged`. VerifyV8 reads it over a list of
///      addresses of different concrete types, so it needs one type to call through; this is that and nothing more.
interface IManagedAuthority {
    function authority() external view returns (address);
}

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
/// @dev Run after `forge build`. `script/v2/DeployV2Batch.sh --verify` exports the environment from the registry; by
///      hand export the `V2_*` variables of lib/V2DeployBase.sol and:
///        forge script script/v2/VerifyV8.s.sol --rpc-url $RH_RPC --no-storage-caching
///
///      WHAT IS CHECKED
///        1. chain id.
///        2. bytecode: each of the 16 contracts, byte for byte outside the immutable slots (the v2 contracts link no
///           library), against its PINNED artifact when {PINNED_MANIFEST} lists that address under that name on this
///           chain -- the live set, whose runtimes were built from the commit that deployed it and proven against the
///           chain (script/v2/pin-deployed.sh, C3-101) -- and against `out/` of this checkout otherwise (a fresh
///           deploy or rehearsal). This is what proves the logic and every compiled ceiling are the deployed commit's,
///           from any later checkout.
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
///           effectiveAt). INTERFACE_VERSION 8 DELETED the `premiumFeeBps <= resaleFeeBps` check: v8 launches
///           premium 500 / resale 0, which the v7 rule refused, and V8-DESIGN.md §4 records the resale dodge as a
///           knowingly accepted risk. The fee CEILINGS still FAIL either way. Payout slippage, the SIX
///           bounties (CANCEL_STALE from INTERFACE_VERSION 7), daily cap, min redeem payout, min roll units, vault
///           limits == the launch values (V2_* overrides). With V2_EXPECT_FRESH=true (the
///           default, right after a deploy) a difference FAILs; with false it is an `info` line, because after launch
///           these are the admin's to tune (the registry says "launch values; the contracts hold the live ones"). Every
///           compiled ceiling FAILs either way.
///        8. calendar: every V2_HOLIDAYS day is a holiday.
///        9. roles (INTERFACE_VERSION 8, all of it read from `script/v2/roles.v8.json` at run time -- no copy of the
///           table lives in this file): HANDOVER, the Admin Safe holds ADMIN at the manifest delay AND has code AND
///           has no pending change to that delay (T-436: `hasRole` discards the pending half), the deployer holds
///           ADMIN no longer, and every managed contract's `authority()` is the accessManager (V4BuybackExecutor is
///           skipped BY MANIFEST NAME: it is deliberately not Managed and its manifest entry is empty).
///           PRINCIPALS, every manifest holder holds every role it is given at the manifest delay and has no pending
///           change to that delay, every holder of a role in 0..6 is a contract, no bot key and not the deployer
///           holds any role in 0..6, every known principal -- the deployer and the treasury Safe included -- holds
///           EXACTLY its manifest roles over EVERY role id in the manifest, which is what covers the instant lanes
///           7..10 that the 0..6 sweep cannot see (SEC-38, closed by T-436), no two manifest targets are the same
///           address, each externally supplied target answers the interface its name claims (T-426), and the seven
///           principals are distinct.
///           EVERY DEPLOYER ASSERTION ABOVE NEEDS V2_DEPLOYER. It is optional and defaults to zero, and a zero
///           deployer is skipped by all three, so without it the hand-over has asserted nothing about the deployer.
///           That is reported as NOT CHECKED -- an `info` line and a count under the VERIFY line -- and not as a
///           FAIL, because `DeployV2Batch.sh --verify` has no deployer to pass (SEC-38-R, T-SEC-P4-VERIFYV8-BOT-LANES).
///           MANIFEST, every listed selector maps to its manifest role, every role's admin
///           and guardian match (an unlisted one means ADMIN, which is AccessManager's own default), every grant
///           delay is 0, and no MANIFEST target is closed or carries a target admin delay -- the manifest, because
///           until T-182 that last pass walked the sixteen-entry deploy list and could not see HouseVault,
///           HouseVaultFactory, Hedger or the lender RewardsDistributor. NO UNLISTED RESTRICTED SELECTOR,
///           each compiled ABI is walked and every selector must answer to exactly its manifest role or to 0.
///           MONEY LANES, the six money-lane treasuries are V2_TREASURY_SAFE -- feeSplitter, keeperRewards,
///           makerVault, rewardsDistributor and, from T-173, rewardsDistributorLender and hedger -- each read
///           through `treasury()`, where a subject that cannot be read FAILS rather than passing unseen; both fee
///           recipients are the FeeSplitter, the splitter is not the treasury, the OrderBook is the only known
///           minter, and neither a discount module nor a funding allowance is set at launch.
///           WHAT A SCRIPT CANNOT CHECK, said rather than faked: AccessManager does not enumerate role members, so
///           "no EOA holds a delayed role" is the two answerable halves above, and the minter and funding sweeps are
///           bounded to the sixteen contracts and the seven principals this run knows.
///           V2_SKIP_EXTERNALS (T-OP-140, owner item 19). A comma list of MANIFEST NAMES among the six externally
///           supplied targets (HouseVault, HouseVaultFactory, Hedger, RewardsDistributorLender, EarnVault,
///           StockVenueAdapter) that this run DELIBERATELY did not deploy -- the driver's `--skip-external
///           hedger,rewardsDistributorLender` (registry keys) becomes `V2_SKIP_EXTERNALS=Hedger,RewardsDistributorLender`
///           here. Each named target is a NOT CHECKED TARGET, by name, in every group that would have read it
///           (authorities, manifest selectors, the unlisted-selector probe, the money lanes): not `present`, not
///           mapped, not walked -- and not a FAIL. The list itself fails closed: a name that is not one of the six
///           REVERTS (a core target cannot be skipped; a misspelling or the registry-key spelling is refused), a
///           name whose V2_* variable IS supplied REVERTS naming the variable (a skip of a supplied target is the
///           look-away a verifier must refuse), and a duplicate REVERTS. The verdict then reads
///           `VERIFY PASSED: <n> checks with <m> targets NOT CHECKED (V2_SKIP_EXTERNALS)` followed by a
///           `NOT CHECKED targets: <m> (<names>)` line -- never a bare PASS; the `VERIFY PASSED: <n> checks` prefix
///           the drivers parse is unchanged. Unset means no skip and today's FAIL text for an unsupplied external.
///       10. markets (V2_TICKERS, the registry rows with registeredAt): token symbol and decimals, feed description and
///           decimals; Clearinghouse market {enabled == (v2.status live), strikeTick, exerciseFeeBps, oracle, mintFeePpm} -- the rent rate
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
/// @notice The Safe reads {VerifyV8._safeTopology} needs, declared here rather than imported.
/// @dev NOT imported from `script/Verify.s.sol`, which declares an identical `ISafeView` at :14. Importing it
///      would compile the whole v7 verify script as a dependency of the v8 one and couple this file's build to a
///      script that live rows are preparing to freeze and retire. The three signatures are Safe's, not ours, and
///      are fixed by the deployed singleton; a local declaration cannot drift from something it does not own.
interface ISafeTopology {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 pageSize) external view returns (address[] memory, address);
}

/// @dev The number of FeeSplitter pointers {VerifyV8._flywheelSubjects} reads, pinned against the deploy script's
///      own count in `VerifyV8.t.sol:test_flywheelPointerCountsAgree`. T-222 suspicion 3: this list mirrors
///      `DeployV8._splitterCalls` BY HAND, and before that test nothing made it grow when the deploy batch did -- a
///      sixth pointer would have shipped unverified while this check still reported "all 5 flywheel pointers are
///      wired", which is the failure the check exists to prevent, wearing the check's own words.
uint256 constant VERIFY_V8_FLYWHEEL_POINTERS = 5;

/// @notice The two call frames `VerifyV8` needs and, under `forge script`, cannot make for itself (T-OP-152).
///
/// @dev WHY THIS CONTRACT EXISTS. Check group 4 ({VerifyV8-_noUnlistedRestricted}) needs (a) one EVM memory frame
///      per manifest target, because an artifact JSON of ~290 KB parsed in the caller's frame never frees and the
///      cumulative expansion ran over the gas limit, and (b) a frame that ALWAYS reverts around each stranger
///      probe, so the EVM itself undoes anything a probe touched. Both used to be external calls to the script's
///      own address (`this.<fn>()`). That works in a forge TEST, where the script is an ordinary contract, and it
///      ABORTS under `forge script`: the runner refuses `address(this)` in a script contract ("Usage of
///      `address(this)` detected in script contract. Script contracts are ephemeral and their addresses should not
///      be relied upon"), so every group after 3 and the VERIFY PASSED/FAILED summary never ran, and the drivers
///      read the log of a script that had stopped mid-walk. Measured at forge 1.3.5-foundry-zksync-v0.1.9 on a
///      scratch project: the same two frames made against a `new`-deployed helper run to completion and record no
///      transaction. VerifyV8 stays read-only: this contract is created inside the simulation, never broadcast.
///
///      NOTHING ABOUT THE CHECK MOVED EXCEPT THE FRAME IT RUNS IN. The manifest is still read by VerifyV8 (which
///      resolves every target into a {Target} before the call); the artifact is still read here, in the frame that
///      dies on return; the probe still runs inside a frame that reverts with `abi.encode(ok, returndata)`; and the
///      caller the target sees is still an address that holds no role in the manager and has no execution delay,
///      so a gated selector takes the `delay == 0` arm and reverts `NotAuthorized` at once. Not a `Script`: a
///      plain contract, which is the whole point.
contract VerifyProbe is CommonBase {
    /// @dev One `roles.v8.json` target, resolved by VerifyV8 so this frame never touches the manifest.
    struct Target {
        /// @dev The manifest name, for the info lines.
        string name;
        /// @dev The deployed address the manifest name resolves to.
        address target;
        /// @dev `out/<Name>.sol/<Name>.json`; VerifyV8 has already required it to exist.
        string artifact;
        /// @dev The signatures `roles.v8.json` lists for this target.
        string[] sigs;
        /// @dev The role each entry of `sigs` must answer to on chain, parallel to `sigs`.
        uint64[] wantRoles;
        /// @dev Signatures that refuse a stranger WITHOUT being manager-`restricted` ({VerifyV8-unmappedExemptSignatures}
        ///      plus the manifest's `.unrestricted.<target>` rows), so an unlisted one of these is not an omission.
        string[] exempt;
    }

    /// @dev Gas ceiling on one probe call. A probe that runs out of gas returns no revert data, which reads as
    ///      "not gated" -- so the stipend has to be far above what a refusal costs and far below the run's budget.
    ///      `Managed._checkCanCall` refuses inside one staticcall to the authority; the whole path is a few tens of
    ///      thousands of gas even behind `nonReentrant`. Without a ceiling a single pathological body could take
    ///      63/64 of the remaining gas and end the run mid-walk.
    uint256 private constant PROBE_GAS = 100_000;

    /// @dev Zero bytes appended after the selector so the function's arguments DECODE. Solidity decodes arguments
    ///      before it runs modifiers, so `abi.encodePacked(selector)` reverts on the decode and never reaches
    ///      `restricted` -- the probe would report every gated selector with arguments as ungated. All-zero args
    ///      decode for every ABI type in this codebase, including the dynamic ones: a head word of 0 is an offset
    ///      of 0, whose length word is that same zero, i.e. an empty `bytes`/`string`/array. Trailing calldata past
    ///      what a signature needs is ignored, so one generous block covers every arity.
    uint256 private constant PROBE_ARG_BYTES = 1024;

    /// @notice One target of {VerifyV8-_noUnlistedRestricted}, in its own EVM memory frame: the artifact and its
    ///         method list are allocated here and die on return. Prints the same `info` lines VerifyV8 printed
    ///         when this walk lived inside it; returns false when any selector is mapped to a role the manifest
    ///         does not give it, or is gated on chain and unlisted.
    function walkTarget(AccessManager mgr, Target memory t) external returns (bool clean) {
        clean = true;
        string[] memory methods = vm.parseJsonKeys(vm.readFile(t.artifact), ".methodIdentifiers");
        // THE PROBE NEEDS A POSITIVE CONTROL PER TARGET, AND THE MANIFEST ALREADY SUPPLIES ONE.
        //
        // The walk below reads "did not refuse a stranger" as "not gated". That reading is worth nothing unless
        // this address really holds the contract whose ABI is being walked, and two ways it does not both answer
        // cheerfully rather than loudly: an address with NO CODE accepts every call and returns nothing, and a
        // DIFFERENT contract at the address answers a `restricted` selector however it likes -- while
        // `out/<name>.sol/<name>.json`, where the selector list comes from, still describes the intended one.
        //
        // So ask the manifest's OWN rows first. Every signature `roles.v8.json` lists for this target is one the
        // real contract must refuse a stranger on. If NONE of them does, the instrument is not pointed at the
        // contract the manifest means and no negative from it is worth reading -- skip the target and NAME it, so
        // a skipped target can never be mistaken for a clean one. If SOME refuse and some do not, that is not an
        // identity problem, it is a specific finding about specific selectors, and it is reported as one.
        //
        // WHY NOT {BytecodeCheck-runtimeMatches}, WHICH IS THE FILE'S REAL IDENTITY TEST: measured, it costs about
        // 12.7 M gas per target and 266 M over the twenty-one, which pushed three cases in
        // `test/v2/unit/VerifyV8.t.sol` past the 2^30 block gas limit. This control costs one call per manifest
        // row. It is also the sharper question here: bytecode equality answers "is this the compiled artifact",
        // and what this walk needs to know is "does this address enforce anything at all".
        //
        // A TARGET WITH NO MANIFEST ROWS HAS NO CONTROL and is skipped for that reason, named. `V4BuybackExecutor`
        // is the one such target today: `roles.v8.json` gives it zero selectors on purpose.
        //
        // The identity failure itself is NOT re-reported here. A target whose runtime disagrees with its artifact
        // is already a named failure of check group 1 ({VerifyV8-_bytecode}), and one this run cannot place is a
        // named failure of {VerifyV8-_authorities}; a second red line would add no information and would move a
        // count that `test/v2/unit/VerifyV8.t.sol` measures.
        uint256 refusing;
        for (uint256 s; s < t.sigs.length; ++s) {
            if (refusesAStranger(t.target, t.sigs[s])) ++refusing;
        }
        bool probeable = t.sigs.length != 0 && refusing != 0;
        if (!probeable) {
            // T-OP-166 F1 / T-OP-171. THE CONTROL'S OWN CONCLUSION IS THE VERDICT. This branch used to print an
            // `info` line and leave `clean` true, so an address that enforces NOTHING -- no `restricted` selector
            // answers to anyone -- verified clean: `_authorities` passes anything that answers `authority()`, the
            // manifest walk reads the manager's map, which is keyed by address and says nothing about what lives
            // there, `_identity` accepts any non-empty return and `_bytecode` never covers the six externals. This
            // walk is the ONLY question that asks an external whether it enforces anything, and its answer "no"
            // was being discarded. A target with no manifest rows at all (V4BuybackExecutor, by design) still has
            // no control and is skipped by name; a target WITH rows that refuses a stranger on none of them is a
            // failure of the group, named here, and the unlisted-selector loop below is skipped for it because a
            // negative from an instrument pointed at the wrong contract is worth nothing either way.
            if (t.sigs.length == 0) {
                _info(
                    string.concat(
                        t.name,
                        " has no roles.v8.json selector to control the probe with, so the stranger probe is skipped"
                    )
                );
            } else {
                clean = false;
                _info(
                    string.concat(
                        t.name,
                        " refuses a stranger on NONE of its ",
                        vm.toString(t.sigs.length),
                        " roles.v8.json selectors: it is not the contract the manifest names here, or it enforces"
                        " nothing -- FAIL (the stranger probe cannot be read from it)"
                    )
                );
            }
        } else if (refusing != t.sigs.length) {
            for (uint256 s; s < t.sigs.length; ++s) {
                if (refusesAStranger(t.target, t.sigs[s])) continue;
                clean = false;
                _info(string.concat(t.name, ".", t.sigs[s], " is named by roles.v8.json and admits a stranger"));
            }
        }
        for (uint256 m; m < methods.length; ++m) {
            bytes4 sel = _selectorOf(methods[m]);
            uint64 onChain = mgr.getTargetFunctionRole(t.target, sel);
            uint64 want;
            // T-SEC-06. `listed` IS NOT `want != 0`. Both branches below need to know whether the manifest NAMES
            // this signature, and the role id cannot answer that: an unnamed signature and a signature named as
            // ADMIN's both leave `want` at 0. `notes.adminHasNoTarget` says the second case does not exist today,
            // which is exactly the kind of premise that holds until it does not.
            bool listed;
            for (uint256 s; s < t.sigs.length; ++s) {
                if (_selectorOf(t.sigs[s]) == sel) {
                    want = t.wantRoles[s];
                    listed = true;
                    break;
                }
            }
            if (onChain != want) {
                clean = false;
                _info(string.concat(t.name, ".", methods[m], " answers to role ", vm.toString(uint256(onChain))));
            }
            // THE FINDING THIS GROUP IS NAMED AFTER. `listed` selectors were already probed above, as the
            // control; what is left is a selector the manifest does not name, which the role comparison cannot
            // see because both sides of it are zero. Ask the contract instead.
            if (listed || !probeable) continue;
            if (refusesAStranger(t.target, methods[m]) && !_exempt(t.exempt, methods[m])) {
                clean = false;
                _info(string.concat(t.name, ".", methods[m], " is gated on chain and roles.v8.json omits it"));
            }
        }
    }

    /// @dev Whether `sig` on `target` refuses THIS contract the way `Managed` refuses an unauthorised caller.
    ///
    ///      THIS IS THE FACT THE MANAGER CANNOT GIVE. `getTargetFunctionRole` and `canCall` both answer
    ///      "role 0 / not allowed" for a `restricted` selector nobody mapped AND for a selector that is not
    ///      `restricted` at all. Only the target tells them apart, and it tells them apart by reverting
    ///      `V2Errors.NotAuthorized` (src/v2/access/Managed.sol:65-71).
    ///
    ///      A CALL, NOT A STATICCALL, AND THAT IS NOT A STYLE CHOICE. The house modifier order is
    ///      `external nonReentrant restricted`, so the reentrancy guard's transient write runs BEFORE the access
    ///      check. Under a staticcall every gated selector in the protocol would revert on that write instead of on
    ///      the authority, the probe would report the entire deployment ungated, and this group would have swapped
    ///      a blind comparison for a blind instrument.
    ///
    ///      SO THE CALL IS MADE INSIDE A FRAME THAT ALWAYS REVERTS. {probeAndRevert} performs it and then reverts
    ///      with the answer as its revert data, so the EVM itself undoes anything a probe touched -- a probe that
    ///      SUCCEEDS is the case that matters, since a refusal already undoes itself, and a verifier that mutated
    ///      the state it is about to read would be worse than one that reads nothing. This was a
    ///      {Vm-snapshotState}/{Vm-revertToState} pair around the whole walk first, and that is the more obvious
    ///      shape and the wrong one: the rollback also erased storage the walk itself had written between the two
    ///      calls, which silently zeroed the counter in `test/v2/unit/VerifyV8.t.sol`'s
    ///      `test_verify_manifestWalkVisitsEveryTargetInFreshFrames` and would have zeroed any later bookkeeping
    ///      just as quietly. A frame that reverts undoes the probe and nothing else.
    ///
    ///      `this.probeAndRevert` is a self-call on THIS contract, which is not the script, so the runner's
    ///      `address(this)` guard does not apply; the caller the target sees is this contract, which holds no role
    ///      in the manager and has no execution delay, so a gated selector always takes the `delay == 0` arm and
    ///      reverts immediately. That assumption is not left to a comment: every manifest-listed selector is probed
    ///      as a positive control by {walkTarget}.
    function refusesAStranger(address target, string memory sig) public returns (bool) {
        bytes memory data = bytes.concat(_selectorOf(sig), new bytes(PROBE_ARG_BYTES));
        try this.probeAndRevert(target, data) {
            // {probeAndRevert} ends in `revert`. Reaching here means it was replaced by something that does not.
            revert("VerifyV8: the stranger probe returned instead of reverting");
        } catch (bytes memory raw) {
            // FAIL LOUD RATHER THAN READ A TRUNCATED ANSWER AS "NOT GATED". Anything other than this frame's own
            // encoded result -- an out-of-gas, a revert from somewhere else -- is the probe failing, not the
            // target answering, and the difference is exactly the false green this whole row is about.
            require(raw.length >= 64, string.concat("VerifyV8: the stranger probe did not answer for ", sig));
            (bool ok, bytes memory ret) = abi.decode(raw, (bool, bytes));
            return !ok && ret.length >= 4 && bytes4(ret) == V2Errors.NotAuthorized.selector;
        }
    }

    /// @notice Calls `data` on `target` and then ALWAYS reverts, carrying `abi.encode(ok, returndata)` as the
    ///         revert reason. Public only so {refusesAStranger} can reach it through `this` and get a frame the
    ///         EVM will roll back for it; it is not meant to be called from anywhere else.
    /// @dev The revert is the point, not an error path. Do not "fix" this into a `view` or a plain return.
    function probeAndRevert(address target, bytes memory data) public {
        (bool ok, bytes memory ret) = target.call{gas: PROBE_GAS}(data);
        bytes memory out = abi.encode(ok, ret);
        assembly ("memory-safe") {
            revert(add(out, 0x20), mload(out))
        }
    }

    /// @dev Mirrors {V2DeployBase-selectorOf}; this contract is not a `Script` and cannot inherit it.
    function _selectorOf(string memory sig) private pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function _exempt(string[] memory exempt, string memory method) private pure returns (bool) {
        for (uint256 i; i < exempt.length; ++i) {
            if (keccak256(bytes(exempt[i])) == keccak256(bytes(method))) return true;
        }
        return false;
    }

    /// @dev The same line shape as {VerifyV8-_info}, so the log reads as one report.
    function _info(string memory what) private pure {
        console2.log(string.concat("  info  ", what));
    }
}

contract VerifyV8 is BytecodeCheck, V2DeployBase {
    struct Inputs {
        Contracts c;
        Roles roles;
        /// @dev V2_DEPLOYER, optional. When set it must hold no role at all. When unset (zero) every deployer
        ///      assertion is vacuous, so {_roles} reports the hand-over as NOT CHECKED rather than letting it pass.
        address deployer;
        External ext;
        Params params;
        uint32[] holidays;
        MarketIn[] markets; // V2_TICKERS, optional
        /// @dev INTERFACE_VERSION 7: the rent rate the registry asks of each market, parallel to `markets`
        ///      (V2_MARKET_<T>_MINT_FEE_PPM over V2_MINT_FEE_PPM over 0), compared with MarketConfig.mintFeePpm.
        uint32[] mintFeePpm;
        /// @dev INTERFACE_VERSION 8: `V2_ALLOW_RENT`. THIS COMMENT DESCRIBED THE v7 RULE AND WAS THE EXACT
        ///      INVERSE OF THE CODE IT DOCUMENTS (T-CV-DEPLOY-VERIFY-SCRIPTS). v7 treated a live market whose
        ///      `mintFeePpm` is 0 as a FAIL, because rent was the only writer fee. v8 takes 5% of the premium on
        ///      first sale and launches rent at 0 everywhere, so 0 is the EXPECTED value and a NON-ZERO rate is
        ///      the failure -- see the check at {_market} and V8-DESIGN.md §4.3. It also named two identifiers
        ///      that do not exist at this base: the flag is `V2_ALLOW_RENT`, not v7's `V2_ALLOW_ZERO_RENT`
        ///      (`docs/DEPLOY-V2.md:505` records that rename as already done), and the gate is
        ///      {V2DeployBase.rentAllowed}, not `zeroRentAllowed`.
        ///      What is unchanged and still true: the opt-in is granted only under the forge TEST runner, so a
        ///      `forge script VerifyV8 --rpc-url <live 4663>` cannot sign off a rent-bearing market with an
        ///      environment variable however it was invoked -- VerifyV8 broadcasts nothing, so nothing keyed to
        ///      `--broadcast` ever covered this path.
        bool allowRent;
        address[] unregistered; // V2_UNREGISTERED_ASSETS, optional
        bool expectFresh; // V2_EXPECT_FRESH, default true
        uint256 expectChainId; // V2_EXPECT_CHAIN_ID, default 4663
        /// @dev T-258. What {_safes} requires of BOTH the Admin and Treasury Safes. Inputs rather than literals:
        ///      the 2-of-3 is an operational arrangement (callhouse-docs `docs/protocol/roles.md`), so the verifier
        ///      must be able to assert whatever arrangement is actually in force without being edited. Defaults
        ///      match v7's `EXPECT_SAFE_THRESHOLD` / `EXPECT_SAFE_OWNERS` at `script/Verify.s.sol:462-467`.
        uint256 safeMinThreshold; // V2_EXPECT_SAFE_THRESHOLD, default 2
        uint256 safeMinOwners; // V2_EXPECT_SAFE_OWNERS, default 3
        /// @dev T-OP-140 (owner item 19). `V2_SKIP_EXTERNALS`: the MANIFEST NAMES (roles.v8.json `targets` keys, e.g.
        ///      `Hedger,RewardsDistributorLender`) of externally supplied targets this run DELIBERATELY did not
        ///      deploy. Each is reported as a visible NOT CHECKED target in {_authorities} and {_manifest} instead
        ///      of the "has no address" FAIL an unsupplied external otherwise earns, and the PASSED line says so.
        ///      Parsed by {inputsFromEnv}; validated by {_validateSkips} at the top of {check}, which REVERTS on a
        ///      name that is not one of the six externals and on a name whose target IS supplied (skipping a
        ///      supplied target is the false-green shape). A run-time decision of the driver's `--skip-external`
        ///      flag, never registry data. Unset means empty: today's behaviour and FAIL text, unchanged.
        ///
        ///      SPELLING, AGREED BY CONSTRUCTION WITH THE DRIVER. The driver takes REGISTRY KEYS
        ///      (`--skip-external hedger,rewardsDistributorLender`, the wrapper's EXTERNAL_KEYS) and exports the
        ///      manifest names (`V2_SKIP_EXTERNALS=Hedger,RewardsDistributorLender`) -- T-OP-116's
        ///      `externals_parse_skip` in script/v2/lib/registry-env.sh. This script accepts ONLY names that are
        ///      both a `targets` key of the manifest it walks AND one of {_isExternalTarget}'s six, which are the
        ///      names `_targetOf` resolves and `DeployV8._externallySupplied` lists; the driver's table is pinned
        ///      to the same manifest keys on its side. A misspelt or registry-key spelling reverts here by name.
        string[] skipExternals;
        /// @dev T-OP-171 (T-OP-166 F2). `V2_EXPECT_CHANGED`: the `_param` SUBJECTS (see {PARAM_SUBJECTS}) the caller
        ///      knows the admin has re-tuned since launch, so a live-set (`V2_EXPECT_FRESH=false`) verify reports
        ///      each of them as `info` instead of FAIL. Per subject, never blanket: an unlisted mismatch is a FAIL in
        ///      EVERY mode, and a name that is not a known subject REVERTS by name ({_validateExpectChanged}). A
        ///      fresh verify ignores the list: launch values are launch values.
        string[] expectChanged;
        /// @dev T-OP-171 (owner: two House vaults). One address per entry of `markets`, from
        ///      `V2_MARKET_<TICKER>_HOUSE_VAULT` (the driver's projection of `markets[].v2.houseVault`, T-OP-156's
        ///      key; unset when null). Each non-zero one is walked as a HouseVault subject with the ticker in every
        ///      line ({_houseVaults}); a zero one is NOT CHECKED naming the ticker.
        address[] marketVaults;
    }

    uint256 internal failures;
    uint256 internal passes;
    /// @dev T-OP-152. The frames group 4 runs in; created on first use, inside the simulation only.
    VerifyProbe internal probe;
    /// @dev Assertions that had no subject to check, counted by {_notChecked}. Neither a pass nor a failure.
    uint256 internal notChecked;
    /// @dev T-OP-140. The validated `V2_SKIP_EXTERNALS` list, copied to storage by {check} so the groups can ask
    ///      {_isSkipped} without threading `Inputs` through frames that are already near the via_ir stack limit
    ///      ({_authorities} was over it once, see {_infoNamed}).
    string[] internal skipList;
    /// @dev T-OP-171. The validated `V2_EXPECT_CHANGED` list, in storage for the same reason {skipList} is.
    string[] internal changedList;
    /// @dev T-OP-140. The manifest targets a group actually put in the NOT CHECKED group on the caller's say-so,
    ///      recorded by {_skippedTarget} so {run} can print them under the verdict.
    string[] internal skippedTargets;

    function run() external {
        runWith(inputsFromEnv());
    }

    /// @notice {run} with explicit inputs: every check, then the summary line, then a revert on any failure.
    /// @dev Public so `test/v2/unit/VerifyV8.t.sol` can drive the WHOLE path -- every group through the summary --
    ///      on its in-test fixture, which `inputsFromEnv` cannot describe. Before T-OP-152 nothing ran this path
    ///      except `forge script` itself, and `forge script` was aborting it in group 4.
    function runWith(Inputs memory in_) public {
        (uint256 passed, uint256 failed) = check(in_);
        console2.log("");
        _summary(passed, failed);
        if (failed != 0) revert("verify failed");
    }

    /// @dev The one line the drivers parse. `VERIFY FAILED: N check(s) failed of M` or `VERIFY PASSED: N checks`
    ///      keep their exact shape: DeployV2Batch.sh parses the count out of the PASSED line, broadcast-v8.sh and
    ///      rehearse-v2.sh require one of the two and treat a log that ends without either as FAILED-INCOMPLETE.
    ///      What was NOT checked goes on its own line, so a pass that skipped a subject says so here. Virtual so a
    ///      test can observe that the summary was reached and what it said; the override must delegate.
    function _summary(uint256 passed, uint256 failed) internal virtual {
        if (failed != 0) {
            console2.log(
                string.concat(
                    "VERIFY FAILED: ", vm.toString(failed), " check(s) failed of ", vm.toString(passed + failed)
                )
            );
            return;
        }
        // The PASSED line keeps its parseable prefix: DeployV2Batch.sh:1052 and DeploySoloBatch.sh:392 take the
        // count with `sed -E 's/.*VERIFY PASSED: ([0-9]+) checks.*/\\1/'` and broadcast-v8.sh:133 greps
        // `VERIFY PASSED:`, so anything after "checks" is free. T-OP-140 uses that: when the caller skipped
        // externals (V2_SKIP_EXTERNALS) the SAME line says so -- "PASS with N targets NOT CHECKED", never a bare
        // PASS -- and the names follow on their own line. What was NOT checked for lack of a subject stays on
        // its own line too, so a pass that skipped a subject says so here.
        if (skippedTargets.length == 0) {
            console2.log(string.concat("VERIFY PASSED: ", vm.toString(passed), " checks"));
        } else {
            console2.log(
                string.concat(
                    "VERIFY PASSED: ",
                    vm.toString(passed),
                    " checks with ",
                    vm.toString(skippedTargets.length),
                    " targets NOT CHECKED (V2_SKIP_EXTERNALS)"
                )
            );
            console2.log(
                string.concat(
                    "NOT CHECKED targets: ",
                    vm.toString(skippedTargets.length),
                    " (",
                    _join(skippedTargets),
                    ") -- deliberately not deployed by this run (V2_SKIP_EXTERNALS); nothing about them was verified"
                )
            );
        }
        if (notChecked != 0) {
            console2.log(
                string.concat("NOT CHECKED: ", vm.toString(notChecked), " assertion group(s) had no subject; see info")
            );
        }
    }

    /// @dev `a, b, c` for the NOT CHECKED targets line.
    function _join(string[] memory names) internal pure returns (string memory out) {
        for (uint256 i; i < names.length; ++i) {
            out = i == 0 ? names[i] : string.concat(out, ", ", names[i]);
        }
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
        // T-OP-171. The per-ticker House vault, `V2_MARKET_<T>_HOUSE_VAULT`, UNSET when the registry row's
        // `markets[].v2.houseVault` is null (T-OP-161 exports it with the same unset-when-absent rule as the six
        // externals). Zero here means "not supplied", which {_houseVaults} reports NOT CHECKED by ticker.
        in_.marketVaults = new address[](in_.markets.length);
        for (uint256 i; i < in_.markets.length; ++i) {
            in_.marketVaults[i] = vm.envOr(_mk(in_.markets[i].ticker, "HOUSE_VAULT"), address(0));
        }
        // INTERFACE_VERSION 8 (V8-DESIGN.md §4.3): rent launches at 0 on every market and a NON-ZERO rate is what
        // must never reach the chain from a script, so the opt-in names the intent and {V2DeployBase.rentAllowed}
        // decides -- and it answers true only under the forge TEST runner, which is why a read-only verify of live
        // 4663 cannot sign off a rent-bearing market with an environment variable.
        in_.allowRent = allowRentFromEnv();
        in_.mintFeePpm = mintFeePpmFromEnv(in_.markets);
        in_.unregistered = vm.envOr("V2_UNREGISTERED_ASSETS", ",", new address[](0));
        in_.expectFresh = vm.envOr("V2_EXPECT_FRESH", true);
        in_.expectChainId = vm.envOr("V2_EXPECT_CHAIN_ID", CHAIN_ID_4663);
        in_.safeMinThreshold = vm.envOr("V2_EXPECT_SAFE_THRESHOLD", uint256(2));
        in_.safeMinOwners = vm.envOr("V2_EXPECT_SAFE_OWNERS", uint256(3));
        // T-OP-140. Unset means none. The driver never exports an EMPTY value (T-OP-116 pins that), and an empty
        // string here would parse as one empty name, which {_validateSkips} refuses as not an external.
        in_.skipExternals = vm.envOr("V2_SKIP_EXTERNALS", ",", new string[](0));
        // T-OP-171. Unset means none: every live-set parameter mismatch is a FAIL unless its subject is listed.
        in_.expectChanged = vm.envOr("V2_EXPECT_CHANGED", ",", new string[](0));
    }

    /// @notice Every check, printed; returns the counts and never reverts on a failed check.
    function check(Inputs memory in_) public returns (uint256 passed, uint256 failed) {
        passes = 0;
        failures = 0;
        notChecked = 0;
        delete skippedTargets;
        delete skipList;
        delete changedList;
        _validateSkips(in_);
        for (uint256 i; i < in_.skipExternals.length; ++i) {
            skipList.push(in_.skipExternals[i]);
        }
        _validateExpectChanged(in_);
        for (uint256 i; i < in_.expectChanged.length; ++i) {
            changedList.push(in_.expectChanged[i]);
        }
        // An Inputs built by hand may leave `marketVaults` short (or empty), or longer after a test trimmed
        // `markets`: it is re-shaped to one slot per ticker, keeping what overlaps and zero beyond -- and a zero slot
        // is NOT CHECKED by ticker, never a silent skip. `inputsFromEnv` always builds the two in step.
        if (in_.marketVaults.length != in_.markets.length) {
            address[] memory shaped = new address[](in_.markets.length);
            for (uint256 i; i < shaped.length && i < in_.marketVaults.length; ++i) {
                shaped[i] = in_.marketVaults[i];
            }
            in_.marketVaults = shaped;
        }
        _group("chain");
        _check(block.chainid == in_.expectChainId, string.concat("chain id ", vm.toString(block.chainid)));
        if (!_haveCode(in_.c)) return (passes, failures);
        _bytecode(in_.c);
        _immutables(in_);
        _dependencies(in_);
        _pointers(in_);
        _flywheel(in_);
        _vault(in_);
        _parameters(in_);
        _calendar(in_);
        _roles(in_);
        _safes(in_);
        // T-OP-166 F3 / T-OP-171. AN ABSENT SUBJECT IS SAID, NOT IMPLIED. With `V2_TICKERS` unset the market
        // group used to run zero times and nothing marked it, so a PASSED line from a run that verified no market
        // read exactly like one that verified all of them -- while the same absence for `V2_DEPLOYER` (SEC-38-R,
        // {_roles}) was already NOT CHECKED by name. The two market-shaped inputs now get the same treatment, and
        // {run} counts them under the verdict.
        if (in_.markets.length == 0) {
            _notChecked("V2_TICKERS is unset or empty, so no market was verified (registration, sources, route, pin)");
        }
        for (uint256 i; i < in_.markets.length; ++i) {
            _market(in_, in_.markets[i]);
        }
        _houseVaults(in_);
        _unregistered(in_);
        if (in_.expectFresh) _fresh(in_);
        return (passes, failures);
    }

    /*//////////////////////////////////////////////////////////////
                  T-OP-171: V2_EXPECT_CHANGED (per-subject opt-in)
    //////////////////////////////////////////////////////////////*/

    /// @notice The `_param` subjects a caller may list in `V2_EXPECT_CHANGED`. The literal names are the ones the
    ///         `_param` call sites pass; a new `_param` line needs its subject added here or the list refuses it.
    ///         `market.<TICKER>.mintFeePpm` is accepted for every ticker in `V2_TICKERS`.
    function paramSubjects() public pure returns (string[] memory names) {
        names = new string[](16);
        names[0] = "orderBook.premiumFeeBps";
        names[1] = "orderBook.resaleFeeBps";
        names[2] = "orderBook.takerFeeFlat";
        names[3] = "orderBook.takerFeeCapBps";
        names[4] = "orderBook.makerRebateBps";
        names[5] = "clearinghouse.maxPayoutSlippageBps";
        names[6] = "clearinghouse.minRedeemPayout";
        names[7] = "keeperRewards.bounty.SNAPSHOT";
        names[8] = "keeperRewards.bounty.FINALIZE";
        names[9] = "keeperRewards.bounty.SETTLE";
        names[10] = "keeperRewards.bounty.REDEEM";
        names[11] = "keeperRewards.bounty.ROLL";
        names[12] = "keeperRewards.bounty.CANCEL_STALE";
        names[13] = "keeperRewards.dailyCap";
        names[14] = "autoRoller.minRollUnits";
        names[15] = "makerVault.limits";
    }

    /// @dev FAIL CLOSED ON THE LIST ITSELF, before any group runs, the same rule as {_validateSkips}: every entry
    ///      must be a {paramSubjects} name or `market.<T>.mintFeePpm` for a ticker of this run, and no name twice.
    ///      A misspelt subject would otherwise silence nothing and look like it had.
    function _validateExpectChanged(Inputs memory in_) internal pure {
        string[] memory known = paramSubjects();
        for (uint256 i; i < in_.expectChanged.length; ++i) {
            string memory name = in_.expectChanged[i];
            bool ok;
            for (uint256 k; k < known.length && !ok; ++k) {
                ok = _eq(known[k], name);
            }
            for (uint256 m; m < in_.markets.length && !ok; ++m) {
                ok = _eq(string.concat("market.", in_.markets[m].ticker, ".mintFeePpm"), name);
            }
            require(
                ok,
                string.concat(
                    "V2_EXPECT_CHANGED names '",
                    name,
                    "', which is not a _param subject (see VerifyV8.paramSubjects(), or market.<TICKER>.mintFeePpm for"
                    " a ticker in V2_TICKERS): an unknown name silences nothing, so it is refused rather than ignored"
                )
            );
            for (uint256 j; j < i; ++j) {
                require(!_eq(in_.expectChanged[j], name), string.concat("V2_EXPECT_CHANGED names ", name, " twice"));
            }
        }
    }

    /// @dev Whether the caller listed `subject` in `V2_EXPECT_CHANGED`. Only a validated name can be in
    ///      {changedList}, so a true answer always means "known subject, explicitly opted out, by the caller".
    function _isChanged(string memory subject) internal view returns (bool) {
        for (uint256 i; i < changedList.length; ++i) {
            if (_eq(changedList[i], subject)) return true;
        }
        return false;
    }

    /// @dev T-258 made this `virtual` and nothing else about it changed. Criterion 6 of that row requires a
    ///      NAMED failure, and `_check` reports the name to the console, which a Solidity test cannot read.
    ///      Overriding it in a test probe is the only way to assert on the name rather than on a count, and a
    ///      count-only assertion is exactly the kind of check that passes for the wrong reason.
    /// @dev A check group's header line. Virtual so a test can record which groups RAN -- the T-OP-152 defect was
    ///      groups 4 onward never running under `forge script` while the log looked normal up to that point. The
    ///      override must delegate so the log keeps its shape.
    function _group(string memory name) internal virtual {
        console2.log(name);
    }

    function _check(bool ok, string memory what) internal virtual {
        if (ok) {
            ++passes;
            console2.log(string.concat("  ok    ", what));
        } else {
            ++failures;
            console2.log(string.concat("  FAIL  ", what));
        }
    }

    /// @dev `_info(string.concat(name, suffix))` with the concatenation in ITS OWN FRAME. Inlined, the concat's
    ///      temporaries live alongside every local of the calling loop, which is what put {_authorities} over the
    ///      via_ir stack limit in C8-DEPLOYPATH-EXECUTES. Same output, one fewer thing on the stack.
    function _infoNamed(string memory name, string memory suffix) internal pure {
        _info(string.concat(name, suffix));
    }

    function _info(string memory what) internal pure {
        console2.log(string.concat("  info  ", what));
    }

    /// @dev An assertion group that asserted NOTHING because its subject was not supplied. It is not a pass, so
    ///      it is not counted as one, and it is not a failure, because a caller may legitimately lack the subject
    ///      (`DeployV2Batch.sh --verify` has no deployer). It prints as an `info` line, which the batch shows on a
    ///      pass, and {run} adds a count under the VERIFY line. `virtual` so a test can observe it by name, the
    ///      same reason `_check` is; `_info` is `pure` and cannot be overridden into recording anything.
    function _notChecked(string memory what) internal virtual {
        ++notChecked;
        _info(string.concat("NOT CHECKED: ", what));
    }

    /*//////////////////////////////////////////////////////////////
                    T-OP-140: SKIPPED EXTERNALS (V2_SKIP_EXTERNALS)
    //////////////////////////////////////////////////////////////*/

    /// @dev The six manifest targets DeployV8 does not create. MIRRORS `DeployV8._externallySupplied` by name; a
    ///      seventh name here without one there (or the reverse) is the drift `test/v2/unit/VerifyV8.t.sol`
    ///      pins. Kept here rather than imported: importing DeployV8 would compile it as a dependency of this
    ///      script (the same reason `ISafeTopology` is declared locally).
    function _isExternalTarget(string memory name) internal pure returns (bool) {
        return _eq(name, "HouseVault") || _eq(name, "HouseVaultFactory") || _eq(name, "Hedger")
            || _eq(name, "RewardsDistributorLender") || _eq(name, "EarnVault") || _eq(name, "StockVenueAdapter");
    }

    /// @dev The variable that would have supplied an external target, for the refusal message. Mirrors
    ///      `DeployV8._envNameFor` and `V2DeployBase.contractsFromEnv`.
    function _envNameOfExternal(string memory name) internal pure returns (string memory) {
        if (_eq(name, "HouseVault")) return "V2_HOUSE_VAULT";
        if (_eq(name, "HouseVaultFactory")) return "V2_HOUSE_VAULT_FACTORY";
        if (_eq(name, "Hedger")) return "V2_HEDGER";
        if (_eq(name, "RewardsDistributorLender")) return "V2_LENDER_REWARDS";
        if (_eq(name, "EarnVault")) return "V2_EARN_VAULT";
        if (_eq(name, "StockVenueAdapter")) return "V2_STOCK_VENUE_ADAPTER";
        return "its V2_* variable";
    }

    /// @dev FAIL CLOSED ON THE LIST ITSELF, before any group runs. Every entry must be (1) one of the six
    ///      externals -- a core target, a misspelling, a registry-key spelling or an empty entry REVERTS naming
    ///      it -- and (2) UNSUPPLIED: a skip of a target whose address this run was given is the false-green
    ///      shape (the deploy supplied it, the verifier would look away from it), so it reverts naming the
    ///      variable. The same name twice reverts too: the count on the PASSED line must mean what it says.
    function _validateSkips(Inputs memory in_) internal pure {
        for (uint256 i; i < in_.skipExternals.length; ++i) {
            string memory name = in_.skipExternals[i];
            if (!_isExternalTarget(name)) {
                revert(
                    string.concat(
                        "V2_SKIP_EXTERNALS names '",
                        name,
                        "', which is not an externally supplied target (HouseVault, HouseVaultFactory, Hedger, RewardsDistributorLender, EarnVault, StockVenueAdapter): a core target cannot be skipped, and the spelling is the manifest name"
                    )
                );
            }
            address supplied = _targetOf(in_.c, name);
            if (supplied != address(0)) {
                revert(
                    string.concat(
                        "V2_SKIP_EXTERNALS names ",
                        name,
                        " but ",
                        _envNameOfExternal(name),
                        " is supplied (",
                        vm.toString(supplied),
                        "): a supplied target is verified, never skipped; unset the variable or drop the skip"
                    )
                );
            }
            for (uint256 j; j < i; ++j) {
                if (_eq(in_.skipExternals[j], name)) {
                    revert(string.concat("V2_SKIP_EXTERNALS names ", name, " twice"));
                }
            }
        }
    }

    /// @dev Whether the caller put this manifest target in the NOT CHECKED group. Only a name {_validateSkips}
    ///      accepted can be in {skipList}, so a true answer always means "external, unsupplied, deliberately".
    function _isSkipped(string memory name) internal view returns (bool) {
        for (uint256 i; i < skipList.length; ++i) {
            if (_eq(skipList[i], name)) return true;
        }
        return false;
    }

    /// @dev The manifest name of a {_moneyLaneSubjects} entry that is an external, or "" for the four the deploy
    ///      creates. Only these two subjects can be skipped, so only these two are mapped.
    function _manifestNameOfMoneySubject(string memory subject) internal pure returns (string memory) {
        if (_eq(subject, "hedger")) return "Hedger";
        if (_eq(subject, "rewardsDistributorLender")) return "RewardsDistributorLender";
        return "";
    }

    /// @dev A manifest target this run deliberately did not deploy: recorded for the verdict line and printed as
    ///      NOT CHECKED by name. Not a pass, not a failure, and NOT `present`: the target keeps its zero address
    ///      everywhere else (so {_distinctTargets}, {_targetsOpen} and {_identity} skip it as they skip any zero).
    ///      `virtual` so a test can observe it by name, as `_check` and `_notChecked` are.
    function _skippedTarget(string memory name, string memory where) internal virtual {
        for (uint256 i; i < skippedTargets.length; ++i) {
            if (_eq(skippedTargets[i], name)) {
                _infoNamed(name, string.concat(" NOT CHECKED (V2_SKIP_EXTERNALS): ", where));
                return;
            }
        }
        skippedTargets.push(name);
        _infoNamed(name, string.concat(" NOT CHECKED (V2_SKIP_EXTERNALS): ", where));
    }

    /*//////////////////////////////////////////////////////////////
                                 BYTECODE
    //////////////////////////////////////////////////////////////*/

    /// @dev Stops early (after counting the failures) when an address is missing: nothing below can be read.
    function _haveCode(Contracts memory c) internal returns (bool all) {
        _group("contracts have code");
        (address[] memory addrs, string[] memory names,) = _set(c);
        all = true;
        for (uint256 i; i < addrs.length; ++i) {
            bool ok = addrs[i] != address(0) && addrs[i].code.length != 0;
            _check(ok, string.concat(names[i], " ", vm.toString(addrs[i]), " has code"));
            all = all && ok;
        }
    }

    /// @notice Only the bytecode group of {check}: the counts of its 16 lines. For tests and the pinned-runtime fork
    ///         suite; `run` and `check` are unchanged by it.
    function checkBytecode(Contracts memory c) public returns (uint256 passed, uint256 failed) {
        passes = 0;
        failures = 0;
        _bytecode(c);
        return (passes, failures);
    }

    /// @dev A live address of the deployed set is compared with its PINNED artifact (C3-101, F1 D12): `src/` moves on
    ///      after a deploy, and a live core address compared with an unrelated current build FAILs on code nobody
    ///      changed on chain. Every other address -- a fresh deploy, a rehearsal's new set -- against `out/`.
    function _bytecode(Contracts memory c) internal {
        _group("bytecode (a pinned live address against its pinned deployed artifact, any other against out/)");
        (address[] memory addrs, string[] memory names, string[] memory artifacts) = _set(c);
        string memory manifest = _pinnedManifest();
        for (uint256 i; i < addrs.length; ++i) {
            (bool pinned, string memory path, string memory rev) = _pinnedIn(manifest, names[i], addrs[i]);
            _check(
                runtimeMatches(addrs[i], pinned ? path : artifacts[i]),
                pinned
                    ? string.concat(
                        names[i], ": runtime == pinned artifact of deployed rev ", rev, ", outside immutable slots"
                    )
                    : string.concat(names[i], ": runtime == compiled artifact, outside immutable slots")
            );
        }
    }

    /// @notice The pinned runtime artifact of the contract registered as `name` (VerifyV8's names: "clearinghouse",
    ///         "sources.chainlink", ...), when {PINNED_MANIFEST} lists `target` under that very name for this chain.
    ///         Any other combination -- another address, another name, another chain, no manifest -- is not pinned
    ///         and is compared with `out/`.
    /// @return pinned whether the manifest pins `target` as `name` on `block.chainid`
    /// @return path   the pinned artifact (forge artifact shape: `deployedBytecode.object` and `.immutableReferences`)
    /// @return rev    the full SHA of the commit the pinned artifact was built from
    function pinnedArtifact(string memory name, address target)
        public
        view
        returns (bool pinned, string memory path, string memory rev)
    {
        return _pinnedIn(_pinnedManifest(), name, target);
    }

    /// @dev {PINNED_MANIFEST}'s JSON when this is its chain, else empty. Off chain 4663 nothing is read at all,
    ///      so a test or local set costs what it did before pinning existed.
    function _pinnedManifest() internal view returns (string memory json) {
        if (block.chainid != CHAIN_ID_4663 || !vm.exists(PINNED_MANIFEST)) return "";
        json = vm.readFile(PINNED_MANIFEST);
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) return "";
    }

    function _pinnedIn(string memory json, string memory name, address target)
        internal
        view
        returns (bool pinned, string memory path, string memory rev)
    {
        if (bytes(json).length == 0) return (false, "", "");
        string memory key = string.concat(".contracts['", name, "']");
        if (!vm.keyExistsJson(json, key)) return (false, "", "");
        if (vm.parseJsonAddress(json, string.concat(key, ".address")) != target) return (false, "", "");
        return
            (true, vm.parseJsonString(json, string.concat(key, ".artifact")), vm.parseJsonString(json, ".source.rev"));
    }

    /// @notice `target`'s runtime equals the artifact at `path` byte for byte outside the immutable slots the artifact
    ///         records (their values are checked through the getters, "immutables" below). The CBOR tail is compared:
    ///         with `bytecode_hash = "none"` it carries the solc version only.
    function runtimeMatches(address target, string memory path) public view returns (bool) {
        string memory json = vm.readFile(path);
        bytes memory want = _artifactRuntime(json);
        bool[] memory mask = new bool[](want.length);
        if (vm.keyExistsJson(json, ".deployedBytecode.immutableReferences")) _maskImmutables(json, mask);
        return _equalMasked(target.code, want, mask);
    }

    /// @dev The 16 contracts with their registry names and artifacts: the thirteen v7 names in deploy order,
    ///      then the three v8 additions appended so the positional readers of the first thirteen do not move.
    function _set(Contracts memory c)
        internal
        pure
        returns (address[] memory addrs, string[] memory names, string[] memory artifacts)
    {
        addrs = new address[](16);
        names = new string[](16);
        artifacts = new string[](16);
        (addrs[0], names[0], artifacts[0]) = (c.expiryCalendar, "expiryCalendar", ART_EXPIRY_CALENDAR);
        (addrs[1], names[1], artifacts[1]) = (c.chainlinkSource, "sources.chainlink", ART_CHAINLINK_SOURCE);
        (addrs[2], names[2], artifacts[2]) = (c.univ3Source, "sources.univ3", ART_UNIV3_SOURCE);
        (addrs[3], names[3], artifacts[3]) = (c.dataStreamsSource, "sources.dataStreams", ART_DATA_STREAMS_SOURCE);
        (addrs[4], names[4], artifacts[4]) = (c.settlementOracle, "settlementOracle", ART_SETTLEMENT_ORACLE);
        (addrs[5], names[5], artifacts[5]) = (c.clearinghouse, "clearinghouse", ART_CLEARINGHOUSE);
        (addrs[6], names[6], artifacts[6]) = (c.orderBook, "orderBook", ART_ORDER_BOOK);
        (addrs[7], names[7], artifacts[7]) = (c.keeperRewards, "keeperRewards", ART_KEEPER_REWARDS);
        (addrs[8], names[8], artifacts[8]) = (c.autoRoller, "autoRoller", ART_AUTO_ROLLER);
        // INTERFACE_VERSION 8: the registry KEY `payoutAdapter` is kept (03-INTERFACES §4) and now names the
        // PayoutRouter, so the NAME stays and only the ARTIFACT moves. The v7 pins in script/artifacts/v2-4663 key on
        // name AND address, so they still match the live v7 adapter and never match this one.
        (addrs[9], names[9], artifacts[9]) = (c.payoutRouter, "payoutAdapter", ART_PAYOUT_ROUTER);
        (addrs[10], names[10], artifacts[10]) = (c.makerRegistry, "makerRegistry", ART_MAKER_REGISTRY);
        (addrs[11], names[11], artifacts[11]) = (c.makerVault, "makerVault", ART_MAKER_VAULT);
        (addrs[12], names[12], artifacts[12]) = (c.rewardsDistributor, "rewardsDistributor", ART_REWARDS_DISTRIBUTOR);
        // The three v8 additions are APPENDED rather than slotted into deploy order: the pinned-runtime suite and
        // rehearse-v2.sh read this list positionally for the thirteen v7 names, and reordering them would move
        // every one of those lines for no check.
        (addrs[13], names[13], artifacts[13]) = (c.accessManager, "accessManager", ART_ACCESS_MANAGER);
        (addrs[14], names[14], artifacts[14]) = (c.feeSplitter, "flywheel.feeSplitter", ART_FEE_SPLITTER);
        (addrs[15], names[15], artifacts[15]) = (c.buybackExecutor, "flywheel.buybackExecutor", ART_BUYBACK_EXECUTOR);
    }

    /*//////////////////////////////////////////////////////////////
                           IMMUTABLES, DEPENDENCIES
    //////////////////////////////////////////////////////////////*/

    function _immutables(Inputs memory in_) internal {
        _group("immutables");
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
        // INTERFACE_VERSION 8: the payout leg is the PayoutRouter. Its getters are `v3Router()` and `v3Factory()`;
        // the v7 `UniV3PayoutAdapter.router()/factory()` casts compile against any address and revert here.
        PayoutRouter router = PayoutRouter(payable(c.payoutRouter));
        _check(router.usdg() == usdg, "payoutAdapter.usdg == V2_USDG");
        _check(router.v3Router() == in_.ext.swapRouter02, "payoutAdapter.router == V2_SWAP_ROUTER02");
        _check(
            router.v3Factory() == in_.ext.univ3Factory
                && IUniV3SwapRouter02(in_.ext.swapRouter02).factory() == in_.ext.univ3Factory,
            "payoutAdapter.factory == swapRouter02.factory() == V2_UNIV3_FACTORY"
        );
        MakerVault vault = MakerVault(c.makerVault);
        _check(address(vault.orderBook()) == c.orderBook, "makerVault.orderBook == orderBook");
        _check(address(vault.clearinghouse()) == c.clearinghouse, "makerVault.clearinghouse == clearinghouse");
        _check(address(vault.usdg()) == usdg, "makerVault.usdg == V2_USDG");
        _check(address(RewardsDistributor(c.rewardsDistributor).usdg()) == usdg, "rewardsDistributor.usdg == V2_USDG");

        _group("compiled constants");
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
        // T-OP-063 / SEC-13: MIN_ASK_BPS 5 -> 50 and the per-call reprice drop cap; both compiled, so the
        // verifier pins them against the deployed bytecode rather than trusting the source it was built from.
        _check(
            roller.MIN_OTM_BPS() == 100 && roller.MAX_OTM_BPS() == 2500 && roller.MIN_ASK_BPS() == 50
                && roller.MAX_ASK_BPS() == 1000 && roller.MAX_REPRICE_DROP_BPS() == 2500,
            "autoRoller strategy bounds otm 100..2500, ask 50..1000 bps, reprice drop <= 2500 bps per call"
        );
        _check(vault.MAX_LIVE_ORDERS_PER_SERIES() == 16, "makerVault MAX_LIVE_ORDERS_PER_SERIES 16");
    }

    function _dependencies(Inputs memory in_) internal {
        _group("dependencies");
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
        _group("pointers");
        Contracts memory c = in_.c;
        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        _check(ch.calendar() == c.expiryCalendar, "clearinghouse.calendar == expiryCalendar");
        _check(ch.feeRecipient() == in_.roles.feeRecipient, "clearinghouse.feeRecipient == V2_FEE_RECIPIENT");
        _check(ch.payoutAdapter() == c.payoutRouter, "clearinghouse.payoutAdapter == payoutAdapter");
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
            !ChainlinkFeedSource(c.chainlinkSource).isOracle(in_.roles.adminSafe)
                && !UniV3TwapSource(c.univ3Source).isOracle(in_.roles.adminSafe)
                && !DataStreamsSource(c.dataStreamsSource).isOracle(in_.roles.adminSafe)
                && !ChainlinkFeedSource(c.chainlinkSource).isOracle(in_.roles.crankerKey)
                && !UniV3TwapSource(c.univ3Source).isOracle(in_.roles.crankerKey)
                && !DataStreamsSource(c.dataStreamsSource).isOracle(in_.roles.crankerKey),
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
        others = others || kr.isCaller(in_.roles.adminSafe) || kr.isCaller(in_.roles.crankerKey);
        _check(!others, "keeperRewards: no other contract of the set, the admin or the cranker is a caller");
    }

    /*//////////////////////////////////////////////////////////////
                                FLYWHEEL
    //////////////////////////////////////////////////////////////*/

    /// @dev The five splitter pointers `DeployV8._splitterCalls` sets, each paired with what it MUST equal. Every
    ///      expectation is read from the deployed set or from the executor's own immutables and NEVER from a literal
    ///      in this file, so the list cannot drift into agreeing with itself. `DeployV8.s.sol` sets exactly these
    ///      five from exactly these sources; if that list grows, this one has to grow with it or the new pointer
    ///      ships unverified.
    function _flywheelSubjects(Contracts memory c)
        internal
        view
        returns (address[] memory have, address[] memory want, string[] memory names)
    {
        FeeSplitter s = FeeSplitter(payable(c.feeSplitter));
        have = new address[](VERIFY_V8_FLYWHEEL_POINTERS);
        want = new address[](VERIFY_V8_FLYWHEEL_POINTERS);
        names = new string[](VERIFY_V8_FLYWHEEL_POINTERS);
        (have[0], want[0], names[0]) = (s.orderBook(), c.orderBook, "feeSplitter.orderBook");
        // THE SPLITTER AND THE CLEARINGHOUSE PAYOUT PATH SHARE ONE ROUTER, re-asserted after deploy. {_pointers}
        // already checks `clearinghouse.payoutAdapter == payoutAdapter`; only with this second line is a
        // `setRouter` that repointed the SPLITTER alone visible at all. `FeeSplitter.router` is plain mutable
        // storage, not an immutable, and `FeeSplitter.setRouter` checks only that the new address has code -- not
        // that it is the Clearinghouse's adapter. Without this the verifier's silence looks the same either way.
        (have[1], want[1], names[1]) = (s.router(), c.payoutRouter, "feeSplitter.router");
        (have[2], want[2], names[2]) = (s.executor(), c.buybackExecutor, "feeSplitter.executor");
        (have[3], want[3], names[3]) = (s.oracle(), c.settlementOracle, "feeSplitter.oracle");
        // The STONKHOUSE token is not a field of `Contracts`, so the expectation is the executor's `token`
        // immutable -- `currency1` of the ONE pinned v4 key. `DeployV8` gives `FeeSplitter.setToken` that same
        // `poolKey.currency1`, so the token the splitter burns and the token the executor buys have one source and
        // this compares them rather than restating either.
        (have[4], want[4], names[4]) =
        (s.stonkhouse(), V4BuybackExecutor(payable(c.buybackExecutor)).token(), "feeSplitter.stonkhouse");
    }

    /// @dev 10. FLYWHEEL WIRING AND ITS TWO DIALS. Nothing else in this run reads a splitter pointer, and the
    ///      failure being guarded is SILENT BY CONSTRUCTION. `FeeSplitter.buyback` answers an unwired splitter with
    ///      `BuybackSkipped(NO_EXECUTOR)` and `return (0, 0)`, and a zero `burnBps` or a zero `buybackCap` with
    ///      `BuybackSkipped(EMPTY)` the same way. All of those SUCCEED: a hand-sent buyback transaction confirms,
    ///      nothing is bought, nothing is burned, no revert is recorded, and a verifier that never reads these
    ///      pointers still prints VERIFY PASSED. An unwired flywheel and an empty one are the same observation from
    ///      outside, which is why the wiring has to be read directly rather than inferred from a successful call.
    function _flywheel(Inputs memory in_) internal {
        _group("flywheel (V8-DESIGN 6)");
        Contracts memory c = in_.c;
        FeeSplitter s = FeeSplitter(payable(c.feeSplitter));

        // Same shape as {_moneyLaneSubjects}: the sentence is built from the list the loop walked, so it cannot
        // name a pointer that was not read, and adding a pointer changes the check and its message at once.
        (address[] memory have, address[] memory want, string[] memory names) = _flywheelSubjects(c);
        bool wired = true;
        string memory walked;
        for (uint256 i; i < have.length; ++i) {
            if (have[i] != want[i]) {
                wired = false;
                _infoNamed(names[i], string.concat(" is ", vm.toString(have[i]), ", not ", vm.toString(want[i])));
            }
            walked = i == 0 ? names[i] : string.concat(walked, ", ", names[i]);
        }
        _check(wired, string.concat("all ", vm.toString(have.length), " flywheel pointers are wired: ", walked));

        // THE BACK-POINTER. The executor pins its splitter at construction and has no setter, so a splitter
        // pointed at an executor that was built to serve a DIFFERENT splitter is only ever visible from this side:
        // the splitter's own `executor` field would look perfectly set.
        _check(
            V4BuybackExecutor(payable(c.buybackExecutor)).splitter() == c.feeSplitter,
            "buybackExecutor.splitter == feeSplitter"
        );

        // THE TWO DIALS. T-222 shipped both as FLOORS and recorded, as its own launch-phase item, that "a splitter
        // deliberately re-dialled to 1 bps and 1 wei would pass" -- a non-zero floor cannot tell the launch dial from
        // any other legal number. T-CV-FLYWHEEL closes HALF of that, and deliberately only half:
        //
        //   burnBps IS NOW AN EQUALITY, against the same source `DeployV8` configures from. `V2_BURN_BPS` over
        //   `V2DeployBase.LAUNCH_BURN_BPS` is exactly what `flywheelFromEnv` hands the splitter's constructor, so
        //   this compares chain state against the deploy's own input rather than against a literal typed here. Only
        //   `V2_BURN_BPS` is read, NOT the whole `flywheelFromEnv()`: that function hard-requires V2_WETH,
        //   V2_BUYBACK_V3_POOL and the four V2_TOKEN_POOL_* variables, and a verify run that does not export them
        //   would start reverting where it used to pass -- a fail-closed change nobody asked for. A deliberate later
        //   re-dial by FEE_MANAGER is re-verified by exporting V2_BURN_BPS with the intended value, which is how
        //   every other registry-driven expectation in this file already works.
        //
        //   buybackCap STAYS A FLOOR, and this is a decision rather than an omission. Its launch value lives in
        //   `FeeSplitter.LAUNCH_BUYBACK_CAP`, which is `private` (FeeSplitter.sol:40) and therefore unreadable from
        //   here, and no registry field carries it. An equality would mean typing 50_000_000 into this file, i.e. an
        //   expectation agreeing with itself -- the exact defect class these edits keep removing. Closing it needs
        //   the launch cap to live somewhere VerifyV8 can READ: a `Flywheel` field in `V2DeployBase` fed from the
        //   registry, which is outside this row's fence. Until then a re-dialled cap is bounded, not pinned.
        //
        // ZERO remains the case that matters most: `FeeSplitter._split` adds `amount * burnBps / BPS` to
        // `buybackBalance`, so `burnBps == 0` means that balance never grows and every buyback is a silent EMPTY
        // skip forever; `buybackCap == 0` short-circuits `buyback` to the same skip before it reads anything else.
        // The ceilings are mirrored from `V2Constants`, not restated.
        uint256 burn = uint256(s.burnBps());
        uint256 cap = s.buybackCap();
        uint256 wantBurn = vm.envOr("V2_BURN_BPS", uint256(LAUNCH_BURN_BPS));
        _check(
            burn == wantBurn && burn != 0 && burn <= V2Constants.BPS,
            string.concat(
                "feeSplitter.burnBps is the configured launch split: ", vm.toString(burn), " == ", vm.toString(wantBurn)
            )
        );
        _check(
            cap != 0 && cap <= V2Constants.BUYBACK_CAP_CEIL,
            string.concat("feeSplitter.buybackCap is non-zero and within BUYBACK_CAP_CEIL: ", vm.toString(cap))
        );
    }

    function _vault(Inputs memory in_) internal {
        _group("maker vault (C2-11)");
        Contracts memory c = in_.c;
        Clearinghouse ch = Clearinghouse(c.clearinghouse);
        _check(ch.isOperator(c.makerVault, c.orderBook), "clearinghouse.isOperator(makerVault, orderBook)");
        _check(ch.isApprovedForAll(c.makerVault, c.orderBook), "clearinghouse.isApprovedForAll(makerVault, orderBook)");
        _check(
            IERC20(in_.ext.usdg).allowance(c.makerVault, c.orderBook) >= type(uint128).max,
            "usdg.allowance(makerVault, orderBook) unlimited"
        );
        _check(
            !ch.isOperator(c.makerVault, in_.roles.quoterKey),
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

    // INTERFACE_VERSION 8: `_premiumUnderResale` IS DELETED, NOT DISABLED, and so is its check in {_parameters}.
    // v8 launches premium 500 / resale 0 (03-INTERFACES.md:198), which the v7 rule refused outright. V8-DESIGN.md §4
    // records the mint-into-your-own-bid-then-resell dodge as a risk the owner KNOWINGLY ACCEPTS and charges no rent
    // for, so a verify that FAILs on 500/0 would refuse every correct v8 deployment. Do not restore it: the
    // PREMIUM_FEE_CEIL_BPS ceilings below are the surviving bound on both fees.

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

    /// @dev Equal to the value the caller supplied: a PASS when equal; when not, a FAIL -- in every mode -- unless
    ///      this is a live-set verify AND the caller listed `subject` in `V2_EXPECT_CHANGED`, in which case it is
    ///      an `info` line that says so.
    ///
    ///      T-OP-166 F2 / T-OP-171. THE OLD SHAPE WAS A BLANKET SILENCE. `!fresh && !equal` printed an `info` line
    ///      for every one of the ~17 subjects, so a post-launch `--verify --expect-fresh false` could not red on a
    ///      value the caller had EXPLICITLY handed it (the registry's fees, the bounty table, the vault limits);
    ///      "the admin may have tuned it" had become "the verifier cannot see it". The admin's re-tune is real and
    ///      is honoured -- per subject, opted into by name, validated up front -- and a fresh verify honours nothing:
    ///      launch values are launch values.
    function _param(string memory subject, bool fresh, bool equal, string memory what, string memory live) internal {
        if (equal) {
            _check(true, what);
        } else if (!fresh && _isChanged(subject)) {
            _info(string.concat(what, ": differs (live ", live, "), listed in V2_EXPECT_CHANGED as ", subject));
        } else {
            _check(false, string.concat(what, " (live ", live, ")"));
        }
    }

    function _parameters(Inputs memory in_) internal {
        _group(
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
        V2Types.FeeParams memory t = pending ? q : f;
        string memory tag = pending ? string.concat(" (scheduled, from unix ", vm.toString(effectiveAt), ")") : "";
        _param(
            "orderBook.premiumFeeBps",
            fresh,
            t.premiumFeeBps == p.fees.premiumFeeBps,
            string.concat("orderBook premiumFeeBps == ", vm.toString(p.fees.premiumFeeBps), tag),
            vm.toString(t.premiumFeeBps)
        );
        _param(
            "orderBook.resaleFeeBps",
            fresh,
            t.resaleFeeBps == p.fees.resaleFeeBps,
            string.concat("orderBook resaleFeeBps == ", vm.toString(p.fees.resaleFeeBps), tag),
            vm.toString(t.resaleFeeBps)
        );
        _param(
            "orderBook.takerFeeFlat",
            fresh,
            t.takerFeeFlat == p.fees.takerFeeFlat,
            string.concat("orderBook takerFeeFlat == ", vm.toString(p.fees.takerFeeFlat), tag),
            vm.toString(t.takerFeeFlat)
        );
        _param(
            "orderBook.takerFeeCapBps",
            fresh,
            t.takerFeeCapBps == p.fees.takerFeeCapBps,
            string.concat("orderBook takerFeeCapBps == ", vm.toString(p.fees.takerFeeCapBps), tag),
            vm.toString(t.takerFeeCapBps)
        );
        _param(
            "orderBook.makerRebateBps",
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
            "clearinghouse.maxPayoutSlippageBps",
            fresh,
            ch.maxPayoutSlippageBps() == p.payoutSlippageBps,
            string.concat("clearinghouse maxPayoutSlippageBps == ", vm.toString(p.payoutSlippageBps)),
            vm.toString(ch.maxPayoutSlippageBps())
        );
        _param(
            "clearinghouse.minRedeemPayout",
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
                string.concat("keeperRewards.bounty.", names[i]),
                fresh,
                live == want[i],
                string.concat("keeperRewards bounty ", names[i], " == ", vm.toString(want[i])),
                vm.toString(live)
            );
        }
        _check(underMax, "keeperRewards bounties <= MAX_BOUNTY");
        _param(
            "keeperRewards.dailyCap",
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
            "autoRoller.minRollUnits",
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
            "makerVault.limits",
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
        _group("calendar");
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
                         ROLES (INTERFACE_VERSION 8)
    //////////////////////////////////////////////////////////////*/

    /// @notice Every access check, all of it read from {ROLES_JSON} at run time.
    /// @dev WHY THE v7 SECTION COULD NOT BE PATCHED. It asked every target for `hasRole` through OpenZeppelin's
    ///      AccessControl interface.
    ///      Every v8 target inherits `Managed`, which is `AccessManaged`: no `hasRole`, no ERC-165. Those staticcalls
    ///      REVERT rather than returning false, so the old section did not report FAIL -- it killed the run.
    ///
    ///      WHAT IS NOT CHECKABLE FROM A SCRIPT, stated rather than faked. `AccessManager` does not enumerate role
    ///      members: `hasRole(uint64, address)` needs an address and there is no `getRoleMembers`. Only the indexer,
    ///      reading `RoleGranted` logs, can answer "who holds role 3". So "no EOA holds a delayed role" is checked in
    ///      the form a script CAN answer -- every manifest holder of a role in 0..6 has code, and none of the five
    ///      known bot keys or the deployer holds any role in 0..6 -- and the same bound applies to the minter and
    ///      funding sweeps: they cover the sixteen contracts and the seven principals this deploy knows, nothing more.
    function _roles(Inputs memory in_) internal {
        _group("roles");
        string memory json = rolesJson();
        AccessManager mgr = AccessManager(in_.c.accessManager);
        // SEC-38-R. Three assertions are about the deployer -- ADMIN shed in {_handover}, no role in 0..6 in
        // {_principals}, and no role at any id in {_noSurplusMemberships} -- and all three skip a zero address. So
        // with V2_DEPLOYER unset they pass having looked at nothing, and the hand-over read as certified.
        if (in_.deployer == address(0)) {
            _notChecked("V2_DEPLOYER is unset, so no check in this group asserts that the deployer shed its roles");
        }
        _handover(in_, mgr, json);
        _principals(in_, mgr, json);
        _manifest(in_, mgr, json);
        _noUnlistedRestricted(in_, mgr, json);
        _accessInvariants(in_);
    }

    /// @dev 1. HANDOVER. The Safe owns the manager, the deployer owns nothing, and every managed target points at it.
    function _handover(Inputs memory in_, AccessManager mgr, string memory json) internal {
        uint64 adminRole = mgr.ADMIN_ROLE();
        uint32 wantDelay = roleDelayOf(json, "ADMIN");
        (uint48 safeSince, uint32 safeDelay, uint32 safePending, uint48 safeEffect) =
            mgr.getAccess(adminRole, in_.roles.adminSafe);
        bool safeIsAdmin = safeSince != 0 && safeSince <= block.timestamp;
        _check(
            safeIsAdmin && safeDelay == wantDelay,
            string.concat("accessManager: the Admin Safe holds ADMIN at ", vm.toString(uint256(wantDelay)), " s")
        );
        // T-436 P1-a. `hasRole` returns `since` and `currentDelay` and DROPS the pending delay and its effect time
        // (AccessManager.sol:217-227), so a scheduled reduction of ADMIN's execution delay reads as a correct 48 h
        // lane right up to the moment it becomes instant. This verifier is run to certify a deployment; certifying
        // a state that is already scheduled to change is the same as not checking it.
        _check(
            safeEffect == 0 || safePending == wantDelay,
            string.concat(
                "accessManager: the Admin Safe has NO pending ADMIN delay change (pending ",
                vm.toString(uint256(safePending)),
                " s at ",
                vm.toString(uint256(safeEffect)),
                ")"
            )
        );
        _check(in_.roles.adminSafe.code.length != 0, "accessManager: the ADMIN principal is a contract, not a key");
        (bool deployerIsAdmin,) = mgr.hasRole(adminRole, in_.deployer);
        _check(in_.deployer == address(0) || !deployerIsAdmin, "accessManager: the deployer holds no ADMIN any more");
        _authorities(in_.c, json);
    }

    /// @dev The authority sweep of {_handover}, in its own frame. It was inline until C8-DEPLOYPATH-EXECUTES,
    ///      where adding three locals to this file pushed `_handover` two slots over the via_ir limit
    ///      ("Cannot swap ... too deep in the stack" at the `string.concat` below). The checks are unchanged;
    ///      only the frame is smaller.
    /// @dev T-220. THE SUBJECT SET IS THE MANIFEST, not `_set(c)`. This walked the sixteen-entry deploy list while
    ///      its own message said "every roles.v8.json target", and `roles.v8.json` names TWENTY-ONE. `_set(c)`
    ///      carries fifteen of them plus the accessManager, so SIX targets were never read at all:
    ///      RewardsDistributorLender, HouseVault, HouseVaultFactory, Hedger, EarnVault and StockVenueAdapter --
    ///      three of which hold money. A vault or hedger left pointing at a stale authority, or still on a v7
    ///      access pattern, passed verification because the check could not see it.
    ///
    ///      `_targetOf` reverts on a name it does not know, so a manifest that grows a target this script cannot
    ///      place stops the run rather than silently checking `address(0)`.
    function _authorities(Contracts memory c, string memory json) internal {
        string[] memory targets = targetNames(json);
        address[] memory resolved = new address[](targets.length);
        bool pointed = true;
        bool managed = true;
        bool present = true;
        for (uint256 i; i < targets.length; ++i) {
            address target = _targetOf(c, targets[i]);
            resolved[i] = target;
            // V4BuybackExecutor is deliberately NOT Managed (src/v2/periphery/V4BuybackExecutor.sol) and its
            // roles.v8.json `targets` entry is empty on purpose, so it has no authority to read.
            //
            // T-426 F-05-03. EXEMPT BY NAME, NOT BY ADDRESS. This line used to read
            // `if (target == c.buybackExecutor) continue;`, which exempts whatever address the executor field
            // happens to hold -- so `V2_HOUSE_VAULT = V2_BUYBACK_EXECUTOR` made the HOUSE VAULT skip this walk and
            // the run report clean. The manifest name is the thing this exemption is actually about, and a name
            // cannot be aliased.
            if (_eq(targets[i], "V4BuybackExecutor")) continue;
            // T-OP-140. A target the caller DECLARED it did not deploy (V2_SKIP_EXTERNALS, validated external and
            // unsupplied) is NOT CHECKED, visibly, by name -- it is not `present`, it is excluded from the three
            // checks below, and its zero address is left in `resolved` so nothing downstream reads it. This is
            // the ONLY way a "has no address" is not a FAIL; an unsupplied external nobody declared still is.
            if (_isSkipped(targets[i])) {
                _skippedTarget(targets[i], "not resolved, not probed for authority()");
                continue;
            }
            if (target == address(0)) {
                // FAIL, NOT SKIP. Several manifest targets are supplied to the run by address rather than deployed
                // by it (V2DeployBase reads them with an `address(0)` default), so "no address" is exactly the case
                // that used to pass by being invisible. Reporting it green would rebuild the defect this removes.
                present = false;
                _infoNamed(targets[i], " has no address: it was never supplied to this run");
                continue;
            }
            // WHY THIS IS A STATICCALL AND NOT A TYPED CALL. A target that is still on v7 `AccessControl` has no
            // `authority()`, and a typed call to it REVERTS -- which would kill the whole run, the exact failure this
            // rewrite exists to remove. Probing instead turns "not converted yet" into a named FAIL that goes green
            // by itself when the conversion lands.
            (bool answers, address authority_) = _authorityOf(target);
            if (!answers) {
                managed = false;
                _infoNamed(targets[i], " has no authority(): it is still on v7 AccessControl");
            } else if (authority_ != c.accessManager) {
                pointed = false;
                _infoNamed(targets[i], " points at a different authority");
            }
        }
        _check(present, "every roles.v8.json target resolves to an address this run was given");
        _check(managed, "every roles.v8.json target is Managed (C8-03 converts the orderBook last)");
        _check(pointed, "every managed contract's authority is the accessManager");
        _distinctTargets(targets, resolved);
        _externalIdentities(c);
    }

    /// @dev T-426 F-05-03. One address under two manifest names is a NAMED FAIL. The addresses are the ones
    ///      {_authorities} already resolved, so this costs a nested address comparison and no second manifest walk.
    ///
    ///      WHY IT IS A CHECK AND NOT A COMMENT. Every other group in this file reads state off `_targetOf(c, name)`
    ///      and reports what it finds, which means an aliased pair is checked TWICE and the second contract is
    ///      checked NEVER -- with no failure anywhere, because everything that was asked was answered. That is the
    ///      same shape as a check that cannot see its subject; the subject here is the target that was never read.
    function _distinctTargets(string[] memory targets, address[] memory resolved) internal {
        bool distinct = true;
        for (uint256 i; i < targets.length; ++i) {
            if (resolved[i] == address(0)) continue;
            for (uint256 j = i + 1; j < targets.length; ++j) {
                if (resolved[i] != resolved[j]) continue;
                distinct = false;
                _info(
                    string.concat(targets[i], " and ", targets[j], " are the same address: ", vm.toString(resolved[i]))
                );
            }
        }
        _check(distinct, "no two roles.v8.json targets are the same address");
    }

    /// @dev T-426 F-05-03, the other half. The six targets the deploy does not create arrive as raw addresses, and
    ///      every other group in this file then reads state off them under the name it was given. If the name and
    ///      the contract disagree, those reads answer about the wrong contract and agree with the mistake.
    ///
    ///      SAME PROBE AS `DeployV8._assertSuppliedTargetsAreWhatTheirNameClaims`, and the same getter pairs, taken
    ///      from the same sources. The two scripts must not disagree about what a HouseVault is. `RewardsDistributor-
    ///      Lender` is the one that cannot be told from the maker instance by interface -- it is the same contract --
    ///      so what catches a swap there is {_distinctTargets}, not this.
    function _externalIdentities(Contracts memory c) internal {
        _identity(c.houseVault, "HouseVault", "underlying()");
        _identity(c.houseVault, "HouseVault", "clearinghouse()");
        _identity(c.houseVaultFactory, "HouseVaultFactory", "vaults()");
        _identity(c.hedger, "Hedger", "notional()");
        _identity(c.hedger, "Hedger", "loan()");
        _identity(c.earnVault, "EarnVault", "queue()");
        _identity(c.earnVault, "EarnVault", "adapter()");
        _identity(c.stockVenueAdapter, "StockVenueAdapter", "venue()");
        _identity(c.stockVenueAdapter, "StockVenueAdapter", "enabled()");
        _identity(c.rewardsDistributorLender, "RewardsDistributorLender", "usdg()");
    }

    /// @dev An UNSET target is already a named FAIL in {_authorities} ("has no address"), so it is skipped here
    ///      rather than counted twice. An address WITH code that does not answer is a FAIL of its own, and a
    ///      staticcall is used for the same reason `authority()` is probed rather than called: a typed call to a
    ///      contract that is not what the manifest claims would revert and take the whole run down.
    function _identity(address target, string memory name, string memory sig) internal {
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        _check(ok && ret.length != 0, string.concat(name, " answers ", sig, ": it is the contract its name claims"));
    }

    /// @dev 2. PRINCIPALS. (a) every manifest holder of a role in 0..6 has code; (b) no bot key and not the deployer
    ///      holds any role in 0..6; (c) each expected (holder, role) pair carries the manifest's delay.
    ///
    ///      (b) IS NARROWER THAN ITS NAME, and {_noSurplusMemberships} is what covers the rest. (b) stops at
    ///      `DELAYED_ROLE_MAX`, so it says nothing about roles 7..10 -- the instant lanes -- for the deployer or
    ///      anyone else. The bound is right for the bot keys, which are SUPPOSED to hold their instant lane, and
    ///      cannot be widened here. T-436's sweep is the wide one: every known principal, the deployer included,
    ///      holds exactly its manifest roles over every declared id. SEC-38 was raised against the gap between the
    ///      two after T-436 had closed it. Both skip a zero deployer; {_roles} reports that case as NOT CHECKED.
    ///
    ///      WHAT THIS GROUP CANNOT SEE, stated so the next reader does not over-trust it. This is NOT "no EOA holds
    ///      a delayed role". `AccessManager` HAS NO MEMBER ENUMERATION -- `hasRole(id, who)` answers only about an
    ///      address you already hold, and there is no `getRoleMember`/`getRoleMemberCount` and no set to walk. So
    ///      the only addresses that can be asked about are the ones this script already has: the `roles.v8.json`
    ///      `.holders` principals, and the five bot keys read from the environment below. AN UNLISTED THIRD-PARTY
    ///      EOA GRANTED CONFIG_ADMIN OR LISTING IS INVISIBLE TO EVERY CHECK IN THIS GROUP, because nothing here (or
    ///      anywhere else in this file) walks `RoleGranted` logs. What is actually proven is the narrower claim
    ///      "no MANIFEST HOLDER and no KNOWN BOT KEY is a plain key in a delayed role". Closing the gap needs an
    ///      event walk over `RoleGranted`/`RoleRevoked` from the deploy block, which a `forge script` read of live
    ///      state cannot do; it belongs to the off-chain monitor, not here.
    function _principals(Inputs memory in_, AccessManager mgr, string memory json) internal {
        string[] memory holders = holderNames(json);
        bool held = true;
        bool delayed = true;
        bool contracts = true;
        for (uint256 i; i < holders.length; ++i) {
            address who = _principalOf(in_.roles, holders[i]);
            string[] memory roleNames = holderRoles(json, holders[i]);
            for (uint256 j; j < roleNames.length; ++j) {
                (bool h, bool d, bool ct) = _principalRole(mgr, json, holders[i], who, roleNames[j]);
                held = held && h;
                delayed = delayed && d;
                contracts = contracts && ct;
            }
        }
        _check(held, "every roles.v8.json holder holds every role the manifest gives it");
        _check(delayed, "every holder's execution delay is the manifest delay for that role");
        _check(contracts, "every holder of a role in 0..6 is a contract");

        address[5] memory keys =
            [in_.deployer, in_.roles.guardianKey, in_.roles.pricerKey, in_.roles.quoterKey, in_.roles.crankerKey];
        bool clean = true;
        for (uint256 k; k < keys.length; ++k) {
            if (keys[k] == address(0)) continue;
            for (uint64 id; id <= DELAYED_ROLE_MAX; ++id) {
                (bool isMember,) = mgr.hasRole(id, keys[k]);
                if (isMember) {
                    clean = false;
                    _info(
                        string.concat(
                            vm.toString(keys[k]), " holds role ", vm.toString(uint256(id)), ", a delayed lane"
                        )
                    );
                }
            }
        }
        _check(clean, "no bot key and not the deployer holds any role in 0..6");
        _noSurplusMemberships(in_, mgr, json);

        address[7] memory principals = [
            in_.roles.adminSafe,
            in_.roles.treasurySafe,
            in_.roles.guardianKey,
            in_.roles.pricerKey,
            in_.roles.quoterKey,
            in_.roles.crankerKey,
            in_.roles.feeRecipient
        ];
        bool distinct = true;
        for (uint256 i; i < principals.length; ++i) {
            for (uint256 j = i + 1; j < principals.length; ++j) {
                distinct = distinct && principals[i] != principals[j];
            }
        }
        _check(distinct, "the seven principals are seven distinct addresses");
    }

    /// @dev The payout route and the settlement pool, extracted from {_market} because three more locals there
    ///      put `_market` over the via_ir stack limit ("Cannot swap ... too deep in the stack"). Same remedy the
    ///      JSON builders in this tree already use: a smaller frame, not fewer checks.
    function _routeAndSettlementPool(Inputs memory in_, Contracts memory c, MarketIn memory m, string memory t)
        internal
    {
        // THE ROUTE IS CHECKED AGAINST `markets[].v2.payoutRoute`, NOT AGAINST THE SETTLEMENT POOL.
        //
        // This check used to key on `m.pool` -- the SETTLEMENT univ3 pool -- and it failed BOTH of its branches
        // on the pinned launch set. TSLA has no settlement pool but a v4 payout route with fee 3000, so it took
        // the else arm and failed `routePool == 0 && routeFee == 0`. NVDA has BOTH a settlement pool and a v4
        // payout route, so it took the if arm and failed `routePool == m.pool` -- which a v4 route can never
        // satisfy, because a v4 route carries no v3Pool by construction. `RegisterMarkets.s.sol:763-764` says it
        // outright: "Payout is markets[].v2.payoutRoute (O8-03), NOT the settlement univ3Pool." The shipped
        // tooling set one thing and verified another.
        //
        // The settlement pool keeps its OWN check below, because its fee tier still bounds what the
        // Clearinghouse's floor will convert.
        PayoutRouter router = PayoutRouter(payable(c.payoutRouter));
        IPayoutRouter.Route memory route = router.routes(m.asset);
        if (m.pool != address(0)) {
            uint24 settlementFee = m.poolFee != 0 ? m.poolFee : IPoolFee(m.pool).fee();
            _check(
                settlementFee <= V2Constants.MAX_ROUTE_FEE_TIER,
                string.concat(
                    t,
                    "settlement pool fee tier ",
                    vm.toString(uint256(settlementFee)),
                    " <= 10000 (above 1 % the Clearinghouse's floor would pay every conversion in kind)"
                )
            );
        }
        // THE ROUTE COMES OFF {MarketIn}, not from a second read of the environment. C8-DEPLOYPATH-EXECUTES
        // moved these onto the struct so the deploy side and the verify side cannot decode the same variables
        // by two different rules -- which is the drift that let the shipped tooling set one route and verify
        // another in the first place.
        uint8 payoutVenue = m.payoutVenue;
        uint24 payoutFee = m.payoutFee;
        int24 payoutTickSpacing = m.payoutTickSpacing;
        if (payoutVenue == uint8(IPayoutRouter.Venue.V3)) {
            _check(
                route.venue == IPayoutRouter.Venue.V3 && route.fee == payoutFee
                    && route.v3Pool == IUniV3PoolFactory(router.v3Factory()).getPool(m.asset, in_.ext.usdg, payoutFee)
                    && route.v3Pool != address(0),
                string.concat(t, "payout route is v3 at fee ", vm.toString(uint256(payoutFee)), ", the factory's pool")
            );
        } else if (payoutVenue == uint8(IPayoutRouter.Venue.V4)) {
            // A v4 route carries fee and tickSpacing and NO v3Pool. `setRouteV4` rebuilds the PoolKey from those
            // two, which is why both are pinned in the registry and both are checked here.
            _check(
                route.venue == IPayoutRouter.Venue.V4 && route.fee == payoutFee
                    && route.tickSpacing == payoutTickSpacing && route.v3Pool == address(0),
                string.concat(
                    t,
                    "payout route is v4 at fee ",
                    vm.toString(uint256(payoutFee)),
                    " tickSpacing ",
                    vm.toString(int256(payoutTickSpacing)),
                    ", no v3 pool"
                )
            );
            // THE PINNED POOL ID. `setRouteV4` stores only (fee, tickSpacing) and rebuilds the PoolKey from
            // them at swap time, so the route above can be entirely self-consistent and STILL address a
            // different pool than the registry pinned. A wrong tickSpacing does not revert -- it routes every
            // payout through whatever pool that key happens to name, and nothing on chain says so. This is the
            // one assertion in this file that is a PIN rather than a check, which is why it runs even under the
            // 2026-09-19 build-mode directive.
            //
            // Fail closed: a v4 route with no pinned id is REFUSED, not skipped. `DeployV2Batch.sh:618` unsets
            // the variable when the registry row has none, so an absent pin means the registry is incomplete --
            // and a check that quietly passes when it cannot see its subject is the exact failure this deploy
            // path has now produced three times.
            _check(
                m.payoutPoolId != bytes32(0),
                string.concat(t, "v4 payout route pins a poolId (V2_MARKET_<T>_PAYOUT_POOL_ID is set)")
            );
            if (m.payoutPoolId != bytes32(0)) {
                bytes32 built = V4Currency.id(V4Currency.key(m.asset, in_.ext.usdg, payoutFee, payoutTickSpacing));
                _check(
                    built == m.payoutPoolId,
                    string.concat(
                        t,
                        "v4 payout route (fee ",
                        vm.toString(uint256(payoutFee)),
                        ", tickSpacing ",
                        vm.toString(int256(payoutTickSpacing)),
                        ") resolves to the PINNED pool ",
                        vm.toString(m.payoutPoolId),
                        ", got ",
                        vm.toString(built)
                    )
                );
            }
        } else {
            _check(
                route.venue == IPayoutRouter.Venue.None && route.v3Pool == address(0) && route.fee == 0,
                string.concat(t, "no payout route (paid in kind)")
            );
        }
    }

    /// @dev One (holder, role) pair of {_principals}, in its own frame: held, delay-correct, and contract-not-key.
    ///      Extracted in C8-DEPLOYPATH-EXECUTES because the `string.concat` reporting below shared a frame with
    ///      both loop counters and three accumulators, which put `_principals` over the via_ir stack limit once
    ///      this file grew. The checks and the messages are unchanged.
    /// @notice Every known principal holds EXACTLY the roles `roles.v8.json` gives it, over every role id.
    /// @dev T-436 P1-b. The sweep above it is narrower than it looks in two ways that matter, and both are the same
    ///      mistake: it asks only about ids 0..6 and only about five addresses.
    ///        THE ID RANGE. Roles 7..10 (GUARDIAN, PRICER, QUOTER, BUYBACK) are the INSTANT lanes -- delay 0 in
    ///        `.delaysS` -- and QUOTER alone reaches 29 mapped selectors. A surplus membership there is not a
    ///        lesser finding than one in a delayed lane; it is a worse one, because there is no delay in which to
    ///        react to it.
    ///        THE ADDRESS LIST. `treasurySafe` appears in this file only inside the distinct-address array, so
    ///        nothing has ever asked what roles it holds. It is the address every money lane pays.
    ///      The id range is derived from `.roles` and the expectation from `.holders`, so an eleventh role or a new
    ///      principal is covered the day the manifest declares it. That is deliberate: `id <= DELAYED_ROLE_MAX` is
    ///      exactly the kind of literal bound that makes a check stop seeing its subject when the subject grows.
    ///
    ///      WHAT THIS STILL CANNOT SEE, stated so nobody over-trusts it: `AccessManager` has no member enumeration,
    ///      so this asks about addresses this run already holds. An unlisted third-party EOA granted a role remains
    ///      invisible to it, exactly as the note on {_principals} says.
    function _noSurplusMemberships(Inputs memory in_, AccessManager mgr, string memory json) internal {
        uint64[] memory ids = _allRoleIds(json);
        address[7] memory who = [
            in_.roles.adminSafe,
            in_.roles.treasurySafe,
            in_.roles.guardianKey,
            in_.roles.pricerKey,
            in_.roles.quoterKey,
            in_.roles.crankerKey,
            in_.deployer
        ];
        // The manifest `.holders` key for each address above, or "" for a principal the manifest gives NO role --
        // which is a real expectation and not a gap: the treasury Safe and the deployer must hold nothing at all.
        string[7] memory names = ["adminSafe", "", "guardianKey", "pricerKey", "quoterKey", "crankerKey", ""];
        bool exact = true;
        for (uint256 k; k < who.length; ++k) {
            if (who[k] == address(0)) continue;
            for (uint256 i; i < ids.length; ++i) {
                (bool isMember,) = mgr.hasRole(ids[i], who[k]);
                if (isMember == _manifestGives(json, names[k], ids[i])) continue;
                exact = false;
                _info(
                    string.concat(
                        vm.toString(who[k]),
                        isMember ? " holds role id " : " is MISSING role id ",
                        vm.toString(uint256(ids[i])),
                        ", which roles.v8.json does ",
                        isMember ? "not give it" : "give it"
                    )
                );
            }
        }
        _check(exact, "every known principal holds exactly its roles.v8.json roles, over every role id");
    }

    /// @dev Does `.holders.<holderName>` contain a role whose id is `id`? An empty holder name means the manifest
    ///      names no roles for that principal, so the answer is false for every id.
    function _manifestGives(string memory json, string memory holderName, uint64 id) internal pure returns (bool) {
        if (bytes(holderName).length == 0) return false;
        string[] memory roleNames_ = holderRoles(json, holderName);
        for (uint256 i; i < roleNames_.length; ++i) {
            if (roleIdOf(json, roleNames_[i]) == id) return true;
        }
        return false;
    }

    /// @notice Every role id `roles.v8.json` declares, in manifest order.
    /// @dev T-436. The twin of `DeployV8._allRoleIds`, declared here for the same reason the Safe interface is:
    ///      importing the deploy script would compile it as a dependency of this one. Derived from `.roles`, never
    ///      written as the literal range.
    function _allRoleIds(string memory json) internal pure returns (uint64[] memory ids) {
        string[] memory names = vm.parseJsonKeys(json, ".roles");
        ids = new uint64[](names.length);
        for (uint256 i; i < names.length; ++i) {
            ids[i] = roleIdOf(json, names[i]);
        }
    }

    function _principalRole(
        AccessManager mgr,
        string memory json,
        string memory holder,
        address who,
        string memory roleName
    ) internal returns (bool held, bool delayed, bool isContract) {
        held = true;
        delayed = true;
        isContract = true;
        uint64 id = roleIdOf(json, roleName);
        uint32 want = roleDelayOf(json, roleName);
        // T-436 P1-a. All four fields. A pending change to THIS pair's execution delay is a future violation of the
        // same invariant the two branches below enforce for the present one, and `hasRole` cannot see it.
        (uint48 since, uint32 delay, uint32 pendingDelay, uint48 effect) = mgr.getAccess(id, who);
        bool isMember = since != 0 && since <= block.timestamp;
        if (isMember && effect != 0 && pendingDelay != want) {
            delayed = false;
            _info(
                string.concat(
                    holder,
                    " has a PENDING ",
                    roleName,
                    " delay change to ",
                    vm.toString(uint256(pendingDelay)),
                    " s at ",
                    vm.toString(uint256(effect)),
                    ", manifest says ",
                    vm.toString(uint256(want))
                )
            );
        }
        if (!isMember) {
            held = false;
            _info(string.concat(holder, " does not hold ", roleName));
        } else if (delay != want) {
            delayed = false;
            _info(
                string.concat(
                    holder,
                    " holds ",
                    roleName,
                    " at delay ",
                    vm.toString(uint256(delay)),
                    ", manifest says ",
                    vm.toString(uint256(want))
                )
            );
        }
        // Reached ONLY for an address the caller already had -- a manifest holder or a known bot key. It is not,
        // and cannot be, a statement about every member of the role: see {_principals} on the missing enumeration.
        if (id <= DELAYED_ROLE_MAX && who.code.length == 0) {
            isContract = false;
            _info(string.concat(holder, " holds the delayed role ", roleName, " and is a plain key"));
        }
    }

    /// @dev 3. MANIFEST MATCH: selector map, role tree, and the two delays roles.v8.json says are deliberately 0.
    function _manifest(Inputs memory in_, AccessManager mgr, string memory json) internal {
        string[] memory targets = targetNames(json);
        bool mapped = true;
        for (uint256 t; t < targets.length; ++t) {
            // T-OP-140. Same exclusion as {_authorities}, same line: a skipped external's selectors are not
            // walked (they would all read ADMIN off address(0) and fail "not mapped"), and the target stays in
            // the NOT CHECKED group the verdict prints.
            if (_isSkipped(targets[t])) {
                _skippedTarget(targets[t], "its manifest selectors were not read");
                continue;
            }
            address target = _targetOf(in_.c, targets[t]);
            string[] memory sigs = targetSigs(json, targets[t]);
            for (uint256 s; s < sigs.length; ++s) {
                uint64 want = roleIdOf(json, roleNameOfSig(json, targets[t], sigs[s]));
                if (mgr.getTargetFunctionRole(target, selectorOf(sigs[s])) != want) {
                    mapped = false;
                    _info(string.concat(targets[t], ".", sigs[s], " is not mapped to its manifest role"));
                }
            }
        }
        _check(mapped, "every roles.v8.json selector is mapped to its manifest role on chain");

        string[] memory roleNames = vm.parseJsonKeys(json, ".roles");
        bool tree = true;
        bool ungated = true;
        for (uint256 i; i < roleNames.length; ++i) {
            uint64 id = roleIdOf(json, roleNames[i]);
            // An unlisted role admin or guardian is ADMIN (0) by AccessManager's own default, which is what the
            // manifest omitting it means. Read the expectation from the file, never from the chain.
            uint64 wantAdmin = _roleRefOr0(json, true, roleNames[i]);
            uint64 wantGuardian = _roleRefOr0(json, false, roleNames[i]);
            if (mgr.getRoleAdmin(id) != wantAdmin || mgr.getRoleGuardian(id) != wantGuardian) {
                tree = false;
                _info(string.concat(roleNames[i], ": role admin or guardian differs from the manifest"));
            }
            if (mgr.getRoleGrantDelay(id) != 0) {
                ungated = false;
                _info(string.concat(roleNames[i], " has a non-zero grant delay"));
            }
        }
        _check(tree, "every role's admin and guardian match roles.v8.json");
        // T-436 P2-e. THE CLAIM IS NARROWED, NOT ANNOTATED. `getRoleGrantDelay` returns the CURRENT value and
        // AccessManager exposes no four-field getter for it, unlike `getAccess` for a membership's execution delay
        // -- so a scheduled change to a grant delay is not readable by any on-chain call this script can make.
        // The two honest options were event-history evidence or a narrower claim; a `forge script` read cannot walk
        // `RoleGrantDelayChanged` logs from the deploy block (the same limitation the note on {_principals}
        // records for `RoleGranted`), so the CLAIM ITSELF now says "at this block". Printing the old sentence with
        // a "pending not checked" line beside it would leave the over-claim on the page, which is the thing being
        // fixed. Closing it properly belongs to the off-chain monitor, which does have the logs.
        _check(
            ungated,
            "every role's grant delay is 0 AT THIS BLOCK (a scheduled change is not readable on chain; notes.grantDelays: minSetback is 5 days)"
        );

        _targetsOpen(in_.c, mgr, json);
    }

    /// @dev The closed-target / target-admin-delay pass of group 3, in its own frame.
    ///
    ///      T-182 / F-DCON-07. THE SUBJECT SET IS THE MANIFEST, not `_set(c)`, for exactly the reason T-220 gives
    ///      above {_authorities}. This walked the SIXTEEN-entry deploy list while `roles.v8.json` names TWENTY-ONE
    ///      targets. HouseVault, HouseVaultFactory, Hedger and RewardsDistributorLender resolve for the selector
    ///      pass forty lines above and are NOT in `_set(c)`, so a closed target or a stray target admin delay on
    ///      any of the four -- three of which hold money -- printed a PASS. The check reported success because its
    ///      subject was not in the list it walked, which is the same defect shape `_noUnlistedRestricted` and
    ///      `_authorities` each had removed before it.
    ///
    ///      WHY THIS IS NOT COSMETIC. `isTargetClosed` makes EVERY restricted selector on that contract answer to
    ///      nobody, including the manager's own; a non-zero `getTargetAdminDelay` puts `setTargetFunctionRole` for
    ///      that contract behind a schedule, so the recovery from a mistake on it is itself delayed. On a house
    ///      vault that is deposits, withdrawals and the epoch roll frozen with the unfreeze five days out --
    ///      `roles.v8.json notes.grantDelays` records that `minSetback` is five days.
    function _targetsOpen(Contracts memory c, AccessManager mgr, string memory json) internal {
        string[] memory targets = targetNames(json);
        bool open = true;
        for (uint256 i; i < targets.length; ++i) {
            address target = _targetOf(c, targets[i]);
            // V4BuybackExecutor is deliberately NOT Managed (src/v2/periphery/V4BuybackExecutor.sol) and its
            // `targets` entry is empty on purpose, so it has no target state to read. {_authorities} skips it for
            // the same reason and with the same words -- including T-426's: BY NAME, never by address equality
            // against `c.buybackExecutor`, which exempts any target aliased onto the executor's address.
            if (_eq(targets[i], "V4BuybackExecutor")) continue;
            // NOT a silent skip of a real problem: a manifest target with no address is ALREADY a named FAIL in
            // {_authorities} ("has no address: it was never supplied to this run"), which runs in the same
            // verification against the same manifest. Reading target state off `address(0)` here would add a
            // second, worse-worded copy of a failure the run already carries.
            if (target == address(0)) continue;
            if (mgr.getTargetAdminDelay(target) != 0 || mgr.isTargetClosed(target)) {
                open = false;
                _infoNamed(targets[i], " is closed or carries a target admin delay");
            }
        }
        // No `accessManager` exemption, deliberately: it is the manager, not a managed contract, and it is not a
        // `roles.v8.json` target. The old loop needed that exemption only because `_set(c)` carried it.
        // T-436 P2-e, same reasoning as the grant delay: `getTargetAdminDelay` and `isTargetClosed` answer about
        // now, and a scheduled change to either is invisible to an on-chain read. The claim states the block it is
        // about rather than implying the state will hold.
        _check(
            open,
            "no roles.v8.json target is closed and none carries a target admin delay AT THIS BLOCK (a scheduled change is not readable on chain)"
        );
    }

    /// @dev 4. NO UNLISTED RESTRICTED SELECTOR. 06-QUIRKS §A.8 turned into an on-chain read: a `restricted` selector
    ///      the manifest never named would silently answer to ADMIN. Walk the compiled ABI and require every selector
    ///      to be mapped to exactly the manifest's role, or to 0 when the manifest does not list it -- which is
    ///      unambiguous only because roles.v8.json `notes.adminHasNoTarget` fixes that no target function is ADMIN's.
    function _noUnlistedRestricted(Inputs memory in_, AccessManager mgr, string memory json) internal {
        string[] memory targets = targetNames(json);
        bool clean = true;
        // T-OP-152. The per-target frame and the reverting probe frame live in {VerifyProbe}, a plain contract
        // created inside the simulation (read-only: nothing is broadcast, and `--broadcast` is never passed to
        // this script). They used to be `this.<fn>()` self-calls, which `forge script` aborts on -- see the helper.
        if (address(probe) == address(0)) probe = new VerifyProbe();
        for (uint256 t; t < targets.length; ++t) {
            // T-OP-140: a skipped external has no address to probe; it is NOT CHECKED by name, not silently clean.
            if (_isSkipped(targets[t])) {
                _skippedTarget(targets[t], "its restricted selectors were not probed");
                continue;
            }
            clean = _noUnlistedRestrictedTarget(in_.c, mgr, json, targets[t]) && clean;
        }
        _check(clean, "no selector outside roles.v8.json is mapped to a role or refuses a stranger");
    }

    /// @dev One target of {_noUnlistedRestricted}: resolved HERE (address, artifact, the manifest's rows for it
    ///      and their roles, the exempt signatures), walked in the helper's own EVM memory frame so the artifact
    ///      and its method list die on return. Public and virtual so the test can count every target the outer
    ///      walk visits without weakening or replacing the real artifact check; called internally, never through
    ///      `this`.
    function _noUnlistedRestrictedTarget(
        Contracts memory c,
        AccessManager mgr,
        string memory json,
        string memory targetName
    ) public virtual returns (bool clean) {
        return _walkTargetAt(mgr, json, targetName, targetName, _targetOf(c, targetName));
    }

    /// @dev The body of {_noUnlistedRestrictedTarget} at an explicit address: `manifestName` selects the artifact,
    ///      the manifest rows and the exemptions; `label` is what the info lines call it. T-OP-171 split it out so
    ///      a per-ticker House vault ({_houseVaults}) is walked exactly as the single `HouseVault` target is,
    ///      with the ticker in every line.
    function _walkTargetAt(
        AccessManager mgr,
        string memory json,
        string memory manifestName,
        string memory label,
        address target
    ) internal returns (bool clean) {
        string memory targetName = manifestName;
        string memory artifact = _artifactOf(targetName);
        if (bytes(artifact).length == 0) return true;
        // T-216. FAIL BY NAME, AT RUNTIME, NOT JUST IN THE TEST. {_artifactOf} derives this path rather than
        // reading it off a table, so a manifest target with no compiled artifact no longer reverts inside the
        // resolver with a sentence naming it. Without this line the run dies one statement below on
        // `vm.readFile: failed to open file .../out/X.sol/X.json`, which states the path and leaves the reader
        // to work out which manifest row produced it. Same defect the sibling assertion in
        // ManifestResolvers.t.sol had: the check was right and could not say what it had caught.
        require(
            vm.isFile(artifact),
            string.concat("no compiled artifact at ", artifact, " for roles.v8.json target: ", targetName)
        );
        if (address(probe) == address(0)) probe = new VerifyProbe();
        VerifyProbe.Target memory t;
        t.name = label;
        t.target = target;
        t.artifact = artifact;
        t.sigs = targetSigs(json, targetName);
        t.wantRoles = new uint64[](t.sigs.length);
        for (uint256 s; s < t.sigs.length; ++s) {
            t.wantRoles[s] = roleIdOf(json, roleNameOfSig(json, targetName, t.sigs[s]));
        }
        t.exempt = _unmappedExemptFor(json, targetName);
        return probe.walkTarget(mgr, t);
    }

    /// @dev Signatures that refuse a stranger WITHOUT being manager-`restricted`, and therefore must not be read as
    ///      a missing manifest row. Two sources, and only one of them is a list in this file:
    ///        - `roles.v8.json` `.unrestricted.<target>`: in-contract gates that reuse `NotAuthorized` on purpose
    ///          (`OrderBook.setFunding`, `V4BuybackExecutor.execute`). Data, so it moves when the manifest moves.
    ///        - {unmappedExemptSignatures}: the ones the manifest does not carry.
    ///      Computed once per target and handed to {VerifyProbe-walkTarget}, which compares method names against it.
    function _unmappedExemptFor(string memory json, string memory targetName)
        internal
        pure
        returns (string[] memory exempt)
    {
        string[] memory hard = unmappedExemptSignatures();
        string[] memory soft;
        string[] memory groups = vm.parseJsonKeys(json, ".unrestricted");
        for (uint256 i; i < groups.length; ++i) {
            if (bytes(groups[i])[0] == "_") continue;
            if (!_eq(groups[i], targetName)) continue;
            soft = vm.parseJsonKeys(json, string.concat(".unrestricted.", groups[i]));
            break;
        }
        exempt = new string[](hard.length + soft.length);
        uint256 n;
        for (uint256 i; i < hard.length; ++i) {
            exempt[n++] = hard[i];
        }
        for (uint256 j; j < soft.length; ++j) {
            if (bytes(soft[j])[0] == "_") continue;
            exempt[n++] = soft[j];
        }
        assembly ("memory-safe") {
            mstore(exempt, n)
        }
    }

    /// @notice Signatures that answer `NotAuthorized` to a stranger through something other than the manager, so the
    ///         unlisted-selector walk must not treat them as a manifest omission.
    /// @dev EVERY ROW HERE IS A HOLE IN THE GUARD, so each one says which non-manager gate produces the refusal:
    ///        - `setAuthority(address)`: `Managed` compares `msg.sender` to `authority()` directly (Managed.sol:57).
    ///        - `batchRedeemOne` / `convertPayout`: Clearinghouse self-calls, gated on `msg.sender == address(this)`.
    ///        - the two ERC-1155 receiver hooks: Clearinghouse-only, or always-revert on the book's batch hook.
    ///        - `placeFor`: the book's maker/delegate `_authorize`, not `restricted`.
    ///        - `unlockCallback(bytes)` / `uniswapV3SwapCallback`: pool-manager and router callbacks.
    ///        - `pin(address,uint40)`: oracle-only (`isOracle` / clearinghouse). It is absent from the manifest's
    ///          `unrestricted` section, and `roles.v8.json` is outside this row's fence, so it is listed here.
    ///        - `buy(uint256,uint256,uint256)`: splitter-only; the manifest's unrestricted row names `execute`.
    ///      PUBLIC AND EXACTLY MIRRORED by `test/v2/unit/AccessMatrix.t.sol`, whose behavioural walk needs the same
    ///      exemptions and asserts set equality with this function rather than keeping a second copy that drifts.
    ///      Adding a row here blinds BOTH walks to that signature; it wants the same evidence a finding wants.
    function unmappedExemptSignatures() public pure returns (string[] memory sigs) {
        sigs = new string[](10);
        sigs[0] = "setAuthority(address)";
        sigs[1] = "batchRedeemOne(uint256,address,address)";
        sigs[2] = "convertPayout(address,uint256,uint256,address)";
        sigs[3] = "onERC1155Received(address,address,uint256,uint256,bytes)";
        sigs[4] = "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)";
        sigs[5] = "placeFor(address,uint256,uint8,uint128,uint64,uint40)";
        sigs[6] = "unlockCallback(bytes)";
        sigs[7] = "pin(address,uint40)";
        sigs[8] = "buy(uint256,uint256,uint256)";
        sigs[9] = "uniswapV3SwapCallback(int256,int256,bytes)";
    }

    /// @dev Every contract that can hold protocol money and answers a `treasury()` exit pointer, with the name the
    ///      report prints for it. THE REPORTED SENTENCE IS BUILT FROM THIS ARRAY, so the two cannot drift apart.
    ///
    ///      DELIBERATELY NOT `_set(c)`. That list is the sixteen contracts the deploy walks for bytecode and for
    ///      role mapping, and it contains neither the Hedger nor the lender `RewardsDistributor` -- so reusing it
    ///      here would have reproduced the very gap this group is closing. `roles.v8.json` names 21 targets; the
    ///      sixteen-entry list is a SEPARATE staleness (F-DCON-07, owned by T-182-C8-DEPLOYPATH-HARDENING) and is
    ///      deliberately left alone here because that file and this one collide.
    function _moneyLaneSubjects(Contracts memory c)
        internal
        pure
        returns (address[] memory addrs, string[] memory names)
    {
        addrs = new address[](6);
        names = new string[](6);
        (addrs[0], names[0]) = (c.feeSplitter, "feeSplitter");
        (addrs[1], names[1]) = (c.keeperRewards, "keeperRewards");
        (addrs[2], names[2]) = (c.makerVault, "makerVault");
        (addrs[3], names[3]) = (c.rewardsDistributor, "rewardsDistributor");
        // The two T-173 adds. Both are `roles.v8.json` targets (21 of them) and both hold USDG: the lender
        // distributor funds the lending-side rewards, and the Hedger holds idle USDG plus Morpho collateral that
        // `withdrawCollateral` returns. Before this, neither contract's exit pointer was verified by anything.
        (addrs[4], names[4]) = (c.rewardsDistributorLender, "rewardsDistributorLender");
        (addrs[5], names[5]) = (c.hedger, "hedger");
    }

    /// @dev 5-7 and 9. The money-lane invariants that do not live on the manager: where value can leave to, who
    ///      collects fees, who may mint, and that the two launch dials are still off.
    function _accessInvariants(Inputs memory in_) internal {
        Contracts memory c = in_.c;
        address treasury = in_.roles.treasurySafe;
        // T-173-C8-HEDGER-MONEYPATH. This used to name four treasuries in a `&&` chain and a hand-written
        // sentence beside it. Both the subject list and the sentence now come from {_moneyLaneSubjects}, so the
        // message CANNOT claim a subject the loop did not walk: adding a contract to that array is the only way to
        // change either, and it changes both at once.
        (address[] memory moneyAddrs, string[] memory moneyNames) = _moneyLaneSubjects(c);
        bool oneExit = true;
        string memory walked;
        uint256 walkedCount;
        for (uint256 i; i < moneyAddrs.length; ++i) {
            // T-OP-140. Two of the six subjects are externals the caller may have declared undeployed
            // (V2_SKIP_EXTERNALS). A skipped one is NOT CHECKED by name and leaves both the count and the sentence
            // below, which must not claim a subject the loop did not walk. An unset subject NOBODY declared is
            // still the FAIL two comments down.
            string memory manifestName = _manifestNameOfMoneySubject(moneyNames[i]);
            if (bytes(manifestName).length != 0 && _isSkipped(manifestName)) {
                _skippedTarget(manifestName, "its treasury() exit was not read");
                continue;
            }
            (bool answers, address held) = _treasuryOf(moneyAddrs[i]);
            if (!answers) {
                // FAIL, NOT SKIP. A subject supplied as address(0) or without a `treasury()` is precisely the
                // case this group exists to catch -- `V2DeployBase.sol:340-341` reads the Hedger and the lender
                // distributor from the environment with an `address(0)` default, so an unset variable would
                // otherwise make this check pass by not being able to see its subject.
                oneExit = false;
                _info(
                    string.concat(
                        moneyNames[i], ": treasury() unreadable (address unset, no code, or no such function)"
                    )
                );
            } else if (held != treasury) {
                oneExit = false;
                _info(string.concat(moneyNames[i], ": treasury() is ", vm.toString(held), ", not V2_TREASURY_SAFE"));
            }
            walked = walkedCount == 0 ? moneyNames[i] : string.concat(walked, ", ", moneyNames[i]);
            ++walkedCount;
        }
        _check(
            oneExit,
            string.concat("all ", vm.toString(walkedCount), " money-lane treasuries are V2_TREASURY_SAFE: ", walked)
        );
        _check(
            Clearinghouse(c.clearinghouse).feeRecipient() == c.feeSplitter
                && OrderBook(c.orderBook).feeRecipient() == c.feeSplitter,
            "clearinghouse and orderBook pay fees to the feeSplitter"
        );
        _check(c.feeSplitter != treasury, "the feeSplitter is not the treasury (it splits, it does not hold)");
        _check(Clearinghouse(c.clearinghouse).isMinter(c.orderBook), "clearinghouse: the orderBook is a minter");
        (address[] memory addrs, string[] memory names,) = _set(c);
        bool onlyBook = true;
        for (uint256 i; i < addrs.length; ++i) {
            if (addrs[i] == c.orderBook) continue;
            if (Clearinghouse(c.clearinghouse).isMinter(addrs[i])) {
                onlyBook = false;
                _info(string.concat(names[i], " is a minter and should not be"));
            }
        }
        address[7] memory principals = [
            in_.roles.adminSafe,
            in_.roles.treasurySafe,
            in_.roles.guardianKey,
            in_.roles.pricerKey,
            in_.roles.quoterKey,
            in_.roles.crankerKey,
            in_.deployer
        ];
        bool noFunding = true;
        for (uint256 i; i < principals.length; ++i) {
            if (principals[i] == address(0)) continue;
            if (Clearinghouse(c.clearinghouse).isMinter(principals[i])) onlyBook = false;
            (bool allowed,) = OrderBook(c.orderBook).fundingOf(principals[i]);
            if (allowed) noFunding = false;
        }
        for (uint256 i; i < addrs.length; ++i) {
            (bool allowed,) = OrderBook(c.orderBook).fundingOf(addrs[i]);
            if (allowed) noFunding = false;
        }
        _check(onlyBook, "clearinghouse: no other contract of the set and no principal is a minter");
        _check(OrderBook(c.orderBook).discountModule() == address(0), "orderBook: no discount module at launch");
        _check(noFunding, "orderBook: no funding allowance for any contract of the set or any principal");
    }

    /// @dev `authority()` if the target has one. Never reverts: a target still on v7 `AccessControl` answers nothing,
    ///      and the caller reports that rather than dying on it.
    function _authorityOf(address target) internal view returns (bool answers, address authority_) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(IManagedAuthority.authority.selector));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    /// @dev `treasury()` if the subject answers one, in the shape of {_authorityOf}: it never reverts, so one
    ///      unreadable subject cannot take the whole report down with it.
    /// @return answers FALSE for a zero address, an address with no code, a call that reverts, and a return that is
    ///         not exactly one word. The caller must treat `false` as a FAILURE rather than as "nothing to check" --
    ///         returning `(false, address(0))` and having the caller compare that zero against the treasury would be
    ///         a check that passes because it cannot see its subject.
    function _treasuryOf(address subject) internal view returns (bool answers, address treasury_) {
        if (subject == address(0) || subject.code.length == 0) return (false, address(0));
        (bool ok, bytes memory ret) = subject.staticcall(abi.encodeWithSignature("treasury()"));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    /// @dev The role id ceiling of the delayed lanes: ADMIN 0 .. OPS_ADMIN 6. GUARDIAN, PRICER, QUOTER and BUYBACK
    ///      (7..10) are the instant bot lanes and a plain key is expected to hold them.
    /*//////////////////////////////////////////////////////////////
                                 SAFES
    //////////////////////////////////////////////////////////////*/

    /// @dev T-258. MIRRORED FROM `script/Verify.s.sol:75-83`, not re-derived. These are Safe's own deployed
    ///      addresses and storage slots; typing them from memory is how a pin ships wrong.
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_L2_130 = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;
    address internal constant SAFE_FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant SAFE_MODULE_SENTINEL = address(0x1);
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    /// @dev T-258. THE v8 VERIFIER USED TO CHECK THAT THE SAFES HAVE CODE. Eleven roles sit on these two
    ///      addresses and `_handover` asserted only `code.length != 0` about either of them. A Safe with a
    ///      threshold of 1, an enabled module, a transaction guard or a non-canonical singleton all have code,
    ///      and every one of those defeats the property the Safes are there to provide. The capability already
    ///      existed at `script/Verify.s.sol:492` and was simply never carried into v8.
    ///
    ///      WHAT IS DELIBERATELY NOT CARRIED ACROSS is that function's CALL SITE. `Verify.s.sol:460` wraps the
    ///      whole admin-Safe block in `if (adminSafe != address(0) && adminSafe.code.length > 0)`, reading
    ///      `SAFE_ADMIN` with an `envOr` default of `address(0)` — so an unset or codeless admin Safe verifies
    ///      clean, silently. That is the same shape as the gap this function closes. Here an absent or
    ///      unreadable subject is a NAMED FAIL and never a skip.
    function _safes(Inputs memory in_) internal {
        _group("safes");
        _safeTopology(in_.roles.adminSafe, "admin Safe", in_.safeMinThreshold, in_.safeMinOwners);
        _safeTopology(in_.roles.treasurySafe, "treasury Safe", in_.safeMinThreshold, in_.safeMinOwners);
    }

    /// @notice The six v7 checks, in the v7 order, for one Safe.
    /// @dev Split across three frames on purpose. `VerifyV8.s.sol` already sits near the via_ir stack limit —
    ///      adding three locals to `_handover` is what forced `_authorities` into its own function — so the
    ///      reads are grouped rather than written as one body like v7's `_safe`.
    function _safeTopology(address safe, string memory label, uint256 minThreshold, uint256 minOwners) internal {
        if (safe == address(0)) {
            _check(false, string.concat(label, ": address is set"));
            return;
        }
        if (safe.code.length == 0) {
            _check(false, string.concat(label, ": is a contract, not a key"));
            return;
        }
        _check(
            _isCanonicalSafeSingleton(safe), string.concat(label, ": singleton is a canonical Safe 1.4.1 / 1.3.0 build")
        );
        _safeOwnership(safe, label, minThreshold, minOwners);
        _safeExtensions(safe, label);
    }

    function _isCanonicalSafeSingleton(address safe) private view returns (bool) {
        address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
        return singleton == SAFE_L2_141 || singleton == SAFE_141 || singleton == SAFE_L2_130;
    }

    /// @dev `try`/`catch` rather than a bare call: an address with code that is not a Safe reverts on
    ///      `getThreshold()`, and an uncaught revert here would take down the whole verify run instead of
    ///      reporting one named failure. A caught revert is a FAIL, never a skip.
    function _safeOwnership(address safe, string memory label, uint256 minThreshold, uint256 minOwners) private {
        // FAIL CLOSED ON AN UNSET EXPECTATION. `inputsFromEnv` defaults these to 2 and 3, but `Inputs` is also
        // built FIELD BY FIELD by callers that predate them -- `test/v2/unit/DeployV2Fixture.t.sol:329` is one --
        // and an unset field is 0. With a minimum of 0, `threshold >= 0` and `owners >= 0` are both tautologies,
        // so the two assertions this function exists for could never fail. A verifier whose expectation defaults
        // to zero verifies nothing, which is the defect this whole row is about; refuse instead of passing.
        if (minThreshold == 0 || minOwners == 0) {
            _check(false, string.concat(label, ": expected threshold and owner minimums are set"));
            return;
        }
        uint256 threshold;
        try ISafeTopology(safe).getThreshold() returns (uint256 t) {
            threshold = t;
        } catch {
            _check(false, string.concat(label, ": getThreshold() answered"));
            return;
        }
        uint256 owners;
        try ISafeTopology(safe).getOwners() returns (address[] memory o) {
            owners = o.length;
        } catch {
            _check(false, string.concat(label, ": getOwners() answered"));
            return;
        }
        // Upper bound included on purpose: a threshold above the owner count can never be met, so the Safe is
        // bricked rather than merely weak, and v7 checks both ends for that reason.
        _check(threshold >= minThreshold && threshold <= owners, string.concat(label, ": threshold"));
        _check(owners >= minOwners, string.concat(label, ": owner count"));
    }

    function _safeExtensions(address safe, string memory label) private {
        try ISafeTopology(safe).getModulesPaginated(SAFE_MODULE_SENTINEL, 10) returns (
            address[] memory modules, address
        ) {
            _check(modules.length == 0, string.concat(label, ": no modules enabled"));
        } catch {
            _check(false, string.concat(label, ": getModulesPaginated() answered"));
        }
        _check(vm.load(safe, SAFE_GUARD_SLOT) == bytes32(0), string.concat(label, ": no transaction guard"));
        address fallbackHandler = address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_SLOT))));
        _check(
            fallbackHandler == SAFE_FALLBACK_141 || fallbackHandler == address(0),
            string.concat(label, ": fallback handler is canonical (or none)")
        );
    }

    uint64 internal constant DELAYED_ROLE_MAX = 6;

    /// @dev `.roleAdmin.<role>` or `.roleGuardian.<role>` as a role id, or 0 (ADMIN) when the manifest omits it.
    ///      AccessManager's own default for an unset role admin or guardian IS ADMIN, so an omission in the manifest
    ///      and a 0 on chain are the same statement -- which is why the expectation is read from the file and the
    ///      absence is not treated as "unchecked".
    function _roleRefOr0(string memory json, bool admin, string memory roleName) internal pure returns (uint64) {
        string[] memory listed = admin ? roleAdminNames(json) : roleGuardianNames(json);
        for (uint256 i; i < listed.length; ++i) {
            if (_eq(listed[i], roleName)) {
                return roleIdOf(json, admin ? roleAdminOf(json, roleName) : roleGuardianOf(json, roleName));
            }
        }
        return 0;
    }

    /// @dev A manifest target name to the address this run deployed. FAILS CLOSED: an unknown name stops the run
    ///      rather than checking address(0), because a manifest that grew a target VerifyV8 does not know is exactly
    ///      the gap this group exists to close.
    function _targetOf(Contracts memory c, string memory name) internal pure returns (address) {
        if (_eq(name, "Clearinghouse")) return c.clearinghouse;
        if (_eq(name, "OrderBook")) return c.orderBook;
        if (_eq(name, "SettlementOracle")) return c.settlementOracle;
        if (_eq(name, "ChainlinkFeedSource")) return c.chainlinkSource;
        if (_eq(name, "UniV3TwapSource")) return c.univ3Source;
        if (_eq(name, "DataStreamsSource")) return c.dataStreamsSource;
        if (_eq(name, "ExpiryCalendar")) return c.expiryCalendar;
        if (_eq(name, "KeeperRewards")) return c.keeperRewards;
        if (_eq(name, "AutoRoller")) return c.autoRoller;
        if (_eq(name, "MakerVault")) return c.makerVault;
        if (_eq(name, "MakerRegistry")) return c.makerRegistry;
        if (_eq(name, "RewardsDistributor")) return c.rewardsDistributor;
        if (_eq(name, "RewardsDistributorLender")) return c.rewardsDistributorLender;
        if (_eq(name, "PayoutRouter")) return c.payoutRouter;
        if (_eq(name, "FeeSplitter")) return c.feeSplitter;
        if (_eq(name, "V4BuybackExecutor")) return c.buybackExecutor;
        if (_eq(name, "HouseVault")) return c.houseVault;
        if (_eq(name, "HouseVaultFactory")) return c.houseVaultFactory;
        if (_eq(name, "Hedger")) return c.hedger;
        if (_eq(name, "EarnVault")) return c.earnVault;
        if (_eq(name, "StockVenueAdapter")) return c.stockVenueAdapter;
        // KEEP THIS REVERT. A target the manifest names and this script cannot place must STOP the run: an address
        // it silently guessed at would be checked against the wrong contract, and a name it silently skipped would
        // leave that contract's whole manifest row unverified. `test/v2/unit/ManifestResolvers.t.sol` is what stops
        // the list going stale again.
        revert(string.concat("roles.v8.json names a target VerifyV8 does not know: ", name));
    }

    /// @dev The compiled artifact of a manifest target, or "" for one with no ABI to walk.
    ///
    ///      T-216, owner Ruling A. THIS WAS A TWENTY-ONE ROW HAND TABLE AND IT IS NOW DERIVED. Foundry writes every
    ///      artifact to `out/<File>.sol/<Contract>.json`, and in this repository every manifest target is declared
    ///      in a file of its own name, so the path IS the name. I checked that rather than assuming it: at
    ///      e8b2489d, 19 of the 21 manifest targets resolved to exactly `out/<Name>.sol/<Name>.json`, and all 22
    ///      `ART_` constants in {V2DeployBase} follow the same convention with none deviating.
    ///
    ///      WHY DERIVING BEATS A LOUD TABLE, which is the ruling's actual point. The old table reverted by name on
    ///      an entry it lacked, so drift was loud -- but only to whoever ran the suite, and under the build-mode
    ///      directive nobody runs it as a shipping gate. A derived path cannot drift at all: adding a target to
    ///      `roles.v8.json` needs no edit here, so there is no table left to forget.
    ///
    ///      THE TWO EXCEPTIONS ARE NAMED BECAUSE THEY ARE FACTS, NOT LEFTOVERS:
    ///      - `V4BuybackExecutor` is not Managed, has no `restricted` selector and an empty manifest entry, so ""
    ///        is right FOR THIS ONE NAME AND NO OTHER. {_noUnlistedRestricted} reads "" as "skip this target",
    ///        which is why it must never become the default again -- it used to be a bare `return ""`, and an
    ///        unknown name then cost that target its entire no-unlisted-restricted pass while the run still
    ///        printed VERIFY PASSED.
    ///      - `RewardsDistributorLender` is a SECOND INSTANCE of `RewardsDistributor`: same contract, same
    ///        artifact, different address and reward token. Keyed on artifact rather than on target name, a walk
    ///        covers one of the two live addresses and looks complete -- the same false-green shape T-220 removed
    ///        from the access matrix.
    ///
    ///      HOW IT FAILS NOW, stated because the failure MOVED rather than vanished: a manifest name with no
    ///      compiled artifact no longer reverts here with a sentence. It yields a path that does not exist, and
    ///      the first `vm.readFile` of it stops the run. `ManifestResolvers.t.sol` asserts every manifest target's
    ///      derived path is a real file carrying an ABI, so the named diagnosis lives there now.
    function _artifactOf(string memory name) internal pure returns (string memory) {
        if (_eq(name, "V4BuybackExecutor")) return "";
        if (_eq(name, "RewardsDistributorLender")) return ART_REWARDS_DISTRIBUTOR;
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    /// @dev A `.holders` principal name to its address.
    function _principalOf(Roles memory r, string memory name) internal pure returns (address) {
        if (_eq(name, "adminSafe")) return r.adminSafe;
        if (_eq(name, "treasurySafe")) return r.treasurySafe;
        if (_eq(name, "guardianKey")) return r.guardianKey;
        if (_eq(name, "pricerKey")) return r.pricerKey;
        if (_eq(name, "quoterKey")) return r.quoterKey;
        if (_eq(name, "crankerKey")) return r.crankerKey;
        revert(string.concat("roles.v8.json names a holder VerifyV8 does not know: ", name));
    }

    /*//////////////////////////////////////////////////////////////
                                 MARKETS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                  T-OP-171: THE PER-TICKER HOUSE VAULTS
    //////////////////////////////////////////////////////////////*/

    /// @dev EVERY `markets[].v2.houseVault` IS A VERIFIED SUBJECT. The owner launches TWO House vaults (NVDA and
    ///      SPCX; T-OP-141 creates one per launch ticker) and the registry home is option A: `v2.contracts.houseVault`
    ///      stays ONE address (the first launch ticker's, what `V2_HOUSE_VAULT` and the roles walk above see) and
    ///      each ticker's vault lives at `markets[].v2.houseVault` (T-OP-156), exported per ticker as
    ///      `V2_MARKET_<T>_HOUSE_VAULT` (T-OP-161). Before this group the second vault was covered by nothing: the
    ///      manifest walk, the identity probes, the stranger probe and the open-target pass all ran on the single
    ///      `HouseVault` target, so a second vault left unmapped, closed, pointed at another manager, or holding
    ///      the wrong underlying verified clean by never being read. Each non-zero vault is walked here as a
    ///      HouseVault instance -- authority, identity against ITS ticker's asset, manifest selectors on ITS address,
    ///      open/no admin delay, the stranger probe in the helper's frame, the money-lane exit (its performance fee
    ///      goes to the feeSplitter) -- with the ticker in every line; a zero one is NOT CHECKED naming the ticker.
    ///      The first launch ticker's vault must be `v2.contracts.houseVault` (T-OP-156's validator rule), and no
    ///      two tickers may share a vault (the factory refuses a second vault per underlying; this refuses the
    ///      registry saying otherwise).
    function _houseVaults(Inputs memory in_) internal {
        if (in_.markets.length == 0) return; // no tickers: already NOT CHECKED above, no vault slot to read
        _group("house vaults (markets[].v2.houseVault, one per ticker)");
        Contracts memory c = in_.c;
        AccessManager mgr = AccessManager(c.accessManager);
        string memory json = rolesJson();
        string[] memory sigs = targetSigs(json, "HouseVault");
        for (uint256 i; i < in_.markets.length; ++i) {
            string memory t = in_.markets[i].ticker;
            address v = in_.marketVaults[i];
            if (v == address(0)) {
                _notChecked(
                    string.concat(
                        "market ", t, ": markets[].v2.houseVault is null, so no House vault was verified for it"
                    )
                );
                continue;
            }
            _houseVault(in_, c, mgr, json, sigs, i, t, v);
        }
    }

    /// @dev One ticker's vault, in its own frame (the outer loop keeps `_houseVaults` under the via_ir stack limit).
    function _houseVault(
        Inputs memory in_,
        Contracts memory c,
        AccessManager mgr,
        string memory json,
        string[] memory sigs,
        uint256 i,
        string memory t,
        address v
    ) internal {
        string memory label = string.concat("HouseVault(", t, ")");
        string memory pre = string.concat("market ", t, ": house vault ");
        (bool answers, address authority_) = _authorityOf(v);
        _check(
            v.code.length != 0 && answers && authority_ == c.accessManager,
            string.concat(pre, vm.toString(v), " has code and its authority is the accessManager")
        );
        // Identity against THIS ticker: the vault's underlying is the market's Stock Token, its clearinghouse and
        // order book are the set's, and its performance fee exits to the feeSplitter (the money lane).
        _check(
            _addrOf(v, "underlying()") == in_.markets[i].asset, string.concat(pre, "underlying() == the ticker's asset")
        );
        _check(_addrOf(v, "clearinghouse()") == c.clearinghouse, string.concat(pre, "clearinghouse() == clearinghouse"));
        _check(_addrOf(v, "orderBook()") == c.orderBook, string.concat(pre, "orderBook() == orderBook"));
        _check(_addrOf(v, "splitter()") == c.feeSplitter, string.concat(pre, "splitter() == feeSplitter (money lane)"));
        // Manifest selectors mapped on THIS address: the manager's map is per (target, selector), so the single
        // HouseVault target being mapped says nothing about a second vault.
        bool mapped = true;
        for (uint256 s; s < sigs.length; ++s) {
            uint64 want = roleIdOf(json, roleNameOfSig(json, "HouseVault", sigs[s]));
            if (mgr.getTargetFunctionRole(v, selectorOf(sigs[s])) != want) {
                mapped = false;
                _info(string.concat(label, ".", sigs[s], " is not mapped to its manifest role on this vault"));
            }
        }
        _check(mapped, string.concat(pre, "every HouseVault selector is mapped to its manifest role on this address"));
        _check(
            !mgr.isTargetClosed(v) && mgr.getTargetAdminDelay(v) == 0,
            string.concat(pre, "is open and carries no target admin delay AT THIS BLOCK")
        );
        // The stranger probe, in the helper's frame, labelled with the ticker; a vault that refuses nobody FAILs
        // here by the same rule as any manifest target (T-OP-166 F1).
        _check(
            _walkTargetAt(mgr, json, "HouseVault", label, v),
            string.concat(pre, "no selector outside roles.v8.json is mapped to a role or refuses a stranger")
        );
        // Registry option A: the first launch ticker's vault IS the single slot the roles walk verified.
        if (i == 0) {
            _check(
                c.houseVault == v,
                string.concat(
                    pre,
                    "is v2.contracts.houseVault (V2_HOUSE_VAULT): the first launch ticker's vault is the roles walk's target"
                )
            );
        }
        // One vault per ticker: a registry that points two tickers at one vault is refused by name.
        bool distinct = true;
        for (uint256 j; j < i; ++j) {
            if (in_.marketVaults[j] == v) {
                distinct = false;
                _info(string.concat(label, " is also market ", in_.markets[j].ticker, "'s vault"));
            }
        }
        _check(distinct, string.concat(pre, "is not another ticker's vault"));
    }

    /// @dev `sig()` on `target` as an address, or zero when it does not answer one word (the caller's comparison
    ///      then fails by name rather than the run dying on a typed call to the wrong contract).
    function _addrOf(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

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
        _group(string.concat("market ", m.ticker));
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
        _check(
            cfg.enabled == m.enabled,
            string.concat(t, m.enabled ? "enabled (v2.status live)" : "disabled (v2.status not live)")
        );
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
        // INVERTED FOR INTERFACE_VERSION 8 (V8-DESIGN.md §4.3). v7 treated 0 as the failure because rent was the
        // only writer fee; v8 takes 5% of the premium on first sale and launches rent at 0 everywhere, so 0 is the
        // expected value and a NON-ZERO rate is the failure. Rent is turned on afterwards through
        // `Clearinghouse.setMarketFees` in the 72 h MARKET_FEE_MANAGER lane, where it waits in the open and the
        // guardian can cancel it; a deploy or a verify run is neither. The `V2_ALLOW_RENT` opt-in runs through
        // `rentAllowed` and is honoured only under the forge test runner, so a read-only verify of live 4663 cannot
        // sign off a rent-bearing market with an environment variable.
        _check(
            cfg.mintFeePpm == 0 || rentAllowed(in_.allowRent), // INTERFACE_VERSION 8: inverted (V8-DESIGN §4.3)
            string.concat(
                t,
                "mintFeePpm == 0 (v8 launches rent at 0; a rate is a 72 h MARKET_FEE_MANAGER operation,",
                " never a script, and setMarketFees reaches NEW series only)"
            )
        );
        _param(
            string.concat("market.", m.ticker, ".mintFeePpm"),
            in_.expectFresh,
            cfg.mintFeePpm == wantPpm,
            string.concat(t, "mintFeePpm == ", vm.toString(uint256(wantPpm))),
            vm.toString(uint256(cfg.mintFeePpm))
        );

        _marketSources(in_, m, t);
    }

    /// @dev The source, oracle, pin and payout-route half of {_market}. Split out of it with NO change of logic by
    ///      C8-10A: `V2DeployBase.Contracts` grew from thirteen fields to sixteen and `Roles` from six to eight for
    ///      INTERFACE_VERSION 8, and the one combined function then exceeded what the via-IR pipeline can lay out
    ///      ("too deep in the stack"). C8-10b rewrites this file as `VerifyV8`; until then the seam is here.
    function _marketSources(Inputs memory in_, MarketIn memory m, string memory t) internal {
        Contracts memory c = in_.c;
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

        // INTERFACE_VERSION 8 ROUTE SHAPE: `routes()` returns a Route struct (venue, fee, tickSpacing, v3Pool,
        // cached feeBps), not a flat (pool, fee) pair. A v4 route carries no v3Pool, which is why the v3 pool and the
        // fee are read separately instead of destructured.
        _routeAndSettlementPool(in_, c, m, t);

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
        // T-OP-166 F3 / T-OP-171: said, not implied (see {check} on V2_TICKERS).
        if (in_.unregistered.length == 0) {
            _notChecked(
                "V2_UNREGISTERED_ASSETS is unset or empty, so no registry row was checked for absence on the Clearinghouse"
            );
            return;
        }
        _group("registry rows not registered");
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
        _group("fresh state");
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
