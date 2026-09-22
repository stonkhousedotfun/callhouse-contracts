// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V4Buy} from "../../../src/v2/periphery/v4/V4Buy.sol";
import {V4Currency} from "../../../src/v2/periphery/v4/V4Types.sol";
import {V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";
import {V2Constants} from "../../../src/v2/interfaces/V2Constants.sol";
import {V2Errors} from "../../../src/v2/interfaces/V2Errors.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Exact-input ERC-20 PoolManager double declared in this file (coordinator: no third file;
///      AC forbids a second mock *file*). 1:1 quote, both v4 sort directions, hookless.
contract V4BuyPoolManagerStub {
    address public unlocker;

    /// @notice The `zeroForOne` the last {swap} was ACTUALLY asked for, and whether any swap recorded one.
    /// @dev T-CV-OTHER-CONTRACTS. Before this, nothing in the suite could see a reversed swap direction:
    ///      the two direction cases asserted {V4Currency.zeroForOne} DIRECTLY, which exercises the library
    ///      rather than what {V4Buy._onUnlock} hands it, and the 1:1 quote makes both orderings return the
    ///      same magnitudes. Flipping `V4Buy.sol:91` to `zeroForOne(k, asset)` therefore left all 8 tests
    ///      green. Recording the flag here makes the CALLER's choice observable.
    ///      `lastZeroForOneSet` exists so an UNRECORDED direction cannot read as `false` and satisfy the
    ///      `oneForZero` assertion vacuously -- assert the flag before trusting the value.
    bool public lastZeroForOne;
    bool public lastZeroForOneSet;

    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlocker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        unlocker = address(0);
    }

    function swap(V4PoolKey memory, V4SwapParams memory params, bytes calldata) external returns (int256 swapDelta) {
        lastZeroForOne = params.zeroForOne;
        lastZeroForOneSet = true;
        uint256 paid = uint256(-params.amountSpecified);
        uint256 taken = paid;
        if (params.zeroForOne) {
            return int256((uint256(uint128(-int128(uint128(paid)))) << 128) | uint256(uint128(taken)));
        }
        return int256((uint256(uint128(taken)) << 128) | uint256(uint128(-int128(uint128(paid)))));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).transfer(to, amount);
    }
}

/// @dev Concrete {V4Buy} so the abstract base can be exercised without a new `src/` file.
contract V4BuyHarness is V4Buy {
    constructor(address poolManager_, address usdg_) V4Buy(poolManager_, usdg_) {}

    function buy(address asset, uint256 amountIn, uint256 minOut, address to, uint24 fee, int24 tickSpacing)
        external
        returns (uint256)
    {
        return _buyExactInput(asset, amountIn, minOut, to, fee, tickSpacing);
    }
}

