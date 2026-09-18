// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {ClearinghouseTestBase} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";

/// @notice Who may redeem whom, and redeemBatch. Third-party redemption is on by default; `setThirdPartyRedeem(false)`
///         leaves only the holder and its operators (the OrderBook's escrow opts out this way). A batch skips holders
///         its caller may not redeem and survives any one holder's failure. The payout always goes to the holder.
/// @dev Fixture: NVDA call K = 240 and put K = 200 settled at 250 (call ITM, put OTM). alice wrote the calls: 100 held
///      by bob, 50 by carol, 20 by mm; 10 puts held by bob. Holders take payouts in kind, so amounts are exact:
///      long 3.75e14 per unit, short 9.6e15 per unit.
contract ClearinghouseRedeemAccessTest is ClearinghouseTestBase {
    bytes32 internal constant TRANSFER_SINGLE = keccak256("TransferSingle(address,address,address,uint256,uint256)");

    uint256 internal callId;
    uint256 internal putId;
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        putId = _put(K_200, FRI_2026_09_18);
        _write(alice, callId, 100, bob);
        _write(alice, callId, 50, carol);
        _write(alice, callId, 20, mm);
        _write(alice, putId, 10, bob);
        address[4] memory holders = [alice, bob, carol, mm];
        for (uint256 i; i < holders.length; ++i) {
            vm.prank(holders[i]);
            ch.setPayoutInKind(true);
        }
        _settle(callId, 250e6);
        vm.prank(keeper);
        ch.settle(putId);
    }

    /*//////////////////////////////////////////////////////////////
                           THIRD-PARTY OPT-OUT
    //////////////////////////////////////////////////////////////*/

    function test_optOut_strangerRevertsHolderAndOperatorSucceed() public {
        vm.prank(bob);
        ch.setThirdPartyRedeem(false);

        vm.prank(keeper);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(callId, bob);
        vm.prank(mm);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(callId, bob);

        // An operator may redeem, and the payout still goes to the holder.
        vm.prank(bob);
        ch.setOperator(mm, true);
        uint256 mmNvda = nvda.balanceOf(mm);
        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Redeemed(callId, bob, bob, 100, address(nvda), 3.75e16, 3.75e16, false);
        vm.prank(mm);
        (uint256 paid,) = ch.redeem(callId, bob);
        assertEq(paid, 3.75e16);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 3.75e16, "paid to the holder");
        assertEq(nvda.balanceOf(mm), mmNvda, "never to the operator");

        // The holder itself.
        vm.prank(bob);
        (paid,) = ch.redeem(putId, bob);
        assertEq(paid, 0, "OTM put, burned");
        assertEq(ch.balanceOf(bob, putId), 0);

        // The opt-out holds even with nothing left to redeem.
        vm.prank(keeper);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(callId, bob);

        vm.prank(bob);
        ch.setThirdPartyRedeem(true);
        vm.prank(keeper);
        ch.redeem(callId, bob); // allowed again (a no-op now)
    }

    function test_optOut_isPerAccount() public {
        vm.prank(bob);
        ch.setThirdPartyRedeem(false);
        (uint256 paid,) = _redeem(callId, carol);
        assertEq(paid, 50 * 3.75e14, "other holders are unaffected");
        (paid,) = _redeem(_short(callId), alice);
        assertEq(paid, 170 * 9.6e15);
    }

    /// @dev An operator of someone else gains nothing: mm is carol's operator, not bob's.
    function test_optOut_operatorOfAnotherAccountRejected() public {
        vm.prank(bob);
        ch.setThirdPartyRedeem(false);
        vm.prank(carol);
        ch.setOperator(mm, true);
        vm.prank(mm);
        vm.expectRevert(V2Errors.ThirdPartyRedeemDisabled.selector);
        ch.redeem(callId, bob);
    }

    /*//////////////////////////////////////////////////////////////
                               REDEEM BATCH
    //////////////////////////////////////////////////////////////*/

    function test_redeemBatch_redeemsEveryoneAndPaysBounties() public {
        address[] memory holders = _list3(bob, carol, mm);
        uint256 k0 = usdg.balanceOf(keeper);
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 3);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 100 * 3.75e14);
        assertEq(nvda.balanceOf(carol), ACTOR_SHARES + 50 * 3.75e14);
        assertEq(nvda.balanceOf(mm), ACTOR_SHARES + 20 * 3.75e14);
        assertEq(ch.totalSupply(callId), 0);
        // bob's 9.375 USDG and carol's 4.6875 USDG clear the 1 USDG threshold; mm's 1.875 USDG too.
        assertEq(usdg.balanceOf(keeper) - k0, 3 * REDEEM_BOUNTY, "one bounty per eligible holder, to the batch caller");

        address[] memory writer = new address[](1);
        writer[0] = alice;
        vm.prank(keeper);
        assertEq(ch.redeemBatch(_short(callId), writer), 1);
        assertEq(ch.locked(callId), 0);
    }

    function test_redeemBatch_skipsOptedOutHolder() public {
        vm.prank(bob);
        ch.setThirdPartyRedeem(false);
        address[] memory holders = _list3(bob, carol, mm);

        vm.recordLogs();
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 2, "bob skipped, no revert");
        assertEq(ch.balanceOf(bob, callId), 100, "bob untouched");
        assertEq(ch.balanceOf(carol, callId), 0);
        assertEq(ch.balanceOf(mm, callId), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IClearinghouse.Redeemed.selector) {
                assertTrue(address(uint160(uint256(logs[i].topics[2]))) != bob, "no Redeemed for bob");
            }
        }

        // bob's operator may batch-redeem bob.
        vm.prank(bob);
        ch.setOperator(dave, true);
        vm.prank(dave);
        assertEq(ch.redeemBatch(callId, holders), 1);
        assertEq(ch.balanceOf(bob, callId), 0);
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 3.75e16);
        assertEq(nvda.balanceOf(dave), 0);
    }

    /// @dev One holder whose redemption frame reverts, one blocklisted holder, holders with nothing, a duplicate and the
    ///      zero address: the batch redeems everyone it can and reports exactly how many.
    function test_redeemBatch_oneBadHolderDoesNotBlock() public {
        // mm's frame reverts outright (the per-holder self-call is made to fail), carol cannot receive NVDA.
        vm.mockCallRevert(address(ch), abi.encodeCall(ch.batchRedeemOne, (callId, mm, keeper)), bytes("holder frame"));
        nvda.blockAccount(carol);

        address[] memory holders = new address[](6);
        holders[0] = mm;
        holders[1] = dave; // no balance
        holders[2] = carol;
        holders[3] = address(0);
        holders[4] = bob;
        holders[5] = bob; // duplicate
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, holders), 2, "bob and carol");

        assertEq(ch.balanceOf(mm, callId), 20, "the failed holder keeps its tokens");
        assertEq(ch.balanceOf(carol, callId), 0);
        assertEq(ch.free(carol, address(nvda)), 50 * 3.75e14, "blocked holder credited to the ledger");
        assertEq(nvda.balanceOf(bob), ACTOR_SHARES + 3.75e16);

        vm.clearMockedCalls();
        address[] memory retry = new address[](1);
        retry[0] = mm;
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, retry), 1, "and is redeemed on a later batch");
        assertEq(ch.balanceOf(mm, callId), 0);
    }

    function test_redeemBatch_idLevelReverts() public {
        address[] memory holders = _list3(bob, carol, mm);
        uint256 unsettled = _call(K_220, FRI_2026_09_11 + 7 days + 7 days); // FRI 2026-09-25: not expired
        vm.expectRevert(V2Errors.NotSettled.selector);
        ch.redeemBatch(unsettled, holders);
        vm.expectRevert(V2Errors.NotSettled.selector);
        ch.redeemBatch(_short(unsettled), holders);
        uint256 unknown = ch.longIdOf(address(tsla), false, K_220, FRI_2026_09_18);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.redeemBatch(unknown, holders);
    }

    function test_redeemBatch_emptyAndLogOperator() public {
        vm.prank(keeper);
        assertEq(ch.redeemBatch(callId, new address[](0)), 0);

        address[] memory one = new address[](1);
        one[0] = carol;
        vm.recordLogs();
        vm.prank(keeper);
        ch.redeemBatch(callId, one);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], TRANSFER_SINGLE);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(ch), "operator is the Clearinghouse in a batch");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), carol);
    }

    function test_gas_redeemBatch() public {
        vm.prank(admin);
        ch.setKeeperRewards(address(0));
        address[] memory holders = _list3(bob, carol, mm);
        vm.prank(keeper);
        uint256 g = gasleft();
        ch.redeemBatch(callId, holders);
        g -= gasleft();
        console2.log("gas: redeemBatch of 3 call longs in kind, no bounty", g);
    }

    function _list3(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }
}
