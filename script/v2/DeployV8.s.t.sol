// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV8} from "./DeployV8.s.sol";
import {V2DeployBase} from "./lib/V2DeployBase.sol";

/// @title DeployV8SetSizeTest
/// @notice Pins the size and the created/external split of the INTERFACE_VERSION 8 contract set.
/// @dev T-527, from the C8-11 (DEPLOYSEC) ledger suspicion: *"The 'sixteen contracts' claim rests on reading,
///      not on a run … Nobody has deployed a v8 set, so the count has never been observed. If a later task
///      adds or removes a contract, every occurrence of 'sixteen' in docs/DEPLOY-V2.md and
///      docs/AUDIT-SCOPE.md is stale at once."*
///
///      WHAT I ESTABLISHED FIRST, so nobody re-derives it. The count is CORRECT and the runtime half of the
///      suspicion is ALREADY ENFORCED — one file away from where it pointed. `script/v2/DeployV2Batch.sh:125`
///      lists the sixteen registry keys, `:130` derives `NKEYS` from them, `:131` refuses an empty list, and
///      `:352`, `:360` and `:364` each refuse unless the recorded count equals it. A v8 deploy cannot call
///      itself complete with fewer than sixteen recorded. So an assertion in `DeployV8` that the set is
///      complete would only duplicate that gate, and `require(created == 16)` would be WRONG outright: every
///      `_create` is guarded by `if (d.<field> == address(0))` over `d = in_.existing` (`DeployV8.s.sol:547`),
///      so on `--resume` a correct run legitimately creates fewer than sixteen.
///
///      WHAT IS ACTUALLY UNPINNED, and all this test claims to cover: the SET DECLARATION itself. The wrapper
///      enforces that sixteen get recorded; nothing notices if a later task adds a twenty-third field to
///      {V2DeployBase.Contracts} or moves the created/external boundary, at which point `CONTRACT_KEYS`, the
///      struct NatSpec at `V2DeployBase.sol:186-190` and twelve occurrences of "sixteen" across two documents
///      are stale at once and the wrapper keeps enforcing the OLD number.
///
///      WHY THERE IS NO `vm.readFile` HERE. An earlier draft of this test counted `_create(` call sites in the
///      source text, which needed two new `fs_permissions` grants in `foundry.toml` — a file outside this
///      row's fence. Both checks below get the same facts without reading anything: the struct's width is a
///      COMPILE-TIME fact, and the split is a pure function. A test that needs no permission cannot be
///      switched off by forgetting to grant one.
contract DeployV8SetSizeTest is Test, DeployV8 {
    /// @dev The set as three documents state it. Change these ONLY together with `CONTRACT_KEYS` in
    ///      DeployV2Batch.sh, the struct NatSpec, docs/DEPLOY-V2.md and docs/AUDIT-SCOPE.md.
    uint256 internal constant TOTAL_IN_SET = 22;
    uint256 internal constant SUPPLIED_EXTERNALLY = 6;
    uint256 internal constant CREATED_HERE = TOTAL_IN_SET - SUPPLIED_EXTERNALLY;

    /// @dev Every manifest target name, in the struct's own order.
    function _targetNames() internal pure returns (string[22] memory) {
        return [
            "AccessManager",
            "FeeSplitter",
            "ExpiryCalendar",
            "ChainlinkFeedSource",
            "UniV3TwapSource",
            "DataStreamsSource",
            "SettlementOracle",
            "KeeperRewards",
            "Clearinghouse",
            "OrderBook",
            "AutoRoller",
            "PayoutRouter",
            "MakerRegistry",
            "MakerVault",
            "RewardsDistributor",
            "BuybackExecutor",
            "HouseVault",
            "HouseVaultFactory",
            "Hedger",
            "RewardsDistributorLender",
            "EarnVault",
            "StockVenueAdapter"
        ];
    }

    /// @notice THE STRUCT IS EXACTLY TWENTY-TWO FIELDS — enforced by the COMPILER, not by an assertion.
    /// @dev This positional constructor lists one argument per field. Add a twenty-third field to
    ///      {V2DeployBase.Contracts}, or remove one, and THIS FILE STOPS COMPILING with a wrong-argument-count
    ///      error naming the struct. That is the loudest failure available and it cannot be skipped, muted or
    ///      passed by a checker that has gone blind — which is the failure mode this whole ledger records.
    ///      The addresses are irrelevant; only the arity is under test.
    function test_theSetIsExactlyTwentyTwoFields() public pure {
        V2DeployBase.Contracts memory c = V2DeployBase.Contracts({
            accessManager: address(0),
            feeSplitter: address(0),
            expiryCalendar: address(0),
            chainlinkSource: address(0),
            univ3Source: address(0),
            dataStreamsSource: address(0),
            settlementOracle: address(0),
            keeperRewards: address(0),
            clearinghouse: address(0),
            orderBook: address(0),
            autoRoller: address(0),
            payoutRouter: address(0),
            makerRegistry: address(0),
            makerVault: address(0),
            rewardsDistributor: address(0),
            buybackExecutor: address(0),
            houseVault: address(0),
            houseVaultFactory: address(0),
            hedger: address(0),
            rewardsDistributorLender: address(0),
            earnVault: address(0),
            stockVenueAdapter: address(0)
        });
        // Touch it so the compiler cannot elide the construction.
        assertEq(c.accessManager, address(0));
        assertEq(_targetNames().length, TOTAL_IN_SET, "the name list and the struct disagree about the set size");
    }

    /// @notice EXACTLY SIX of the twenty-two are supplied externally, so exactly sixteen are CREATEd here.
    /// @dev {DeployV8._externallySupplied} is the single source of that split (`DeployV8.s.sol:1739-1742`) and
    ///      its own NatSpec says it is kept as an explicit list rather than inferred from a zero address,
    ///      "because inferring it is exactly how a target this script DOES deploy would get silently skipped
    ///      after a refactor". This counts it rather than trusting the comment: move one name across the
    ///      boundary and the arithmetic below reports the new split against the documented one.
    function test_exactlySixArriveExternallySoSixteenAreCreatedHere() public pure {
        string[22] memory names = _targetNames();
        uint256 external_;
        for (uint256 i; i < names.length; ++i) {
            if (_externallySupplied(names[i])) ++external_;
        }
        assertEq(
            external_,
            SUPPLIED_EXTERNALLY,
            "the created/external boundary moved: CONTRACT_KEYS in DeployV2Batch.sh, the struct NatSpec and every 'sixteen' in docs/DEPLOY-V2.md and docs/AUDIT-SCOPE.md are now stale"
        );
        assertEq(names.length - external_, CREATED_HERE, "DeployV8 no longer CREATEs sixteen contracts");
    }

    /// @notice The six external names are the six the struct puts LAST, in order.
    /// @dev The split is not just a count: `CONTRACT_KEYS` is the first sixteen IN ORDER, so a name moving
    ///      across the boundary without the struct order moving with it would keep both counts right and make
    ///      the registry list wrong. This pins the partition, not only its size.
    function test_theExternalSixAreTheLastSixInOrder() public pure {
        string[22] memory names = _targetNames();
        for (uint256 i; i < CREATED_HERE; ++i) {
            assertFalse(_externallySupplied(names[i]), "a contract before the boundary is marked externally supplied");
        }
        for (uint256 i = CREATED_HERE; i < names.length; ++i) {
            assertTrue(_externallySupplied(names[i]), "a contract after the boundary is not marked externally supplied");
        }
    }
}
