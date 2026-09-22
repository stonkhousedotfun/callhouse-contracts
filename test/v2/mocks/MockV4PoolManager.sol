// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPonsLaunchHook, V4PoolKey, V4SwapParams} from "../../../src/v2/periphery/BuybackDeps.sol";

/// @notice The unlock callback a v4 PoolManager makes on whoever called `unlock`.
interface IMockUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IInFlightUnlockAttacker {
    function hitUnlock(address exec, bytes calldata data) external;
}

/// @notice A mintable ERC-20 (MockERC20's `mint`), which this mock uses to pay a swap's output.
interface IMockMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice A Uniswap v4 PoolManager stand-in for the V4BuybackExecutor suites: the lock, one exact-input
///         ETH -> token swap per pool id, the hook's afterSwap cut, and sync / settle / take.
/// @dev Fee model per swap, in the order the live venue charges them:
///        1. the PoolManager protocol fee and the pool's LP fee come off the ETH INPUT, in pips;
///        2. `gross = ethAfterFees * tokensPerEth / 1e18`;
///        3. the hook takes `hookFeeBps + creatorTaxBps` of the gross OUTPUT, read from the key's hook so the
///           declared terms and the charged terms agree by construction, plus {extraCutBps}, which is charged but
///           NOT declared anywhere — that is how a test drives the executor's measured-total guard apart from its
///           declared one.
///      The returned `BalanceDelta` is already net of the hook's cut, as v4-core's is: `amount0` (ETH, negative) in
///      the upper 128 bits and `amount1` (token, positive) in the lower.
///
///      LOCK. {unlock} calls `unlockCallback` back on its caller and records the caller for the duration; {swap},
///      {settle} and {take} refuse outside it. {pokeUnlockCallback} deliberately breaks that rule: it calls a
///      target's `unlockCallback` with no lock at all, which is how the suite proves the executor refuses its own
///      callback when no buy is on the stack.
contract MockV4PoolManager {
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
    }

    /// @notice Token base units bought per 1e18 wei of ETH, before any fee.
    uint256 public tokensPerEth;
    /// @notice A cut the hook takes on top of its declared terms. Charged, never declared.
    uint16 public extraCutBps;
    /// @notice Where the output cut is minted. Zero means `key.hooks` (the live shape). A third address makes the
    ///         executor's measured hook-balance delta 0 so the DECLARED fee-cap check is the only bound.
    address public cutRecipient;
    /// @notice Whoever holds the lock right now; zero outside {unlock}.
    address public unlocker;
    /// @notice Set by {sync} for the currency of the next {settle}.
    address public syncedCurrency;
    /// @notice Whether {sync} was called for the open lock; {settle} refuses without it, as v4-core does.
    bool public synced;
    uint256 public swaps;

    mapping(bytes32 poolId => Slot0) internal _slot0;
    mapping(bytes32 poolId => uint128) internal _liquidity;
    /// @dev What the locker still owes (ETH) and may still take (token) in the open lock.
    uint256 internal _ethOwed;
    uint256 internal _tokenOwed;

    error MockNotUnlocked();
    error MockAlreadyUnlocked();
    error MockNotSynced();
    error MockCurrencyNotSettled();
    error MockExactOutputNotSupported();
    error MockTakeTooMuch(uint256 amount, uint256 owed);
    error MockSettleMismatch(uint256 paid, uint256 owed);

    function setPool(V4PoolKey calldata key, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        external
    {
        bytes32 poolId = keccak256(abi.encode(key));
        _slot0[poolId] = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: protocolFee, lpFee: lpFee});
    }

    function setLiquidity(bytes32 poolId, uint128 liquidity) external {
        _liquidity[poolId] = liquidity;
    }

    function setPrice(uint256 tokensPerEth_) external {
        tokensPerEth = tokensPerEth_;
    }

    function setExtraCutBps(uint16 bps) external {
        extraCutBps = bps;
    }

    function setCutRecipient(address to) external {
        cutRecipient = to;
    }

    /// @notice If set, {swap} asks this attacker to call the executor's unlockCallback as a stranger while the
    ///         buy (and the lock) are on the stack.
    address public inFlightUnlockAttacker;

    function setInFlightUnlockAttacker(address attacker) external {
        inFlightUnlockAttacker = attacker;
    }

    /// @notice The packed pool state {MockV4StateView} serves.
    function slot0Of(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0 memory s = _slot0[poolId];
        return (s.sqrtPriceX96, s.tick, s.protocolFee, s.lpFee);
    }

    function liquidityOf(bytes32 poolId) external view returns (uint128) {
        return _liquidity[poolId];
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocker != address(0)) revert MockAlreadyUnlocked();
        unlocker = msg.sender;
        result = IMockUnlockCallback(msg.sender).unlockCallback(data);
        if (_ethOwed != 0 || _tokenOwed != 0) revert MockCurrencyNotSettled();
        unlocker = address(0);
        syncedCurrency = address(0);
        synced = false;
    }

    /// @notice Calls `unlockCallback` on `target` with NO lock open, to prove a callee's own in-flight check.
    function pokeUnlockCallback(address target, bytes calldata data) external returns (bytes memory) {
        return IMockUnlockCallback(target).unlockCallback(data);
    }

    /*//////////////////////////////////////////////////////////////
                                  SWAP
    //////////////////////////////////////////////////////////////*/

    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata) external returns (int256) {
        if (unlocker != msg.sender) revert MockNotUnlocked();
        if (inFlightUnlockAttacker != address(0)) {
            IInFlightUnlockAttacker(inFlightUnlockAttacker).hitUnlock(unlocker, abi.encode(uint256(1)));
        }
        if (params.amountSpecified >= 0) revert MockExactOutputNotSupported();
        bytes32 poolId = keccak256(abi.encode(key));
        uint256 ethIn = uint256(-params.amountSpecified);
        ++swaps;

        Slot0 memory s = _slot0[poolId];
        uint256 pips = params.zeroForOne ? uint256(s.protocolFee & 0xFFF) : uint256(s.protocolFee >> 12);
        uint256 afterFees = ethIn - (ethIn * pips / 1_000_000);
        afterFees -= afterFees * uint256(s.lpFee) / 1_000_000;
        uint256 gross = afterFees * tokensPerEth / 1e18;

        (,,,,,,, uint16 creatorTaxBps,,, uint16 hookFeeBps,,) = IPonsLaunchHook(key.hooks).launches(poolId);
        uint256 cut = gross * (uint256(hookFeeBps) + creatorTaxBps + extraCutBps) / 10_000;
        uint256 net = gross - cut;
        address payCut = cutRecipient == address(0) ? key.hooks : cutRecipient;
        if (cut != 0) IMockMintable(key.currency1).mint(payCut, cut);
        IMockMintable(key.currency1).mint(address(this), net);

        _ethOwed = ethIn;
        _tokenOwed = net;
        // casting to 'int128' is safe for every amount a test configures
        return int256((uint256(uint128(-int128(uint128(ethIn)))) << 128) | uint256(uint128(net)));
    }

    /*//////////////////////////////////////////////////////////////
                           SETTLE AND TAKE
    //////////////////////////////////////////////////////////////*/

    function sync(address currency) external {
        if (unlocker != msg.sender) revert MockNotUnlocked();
        syncedCurrency = currency;
        synced = true;
    }

    function settle() external payable returns (uint256 paid) {
        if (unlocker != msg.sender) revert MockNotUnlocked();
        if (!synced || syncedCurrency != address(0)) revert MockNotSynced();
        if (msg.value != _ethOwed) revert MockSettleMismatch(msg.value, _ethOwed);
        paid = msg.value;
        _ethOwed = 0;
        synced = false;
    }

    function take(address currency, address to, uint256 amount) external {
        if (unlocker != msg.sender) revert MockNotUnlocked();
        if (amount > _tokenOwed) revert MockTakeTooMuch(amount, _tokenOwed);
        _tokenOwed -= amount;
        IERC20(currency).transfer(to, amount);
    }

    receive() external payable {}
}
