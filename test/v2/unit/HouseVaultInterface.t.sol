// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HouseVault} from "../../../src/v2/periphery/house/HouseVault.sol";
import {HouseVaultFactory} from "../../../src/v2/periphery/house/HouseVaultFactory.sol";

/// @title HouseVaultInterface
/// @notice THE PINNED-ARTIFACT SUITE for P8-06. Everything downstream -- P8-06b's role manifest, the MM bot (K8-05),
///         the indexer (X8-07) and the UI (W8-06) -- is written against the selector and topic strings frozen in the
///         P8-06 task contract. This file is what makes those strings TRUE rather than believed.
/// @dev HOW IT DERIVES THEM, AND WHY THAT SHAPE. Every assertion compares two INDEPENDENT derivations of the same
///      value:
///        - the COMPILER's, via `HouseVault.fn.selector` / `HouseVault.Event.selector`, which changes the moment a
///          parameter type changes, and
///        - the HASH of the literal signature string that P8-06b will actually write into `roles.v8.json`.
///      A single-sided test -- hashing the string and comparing it to itself, or reading the artifact and trusting
///      it -- proves nothing. This is the same redundancy that caught F8-02: `INTERFACE-CHANGES-V8.md` Entry 2
///      records `take` and `quoteTake` published as 0x42e3b3d7 / 0xc4b1417b when they are actually 0xcf96851b /
///      0xe2e13f01, found only because a second task computed them by another route and disagreed.
///
///      THE ARTIFACT HALF, NOW READ FROM THE TREE UNDER TEST (T-OP-057, F-CT5B-01). {test_artifact_hasNoAssetExit},
///      {test_artifact_declaresTheFrozenSurface} and {test_artifact_armingAddedNoNewRestrictedSelector} used to
///      read `out/HouseVault.sol/HouseVault.json` and walk `.methodIdentifiers`. That answered ABSENCE from a
///      file on disk, and a file on disk can predate the source: a stale `out/`, another profile's `out/`
///      (`forge test` with a profile whose `out` differs still resolves the literal path), or a partial rebuild
///      would satisfy `assertFalse(_hasMethod("withdraw(address,uint256)"))` AFTER `withdraw` had been added,
///      which is the exact case the assertion exists to catch. {_hasMethod} now scans
///      `type(HouseVault).creationCode` -- the bytecode solc emitted for the HouseVault THIS test file imports,
///      linked into this test binary at compile time -- for the dispatcher's `PUSH4 <selector>`. There is no
///      artifact between the source and the answer: if the source under test gains a function, the selector is
///      in that bytecode in the same build that runs the assertion, and it goes red. Absence is still provable
///      this way because a selector that is not dispatched is not pushed.
contract HouseVaultInterfaceTest is Test {
    /*//////////////////////////////////////////////////////////////
                    RESTRICTED: QUOTER (the mm-bot key)
    //////////////////////////////////////////////////////////////*/

    function test_selector_depositToClearinghouse() public pure {
        assertEq(
            HouseVault.depositToClearinghouse.selector,
            bytes4(keccak256("depositToClearinghouse(address,uint256)")),
            "depositToClearinghouse"
        );
    }

    function test_selector_withdrawFromClearinghouse() public pure {
        assertEq(
            HouseVault.withdrawFromClearinghouse.selector,
            bytes4(keccak256("withdrawFromClearinghouse(address,uint256)")),
            "withdrawFromClearinghouse"
        );
    }

    function test_selector_place() public pure {
        assertEq(HouseVault.place.selector, bytes4(keccak256("place(uint256,uint8,uint128,uint64,uint40)")), "place");
    }

    function test_selector_replace() public pure {
        assertEq(HouseVault.replace.selector, bytes4(keccak256("replace(uint256,uint128,uint64)")), "replace");
    }

    function test_selector_cancel() public pure {
        assertEq(HouseVault.cancel.selector, bytes4(keccak256("cancel(uint256[])")), "cancel");
    }

    /// @dev The one that bit F8-02. `TakeParams` carries a dynamic member (`orderIds`), and `maxTotalFee` is the
    ///      TENTH and last field -- a v7 decoder that stops at nine mis-decodes silently rather than reverting.
    function test_selector_take() public pure {
        assertEq(
            HouseVault.take.selector,
            bytes4(keccak256("take((uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128))")),
            "take"
        );
    }

    function test_selector_close() public pure {
        assertEq(HouseVault.close.selector, bytes4(keccak256("close(uint256,uint64)")), "close");
    }

    function test_selector_claimOwed() public pure {
        assertEq(HouseVault.claimOwed.selector, bytes4(keccak256("claimOwed()")), "claimOwed");
    }

    function test_selector_sync() public pure {
        assertEq(HouseVault.sync.selector, bytes4(keccak256("sync(uint256[])")), "sync");
    }

    function test_selector_refreshApprovals() public pure {
        assertEq(HouseVault.refreshApprovals.selector, bytes4(keccak256("refreshApprovals()")), "refreshApprovals");
    }

    /*//////////////////////////////////////////////////////////////
          RESTRICTED: GUARDIAN (setLimits) / TREASURY_ADMIN (setPerformanceFeeBps)
    //////////////////////////////////////////////////////////////*/

    /// @dev `Limits` is a STATIC tuple, so the encoding is the six fields in declaration order. If anyone reorders
    ///      them for packing, this selector moves and P8-06b's manifest row stops matching -- which is the point.
    ///      The role is GUARDIAN at zero delay since T-OP-159 (roles.v8.json `.targets.HouseVault`, owner order
    ///      2026-09-22: no delay on the limits); the banner above used to say TREASURY_ADMIN for both (T-OP-168).
    function test_selector_setLimits() public pure {
        assertEq(
            HouseVault.setLimits.selector,
            bytes4(keccak256("setLimits((uint64,uint128,uint16,uint16,uint32,uint128))")),
            "setLimits"
        );
    }

    function test_selector_setPerformanceFeeBps() public pure {
        assertEq(
            HouseVault.setPerformanceFeeBps.selector,
            bytes4(keccak256("setPerformanceFeeBps(uint16)")),
            "setPerformanceFeeBps"
        );
    }

    /*//////////////////////////////////////////////////////////////
                RESTRICTED: CONFIG_ADMIN / GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function test_selector_setProtocolAccount() public pure {
        assertEq(
            HouseVault.setProtocolAccount.selector,
            bytes4(keccak256("setProtocolAccount(address,bool)")),
            "setProtocolAccount"
        );
    }

    function test_selector_setQuotingPaused() public pure {
        assertEq(HouseVault.setQuotingPaused.selector, bytes4(keccak256("setQuotingPaused(bool)")), "setQuotingPaused");
    }

    /*//////////////////////////////////////////////////////////////
                              UNRESTRICTED
    //////////////////////////////////////////////////////////////*/

    function test_selector_requestDeposit() public pure {
        assertEq(
            HouseVault.requestDeposit.selector, bytes4(keccak256("requestDeposit(address,uint256)")), "requestDeposit"
        );
    }

    function test_selector_requestWithdraw() public pure {
        assertEq(HouseVault.requestWithdraw.selector, bytes4(keccak256("requestWithdraw(uint256)")), "requestWithdraw");
    }

    function test_selector_cancelDepositRequest() public pure {
        assertEq(
            HouseVault.cancelDepositRequest.selector,
            bytes4(keccak256("cancelDepositRequest(address)")),
            "cancelDepositRequest"
        );
    }

    function test_selector_cancelWithdrawRequest() public pure {
        assertEq(
            HouseVault.cancelWithdrawRequest.selector,
            bytes4(keccak256("cancelWithdrawRequest()")),
            "cancelWithdrawRequest"
        );
    }

    function test_selector_rollEpoch() public pure {
        assertEq(HouseVault.rollEpoch.selector, bytes4(keccak256("rollEpoch()")), "rollEpoch");
    }

    function test_selector_claim() public pure {
        assertEq(HouseVault.claim.selector, bytes4(keccak256("claim()")), "claim");
    }

    /*//////////////////////////////////////////////////////////////
                                FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_selector_createVault() public pure {
        assertEq(
            HouseVaultFactory.createVault.selector,
            bytes4(keccak256("createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)")),
            "createVault"
        );
    }

    /// @dev `vaultOf` is a public mapping, so solc generates its getter and it is NOT reachable as
    ///      `HouseVaultFactory.vaultOf.selector`. It is checked against the factory's own artifact instead, which is
    ///      the stronger half of the pair anyway: it reads what solc emitted.
    function test_selector_vaults() public pure {
        assertEq(HouseVaultFactory.vaults.selector, bytes4(keccak256("vaults()")), "vaults");
    }

    function test_artifact_factorySurface() public pure {
        assertTrue(_hasFactoryMethod("vaultOf(address)"), "vaultOf(address)");
        assertTrue(_hasFactoryMethod("vaults()"), "vaults()");
        assertTrue(
            _hasFactoryMethod("createVault(address,(uint64,uint128,uint16,uint16,uint32,uint128),string,string)"),
            "createVault"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 TOPICS
    //////////////////////////////////////////////////////////////*/

    function test_topic_EpochRolled() public pure {
        assertEq(
            HouseVault.EpochRolled.selector,
            keccak256("EpochRolled(uint64,uint40,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "EpochRolled"
        );
    }

    function test_topic_depositAndWithdrawQueue() public pure {
        assertEq(
            HouseVault.DepositRequested.selector,
            keccak256("DepositRequested(address,uint256,uint256,uint64)"),
            "DepositRequested"
        );
        assertEq(
            HouseVault.WithdrawRequested.selector,
            keccak256("WithdrawRequested(address,uint256,uint64)"),
            "WithdrawRequested"
        );
        assertEq(
            HouseVault.DepositRequestCancelled.selector,
            keccak256("DepositRequestCancelled(address,uint256,uint256)"),
            "DepositRequestCancelled"
        );
        assertEq(
            HouseVault.WithdrawRequestCancelled.selector,
            keccak256("WithdrawRequestCancelled(address,uint256)"),
            "WithdrawRequestCancelled"
        );
    }

    function test_topic_Claimed() public pure {
        assertEq(HouseVault.Claimed.selector, keccak256("Claimed(address,uint256,uint256,uint256)"), "Claimed");
    }

    function test_topic_adminEvents() public pure {
        assertEq(
            HouseVault.LimitsSet.selector,
            keccak256("LimitsSet((uint64,uint128,uint16,uint16,uint32,uint128))"),
            "LimitsSet"
        );
        assertEq(
            HouseVault.PerformanceFeeBpsSet.selector, keccak256("PerformanceFeeBpsSet(uint16)"), "PerformanceFeeBpsSet"
        );
        assertEq(
            HouseVault.ProtocolAccountSet.selector, keccak256("ProtocolAccountSet(address,bool)"), "ProtocolAccountSet"
        );
        assertEq(HouseVault.QuotingPausedSet.selector, keccak256("QuotingPausedSet(bool)"), "QuotingPausedSet");
        assertEq(
            HouseVault.ExposureSet.selector, keccak256("ExposureSet(uint256,uint256,uint256,uint256)"), "ExposureSet"
        );
    }

    function test_topic_VaultCreated() public pure {
        assertEq(
            HouseVaultFactory.VaultCreated.selector,
            keccak256("VaultCreated(address,address,string,string)"),
            "VaultCreated"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      THE ARTIFACT HALF (criterion 6)
    //////////////////////////////////////////////////////////////*/

    /// @notice NO ROLE MOVES DEPOSITOR ASSETS. Proven against the compiled artifact, because absence cannot be
    ///         proven by a reference that has to compile.
    /// @dev This is the sharpest difference from MakerVault, which HAS all four of these and pays them to its
    ///      treasury. If any of them ever appears here, depositor money has a role-chosen exit and this vault is a
    ///      different product.
    function test_artifact_hasNoAssetExit() public pure {
        assertFalse(_hasMethod("withdraw(address,uint256)"), "withdraw(address,uint256) must not exist");
        assertFalse(_hasMethod("withdrawPosition(uint256,uint256)"), "withdrawPosition must not exist");
        assertFalse(_hasMethod("setTreasury(address)"), "setTreasury must not exist");
        assertFalse(_hasMethod("treasury()"), "treasury() must not exist");
    }

    /// @notice Every frozen string in the task contract's section 12 is present in the compiled artifact under
    ///         exactly that spelling.
    function test_artifact_declaresTheFrozenSurface() public pure {
        string[21] memory frozen = [
            "depositToClearinghouse(address,uint256)",
            "withdrawFromClearinghouse(address,uint256)",
            "place(uint256,uint8,uint128,uint64,uint40)",
            "replace(uint256,uint128,uint64)",
            "cancel(uint256[])",
            "take((uint256,bool,uint256[],uint64,uint64,uint128,bool,address,uint40,uint128))",
            "close(uint256,uint64)",
            "claimOwed()",
            "sync(uint256[])",
            "refreshApprovals()",
            "setLimits((uint64,uint128,uint16,uint16,uint32,uint128))",
            "setPerformanceFeeBps(uint16)",
            "setProtocolAccount(address,bool)",
            "setQuotingPaused(bool)",
            "requestDeposit(address,uint256)",
            "requestWithdraw(uint256)",
            "cancelDepositRequest(address)",
            "cancelWithdrawRequest()",
            "rollEpoch()",
            "claim()",
            "nav()"
        ];
        for (uint256 i; i < frozen.length; ++i) {
            assertTrue(_hasMethod(frozen[i]), frozen[i]);
        }
    }

    /// @notice The fail-closed flag is a READ-ONLY getter and the arming rides the EXISTING CONFIG_ADMIN selector.
    /// @dev THIS IS A MANIFEST-SAFETY ASSERTION, not a style one. `test/v2/unit/AccessMatrix.t.sol` walks every
    ///      target's ABI and fails any `restricted` selector that `script/v2/roles.v8.json` does not list, and
    ///      neither file is in this row's scope. So the fail-closed state had to be reachable without adding a new
    ///      restricted entry point. If someone later adds `confirmProtocolAccounts(address[])` and stops there,
    ///      this goes red HERE rather than in a file they did not touch and would not think to run.
    function test_artifact_armingAddedNoNewRestrictedSelector() public pure {
        assertTrue(_hasMethod("protocolAccountsConfirmed()"), "protocolAccountsConfirmed() getter must exist");
        assertTrue(_hasMethod("setProtocolAccount(address,bool)"), "the arming selector is the existing one");
        assertFalse(
            _hasMethod("confirmProtocolAccounts(address[])"),
            "a new restricted selector needs a roles.v8.json row and an AccessMatrix update first"
        );
    }

    /// @notice The compiled ceiling is real and is not a doc claim. A public constant's getter is generated by
    ///         solc, so this is read from the artifact rather than through `.selector`.
    function test_artifact_performanceFeeCeilIsCompiledIn() public pure {
        assertTrue(_hasMethod("PERFORMANCE_FEE_CEIL_BPS()"), "PERFORMANCE_FEE_CEIL_BPS()");
        assertTrue(_hasMethod("MIN_SHARES()"), "MIN_SHARES()");
        assertTrue(_hasMethod("OUTFLOW_WINDOW()"), "OUTFLOW_WINDOW()");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev T-OP-057. Whether the HouseVault compiled INTO THIS TEST BINARY dispatches `signature`. Reads
    ///      `type(HouseVault).creationCode`, never `out/`: the creation code embeds the runtime code it will
    ///      return, and the runtime dispatcher compares the calldata selector against a `PUSH4 <selector>`
    ///      immediate for every external function (via_ir or legacy, and for solc-generated getters of public
    ///      state too). So "this selector appears as a PUSH4 immediate in the code" is "this contract answers
    ///      that selector", and a function that does not exist has no immediate to find.
    ///      WHY NOT `type(HouseVault).runtimeCode`: HouseVault has immutables, and solc refuses `runtimeCode`
    ///      for contracts with immutables; `creationCode` is always available and contains the same dispatcher.
    ///      WHY NOT `vm.getCode`: it is still an artifact lookup, only profile-aware; the staleness class is the
    ///      same. WHY NOT a deployed probe: constructing a HouseVault needs a live book, Clearinghouse and
    ///      calendar, and a probe answers "reverted with no data", which an existing function can also do.
    ///      BOUND: a 5-byte pattern can occur by chance elsewhere in ~50 KB of code (about 5e4 positions at
    ///      2^-40 each), which would make an ABSENCE claim red for a phantom -- loud, never silently green.
    function _hasMethod(string memory signature) private pure returns (bool) {
        return _codeDispatches(type(HouseVault).creationCode, bytes4(keccak256(bytes(signature))));
    }

    /// @dev Same shape for the factory; same reason (the `out/` read had the same staleness).
    function _hasFactoryMethod(string memory signature) private pure returns (bool) {
        return _codeDispatches(type(HouseVaultFactory).creationCode, bytes4(keccak256(bytes(signature))));
    }

    /// @dev True when `code` contains the EVM `PUSH4` opcode (0x63) immediately followed by `selector`.
    function _codeDispatches(bytes memory code, bytes4 selector) private pure returns (bool) {
        uint256 n = code.length;
        if (n < 5) return false;
        // The 5-byte pattern we are looking for, left-aligned in a word, and a mask for its top 40 bits.
        bytes32 want = bytes32(bytes5(abi.encodePacked(bytes1(0x63), selector)));
        bytes32 mask = bytes32(uint256(type(uint40).max) << 216);
        for (uint256 i; i + 5 <= n; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 0x20), i))
            }
            if ((word & mask) == want) return true;
        }
        return false;
    }
}
