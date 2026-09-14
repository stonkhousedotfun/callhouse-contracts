// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-01 regression: a third party cannot take in-the-money value from the vault's unsold calls
/// @notice Ported from the audit PoC `PoC_unsold_inventory_third_party_assignment.t.sol` (AUDIT-FINDINGS
///         F-01, High), FIXED FORM (decision D1 = A(ii), write on fill). The attack steps are the audit's;
///         the final assertions are inverted: the vault is never assigned on more than it SOLD, and the
///         depositor's recoverable USD under attack equals the honest baseline to the unit.
/// @dev Runs against the REAL Valorem Clear bytecode (6436c82) via {RealClearBase}: the assignment maths
///      lives in Valorem's bucket engine, and the mock that models it is itself under test elsewhere
///      (test/unit/MockClearDiff.t.sol), so a regression that asserts a USDG figure must not depend on it.
///
///      WHY THE ATTACK NO LONGER PAYS. Upstream `write` checks only `expiry > now`, so before any exercise
///      Mallory can still write 200 of the SAME option id into bucket 0 with the vault, and assignment is
///      still pro rata by amount WRITTEN across the bucket. What changed is what the vault has written:
///      NOTHING at `rollOpen`, and inside every Seaport fill exactly the contracts that fill moves to the
///      buyer ({Vault.authorizeOrder}). A claim can never be assigned on more than its own amount written,
///      so the vault can be assigned on at most what it sold, and every one of those contracts earned a
///      premium and was priced as a covered call. There is no unsold inventory to steer against.
///
///      Setup mirrors the launch market: lot 1e18, 231 USDG strike, spot 220 -> 260 (in the money in the
///      24h exercise window). The keeper lists 20 (capacity) and only 5 sell, which under the old design left
///      15 unsold-but-written contracts and a 395.45 USDG loss; now it leaves 5 written, 5 sold.
contract AF01_UnsoldInventory is BaseTest, RealClearBase {
    address internal mallory = makeAddr("mallory");

    int256 internal constant SPOT_ITM = 260_00000000;
    uint256 internal constant SPOT_ITM_USDG = 260_000_000;
    uint256 internal constant STRIKE = 231_000_000;

    function _deployClear() internal override returns (IValoremClear) {
        return _deployRealClear();
    }

    function setUp() public override {
        super.setUp();
        // Attacker capital. Both legs round-trip: the collateral comes back at expiry and the strike
        // USDG buys NVDA worth more than it cost.
        _fund(mallory, 400e18, 100_000_000_000);
        _fund(buyer, 0, 5_000_000_000); // $10,000 total, enough to exercise 5 at 231
    }

    /// @dev List 20 (the whole capacity), sell 5. Returns the option id; the vault has written exactly 5.
    function _listTwentySellFive() internal returns (uint256 optionId) {
        _deposit(alice, 30e18);
        optionId = _rollOpen(); // 231 rung, in band at spot 220
        OrderComponents memory order = _approveListing(optionId, 20, _okUnitPrice());
        _fill(order, 5); // only 5 of 20 sell

        assertEq(vault.contractsWritten(), 5, "written == sold: the vault wrote only what the fill moved");
        assertEq(clear.balanceOf(address(vault), optionId), 0, "no option token stays in the vault");
        assertEq(clear.balanceOf(buyer, optionId), 5, "the buyer holds the five");
        assertEq(vault.lockedAssets(), 5e18, "five lots of collateral behind the claim, not twenty");

        // Rally into the money and open the exercise window.
        feed.setAnswer(SPOT_ITM);
        vm.warp(exerciseTs);
    }

    /// @dev The honest week: the buyer exercises the 5 it bought, nobody else touches the id.
    function _honestBaseline(uint256 optionId) internal returns (uint256 aliceUsd) {
        _exercise(optionId, 5);
        assertEq(vault.contractsAssigned(), 5, "baseline: assigned on exactly what was sold");
        vm.warp(expiryTs);
        _rollClose();
        aliceUsd = _aliceRecoverableUsd();
    }

    /// @notice The audit's UNSTEERED attack: Mallory writes 200 into the vault's bucket before any exercise,
    ///         then everyone exercises. Bucket 0 is fully consumed, so the vault is 100% assigned: on the 5 it
    ///         sold, not one contract more, and alice is exactly where the honest week left her.
    function test_unsteeredAttack_vaultAssignedOnlyWhatItSold_depositorLossZero() public {
        uint256 optionId = _listTwentySellFive();
        uint256 snap = vm.snapshotState();

        uint256 aliceBaseline = _honestBaseline(optionId);

        // ================= ATTACK ==================================================================
        vm.revertToState(snap);
        uint256 malloryNvda0 = nvda.balanceOf(mallory);
        uint256 malloryUsdg0 = usdg.balanceOf(mallory);

        // (1) Mallory writes 200 of the SAME option id directly on Valorem. Bucket 0 is still
        //     unexercised, so her writes join the vault's bucket, exactly as in the audit.
        vm.startPrank(mallory);
        nvda.approve(address(clear), type(uint256).max);
        usdg.approve(address(clear), type(uint256).max);
        uint256 malloryClaim = clear.write(optionId, 200);
        vm.stopPrank();
        assertEq(clear.claim(malloryClaim).amountWritten, 200e18, "attacker in the vault's bucket");

        // (2) The buyer exercises its 5 and Mallory her 200: bucket 0 (5 + 200 written) is consumed.
        _exercise(optionId, 5);
        vm.prank(mallory);
        clear.exercise(optionId, 200);

        uint256 vaultAssigned = vault.contractsAssigned();
        emit log_named_uint("vault contracts assigned (attack)", vaultAssigned);
        // FIXED: 5 written, 5 sold, 5 assigned. The old design was assigned 18 of its 20 having sold 5.
        assertEq(vaultAssigned, 5, "the vault is assigned on exactly the 5 it sold");
        assertLe(vaultAssigned, vault.contractsWritten(), "assigned <= written == sold");

        // (3) Expiry: everyone redeems.
        vm.warp(expiryTs);
        vm.prank(mallory);
        clear.redeem(malloryClaim);
        _rollClose();

        uint256 aliceAttack = _aliceRecoverableUsd();
        int256 malloryProfitUsd = _valueUsd(
            int256(nvda.balanceOf(mallory)) - int256(malloryNvda0),
            int256(usdg.balanceOf(mallory)) - int256(malloryUsdg0)
        );

        emit log_named_uint("alice recoverable USD, baseline (6dp)", aliceBaseline);
        emit log_named_uint("alice recoverable USD, attack   (6dp)", aliceAttack);
        emit log_named_int("mallory profit USD (6dp)", malloryProfitUsd);

        // FIXED, the two things that used to make this a theft:
        // A) the attack does not harm the depositor: her USD equals the honest baseline to the unit;
        assertEq(aliceAttack, aliceBaseline, "alice ends exactly where the honest week left her");
        // B) Mallory's round trip nets her nothing: her 200 contracts were assigned on her own collateral.
        assertLe(malloryProfitUsd, 0, "no riskless profit for the attacker");
        assertGe(malloryProfitUsd, -1_000_000, "and no more than rounding dust lost on the round trip");
    }

    /// @notice The STEERED attack, with the buyer asleep. Mallory partially exercises bucket 0 so that her
    ///         next write opens a sacrificial bucket, then exercises EVERYTHING she holds so every bucket is
    ///         consumed whatever the settlement seed says: the vault's whole claim is assigned (100%) while
    ///         the buyer never exercised its own calls. Even so the vault is assigned on exactly the 5 it
    ///         sold, and alice ends where the honest week left her: the sleeping buyer's intrinsic went to
    ///         Mallory, none of alice's did.
    function test_steeredAttack_buyerAsleep_fullAssignmentIsStillOnlyWhatWasSold() public {
        uint256 optionId = _listTwentySellFive();
        uint256 snap = vm.snapshotState();

        uint256 aliceBaseline = _honestBaseline(optionId);

        // ================= ATTACK ==================================================================
        vm.revertToState(snap);

        vm.startPrank(mallory);
        nvda.approve(address(clear), type(uint256).max);
        usdg.approve(address(clear), type(uint256).max);
        // (1) 200 into bucket 0 with the vault, then ONE exercise: bucket 0 is now partially exercised,
        //     so the next write opens a new bucket (upstream `_addOrUpdateBucket`).
        uint256 claimA = clear.write(optionId, 200);
        clear.exercise(optionId, 1);
        // (2) A sacrificial bucket of 100.
        uint256 claimB = clear.write(optionId, 100);
        // (3) Exercise everything she holds: 199 + 100. Both buckets are consumed in full, so the walk
        //     order the seed dictates no longer matters: 100% of bucket 0 is assigned, the vault's 5 included.
        clear.exercise(optionId, 299);
        vm.stopPrank();

        uint256 vaultAssigned = vault.contractsAssigned();
        emit log_named_uint("vault contracts assigned (steered, buyer asleep)", vaultAssigned);
        assertEq(vaultAssigned, 5, "100% assigned, and 100% of the vault's claim is the 5 it sold");
        assertEq(vault.lockedAssets(), 0, "nothing left behind the claim");
        assertEq(clear.balanceOf(buyer, optionId), 5, "the buyer still holds its five, never exercised");

        vm.warp(expiryTs);
        vm.startPrank(mallory);
        clear.redeem(claimA);
        clear.redeem(claimB);
        vm.stopPrank();
        _rollClose();

        uint256 aliceAttack = _aliceRecoverableUsd();
        emit log_named_uint("alice recoverable USD, baseline (6dp)", aliceBaseline);
        emit log_named_uint("alice recoverable USD, steered  (6dp)", aliceAttack);

        // The vault delivered the 5 lots it sold at the strike and was paid for them: the same outcome as
        // the honest week. Whatever the sleeping buyer forfeited is the buyer's, not the depositors'.
        assertEq(aliceAttack, aliceBaseline, "alice ends exactly where the honest week left her");
    }

    /// @notice Control: with no attacker and a sleeping buyer, every lot of collateral comes home and the
    ///         premium is kept. Pins the baseline the two attack tests are measured against.
    function test_control_sleepingBuyerNoAttacker_collateralComesHome() public {
        uint256 optionId = _listTwentySellFive();
        vm.warp(expiryTs);
        _rollClose();
        assertEq(nvda.balanceOf(address(vault)), 30e18, "all 30 lots home: nothing assigned");
        assertEq(vault.contractsWritten(), 0, "position cleared");
        assertApproxEqAbs(
            vault.claimableUsdg(alice), 9_025_000, 1, "95% of 5 x 1.90 USDG of premium, to the index unit"
        );
        assertEq(clear.balanceOf(buyer, optionId), 5, "the buyer's expired calls");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev What alice can actually get out once the vault is Idle: redeem all shares for NVDA
    ///      (valued at the ITM spot) plus claim all accrued USDG. In USDG base units (6dp).
    function _aliceRecoverableUsd() internal returns (uint256) {
        require(vault.canRedeemInstantly(), "expected Idle/flat after rollClose");
        uint256 usdgOut;
        if (vault.claimableUsdg(alice) != 0) {
            vm.prank(alice);
            usdgOut = vault.claimUsdg();
        }
        uint256 shares = vault.balanceOf(alice);
        uint256 assetsOut;
        if (shares != 0) {
            vm.prank(alice);
            assetsOut = vault.redeem(shares, alice, alice);
        }
        return (assetsOut * SPOT_ITM_USDG) / 1e18 + usdgOut;
    }

    function _valueUsd(int256 dNvda, int256 dUsdg) internal pure returns (int256) {
        return (dNvda * int256(SPOT_ITM_USDG)) / int256(1e18) + dUsdg;
    }
}
