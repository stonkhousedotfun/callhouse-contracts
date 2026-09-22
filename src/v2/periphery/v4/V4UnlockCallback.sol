// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IV4PoolManager} from "./V4Types.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";

/// @title V4UnlockCallback
/// @notice The Uniswap v4 lock pattern, once, for every v8 contract that swaps on v4 (03-INTERFACES §1.4).
/// @dev v4 does not let anyone call `swap` directly. A caller calls `PoolManager.unlock(data)`; the manager calls
///      `unlockCallback(data)` back on that same caller, and only inside that callback may `swap`, `sync`, `settle`
///      and `take` be used. Everything must be settled before the callback returns or the whole call reverts.
///
///      TWO GUARDS, BOTH NECESSARY. `unlockCallback` is external, so it must refuse a caller that is not the pinned
///      PoolManager AND refuse to run when this contract did not itself open the lock: the manager is a public
///      contract and anyone can ask it to unlock on our behalf. The transient `_unlocking` flag is the second half.
///
///      PINNED MANAGER. The PoolManager is immutable. Chain 4663's official one is
///      `0x8366a39cc670b4001a1121b8f6a443a643e40951` (venue recon 2026-09-17, exercised by the `C3-602` fork spike);
///      it is a constructor argument so tests can pass a mock, never a discovered address.
abstract contract V4UnlockCallback {
    /// @notice The Uniswap v4 PoolManager this contract swaps through, and the only allowed callback caller.
    address public immutable poolManager;

    /// @dev True only between this contract calling `unlock` and the callback returning. Transient: the flag must not
    ///      survive the transaction, and a v4 swap never spans two.
    bool private transient _unlocking;

    /// @param poolManager_ The v4 PoolManager. Must be a contract (`NoSource`).
    constructor(address poolManager_) {
        if (poolManager_.code.length == 0) revert V2Errors.NoSource();
        poolManager = poolManager_;
    }

    /// @notice The PoolManager's callback into this contract. Not for anyone else.
    /// @dev Reverts `V2Errors.NotAuthorized` for any caller but the pinned manager, and for a manager-initiated
    ///      unlock this contract did not start.
    /// @param data Exactly the bytes this contract passed to {_unlock}.
    /// @return Whatever {_onUnlock} returns; the manager hands it back to {_unlock}'s caller.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager || !_unlocking) revert V2Errors.NotAuthorized();
        return _onUnlock(data);
    }

    /// @dev Opens the lock and runs {_onUnlock} inside it. The flag is cleared even if the manager reverts, because
    ///      the revert unwinds the whole transaction anyway; it is cleared on the success path so a second swap in
    ///      one call has to open its own lock.
    /// @param data Payload handed to {_onUnlock}.
    /// @return The payload {_onUnlock} returned.
    function _unlock(bytes memory data) internal returns (bytes memory) {
        _unlocking = true;
        bytes memory out = IV4PoolManager(poolManager).unlock(data);
        _unlocking = false;
        return out;
    }

    /// @dev The body of the lock: swap, settle and take here. Implemented by `PayoutRouter` (`C8-06`) and any other
    ///      v4 consumer. It runs with `msg.sender == poolManager`, so it must not read `msg.sender` as a user.
    /// @param data The payload {_unlock} was given.
    /// @return Anything the caller of {_unlock} needs back.
    function _onUnlock(bytes calldata data) internal virtual returns (bytes memory);
}
