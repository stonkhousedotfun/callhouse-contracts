// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V8AccessTest} from "./V8Access.sol";
import {V8Roles} from "../../../src/v2/access/V8Roles.sol";

/// @notice T-519. The fixture's own side effects, pinned so they are visible rather than inferred.
/// @dev THE LEDGER SUSPICION THIS ANSWERS (T-62-C8-04-ORACLE-KEEPER, P2): "the `_wire` fix routes every
///      manifest grant through `_grant` (which acquires the role-admin); the access matrix passed and
///      SettlementOracle wired, but any later suite that relies on `_wire` NOT granting a parented role could
///      be surprised — check the access-matrix stranger probe first."
///
///      THE STRANGER PROBE IS NOT THE EXPOSURE. It prANKs `makeAddr("stranger")`
///      (`test/v2/unit/AccessMatrix.t.sol:72`), never `address(this)`, so nothing `_grant` does to the harness
///      can reach it. Neither is `test/v2/unit/ExpiryCalendar.t.sol:315-316`, which asserts the harness does
///      NOT hold `LISTING`: `roles.v8.json` `roleAdmin` parents only GUARDIAN, PRICER, QUOTER and BUYBACK, so
///      `LISTING`'s admin is `ADMIN`, which the harness already holds (`V8Access.sol:43`), and `_grant`'s
///      acquisition branch (`:97-102`) is never taken for it.
///
///      WHAT IS REAL, and what these tests pin: wiring a target that carries a PARENTED role makes `_grant`
///      grant `OPS_ADMIN` to `address(this)` (`V8Access.sol:101`) and NEVER give it back. The production
///      hand-over does the same self-grant and then renounces — step 8 of the nine — and this fixture has no
///      step 8. Nothing else in the suite asserts that, which is why it was invisible rather than broken.
///      The shape that would bite: a test meaning to prove "only OPS_ADMIN can do X", satisfied by the
///      harness itself, masking a grant that was never made.
contract V8AccessSideEffectsTest is V8AccessTest {
    address internal holder = makeAddr("holder");

    /// @dev Before any wiring the harness is ADMIN and nothing else. If this fails, the fixture changed
    ///      shape and the two tests below are measuring something other than what they claim.
    function test_harness_startsWithAdminOnly() public {
        _deployManager();
        (bool isAdmin,) = manager.hasRole(V8Roles.ADMIN, address(this));
        assertTrue(isAdmin, "the harness is the manager's initial ADMIN");
        (bool isOps,) = manager.hasRole(V8Roles.OPS_ADMIN, address(this));
        assertFalse(isOps, "and holds no OPS_ADMIN before anything is wired");
    }

    /// @dev PINNED SIDE EFFECT. SettlementOracle's manifest rows are CONFIG_ADMIN and GUARDIAN; GUARDIAN is
    ///      parented to OPS_ADMIN, so wiring it takes `_grant`'s acquisition branch.
    function test_wiringAParentedRoleLeavesTheHarnessHoldingOpsAdmin() public {
        _deployManager();
        (bool before_,) = manager.hasRole(V8Roles.OPS_ADMIN, address(this));
        assertFalse(before_, "precondition: no OPS_ADMIN yet");

        _newSettlementOracle(holder);

        (bool isOps,) = manager.hasRole(V8Roles.OPS_ADMIN, address(this));
        assertTrue(isOps, "wiring a parented role leaves the harness holding OPS_ADMIN, and nothing renounces it");
        (bool holderHasGuardian,) = manager.hasRole(V8Roles.GUARDIAN, holder);
        assertTrue(holderHasGuardian, "and the holder did get the parented role it was wired for");
        (bool harnessHasGuardian,) = manager.hasRole(V8Roles.GUARDIAN, address(this));
        assertFalse(harnessHasGuardian, "the harness acquires the ADMIN of the role, never the role itself");
    }

    /// @dev THE SAFE CASE, pinned because `test/v2/unit/ExpiryCalendar.t.sol:316` depends on it from another
    ///      file: an UNPARENTED role is granted without any acquisition, so the harness gains nothing.
    function test_wiringAnUnparentedRoleGrantsTheHarnessNothing() public {
        _deployManager();
        _newCalendar(new uint32[](0), holder);

        (bool harnessHasListing,) = manager.hasRole(V8Roles.LISTING, address(this));
        assertFalse(harnessHasListing, "LISTING is unparented, so the harness never self-grants it");
        (bool isOps,) = manager.hasRole(V8Roles.OPS_ADMIN, address(this));
        assertFalse(isOps, "and wiring an unparented role acquires no OPS_ADMIN either");
        (bool holderHasListing,) = manager.hasRole(V8Roles.LISTING, holder);
        assertTrue(holderHasListing, "the holder still got LISTING");
    }
}
