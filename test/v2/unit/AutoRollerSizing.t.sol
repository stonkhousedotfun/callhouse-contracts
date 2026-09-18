// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutoRollerTestBase} from "./AutoRollerBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";
import {OptionMath} from "../../../src/v2/lib/OptionMath.sol";

/// @notice {AutoRoller.roll} sizes the ask at free collateral NET OF RENT (INTERFACE_VERSION 7, v7 design §4.5.4):
///         `free / (UNIT + rent per unit)`, at the series' pinned rate when the series already exists and the market's
///         current rate otherwise.
/// @dev Rent is what `Clearinghouse.mint` charges the writer on the collateral it locks, out of the same free balance
///      (c05). This suite is the only AutoRoller one that registers a non-zero `mintFeePpm`: the shared fixture keeps
///      0, so every other AutoRoller number in the suite stays where it was (v7 design §3.8).
///
///      The "the whole ask still fills" assertions are written against the real Clearinghouse and pass today because
///      `mint` does not charge yet (c05 is WP-A); they become the real statement — that the last unit of an ask sized
///      net of rent can still be minted — once WP-A lands and WP-I re-runs them.
contract AutoRollerSizingTest is AutoRollerTestBase {
    /// @dev NVDA's launch rate, millionths of locked collateral per 7 days of remaining life (v7 design §5.1).
    uint32 internal constant PPM_80 = 80;

    /// @dev Thursday 10:00 to the Friday 09-11 16:00 expiry: 30 hours.
    uint256 internal constant REMAINING = 108_000;

    function _setMintFeePpm(uint32 ppm) internal {
        V2Types.MarketConfig memory m = ch.market(address(nvda));
        m.mintFeePpm = ppm;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), m);
    }

    /// @dev What a roll at Thursday 10:00 pays in rent for one unit at `ppm`.
    function _feePerUnit(uint32 ppm) internal pure returns (uint256) {
        return OptionMath.mintFee(V2Constants.UNIT, ppm, REMAINING);
    }

    /// @dev Leaves `writer` exactly `amount` of free NVDA in the ledger.
    function _setFree(address writer, uint256 amount) internal {
        uint256 free = ch.free(writer, address(nvda));
        vm.startPrank(writer);
        if (free > amount) ch.withdraw(address(nvda), free - amount, writer);
        if (free < amount) ch.deposit(address(nvda), amount - free, writer);
        vm.stopPrank();
        assertEq(ch.free(writer, address(nvda)), amount, "free set");
    }

    /*//////////////////////////////////////////////////////////////
                                 SIZING
    //////////////////////////////////////////////////////////////*/

    /// A writer who deposits exactly N shares writes N x 100 - 1 units: the last unit's rent has nowhere to come from.
    function test_size_exactShares_writesOneUnitLess() public {
        _setMintFeePpm(PPM_80);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);

        Rolled memory r = _mustRoll(alice);
        assertEq(r.expiry, FRI_2026_09_11, "the 30 h expiry the rent is quoted against");
        uint256 fee = _feePerUnit(PPM_80);
        assertGt(fee, 0, "rent is charged");
        assertEq(r.units, WRITER_SHARES / (V2Constants.UNIT + fee), "free / (UNIT + rent per unit)");
        assertEq(r.units, 999, "10 shares -> 1,000 units of collateral -> 999 units of ask");
    }

    /// Rent headroom in the deposit buys the last unit back.
    function test_size_withRentHeadroom_writesTheWholeDeposit() public {
        _setMintFeePpm(PPM_80);
        _setStrategy(alice, _weekly(500, 150));
        _setFree(alice, WRITER_SHARES + 1000 * _feePerUnit(PPM_80));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).units, 1000, "1,000 units with their rent alongside");
    }

    /// At ppm 0 nothing changes: `free / UNIT`, exactly as before INTERFACE_VERSION 7.
    function test_size_zeroPpm_isUnchanged() public {
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        assertEq(_mustRoll(alice).units, 1000, "no rent, no headroom needed");
    }

    /// The rate is the SERIES' pinned one whenever the series exists: anyone may have created it while the market
    /// carried a different rate, and that is the rate its mints pay.
    function test_size_preCreatedSeries_usesThePinnedRate() public {
        _setMintFeePpm(V2Constants.MINT_FEE_CEIL_PPM);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);

        // Anyone pre-creates the series the roll is about to want, at the market's rate of the moment.
        uint256 longId = ch.createSeries(address(nvda), false, K_231, FRI_2026_09_11);
        assertEq(ch.series(longId).mintFeePpm, V2Constants.MINT_FEE_CEIL_PPM, "pinned at the ceiling");

        // The admin drops the market to zero. Existing series keep their pinned rate, so the roll must too.
        _setMintFeePpm(0);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.longId, longId, "the roll reused the pre-created series");
        uint256 fee = _feePerUnit(V2Constants.MINT_FEE_CEIL_PPM);
        assertEq(r.units, WRITER_SHARES / (V2Constants.UNIT + fee), "sized by the pinned rate, not the market's");
        assertLt(r.units, 1000, "and therefore below the market's own zero-rent size");
    }

    /// Nothing left after rent is "not now", not a half-done roll: {_plan} is a view, so no series is created.
    function test_size_zeroAfterRent_returnsFalseWithoutCreatingASeries() public {
        _setMintFeePpm(V2Constants.MINT_FEE_CEIL_PPM);
        _setStrategy(alice, _weekly(500, 150));
        _setFree(alice, V2Constants.UNIT); // exactly one unit of collateral, and no rent
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);

        _noRoll(alice, "one unit of collateral cannot pay for itself");
        assertFalse(ch.seriesExists(ch.longIdOf(address(nvda), false, K_231, FRI_2026_09_11)), "no series created");
    }

    /*//////////////////////////////////////////////////////////////
                           THE ASK STILL FILLS
    //////////////////////////////////////////////////////////////*/

    /// The whole ask fills in one bulk take. Every unit it mints pays at most the rent the sizing reserved, because
    /// less time is left by then and ceil(u * x) <= u * ceil(x).
    function test_wholeAskFills_bulkTake() public {
        _setMintFeePpm(PPM_80);
        _setStrategy(alice, _weekly(500, 150));
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);

        vm.warp(_ny(THU_0910, 15, 0, 0));
        assertEq(_buy(bob, r.longId, r.orderId, r.units), r.units, "every unit of the ask minted");
        assertEq(ch.balanceOf(alice, r.longId | 1), r.units, "the writer is short the whole ask");
    }

    /// And one unit at a time, right up to the mint cutoff, where the rent per unit is at its smallest.
    function test_wholeAskFills_oneUnitAtATime() public {
        _setMintFeePpm(PPM_80);
        V2Types.Strategy memory s = _weekly(500, 150);
        s.maxUnits = 5;
        _setStrategy(alice, s);
        _spotAt(_ny(THU_0910, 10, 0, 0), 220_00000000);
        Rolled memory r = _mustRoll(alice);
        assertEq(r.units, 5, "capped at 5 units");

        uint256[5] memory when = [
            _ny(THU_0910, 11, 0, 0),
            _ny(THU_0910, 15, 59, 0),
            _ny(FRI_0911, 9, 30, 0),
            _ny(FRI_0911, 14, 0, 0),
            uint256(FRI_2026_09_11) - V2Constants.SETTLEMENT_WINDOW - 1
        ];
        for (uint256 i; i < 5; ++i) {
            vm.warp(when[i]);
            assertEq(_buy(bob, r.longId, r.orderId, 1), 1, "one more unit fits");
        }
        assertEq(_order(r.orderId).filled, 5, "the whole ask filled");
    }
}
