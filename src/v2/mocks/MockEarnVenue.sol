// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEarnVenueAdapter} from "../interfaces/IEarnVenueAdapter.sol";

/// @title MockEarnVenue
/// @notice Test double for {IEarnVenueAdapter}: a venue whose assets held, NOMINAL report and ABILITY TO PAY are
///         independently controllable.
/// @dev THAT SEPARATION IS THE WHOLE POINT OF THIS DOUBLE. {totalAssets} normally answers {held}, but
///      {nominalBlind} can hide that number without moving the assets. {withdrawable} answers {held} unless the
///      venue is {frozen} or capped, in which case it answers less -- down to zero while {totalAssets} is still
///      large. A vault that derived `fundable` from a nominal figure passes every test written against a venue
///      that always pays, and fails exactly here (T-103 AC-5).
///
///      NOT AN ERC-4626 MOCK. It issues no shares and has no preview functions on purpose: the seam this stands in
///      for is five functions wide and a share token would invite the vault to price itself off one.
///
///      A LOSS IS A REAL LOSS. {loseAssets} both lowers {held} and moves the tokens out to {SINK}, so a test cannot
///      accidentally prove solvency out of tokens that are still sitting here.
contract MockEarnVenue is IEarnVenueAdapter {
    using SafeERC20 for IERC20;

    /// @dev Where {loseAssets} sends the tokens. A plain burn address; ERC-20s refuse `address(0)`.
    address public constant SINK = address(0xdead);

    IERC20 private immutable _token;

    /// @notice Base units this venue actually holds. {totalAssets} reports it unless {nominalBlind} is set.
    uint256 public held;
    /// @notice When true, {totalAssets} reports 0 without changing {held}, token custody or liquidity.
    bool public nominalBlind;
    /// @notice Venue freeze: {withdrawable} answers 0 while this is true, whatever {held} says.
    bool public frozen;
    /// @notice Utilisation cap: {withdrawable} is clamped to this. `type(uint256).max` (the default) means no cap.
    uint256 public withdrawableCap;
    /// @notice Most this venue will take in one {deposit}; the rest is refused, which the vault must MEASURE rather
    ///         than assume. `type(uint256).max` (the default) means no cap.
    uint256 public depositCap;

    /// @dev SEC-30: the vault this venue claims to belong to, or zero to answer whoever asks. {EarnVault.setAdapter}
    ///      probes `vault()` and refuses an adapter that names a DIFFERENT vault, so a double that answered a fixed
    ///      address would have to be constructed with the vault's address -- and this venue is constructed before
    ///      the vault in several suites, some of which are outside this row's scope. Answering the CALLER by default
    ///      keeps every existing wiring working unchanged; {setVault} pins it to a specific address so the refusal
    ///      itself can be tested. A real adapter's `vault` is immutable and cannot do either.
    address private _vaultOverride;

    constructor(IERC20 token_) {
        _token = token_;
        withdrawableCap = type(uint256).max;
        depositCap = type(uint256).max;
    }

    /// @notice Pin the vault this venue claims to belong to. Zero restores "answer whoever asks".
    function setVault(address vault_) external {
        _vaultOverride = vault_;
    }

    /// @notice SEC-30: what {EarnVault.setAdapter} probes. Defaults to the caller.
    function vault() external view returns (address) {
        return _vaultOverride == address(0) ? msg.sender : _vaultOverride;
    }

    /*//////////////////////////////////////////////////////////////
                              TEST CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Freeze or unfreeze the venue. Frozen means {withdrawable} is 0 and {withdraw} pays nothing.
    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    /// @notice Hide or reveal the nominal report without moving assets or changing what the venue can pay.
    function setNominalBlind(bool blind_) external {
        nominalBlind = blind_;
    }

    /// @notice Clamp {withdrawable} to `cap`, standing in for a lending venue at high utilisation.
    function setWithdrawableCap(uint256 cap) external {
        withdrawableCap = cap;
    }

    /// @notice Refuse anything above `cap` in one {deposit}.
    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }

    /// @notice Venue bad debt: `amount` base units stop being held AND leave this contract for {SINK}.
    function loseAssets(uint256 amount) external {
        held -= amount;
        _token.safeTransfer(SINK, amount);
    }

    /// @notice Venue yield: the caller pays `amount` base units in and they become part of the position.
    function addYield(uint256 amount) external {
        _token.safeTransferFrom(msg.sender, address(this), amount);
        held += amount;
    }

    /*//////////////////////////////////////////////////////////////
                          IEarnVenueAdapter
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEarnVenueAdapter
    function asset() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev PULLS UNDER AN ALLOWANCE (the caller approves this contract), and credits the MEASURED delta. Takes at
    ///      most {depositCap}, so `deposited < assets` is a normal answer and not an error.
    function deposit(uint256 assets) external returns (uint256 deposited) {
        uint256 take = assets > depositCap ? depositCap : assets;
        if (take == 0) return 0;
        uint256 before = _token.balanceOf(address(this));
        _token.safeTransferFrom(msg.sender, address(this), take);
        deposited = _token.balanceOf(address(this)) - before;
        held += deposited;
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev NEVER REVERTS ON UNDER-DELIVERY, as the interface requires: it pays what {withdrawable} says it can and
    ///      returns that, which may be 0.
    function withdraw(uint256 assets, address to) external returns (uint256 withdrawn) {
        uint256 can = _withdrawable();
        withdrawn = assets > can ? can : assets;
        if (withdrawn == 0) return 0;
        held -= withdrawn;
        _token.safeTransfer(to, withdrawn);
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev Three storage reads and a balance call, well inside `V2Constants.FUNDABLE_READ_GAS`.
    function withdrawable() external view returns (uint256) {
        return _withdrawable();
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev THE NOMINAL NUMBER. {nominalBlind} can hide it independently from {frozen} and {withdrawableCap}, so
    ///      the double can model both a truthful-but-illiquid venue and a venue whose report hides held assets.
    function totalAssets() external view returns (uint256) {
        return nominalBlind ? 0 : held;
    }

    function _withdrawable() private view returns (uint256) {
        if (frozen) return 0;
        uint256 w = held;
        uint256 cap = withdrawableCap;
        if (w > cap) w = cap;
        uint256 bal = _token.balanceOf(address(this));
        return w > bal ? bal : w;
    }
}
