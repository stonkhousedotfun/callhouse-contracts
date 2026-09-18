// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMakerRegistry} from "../interfaces/IMakerRegistry.sol";
import {V2Constants} from "../interfaces/V2Constants.sol";
import {V2Errors} from "../interfaces/V2Errors.sol";

/// @title MakerRegistry
/// @notice Per-maker rebate tiers (roadmap 1.4, architecture §3.10). The OrderBook reads {rebateBps} on every fill and
///         pays a maker `share of the taker fee x rebateBps / 1e4`; a maker without a tier gets the book's
///         FeeParams.makerRebateBps.
/// @dev UNITS. A tier is bps of the maker's pro-rata share of a take's taker fee, BPS = 10_000 = the whole share.
///
///      ZERO MEANS "BOOK DEFAULT", NOT "NO REBATE". The frozen interface reserves 0 for "use the book default", and the
///      book treats it so (OrderBook._rebateBps). A maker cannot be tiered to exactly zero here; the smallest tier is
///      1 bps. To stop paying rebates to everyone, the admin sets the book's makerRebateBps instead.
///
///      TRUST (ADR-09). DEFAULT_ADMIN_ROLE sets tiers. A tier only redistributes the taker fee between the maker and the
///      fee recipient: the book clamps every rebate so the rebates of a take never exceed its taker fee, whatever a
///      registry answers. Tiers above BPS are refused here anyway (the book would clamp them to BPS).
contract MakerRegistry is IMakerRegistry, AccessControl, ReentrancyGuardTransient {
    /// @inheritdoc IMakerRegistry
    mapping(address maker => uint16) public rebateBps;

    /// @param admin Receives DEFAULT_ADMIN_ROLE (NotAuthorized when zero).
    constructor(address admin) {
        if (admin == address(0)) revert V2Errors.NotAuthorized();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Sets `maker`'s rebate tier. DEFAULT_ADMIN_ROLE.
    /// @dev CeilingExceeded above BPS. 0 returns the maker to the book default. Applies from the next take.
    /// @param maker Maker address (a wallet, a MakerVault, any contract that places orders).
    /// @param bps Bps of the maker's taker-fee share, <= 10_000; 0 = book default.
    function setTier(address maker, uint16 bps) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > V2Constants.BPS) revert V2Errors.CeilingExceeded();
        rebateBps[maker] = bps;
        emit TierSet(maker, bps);
    }

    /// @dev Every role check reverts with the shared v2 error, so the one error ABI consumers merge (V2Errors) decodes
    ///      it. Covers grantRole / revokeRole as well.
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) revert V2Errors.NotAuthorized();
    }
}
