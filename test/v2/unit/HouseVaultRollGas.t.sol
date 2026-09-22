// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {HouseVaultTestBase} from "./HouseVaultBase.t.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Ids} from "../../../src/v2/interfaces/V2Ids.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice T-OP-125. The keeper sends {HouseVault.rollEpoch} with a FIXED gas limit,
///         `HOUSE_ROLL_GAS = 2_500_000n` (callhouse `keeper/src/v2/cranker/steps.ts`, T-OP-117). That number was
///         reasoned, not measured. A fixed limit that is too low fails the weekly boundary SILENTLY: the send runs
///         out of gas, the cranker's overdue page fires seven hours later, and nothing in the contract says why.
///         This file measures the boundary against the load the constant has to survive and pins the ceiling so a
///         regression that pushes the roll above it goes red here first.
/// @dev THE LOAD. {rollEpoch} walks {_tracked} three times per boundary ({_redeemSettled}, {_requireFlat}, the
///      NAV path) and the first walk REDEEMS every settled leg the vault still holds. The costly leg is the
///      in-the-money one: an ITM long call pays out underlying through `Clearinghouse.redeem` (a transfer, the
///      fee accrual and the open-interest decrement), an OTM one burns and returns. So the series here are all
///      ITM at the settled price, and two shapes are measured per count:
///        - LONGS ONLY: the vault took `mm`'s AskWrite on each series and holds 10 longs per series.
///        - BOTH LEGS: additionally the vault wrote 10 into its own resting ask which `mm` took, so it also holds 10
///          shorts per series and the boundary redeems twenty legs, not ten. This is the market-maker's ordinary
///          end-of-week state and is the heavier of the two.
///      The three counts are 1, 3 and 5 tracked series, each settled before the roll, measured with `gasleft()`
///      around the call exactly as `HouseVaultEpoch.t.sol:_measureRollWithTracked` does. `vm.snapshotGasLastCall`
///      is not used: the box's forge (1.3.5-foundry-zksync-v0.1.9; forge 1.5.1 is pinned for `fmt` only) and the
///      `gasleft()` delta agree on the external-call cost to within the call overhead, and the delta needs no
///      cheatcode support to be re-run under either version.
///
///      THE ASSERTION IS THE KEEPER'S NUMBER, mirrored here as {HOUSE_ROLL_GAS}. Changing the keeper constant
///      without changing this one is what the pin is for: a roll measured above it is a boundary the keeper
///      cannot send. The measured values are logged so the ledger can quote them; the slope per series is the
///      difference between the 5- and 1-series measurements divided by four.
///
///      WHAT THIS DOES NOT MEASURE. Every fixture read here is a warm SLOAD after setup, and the real chain pays
///      cold access on the first touch of each series slot and each ERC-1155 balance (EIP-2929: 2 100 gas per cold
///      slot, 2 600 per cold account). A real boundary therefore costs MORE than this by roughly the cold surcharge
///      per touched slot; the headroom below {HOUSE_ROLL_GAS} must cover that, and the ledger states it.
///
///      MEASURED ONCE, at ee14bfbc56949f1cb626bb4656ffb0965db1f48f with forge 1.3.5-foundry-zksync-v0.1.9
///      (`forge test --match-path test/v2/unit/HouseVaultRollGas.t.sol -vv`, 7 passed, 0 failed), gasleft() delta:
///        | tracked ITM series | longs only | both legs |
///        | 1                  |    287 925 |   317 254 |
///        | 3                  |    395 574 |   473 964 |
///        | 5                  |    503 294 |   630 752 |
///      Slope per series: 53 842 (longs only), 78 372 (both legs, measured inside the slope test, whose own
///      five-series call read 630 748: the gasleft() delta moves by a few gas with the caller's stack). Headroom
///      at five series, both legs: 1 869 252, i.e. the heaviest measured boundary uses 25 % of HOUSE_ROLL_GAS.
///      A scratch run with the mirror lowered to 300 000 left exactly the one-series longs-only case green
///      (287 925) and failed the other six by name. These are the figures the ledger quotes;
///      they are NOT asserted -- only the ceiling is, so a future compiler or contract change moves the numbers
///      without moving the test unless it crosses the keeper's limit.
contract HouseVaultRollGasTest is HouseVaultTestBase {
    /// @dev MIRROR of callhouse `keeper/src/v2/cranker/steps.ts` `HOUSE_ROLL_GAS = 2_500_000n` (T-OP-117).
    uint256 internal constant HOUSE_ROLL_GAS = 2_500_000;

    /// @dev The settled price, USDG 6 dp per whole share. NVDA_SPOT is 220.00; every strike below sits UNDER it so
    ///      each call is in the money at the boundary, and inside the createSeries band [spot/2, spot*2].
    uint256 internal constant BOUNDARY_PRICE = 220_000_000;

    /// @dev First ITM strike, one whole-USDG tick below spot; series i uses `ITM_STRIKE_0 - i * STRIKE_TICK`.
    uint128 internal constant ITM_STRIKE_0 = 219_000_000;

    /*//////////////////////////////////////////////////////////////
                              LONGS ONLY
    //////////////////////////////////////////////////////////////*/

    function test_gas_rollEpoch_oneItmSeries_longsOnly() public {
        uint256 used = _measureRoll(1, false);
        console2.log("rollEpoch gas, 1 ITM series, longs only:", used);
        assertLt(used, HOUSE_ROLL_GAS, "one ITM series already exceeds the keeper's fixed gas limit");
    }

    function test_gas_rollEpoch_threeItmSeries_longsOnly() public {
        uint256 used = _measureRoll(3, false);
        console2.log("rollEpoch gas, 3 ITM series, longs only:", used);
        assertLt(used, HOUSE_ROLL_GAS, "three ITM series exceed the keeper's fixed gas limit");
    }

    function test_gas_rollEpoch_fiveItmSeries_longsOnly() public {
        uint256 used = _measureRoll(5, false);
        console2.log("rollEpoch gas, 5 ITM series, longs only:", used);
        assertLt(used, HOUSE_ROLL_GAS, "five ITM series exceed the keeper's fixed gas limit");
    }

    /*//////////////////////////////////////////////////////////////
                               BOTH LEGS
    //////////////////////////////////////////////////////////////*/

    function test_gas_rollEpoch_oneItmSeries_bothLegs() public {
        uint256 used = _measureRoll(1, true);
        console2.log("rollEpoch gas, 1 ITM series, both legs:", used);
        assertLt(used, HOUSE_ROLL_GAS, "one ITM series (both legs) exceeds the keeper's fixed gas limit");
    }

    function test_gas_rollEpoch_threeItmSeries_bothLegs() public {
        uint256 used = _measureRoll(3, true);
        console2.log("rollEpoch gas, 3 ITM series, both legs:", used);
        assertLt(used, HOUSE_ROLL_GAS, "three ITM series (both legs) exceed the keeper's fixed gas limit");
    }

    function test_gas_rollEpoch_fiveItmSeries_bothLegs() public {
        uint256 used = _measureRoll(5, true);
        console2.log("rollEpoch gas, 5 ITM series, both legs:", used);
        assertLt(used, HOUSE_ROLL_GAS, "five ITM series (both legs) exceed the keeper's fixed gas limit");
    }

    /// @dev The slope is what the keeper constant has to absorb per extra tracked series. Logged, and bounded by the
    ///      remaining headroom: five series must leave room for at least five more at the measured slope before the
    ///      limit is reached, otherwise a busy week is one series away from a silent boundary failure.
    function test_gas_rollEpoch_slopeLeavesHeadroom_bothLegs() public {
        uint256 one = _measureRoll(1, true);
        uint256 five = _measureRollFresh(5, true);
        assertGe(five, one, "five series cost less than one");
        // Asserted before the headroom subtraction so a broken ceiling fails by name rather than by panic 0x11.
        assertLt(five, HOUSE_ROLL_GAS, "five ITM series (both legs) exceed the keeper's fixed gas limit");
        uint256 slope = (five - one) / 4;
        console2.log("rollEpoch gas slope per ITM series (both legs):", slope);
        console2.log("rollEpoch gas headroom below HOUSE_ROLL_GAS at 5 series:", HOUSE_ROLL_GAS - five);
        assertLt(five + 5 * slope, HOUSE_ROLL_GAS, "ten tracked ITM series would exceed the keeper's fixed gas limit");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A second measurement inside one test needs a fresh vault: {_seedFirstEpoch} has already rolled the
    ///      shared one, and the series created for the first measurement are settled and would be re-tracked.
    function _measureRollFresh(uint256 n, bool bothLegs) internal returns (uint256 used) {
        setUp();
        return _measureRoll(n, bothLegs);
    }

    /// @dev Builds `n` distinct ITM series the vault holds and has tracked, settles each, then measures ONE
    ///      {HouseVault.rollEpoch}. Mirrors `HouseVaultEpoch.t.sol:_measureRollWithTracked` for the long leg and
    ///      `_houseHoldsAMatchedPair` for the short leg; neither fixture is modified.
    function _measureRoll(uint256 n, bool bothLegs) internal returns (uint256 used) {
        _seedFirstEpoch();
        vm.prank(quoter);
        house.depositToClearinghouse(address(usdg), 5_000e6);
        if (bothLegs) {
            vm.prank(quoter);
            house.depositToClearinghouse(address(nvda), uint256(n) * 1e18);
        }

        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // Strikes step DOWN from one tick under spot in whole-USDG ticks: on the market's strikeTick, inside the
            // spot band, and every one of them in the money at BOUNDARY_PRICE.
            uint128 strike = uint128(ITM_STRIKE_0 - i * STRIKE_TICK);
            ids[i] = ch.createSeries(address(nvda), false, strike, FRI_2026_09_18);
            _houseTakesTenLongs(ids[i]);
            if (bothLegs) _houseWritesTenShorts(ids[i]);
        }
        vm.prank(quoter);
        house.sync(ids);
        assertEq(house.trackedSeries().length, n, "the fixture did not track n series");
        for (uint256 i; i < n; ++i) {
            assertEq(ch.balanceOf(address(house), ids[i]), 10, "the vault does not hold the longs");
            if (bothLegs) {
                assertEq(
                    ch.balanceOf(address(house), V2Ids.shortIdOf(ids[i])), 10, "the vault does not hold the shorts"
                );
            }
        }

        _finalizeBoundary(BOUNDARY_PRICE);
        for (uint256 i; i < n; ++i) {
            vm.prank(keeper);
            assertTrue(ch.settle(ids[i]), "series did not settle");
            V2Types.Series memory s = ch.series(ids[i]);
            assertGt(s.longPayoutPerUnit, 0, "the series is not in the money at the settled price");
        }

        uint256 before = gasleft();
        house.rollEpoch();
        used = before - gasleft();

        for (uint256 i; i < n; ++i) {
            assertEq(ch.balanceOf(address(house), ids[i]), 0, "the boundary did not redeem the settled long");
            assertEq(
                ch.balanceOf(address(house), V2Ids.shortIdOf(ids[i])),
                0,
                "the boundary did not redeem the settled short"
            );
        }
    }

    /// @dev `mm` writes ten units at P3_00 and the vault takes them: the vault holds 10 longs of `longId`.
    function _houseTakesTenLongs(uint256 longId) internal {
        uint256 askId = _place(mm, longId, WRITE, P3_00, 10);
        V2Types.TakeParams memory p;
        p.longId = longId;
        p.buying = true;
        p.orderIds = _ids(askId);
        p.units = 10;
        p.limitPrice = P3_00;
        p.recipient = address(house);
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        vm.prank(quoter);
        house.take(p);
    }

    /// @dev The vault writes ten units into its own resting ask at (or above) its ask floor and `mm` takes them:
    ///      the vault holds 10 shorts of `longId`. Same shape as `HouseVaultEpoch.t.sol:_houseHoldsAMatchedPair`.
    function _houseWritesTenShorts(uint256 longId) internal {
        uint256 floor_ = house.askFloorOf(longId, true);
        uint128 ask = uint128(
            floor_ > P3_00
                ? (floor_ + V2Constants.PRICE_TICK - 1) / V2Constants.PRICE_TICK * V2Constants.PRICE_TICK
                : P3_00
        );
        vm.prank(quoter);
        uint256 askId = house.place(longId, WRITE, ask, 10, 0);

        V2Types.TakeParams memory p;
        p.longId = longId;
        p.buying = true;
        p.orderIds = _ids(askId);
        p.units = 10;
        p.limitPrice = ask;
        p.recipient = mm;
        p.deadline = NO_DEADLINE;
        p.maxTotalFee = type(uint128).max;
        assertEq(_take(mm, p), 10, "mm did not take the vault's ask");
    }

    function _seedFirstEpoch() internal {
        _requestDeposit(depositorA, DEP_USDG, DEP_STOCK);
        _finalizeBoundary(BOUNDARY_PRICE);
        house.rollEpoch();
        vm.prank(depositorA);
        house.claim();
    }
}
