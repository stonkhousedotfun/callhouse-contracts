// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {V8AccessTest} from "../lib/V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MakerRegistry} from "../../../src/v2/mm/MakerRegistry.sol";

/// @notice C8-01 unit coverage of `Managed._checkCanCall`: immediate, delayed via execute, delayed via
///         schedule + direct call, wrong caller, expired operation, cancelled operation, closed target.
contract ManagedAccessTest is V8AccessTest {
    address internal feeAdmin = makeAddr("feeAdmin");
    MakerRegistry internal registry;

    function setUp() public {
        registry = _newRegistry(feeAdmin);
    }

    function test_immediateRole_holderSetsTier() public {
        vm.prank(feeAdmin);
        registry.setTier(feeAdmin, 10);
        assertEq(registry.rebateBps(feeAdmin), 10);
    }

    function test_wrongCaller_revertsNotAuthorized() public {
        vm.prank(makeAddr("nope"));
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        registry.setTier(feeAdmin, 1);
    }

    function test_delayedRole_scheduleThenDirectCall() public {
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        manager.grantRole(V8Roles.FEE_MANAGER, feeAdmin, delay);
        bytes memory data = abi.encodeCall(MakerRegistry.setTier, (feeAdmin, 7));
        vm.prank(feeAdmin);
        manager.schedule(address(registry), data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(feeAdmin);
        registry.setTier(feeAdmin, 7);
        assertEq(registry.rebateBps(feeAdmin), 7);
    }

    function test_delayedRole_managerExecute() public {
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        address other = makeAddr("otherFee");
        manager.grantRole(V8Roles.FEE_MANAGER, other, delay);
        bytes memory data = abi.encodeCall(MakerRegistry.setTier, (other, 3));
        vm.prank(other);
        manager.schedule(address(registry), data, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(other);
        manager.execute(address(registry), data);
        assertEq(registry.rebateBps(other), 3);
    }

    function test_expiredOperation_reverts() public {
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        manager.grantRole(V8Roles.FEE_MANAGER, feeAdmin, delay);
        bytes memory data = abi.encodeCall(MakerRegistry.setTier, (feeAdmin, 4));
        vm.prank(feeAdmin);
        manager.schedule(address(registry), data, 0);
        vm.warp(block.timestamp + delay + 8 days);
        // T-OP-056. The exact refusal, not "any revert": a delayed member reaches
        // `AccessManager._consumeScheduledOp`, which finds the timepoint past `expiration()` and reverts
        // `AccessManagerExpired(operationId)`. A bare `expectRevert()` would also pass on a zero-address check or a
        // pause added in front of the guard, which is the access guard silently bypassed with a green test.
        // The id is computed BEFORE the prank: `hashOperation` is a call, and a prank spends itself on the next one.
        // With the bare assertion that mistake was invisible -- the unpranked call reverted `NotAuthorized()` and the
        // test stayed green; with the selector it failed naming the wrong error.
        bytes32 opId = manager.hashOperation(feeAdmin, address(registry), data);
        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, opId));
        registry.setTier(feeAdmin, 4);
    }

    function test_cancelledOperation_reverts() public {
        uint32 delay = V8Roles.FEE_MANAGER_DELAY;
        manager.grantRole(V8Roles.FEE_MANAGER, feeAdmin, delay);
        // Cancel path: scheduler OR ADMIN OR the guardian of the function's role.
        // FEE_MANAGER's guardian is GUARDIAN, not OPS_ADMIN. OPS_ADMIN is only the role-admin
        // that can *grant* GUARDIAN; `_grant` walks that chain. Role table unchanged.
        _grant(V8Roles.GUARDIAN, makeAddr("g"), 0);
        bytes memory data = abi.encodeCall(MakerRegistry.setTier, (feeAdmin, 5));
        vm.prank(feeAdmin);
        (bytes32 opId,) = manager.schedule(address(registry), data, 0);
        vm.prank(makeAddr("g"));
        manager.cancel(feeAdmin, address(registry), data);
        vm.warp(block.timestamp + delay);
        vm.prank(feeAdmin);
        // T-OP-056. `cancel` deletes the operation's timepoint, so the consume path sees 0 and reverts
        // `AccessManagerNotScheduled(operationId)` — the same id `schedule` returned above.
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, opId));
        registry.setTier(feeAdmin, 5);
    }

    function test_closedTarget_reverts() public {
        manager.setTargetClosed(address(registry), true);
        vm.prank(feeAdmin);
        // T-OP-056. A closed target makes `AccessManager.canCall` answer `(false, 0)`; with no delay to defer to,
        // `Managed._checkCanCall` reverts the v2 error, not OpenZeppelin's `AccessManagedUnauthorized`.
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        registry.setTier(feeAdmin, 1);
    }

    function test_codeLessAuthority_revertsNoSource() public {
        vm.expectRevert(V2Errors.NoSource.selector);
        new MakerRegistry(address(0));
    }
}