contract V4BuyTest is Test {
    V4BuyPoolManagerStub internal pm;
    MockERC20 internal usdg;
    MockERC20 internal assetHi;
    MockERC20 internal assetLo;
    V4BuyHarness internal buy;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK = 60;
    uint256 internal constant AMOUNT = 1e6;

    function setUp() public {
        pm = new V4BuyPoolManagerStub();
        usdg = new MockERC20("USDG", "USDG", 6);
        assetHi = new MockERC20("NVDA", "NVDA", 18);
        while (uint160(address(assetHi)) <= uint160(address(usdg))) {
            assetHi = new MockERC20("NVDA", "NVDA", 18);
        }
        assetLo = new MockERC20("LO", "LO", 18);
        while (uint160(address(assetLo)) >= uint160(address(usdg))) {
            assetLo = new MockERC20("LO", "LO", 18);
        }
        buy = new V4BuyHarness(address(pm), address(usdg));
        assetHi.mint(address(pm), 1_000e18);
        assetLo.mint(address(pm), 1_000e18);
        // F-CP-05: {V4Buy._buyExactInput} spends the CONTRACT'S OWN balance rather than pulling from msg.sender,
        // so the harness is funded, not `alice`. Alice keeps her approval only so the refusal tests below still
        // prove that an approved caller with a funded wallet gets nothing extra from it -- the money that moves is
        // the contract's.
        usdg.mint(address(buy), 1_000e6);
        usdg.mint(alice, 1_000e6);
        vm.prank(alice);
        usdg.approve(address(buy), type(uint256).max);
    }

    function test_buy_zeroForOne_recipientDeltaAndHarnessEmpty() public {
        assertTrue(V4Currency.zeroForOne(V4Currency.key(address(assetHi), address(usdg), FEE, TICK), address(usdg)));
        uint256 usdgBefore = usdg.balanceOf(address(buy));
        uint256 assetBefore = assetHi.balanceOf(address(buy));
        uint256 bobBefore = assetHi.balanceOf(bob);

        vm.prank(alice);
        uint256 out = buy.buy(address(assetHi), AMOUNT, 1, bob, FEE, TICK);

        assertEq(out, AMOUNT, "1:1 stub quote");
        assertEq(assetHi.balanceOf(bob) - bobBefore, out, "minOut is the recipient delta");
        // F-CP-05 MOVED THE PROTECTED FACT. It used to be "the contract's USDG is unchanged", which held because
        // the contract pulled exactly what it spent from the CALLER. Now the contract spends its OWN balance, so the
        // fact worth protecting is that it spends EXACTLY the amount asked for and keeps no stock -- an over-spend
        // is the failure this guards, and an unchanged balance would now mean the swap never happened.
        assertEq(usdg.balanceOf(address(buy)), usdgBefore - AMOUNT, "spent exactly amountIn of its own USDG");
        assertEq(assetHi.balanceOf(address(buy)), assetBefore, "keeps no stock; it all goes to the recipient");
        // And the caller pays NOTHING, which is the whole point of the finding: the hot key stopped funding it.
        assertEq(usdg.balanceOf(alice), 1_000e6, "the caller's wallet is untouched");
        // THE DIRECTION V4Buy ACTUALLY REQUESTED, not the one the library computes. The assertion above at the
        // top of this test reads V4Currency directly and stays green if `_onUnlock` passes the wrong currency.
        assertTrue(pm.lastZeroForOneSet(), "no swap recorded a direction -- the assertion below would be vacuous");
        assertTrue(pm.lastZeroForOne(), "V4Buy must sell USDG as currency0 on a high-sorting asset");
    }

    function test_buy_oneForZero_priceLimitOtherExtreme() public {
        assertFalse(V4Currency.zeroForOne(V4Currency.key(address(assetLo), address(usdg), FEE, TICK), address(usdg)));
        uint256 bobBefore = assetLo.balanceOf(bob);
        vm.prank(alice);
        uint256 out = buy.buy(address(assetLo), AMOUNT, 1, bob, FEE, TICK);
        assertEq(out, AMOUNT);
        assertEq(assetLo.balanceOf(bob) - bobBefore, out);
        assertEq(usdg.balanceOf(address(buy)), 1_000e6 - AMOUNT, "spent exactly amountIn of its own USDG");
        assertEq(assetLo.balanceOf(address(buy)), 0, "keeps no stock");
        assertTrue(pm.lastZeroForOneSet(), "no swap recorded a direction -- the assertion below would be vacuous");
        assertFalse(pm.lastZeroForOne(), "V4Buy must sell USDG as currency1 on a low-sorting asset");
    }

    function test_buy_minOutEnforcedOnRecipientDelta() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        buy.buy(address(assetHi), AMOUNT, AMOUNT + 1, bob, FEE, TICK);
    }

    function test_buy_minOutZeroRevertsBadPrice() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadPrice.selector);
        buy.buy(address(assetHi), AMOUNT, 0, bob, FEE, TICK);
    }

    function test_buy_dynamicFeeFlagRejected() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.RouteRejected.selector, keccak256("DYNAMIC_FEE")));
        buy.buy(address(assetHi), AMOUNT, 1, bob, FEE | 0x800000, TICK);
    }

    function test_buy_feeAboveMaxRouteFeeTierRejected() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.RouteRejected.selector, keccak256("FEE_TIER")));
        buy.buy(address(assetHi), AMOUNT, 1, bob, V2Constants.MAX_ROUTE_FEE_TIER + 1, TICK);
    }

    function test_buy_zeroAmountRevertsBadUnits() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.BadUnits.selector);
        buy.buy(address(assetHi), 0, 1, bob, FEE, TICK);
    }

    function test_buy_assetIsUsdgReverts() public {
        vm.prank(alice);
        vm.expectRevert(V2Errors.UnsupportedAsset.selector);
        buy.buy(address(usdg), AMOUNT, 1, bob, FEE, TICK);
    }
}
