// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title V4ProtocolFeeMirror
/// @notice The two `protocolFee` accessors of Uniswap v4-core's `ProtocolFeeLibrary`, MIRRORED so the nibble pin
///         in `test/v2/unit/V4FeeNibblePin.t.sol` can assert our decode sites against the DEPENDENCY rather than
///         against a literal we typed ourselves.
///
/// @dev WHY THIS FILE EXISTS. Before it, `V4FeeNibblePin.t.sol` pinned our three decode sites to an explicit
///      constant and said so in its own NatSpec: it proved every site agrees with each other, and could not prove
///      any of them agrees with v4-core. If all three were wrong in the same direction, that suite froze the error
///      instead of finding it. That gap is what this file closes.
///
///      MIRRORED, NOT RE-DERIVED. Copied line for line from the v4-core checkout on this machine,
///      `/Users/omaidfaizyar/Desktop/web3-repos/Uniswap__v4-core/src/libraries/ProtocolFeeLibrary.sol`:
///        - `:8`      `uint16 public constant MAX_PROTOCOL_FEE = 1000;`   ("Max protocol fee is 0.1% (1000 pips)")
///        - `:17-19`  `getZeroForOneFee(uint24 self) => uint16(self & 0xfff)`
///        - `:21-23`  `getOneForZeroFee(uint24 self) => uint16(self >> 12)`
///      Nothing here is inferred from a plan document, a comment or a remembered convention. If v4-core changes
///      these, this file is wrong and the pin must be re-mirrored from the same path — that is the intended failure
///      mode, and it is louder than the one it replaces.
///
///      WHY A MIRROR AND NOT A SUBMODULE. v4-core is not a dependency of this repository (`.gitmodules` carries
///      `forge-std` and `openzeppelin-contracts` only) and adding one for two pure accessors would pull a large
///      tree into every build to assert twenty bytes of masking. The cost of the mirror is that it can go stale;
///      the NatSpec above names the exact file and lines so re-checking it is a one-command job.
///
///      TEST SCOPE ONLY. Nothing under `src/` imports this. It exists so a test can state the upstream convention
///      independently of the code under test.
library V4ProtocolFeeMirror {
    /// @dev v4-core `ProtocolFeeLibrary.sol:8`. 0.1 %, expressed in pips.
    uint16 internal constant MAX_PROTOCOL_FEE = 1000;

    /// @notice The fee charged on a `zeroForOne` swap: the LOW twelve bits of the packed value.
    /// @dev v4-core `ProtocolFeeLibrary.sol:17-19`.
    function getZeroForOneFee(uint24 self) internal pure returns (uint16) {
        return uint16(self & 0xfff);
    }

    /// @notice The fee charged on a `oneForZero` swap: the HIGH twelve bits of the packed value.
    /// @dev v4-core `ProtocolFeeLibrary.sol:21-23`.
    function getOneForZeroFee(uint24 self) internal pure returns (uint16) {
        return uint16(self >> 12);
    }
}
