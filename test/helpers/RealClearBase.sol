// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";

/// @notice Deploys the REAL ValoremOptionsClearinghouse bytecode from the vendored artifact.
/// @dev WHY A FIXTURE AND NOT THE MOCK. The audit's F-01 and the assignment maths only exist in
///      Valorem's bucket engine. {MockClear} now models that engine and is checked against this
///      artifact by a differential test, but every regression that asserts a LOSS or a payout in
///      USDG must run against the genuine code, because the mock is the thing under suspicion.
///
///      The artifact is upstream valorem-labs-inc/clear @ 6436c823, built with solc 0.8.16, optimizer
///      200, viaIR off, evm london. Its clearinghouse source is byte-identical to the Sourcify
///      exact-match source of the 4663 deployment at 0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0
///      (integrations/valorem.md §2). The constructor is `(address feeTo, address tokenURIGenerator)`
///      and reverts `InvalidAddress` for a zero in either slot; the generator is only ever reached by
///      `uri()`, which nothing on the vault's paths calls, so a non-zero stub address suffices.
///
///      REAL-BYTECODE GOTCHAS a test must respect:
///      - `newOptionType` requires `totalSupply(underlying) >= underlyingAmount` and
///        `totalSupply(exercise) >= exerciseAmount`: mint before creating option types.
///      - `redeem` before expiry reverts `ClaimTooSoon`; `position(optionId)` reverts after expiry.
///      - After `redeem`, `claim()` / `position(claimId)` revert `TokenNotFound`.
abstract contract RealClearBase is Test {
    string internal constant CLEAR_ARTIFACT = "test/fixtures/valorem/ValoremOptionsClearinghouse.json";

    /// @dev Stand-in constructor arguments. `feeTo` is the only admin on Clear (fee switch, sweep).
    address internal constant CLEAR_FEE_TO = address(0xFEE);
    address internal constant CLEAR_URI_GENERATOR = address(0xDEAD);

    /// @notice Deploy the real clearinghouse with the default stand-in admin.
    function _deployRealClear() internal returns (IValoremClear) {
        return _deployRealClear(CLEAR_FEE_TO, CLEAR_URI_GENERATOR);
    }

    /// @notice Deploy the real clearinghouse with an explicit admin (fee switch holder).
    function _deployRealClear(address feeTo, address uriGenerator) internal returns (IValoremClear c) {
        c = IValoremClear(vm.deployCode(CLEAR_ARTIFACT, abi.encode(feeTo, uriGenerator)));
        vm.label(address(c), "ValoremClear(real)");
        // The two facts the deploy script and the vault's fee gate rely on.
        assertEq(c.feeBps(), 15, "real Clear feeBps");
        assertFalse(c.feesEnabled(), "real Clear ships with the fee switch off");
        assertEq(c.feeTo(), feeTo, "real Clear feeTo");
    }

    /// @notice Flip the real clearinghouse's fee switch as its admin.
    function _setRealClearFees(IValoremClear c, bool on) internal {
        vm.prank(c.feeTo());
        c.setFeesEnabled(on);
    }
}
