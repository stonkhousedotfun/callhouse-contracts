// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";

/// @title Managed
/// @notice The thin shared access base of every INTERFACE_VERSION 8 target: OpenZeppelin `AccessManaged` with one
///         change, an unauthorised caller reverting `V2Errors.NotAuthorized()` (selector `0xea8e4eb5`) instead of
///         `AccessManagedUnauthorized(address)`.
/// @dev WHY THE OVERRIDE EXISTS. v2 has one error ABI: every unauthorised call in every contract reverts
///      `V2Errors.NotAuthorized()`, and dozens of tests, the keeper's and the MM bot's revert decoders, the web and
///      the monitor all switch on that one selector. `AccessManaged` would introduce a second "you may not" error,
///      per contract, which every off-chain decoder would have to learn. `_checkCanCall` is overridden instead.
///
///      THE OVERRIDE IS OpenZeppelin's LOGIC, NOT A NEW POLICY. It asks the authority the same question through
///      `AuthorityUtils.canCallWithDelay`:
///        - immediate: allowed, return;
///        - not immediate and no delay for this (role, member): `NotAuthorized`;
///        - not immediate but a delay exists: defer to `super._checkCanCall`, which consumes the scheduled operation
///          on the manager (`consumeScheduledOp`) while `isConsumingScheduledOp()` answers truthfully. That state flag
///          is `private` in the base, so the scheduled path MUST go through `super`; the extra `canCall` staticcall it
///          costs is paid only on the delayed path, never on a user call and never on an immediate admin call.
///      A caller who scheduled nothing therefore still reverts through the manager's own
///      `AccessManagerNotScheduled`, which is the honest answer: the role was right and the operation was missing.
///
///      SCOPE. This base grants nothing and knows no role ids: `(target, selector) -> role` and the per-member
///      execution delays live entirely in the manager (`V8Roles`, `script/v2/roles.v8.json`). A v8 constructor takes
///      `address authority` and nothing else; no target ever grants a role to anybody.
///
///      STORAGE. `AccessManaged` holds `address _authority` and `bool _consumingSchedule` packed into ONE slot, the
///      same single slot v7's `AccessControl` used for its `_roles` mapping. Keeping `Managed` in `AccessControl`'s
///      old inheritance position therefore leaves every later slot where it was, which is what the tests that pin
///      `SERIES_SLOT = 12` and `SNAPSHOTS_SLOT = 2` rely on.
///
///      NO ERC-165. `AccessManaged` declares no `supportsInterface`, so a v8 target no longer reports
///      `type(IAccessControl).interfaceId`. That is deliberate: roles are not on the target any more.
///
///      `restricted` IS NOT VIEW-SAFE. It makes an external call to the authority, so it belongs on `external`
///      functions only, after `nonReentrant`: the house order is `external nonReentrant restricted`. The manager
///      calls back into `isConsumingScheduledOp()`, a view, which the transient reentrancy guard permits.
abstract contract Managed is AccessManaged {
    /// @param authority_ The `AccessManager` that gates this contract. Must be a contract (`NoSource`); a zero or
    ///        code-less authority would make every `restricted` call revert and could never be replaced, because
    ///        {setAuthority} is callable only by the authority itself.
    constructor(address authority_) AccessManaged(authority_) {
        if (authority_.code.length == 0) revert V2Errors.NoSource();
    }

    /// @notice Points this contract at another `AccessManager`. The current authority only.
    /// @dev Same rule as OpenZeppelin's, with this repository's errors: `NotAuthorized` for any other caller,
    ///      `NoSource` for a code-less replacement. In v8 the call itself is an ADMIN-lane operation on the current
    ///      manager, so it inherits ADMIN's 48 h execution delay.
    /// @param newAuthority The replacement `AccessManager`.
    function setAuthority(address newAuthority) public virtual override {
        if (msg.sender != authority()) revert V2Errors.NotAuthorized();
        if (newAuthority.code.length == 0) revert V2Errors.NoSource();
        _setAuthority(newAuthority);
    }

    /// @dev OpenZeppelin's `_checkCanCall` with `AccessManagedUnauthorized` replaced by `V2Errors.NotAuthorized`.
    ///      Panics, as the base does, on calldata shorter than four bytes, which is why `restricted` is never put on
    ///      `receive` or `fallback`.
    function _checkCanCall(address caller, bytes calldata data) internal virtual override {
        (bool immediate, uint32 delay) =
            AuthorityUtils.canCallWithDelay(authority(), caller, address(this), bytes4(data[0:4]));
        if (immediate) return;
        if (delay == 0) revert V2Errors.NotAuthorized();
        // Delayed member: the base consumes the scheduled operation and owns the `_consumingSchedule` flag.
        super._checkCanCall(caller, data);
    }
}
