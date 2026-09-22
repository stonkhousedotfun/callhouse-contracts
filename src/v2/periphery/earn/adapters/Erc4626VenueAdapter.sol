// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Managed} from "../../../access/Managed.sol";
import {IEarnVenueAdapter} from "../../../interfaces/IEarnVenueAdapter.sol";
import {V2Errors} from "../../../interfaces/V2Errors.sol";

/// @title Erc4626VenueAdapter
/// @notice Earn vault venue adapter over a generic ERC-4626 (INTERFACE_VERSION 8, v8 design §8.2). Named for the
///         shape it wraps, not a curator: the 4663 cash venue today is Steakhouse USDG
///         `0xBeEff033F34C046626B8D0A041844C5d1A5409dd` sitting on Morpho Blue
///         `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` (v8-plan/LENDING-RECON-2026-09-19.md:11,29,247). Both are
///         constructor arguments, never compiled in. The canonical Morpho address has no code on 4663 and is not
///         named here.
/// @dev VENUE IS IMMUTABLE. Moving the pointer while this adapter still holds 4626 shares would leave those
///      shares stranded behind a new venue. Redeploy the adapter (EarnVault.setAdapter) instead of a setter.
///
///      PULLS UNDER ALLOWANCE. The vault `forceApprove`s this adapter, then calls {deposit}; this contract
///      `transferFrom`s the caller and pushes into the 4626. Returns are MEASURED as the underlying that left
///      THIS adapter across the venue call (deposit) or the recipient's underlying balance delta (withdraw),
///      never a 4626 return value and never a preview. Deposit is never measured on the venue's balance: a
///      venue that allocates onward in the same call (the live 4663 venue does) leaves that balance unchanged.
///
///      ROUNDING IS AGAINST THIS ADAPTER. {totalAssets} uses `convertToAssets` (floor). {withdraw} caps to
///      {IERC4626.maxWithdraw} then reports what the recipient actually received. A leftover from a failed or
///      partial 4626 deposit is returned to the caller so it cannot inflate the vault's idle balance.
///
///      {withdrawable} is a single `maxWithdraw(address(this))` staticcall so it fits the book's
///      `V2Constants.FUNDABLE_READ_GAS` budget. It must not consult a preview or a nominal worth.
///
///      ONLY THE OWNING VAULT MOVES MONEY. {deposit} and {withdraw} are gated on `vault`, an immutable set at
///      construction, and NOT on a `restricted` role. That is deliberate and it is the narrower guarantee of the
///      two. {withdraw} takes a caller-supplied recipient, so a role-gated version would still let any holder of
///      that role call `withdraw(max, attacker)` -- and every delay-0 role in `V8Roles` is a hot key. Gating on a
///      role would turn anyone-can-drain into hot-key-can-drain; gating on the vault removes the drain. The vault
///      is the only legitimate caller in the tree (`EarnVault.sweepToVenue` -> {deposit}, `EarnVault.pullFromVenue`
///      -> {withdraw}) and it always passes `address(this)` as the recipient.
///
///      The recipient parameter STAYS. Hardcoding it would read as safe to the next reviewer while leaving the
///      function callable by anyone, which is the missing authorisation dressed up as a fix.
contract Erc4626VenueAdapter is IEarnVenueAdapter, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;
    IERC4626 private immutable _venue;

    /// @notice The EarnVault this adapter serves. Immutable: the authorisation must not be re-pointable by
    ///         anyone who can already call a setter, and there is no setter for the same reason `venue` has none.
    address public immutable vault;

    /// @dev The whole authorisation. Anchored to immutable state, never to a caller argument.
    modifier onlyVault() {
        if (msg.sender != vault) revert V2Errors.NotAuthorized();
        _;
    }

    constructor(address authority_, address asset_, address venue_, address vault_) Managed(authority_) {
        if (asset_.code.length == 0 || venue_.code.length == 0) revert V2Errors.NoSource();
        if (IERC4626(venue_).asset() != asset_) revert V2Errors.UnsupportedAsset();
        // A zero vault would make every deposit and withdraw unreachable rather than unguarded: fail closed, loudly.
        if (vault_ == address(0)) revert V2Errors.NotAuthorized();
        _asset = IERC20(asset_);
        _venue = IERC4626(venue_);
        vault = vault_;
    }

    /// @inheritdoc IEarnVenueAdapter
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @notice The ERC-4626 this adapter deposits into. Immutable; see the contract NatSpec.
    function venue() external view returns (address) {
        return address(_venue);
    }

    /// @inheritdoc IEarnVenueAdapter
    function deposit(uint256 assets) external nonReentrant onlyVault returns (uint256 deposited) {
        deposited = _depositIntoVenue(assets);
    }

    /// @inheritdoc IEarnVenueAdapter
    function withdraw(uint256 assets, address to) external nonReentrant onlyVault returns (uint256 withdrawn) {
        withdrawn = _withdrawFromVenue(assets, to);
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev One IERC4626.maxWithdraw staticcall. Do not add reads.
    function withdrawable() public view virtual returns (uint256) {
        return _venue.maxWithdraw(address(this));
    }

    /// @inheritdoc IEarnVenueAdapter
    /// @dev Floor conversion of our share balance. Over-reporting here would overpay a later redeem.
    function totalAssets() public view virtual returns (uint256) {
        return _venue.convertToAssets(_venue.balanceOf(address(this)));
    }

    function _depositIntoVenue(uint256 assets) internal virtual returns (uint256 deposited) {
        if (assets == 0) return 0;
        uint256 before = _asset.balanceOf(address(this));
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 got = _asset.balanceOf(address(this)) - before;
        if (got == 0) return 0;

        // MEASURED ON THIS ADAPTER'S OWN BALANCE, NEVER THE VENUE'S (T-OP-008). A venue is free to do anything
        // with what it takes: the live Steakhouse vault on 4663 allocates a deposit onward to Morpho Blue inside
        // the same call, so its own asset balance ends where it started and a venue-balance delta read 0 for a
        // deposit that fully succeeded. What left THIS contract does not depend on where the venue puts it. For a
        // venue that holds part and allocates part, it is still the whole amount taken; a venue fee is charged
        // inside the venue after the take and shows in {totalAssets}, not here. `held` includes any stray balance
        // that was here before the pull, so a donation is never reported as deposited, and a venue that hands
        // tokens back during the call can only lower the figure, never underflow it.
        uint256 held = before + got;
        _asset.forceApprove(address(_venue), got);
        try _venue.deposit(got, address(this)) {} catch {}
        _asset.forceApprove(address(_venue), 0);

        uint256 remaining = _asset.balanceOf(address(this));
        uint256 left = remaining < held ? held - remaining : 0;
        deposited = left > got ? got : left;
        // Refunded to the vault, not to `msg.sender`. Identical today because {deposit} is vault-only, and it
        // stays correct if that ever loosens: this adapter holds no float of its own, so any leftover is the
        // vault's money and a refund keyed on the caller would be a way to route it elsewhere.
        uint256 leftover = _asset.balanceOf(address(this));
        if (leftover != 0) _asset.safeTransfer(vault, leftover);
    }

    function _withdrawFromVenue(uint256 assets, address to) internal virtual returns (uint256 withdrawn) {
        if (assets == 0 || to == address(0)) return 0;
        uint256 can = _venue.maxWithdraw(address(this));
        uint256 ask = assets > can ? can : assets;
        if (ask == 0) return 0;
        uint256 toBefore = _asset.balanceOf(to);
        try _venue.withdraw(ask, to, address(this)) {}
        catch {
            return 0;
        }
        withdrawn = _asset.balanceOf(to) - toBefore;
    }
}
