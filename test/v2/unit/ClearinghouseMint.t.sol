// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ClearinghouseTestBase, ClearinghouseTestReceiver} from "./ClearinghouseBase.t.sol";
import {IClearinghouse} from "../../../src/v2/interfaces/IClearinghouse.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {V2Types} from "../../../src/v2/interfaces/V2Types.sol";

/// @notice Clearinghouse mint, close and ERC-1155 transfers: collateral movement, cutoff, pauses, operators, the §1.8
///         log order, acceptance callbacks and receiver reentrancy, and the mint gas target.
contract ClearinghouseMintTest is ClearinghouseTestBase {
    bytes32 internal constant TRANSFER_SINGLE = keccak256("TransferSingle(address,address,address,uint256,uint256)");
    bytes32 internal constant TRANSFER_BATCH = keccak256("TransferBatch(address,address,address,uint256[],uint256[])");

    uint256 internal callId;
    uint256 internal putId;

    function setUp() public override {
        super.setUp();
        callId = _call(K_240, FRI_2026_09_18);
        putId = _put(K_200, FRI_2026_09_18);
    }

    /*//////////////////////////////////////////////////////////////
                                   MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_callMovesCollateral() public {
        _deposit(alice, address(nvda), 2e18);
        uint256 chBalance = nvda.balanceOf(address(ch));

        vm.expectEmit(true, true, true, true, address(ch));
        emit IClearinghouse.Minted(callId, alice, bob, 150, 150e16, 0);
        vm.prank(alice);
        ch.mint(callId, 150, alice, bob);

        assertEq(ch.free(alice, address(nvda)), 2e18 - 150e16, "free down by units * UNIT");
        assertEq(ch.locked(callId), 150e16, "locked up by the same");
        assertEq(nvda.balanceOf(address(ch)), chBalance, "no token moves on mint");
        assertEq(ch.balanceOf(bob, callId), 150, "longs to longTo");
        assertEq(ch.balanceOf(alice, _short(callId)), 150, "shorts to the writer");
        assertEq(ch.balanceOf(alice, callId), 0);
        assertEq(ch.totalSupply(callId), 150);
        assertEq(ch.totalSupply(_short(callId)), 150);
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 150);
        _assertBacked(callId);
    }

    function test_mint_putLocksStrikeOver100Usdg() public {
        _deposit(alice, address(usdg), 1_000e6);
        vm.prank(alice);
        ch.mint(putId, 37, alice, alice);
        assertEq(ch.locked(putId), 37 * (K_200 / 100), "37 units * 2.00 USDG");
        assertEq(ch.free(alice, address(usdg)), 1_000e6 - 74e6);
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 37);
        _assertBacked(putId);
    }

    function test_mint_fractionalSingleUnit() public {
        _write(alice, callId, 1, bob);
        assertEq(ch.locked(callId), 1e16, "0.01 share");
        _write(alice, putId, 1, bob);
        assertEq(ch.locked(putId), 2_000_000, "2.00 USDG for a 200 strike");
        assertEq(ch.balanceOf(bob, callId), 1);
        assertEq(ch.balanceOf(bob, putId), 1);
    }

    function test_mint_openInterestSumsSeriesOfOneExpiry() public {
        _write(alice, callId, 10, bob);
        _write(carol, putId, 7, bob);
        uint256 other = _call(K_220, FRI_2026_09_11);
        _write(carol, other, 5, bob);
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 17);
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_11), 5);
        assertEq(ch.openInterest(address(tsla), FRI_2026_09_18), 0);
    }

    /// @dev 02-interfaces §1.8: TransferSingle(long -> longTo), TransferSingle(short -> writer), Minted. Nothing else,
    ///      never TransferBatch.
    function test_mint_logOrder() public {
        _deposit(alice, address(nvda), 1e18);
        vm.prank(alice);
        ch.setOperator(mm, true);

        vm.recordLogs();
        vm.prank(mm);
        ch.mint(callId, 5, alice, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 3, "exactly three logs");
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(ch));
            assertTrue(logs[i].topics[0] != TRANSFER_BATCH, "no TransferBatch");
        }
        _assertTransferSingle(logs[0], mm, address(0), bob, callId, 5);
        _assertTransferSingle(logs[1], mm, address(0), alice, _short(callId), 5);
        assertEq(logs[2].topics[0], IClearinghouse.Minted.selector);
        assertEq(uint256(logs[2].topics[1]), callId);
        assertEq(address(uint160(uint256(logs[2].topics[2]))), alice, "writer");
        assertEq(address(uint160(uint256(logs[2].topics[3]))), bob, "longTo");
        (uint64 units, uint256 collateral) = abi.decode(logs[2].data, (uint64, uint256));
        assertEq(units, 5);
        assertEq(collateral, 5e16);
    }

    function test_mint_cutoff() public {
        _deposit(alice, address(nvda), 1e18);
        uint40 cutoff = ch.mintCutoff(callId);

        vm.warp(cutoff - 1);
        vm.prank(alice);
        ch.mint(callId, 1, alice, alice);

        vm.warp(cutoff);
        vm.prank(alice);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        ch.mint(callId, 1, alice, alice);

        vm.warp(FRI_2026_09_18 + 1 days);
        vm.prank(alice);
        vm.expectRevert(V2Errors.PastCutoff.selector);
        ch.mint(callId, 1, alice, alice);
    }

    function test_mint_pausedAndDisabled() public {
        _deposit(alice, address(nvda), 1e18);
        vm.prank(guardian);
        ch.setMintPaused(address(nvda), true);
        vm.prank(alice);
        vm.expectRevert(V2Errors.MintPaused.selector);
        ch.mint(callId, 1, alice, alice);

        vm.prank(guardian);
        ch.setMintPaused(address(nvda), false);
        vm.prank(guardian);
        ch.setCreatePaused(true);
        vm.prank(alice);
        ch.mint(callId, 1, alice, alice); // creation pause does not stop mints of existing series

        V2Types.MarketConfig memory off = _cfg(address(oracle));
        off.enabled = false;
        vm.prank(admin);
        ch.setMarketConfig(address(nvda), off);
        vm.prank(alice);
        vm.expectRevert(V2Errors.MarketDisabled.selector);
        ch.mint(callId, 1, alice, alice);
    }

    function test_mint_inputChecks() public {
        _deposit(alice, address(nvda), 1e18);

        vm.prank(bob);
        vm.expectRevert(V2Errors.NotAuthorized.selector);
        ch.mint(callId, 1, alice, bob);

        vm.prank(alice);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.mint(_short(callId), 1, alice, alice);

        vm.prank(alice);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.mint(12_345, 1, alice, alice);

        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        ch.mint(callId, 0, alice, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0)));
        ch.mint(callId, 1, alice, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 1e18, 101e16));
        ch.mint(callId, 101, alice, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.InsufficientCollateral.selector, 0, 2_000_000));
        ch.mint(putId, 1, alice, alice);
    }

    function test_mint_receiverContractAcceptsOrRejects() public {
        ClearinghouseTestReceiver receiver = new ClearinghouseTestReceiver();
        _write(alice, callId, 3, address(receiver));
        assertEq(ch.balanceOf(address(receiver), callId), 3);

        receiver.setReject(true);
        _deposit(alice, address(nvda), 1e16);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(receiver)));
        ch.mint(callId, 1, alice, address(receiver));
    }

    /// @dev "State first, ERC-1155 acceptance callbacks last": inside the long receiver's hook the short is already
    ///      minted and the collateral already locked.
    function test_mint_callbacksRunAfterAllState() public {
        ClearinghouseTestReceiver receiver = new ClearinghouseTestReceiver();
        receiver.setAttack(address(ch), abi.encodeCall(ch.balanceOf, (alice, _short(callId))), false);
        _write(alice, callId, 4, address(receiver));
        assertTrue(receiver.succeeded(), "a view is readable from the hook");
        assertEq(abi.decode(receiver.revertData(), (uint256)), 4, "short already minted when the long hook runs");
    }

    /// @dev Every state-changing entry point, called back from the long receiver's hook during mint, hits the guard.
    function test_mint_receiverReentrancyIsBlocked() public {
        _deposit(alice, address(nvda), 10e18);
        _deposit(alice, address(usdg), 1_000e6);
        bytes[10] memory attacks;
        ClearinghouseTestReceiver probe = new ClearinghouseTestReceiver();
        attacks[0] = abi.encodeCall(ch.close, (callId, 1));
        attacks[1] = abi.encodeCall(ch.mint, (callId, 1, address(probe), address(probe)));
        attacks[2] = abi.encodeCall(ch.withdraw, (address(nvda), 1, address(probe)));
        attacks[3] = abi.encodeCall(ch.redeem, (callId, alice));
        attacks[4] = abi.encodeCall(IERC1155.safeTransferFrom, (address(probe), alice, callId, 1, ""));
        attacks[5] = abi.encodeCall(IERC1155.setApprovalForAll, (alice, true));
        attacks[6] = abi.encodeCall(ch.settle, (callId));
        attacks[7] = abi.encodeCall(ch.createSeries, (address(nvda), false, K_220, FRI_2026_09_18));
        attacks[8] = abi.encodeCall(ch.setOperator, (alice, true));
        attacks[9] = abi.encodeCall(ch.deposit, (address(usdg), 0, address(probe)));

        for (uint256 i; i < attacks.length; ++i) {
            ClearinghouseTestReceiver receiver = new ClearinghouseTestReceiver();
            receiver.setAttack(address(ch), attacks[i], false);
            vm.prank(alice);
            ch.mint(callId, 1, alice, address(receiver));
            assertTrue(receiver.attempted(), "hook ran");
            assertFalse(receiver.succeeded(), "re-entry blocked");
            assertEq(
                bytes4(receiver.revertData()),
                ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                "blocked by the reentrancy guard"
            );
        }

        ClearinghouseTestReceiver loud = new ClearinghouseTestReceiver();
        loud.setAttack(address(ch), attacks[0], true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ch.mint(callId, 1, alice, address(loud));
    }

    /// @dev Gas target: mint <= 200k. Measured on the worst case (fresh series, fresh receiver balances, first ever
    ///      supply) and on a repeat mint.
    function test_gas_mint() public {
        _deposit(alice, address(nvda), 10e18);
        uint256 fresh = _call(K_220, FRI_2026_09_11);

        vm.prank(alice);
        uint256 g = gasleft();
        ch.mint(fresh, 100, alice, bob);
        uint256 first = g - gasleft();

        vm.prank(alice);
        g = gasleft();
        ch.mint(fresh, 100, alice, bob);
        uint256 repeat = g - gasleft();

        vm.prank(alice);
        ch.setOperator(mm, true);
        vm.prank(mm);
        g = gasleft();
        ch.mint(callId, 1, alice, carol);
        uint256 viaOperator = g - gasleft();

        console2.log("gas: mint, fresh series and holders", first);
        console2.log("gas: mint, repeat", repeat);
        console2.log("gas: mint, via operator into a fresh series id", viaOperator);
        assertLe(first, 200_000, "mint <= 200k");
        assertLe(repeat, 200_000);
        assertLe(viaOperator, 200_000);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLOSE
    //////////////////////////////////////////////////////////////*/

    function test_close_partialAndFull() public {
        _write(alice, callId, 100, alice);

        vm.expectEmit(true, true, false, true, address(ch));
        emit IClearinghouse.Closed(callId, alice, 30, 30e16, 0);
        vm.prank(alice);
        ch.close(callId, 30);
        assertEq(ch.free(alice, address(nvda)), 30e16);
        assertEq(ch.locked(callId), 70e16);
        assertEq(ch.balanceOf(alice, callId), 70);
        assertEq(ch.balanceOf(alice, _short(callId)), 70);
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 70);
        _assertBacked(callId);

        vm.prank(alice);
        ch.close(callId, 70);
        assertEq(ch.locked(callId), 0);
        assertEq(ch.totalSupply(callId), 0);
        assertEq(ch.free(alice, address(nvda)), 1e18);

        vm.prank(alice);
        ch.withdraw(address(nvda), 1e18, alice);
        assertEq(nvda.balanceOf(alice), ACTOR_SHARES, "round trip");
    }

    function test_close_put() public {
        _write(carol, putId, 9, carol);
        vm.prank(carol);
        ch.close(putId, 9);
        assertEq(ch.free(carol, address(usdg)), 18e6);
        assertEq(ch.locked(putId), 0);
    }

    function test_close_logOrder() public {
        _write(alice, callId, 10, alice);
        vm.recordLogs();
        vm.prank(alice);
        ch.close(callId, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        _assertTransferSingle(logs[0], alice, alice, address(0), callId, 4);
        _assertTransferSingle(logs[1], alice, alice, address(0), _short(callId), 4);
        assertEq(logs[2].topics[0], IClearinghouse.Closed.selector);
    }

    function test_close_needsBothSides() public {
        _write(alice, callId, 10, bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1, _short(callId))
        );
        ch.close(callId, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 1, callId));
        ch.close(callId, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 0, 11, callId)
        );
        ch.close(callId, 11);
    }

    function test_close_inputChecks() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.UnknownSeries.selector);
        ch.close(_short(callId), 1);
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        ch.close(callId, 0);
    }

    function test_close_afterExpiryUntilSettled() public {
        _write(alice, callId, 10, alice);
        vm.warp(FRI_2026_09_18 + 1 hours);
        vm.prank(alice);
        ch.close(callId, 4);
        assertEq(ch.free(alice, address(nvda)), 4e16, "closing after expiry, before settle, works");

        _settle(callId, 250_000_000);
        vm.prank(alice);
        vm.expectRevert(V2Errors.AlreadySettled.selector);
        ch.close(callId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Longs and shorts move freely; open interest and locked do not change; the new holders are redeemed.
    function test_transfers_thenNewHoldersRedeem() public {
        _write(alice, callId, 100, alice);
        vm.prank(alice);
        ch.safeTransferFrom(alice, bob, callId, 60, "");
        vm.prank(alice);
        ch.safeTransferFrom(alice, carol, _short(callId), 100, "");
        assertEq(ch.openInterest(address(nvda), FRI_2026_09_18), 100, "transfers do not change open interest");
        assertEq(ch.locked(callId), 100e16);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, alice, bob));
        ch.safeTransferFrom(bob, alice, callId, 1, "");

        // Settle out of the money for the calls: longs get nothing, the short holder gets all collateral back.
        _settle(callId, 230_000_000);
        _redeem(callId, bob);
        _redeem(callId, alice);
        (uint256 paid,) = _redeem(_short(callId), carol);
        assertEq(paid, 100e16);
        assertEq(nvda.balanceOf(carol), ACTOR_SHARES + 100e16, "the short's new holder is paid");
        assertEq(ch.locked(callId), 0);
        assertEq(ch.totalSupply(callId), 0);
        assertEq(ch.totalSupply(_short(callId)), 0);
    }

    function test_transfers_batchIsAllowedForHolders() public {
        _write(alice, callId, 10, alice);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        ids[0] = callId;
        ids[1] = _short(callId);
        values[0] = 3;
        values[1] = 4;
        vm.prank(alice);
        ch.safeBatchTransferFrom(alice, bob, ids, values, "");
        assertEq(ch.balanceOf(bob, callId), 3);
        assertEq(ch.balanceOf(bob, _short(callId)), 4);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertTransferSingle(
        Vm.Log memory log,
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 value
    ) internal pure {
        assertEq(log.topics[0], TRANSFER_SINGLE, "TransferSingle");
        assertEq(address(uint160(uint256(log.topics[1]))), operator, "operator");
        assertEq(address(uint160(uint256(log.topics[2]))), from, "from");
        assertEq(address(uint160(uint256(log.topics[3]))), to, "to");
        (uint256 gotId, uint256 gotValue) = abi.decode(log.data, (uint256, uint256));
        assertEq(gotId, id, "id");
        assertEq(gotValue, value, "value");
    }
}
