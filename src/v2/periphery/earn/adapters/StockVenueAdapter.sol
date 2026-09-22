// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Erc4626VenueAdapter} from "./Erc4626VenueAdapter.sol";

/// @title StockVenueAdapter
/// @notice Earn vault stock-side venue adapter, SHIPPED DISABLED (INTERFACE_VERSION 8, v8 design §8.2).
/// @dev WHY IT STARTS OFF. v8-plan/LENDING-RECON-2026-09-19.md:12,177: on 2026-09-19 Morpho had 12 stock-loan
///      markets, all with zero supply and zero borrow; the NVDA and SPY Vault V2s both reported totalAssets = 0.
///      P8-04 (T-107 / T-108) is the task that samples utilisation and decides whether this flag ever flips.
///      Until then {deposit} is a no-op that takes no tokens.
///
///      NOTE FOR P8-04, AND READ IT BEFORE FLIPPING THE FLAG: `enabled` gates the DEPOSIT path only.
///      {totalAssets}, {withdrawable} and the withdraw path are deliberately NOT gated, because gating
///      them meant a later {setEnabled}(false) on a funded adapter silently removed the venue balance
///      from {EarnVault} NAV -- underpaying redemptions, over-minting deposits, and blinding
///      {EarnVault.setAdapter}'s stranding guard so the vault could be re-pointed over a funded venue.
///      Turning the adapter OFF is therefore safe at any time and does not trap or hide anything; it
///      only stops new assets being placed. See the comment on {_depositIntoVenue}.
///
///      Enabling is a `restricted` call ({setEnabled}), and `StockVenueAdapter.setEnabled(bool)` IS now mapped in
///      `script/v2/roles.v8.json` (T-170). It previously was not, which meant it silently belonged to ADMIN
///      (06-QUIRKS.md §A.8) and, worse, was invisible to the AccessMatrix walk that exists to catch exactly that.
///
///      {deposit} and {withdraw} are INHERITED, not redeclared here, so the vault-only authorisation added to
///      {Erc4626VenueAdapter} covers this contract too. Before T-170 that inheritance carried the unauthorised
///      versions: this adapter had the same anyone-can-drain hole without declaring a single line of it.
///
///      The venue is still an ERC-4626 constructor argument, same as {Erc4626VenueAdapter}, so a later enable
///      does not need a redeploy — only the flag.
contract StockVenueAdapter is Erc4626VenueAdapter {
    /// @notice False at construction. P8-04 is the go/no-go for flipping it.
    bool public enabled;

    event EnabledSet(bool enabled);

    constructor(address authority_, address asset_, address venue_, address vault_)
        Erc4626VenueAdapter(authority_, asset_, venue_, vault_)
    {
        enabled = false;
    }

    /// @notice Turn the adapter on or off. `restricted` (ADMIN until the EarnVault/adapter rows land in
    ///         `roles.v8.json`). Does not move tokens.
    function setEnabled(bool on) external restricted {
        enabled = on;
        emit EnabledSet(on);
    }

    /// @dev `enabled` GATES ONE THING: PUTTING NEW MONEY IN. It is deliberately NOT applied to
    ///      {totalAssets}, {withdrawable} or {_withdrawFromVenue}, and the reason is the same one
    ///      {HouseVault} states for its own brake at `HouseVault.sol:654` -- "a brake must never trap
    ///      inventory".
    ///
    ///      IT USED TO GATE ALL FOUR, and that was a live money defect rather than a stylistic one.
    ///      {EarnVault.totalAssets} adds `a.totalAssets()` (`EarnVault.sol:642`), so a single
    ///      {setEnabled}(false) on a FUNDED adapter removed the whole venue balance from the vault's NAV
    ///      and three things broke at once:
    ///        - REDEMPTIONS UNDERPAID. `owed = mulDiv(shares, totalAssets(), supply)`
    ///          (`EarnVault.sol:283`) priced against `W` instead of `W + V`.
    ///        - DEPOSITS OVER-MINTED. `shares = mulDiv(received, supply, before)`
    ///          (`EarnVault.sol:262`) divided by the smaller `before`. Worse, with `W == 0` the vault
    ///          read `before == 0`, took its total-loss branch and reopened at the fixed 1:1 rate while
    ///          it was in fact fully solvent.
    ///        - {setAdapter} ORPHANED THE VENUE. Its stranding guard (`EarnVault.sol:511-514`) reads
    ///          `old.withdrawable()` then `old.totalAssets()` and reverts `InsufficientCollateral` when
    ///          anything is left. Both returned 0 while disabled, so the guard -- which is a real revert
    ///          and not a log -- passed, and the vault could be re-pointed away from a venue still
    ///          holding depositor assets, losing its only reference to them. A guard satisfied because
    ///          it cannot see its subject.
    ///
    ///      Measurement now always tells the truth, and the exit is always open, so the guard sees what
    ///      it is guarding and a disabled adapter can still be drained and swapped out. What `enabled`
    ///      still does is refuse to ACQUIRE a venue position, which is what "ships disabled" means.
    function _depositIntoVenue(uint256 assets) internal override returns (uint256) {
        if (!enabled) return 0;
        return super._depositIntoVenue(assets);
    }
}
