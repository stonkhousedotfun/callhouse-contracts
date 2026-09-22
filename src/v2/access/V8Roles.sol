// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title V8Roles
/// @notice The `uint64` role ids and per-role execution delays of the one OpenZeppelin `AccessManager` that gates
///         every privileged function of INTERFACE_VERSION 8 (v8 design §2.2, 03-INTERFACES §3).
/// @dev v7 held a `bytes32` AccessControl role table inside each contract (`V2Constants.DEFAULT_ADMIN_ROLE`,
///      `GUARDIAN_ROLE`, `PRICER_ROLE`, `QUOTER_ROLE`). v8 replaces all of it with one manager that maps
///      `(target, selector) -> uint64 role` and enforces a per-member EXECUTION DELAY. This library is the compiled
///      mirror of `script/v2/roles.v8.json`, which is the source of truth the deploy script, `VerifyV8`, the access
///      matrix test, the indexer and the monitor all read; the access matrix test compares the two.
///
///      FACTS THAT SHAPE THIS TABLE (OpenZeppelin v5.7.0 `AccessManager`, checked at the pinned commit):
///        - The execution delay belongs to a (role, member) PAIR and one selector maps to exactly one role, so every
///          delay lane has to be its own role. That is why `FEE_MANAGER` (48 h) and `MARKET_FEE_MANAGER` (72 h) are
///          separate roles rather than one "fees" role.
///        - A member with a delay either calls `manager.execute(target, data)` -- the target then sees
///          `msg.sender == manager` -- or calls `schedule` and later calls the TARGET DIRECTLY. Anything that reads
///          `msg.sender` to move funds must take the second route.
///        - A role's GUARDIAN role may cancel operations scheduled under that role. `ADMIN` can never be given one,
///          so the guardian stops money-lane operations and never role or mapping changes.
///        - `setGrantDelay` and `setTargetAdminDelay` need at least five days (`minSetback`) to take effect, so v8
///          does not use them: grant delays and target admin delays stay 0 and every role change is itself an ADMIN
///          call, delayed by ADMIN's own 48 h execution delay.
///        - T-223/D13, SO NOBODY SIZES THIS RISK OFF THE WRONG MECHANISM. "Lowering a delay is itself delayed" is
///          TRUE, but ONLY on the direct path and NOT because of `minSetback`. `AccessManager._grantRole` on an
///          EXISTING member calls `Time.withUpdate(executionDelay, 0)`, and `withUpdate` takes
///          `setback = max(minSetback, value > newValue ? value - newValue : 0)` -- so dropping a 48 h lane to 0 is
///          itself held 48 h, with the 0 `minSetback` contributing nothing. REVOKE THEN GRANT SKIPS THAT ENTIRELY:
///          revoke clears the member's `since`, the next grant takes the new-member branch and assigns the delay
///          outright, and grant delays here are 0. Both legs are ADMIN calls, so what actually buys the 48 h is the
///          line above -- ADMIN's own execution delay -- and not any per-delay setback. Both halves are asserted
///          against the real `AccessManager` in `test/v2/unit/AccessManagerDelays.t.sol`, in one case, because
///          either half alone passes for the wrong reason.
///        - A scheduled operation expires one week after it becomes ready.
///
///      `uint64` matches `AccessManager`'s own role type, so a value here drops into `grantRole`, `setTargetFunctionRole`,
///      `setRoleAdmin` and `setRoleGuardian` with no cast. `ADMIN` is 0 because OpenZeppelin fixes
///      `AccessManager.ADMIN_ROLE` at 0; `PUBLIC_ROLE` is `type(uint64).max` and is never used here (user paths carry
///      no `restricted` modifier at all, so they pay no extra gas).
library V8Roles {
    /*//////////////////////////////////////////////////////////////
                                ROLE IDS
    //////////////////////////////////////////////////////////////*/

    /// @dev OpenZeppelin's own `AccessManager.ADMIN_ROLE`. Manager-only: grants and revokes roles, maps selectors,
    ///      sets role admins and guardians. NO TARGET FUNCTION IS MAPPED TO IT. Held by the Admin Safe with a 48 h
    ///      execution delay, so every role change is visible on chain for 48 h.
    uint64 internal constant ADMIN = 0;

    /// @dev Order-book and maker fee dials: `OrderBook.setFeeParams` (which also keeps its own in-contract 48 h
    ///      pending window), `setMakerRegistry`, `setDiscountModule`, `MakerRegistry.setTier`,
    ///      `KeeperRewards.setBounty` / `setDailyCap`, and the FeeSplitter split, cap and slippage setters.
    uint64 internal constant FEE_MANAGER = 1;

    /// @dev Per-market and default exercise fee and collateral rent (`Clearinghouse.setMarketFees`,
    ///      `setDefaultMarketFees`). Its own role because it is the only 72 h lane.
    uint64 internal constant MARKET_FEE_MANAGER = 2;

    /// @dev Pointers that decide where a call goes but never move money: oracles, calendar, payout adapter, keeper
    ///      rewards, minter allowlist, the six price-source setters, payout routes, funding allow-list.
    uint64 internal constant CONFIG_ADMIN = 3;

    /// @dev Everything that names or pays the treasury: fee recipients, `setTreasury` on all four holders,
    ///      `MakerVault.withdraw` / `withdrawPosition` / `setLimits`, `KeeperRewards.defund`,
    ///      `RewardsDistributor.setRoot` / `defund`, FeeSplitter wiring.
    uint64 internal constant TREASURY_ADMIN = 4;

    /// @dev Listing surface: registering a market, `enabled`, strike tick, redeem floor, base URI, calendar holidays
    ///      and special expiries, `AutoRoller.setMinRollUnits`. One hour, because a listing is reversible and cheap.
    uint64 internal constant LISTING = 5;

    /// @dev Manager-only and instant: the role ADMIN of `GUARDIAN`, `PRICER`, `QUOTER` and `BUYBACK`, so a compromised
    ///      hot key is revoked and rotated with two signatures and no delay. It can grant nothing else, and NO TARGET
    ///      FUNCTION IS MAPPED TO IT -- owner ruling G, completed by T-253, which moved the last one
    ///      (`EarnVault.refreshApprovals`) to `QUOTER`. This sentence is load-bearing precisely because OPS_ADMIN is
    ///      the Safe with NO timelock: one selector here would execute with no delay. It is a claim about
    ///      `script/v2/roles.v8.json`, not about this file, so `AccessMatrix.t.sol` derives it from that manifest
    ///      and fails by name rather than letting this comment be the only place it is asserted.
    uint64 internal constant OPS_ADMIN = 6;

    /// @dev Instant risk brake: the Clearinghouse mint and create pauses, the book's trading pause, the oracle veto
    ///      and unveto, `PayoutRouter.clearRoute`. Also set as the ROLE GUARDIAN of roles 1-5, so it can cancel any
    ///      scheduled fee, market-fee, config, treasury or listing operation while that operation waits out its delay.
    ///
    ///      T-223/D20, ON THE SCOPE OF THE ORACLE VETO, because this is where a reader asks what a delay-0 key can
    ///      reach. The veto CANNOT freeze a corroborated settlement: `SettlementOracle._advance` finalizes on
    ///      corroboration BEFORE it reads `Held`, so a held expiry that two agreeing sources cover settles anyway.
    ///      It bites only the uncorroborated path -- the single-source settlement this role is authorised to veto --
    ///      and even there `adminResolve` (CONFIG_ADMIN) finalizes within a deviation band from expiry +
    ///      `RESOLVE_DELAY`. An audit finding claimed the opposite by reading one row of that contract's state
    ///      table without its branch; the row is scoped to "ok source(s), none agreeing".
    uint64 internal constant GUARDIAN = 7;

    /// @dev `AutoRoller.reprice` only.
    uint64 internal constant PRICER = 8;

    /// @dev The ten `MakerVault` quoter functions. The Admin Safe is a member too, so it can cancel and close in an
    ///      emergency; v7's "quoter OR admin" check inside the vault is removed.
    uint64 internal constant QUOTER = 9;

    /// @dev `FeeSplitter.buyback(minTokenOut)` only.
    uint64 internal constant BUYBACK = 10;

    /// @dev Number of roles in the manifest, ADMIN included. The access-matrix test walks 0..COUNT-1.
    uint64 internal constant COUNT = 11;

    /*//////////////////////////////////////////////////////////////
                            EXECUTION DELAYS
    //////////////////////////////////////////////////////////////*/

    /// @dev Seconds a member of the role waits between `schedule` and `execute`. `uint32` is `AccessManager`'s own
    ///      delay type (`grantRole(role, account, executionDelay)`), so these drop in with no cast.
    uint32 internal constant ADMIN_DELAY = 48 hours; // 172_800 -- every role and mapping change
    uint32 internal constant FEE_MANAGER_DELAY = 48 hours; // 172_800
    uint32 internal constant MARKET_FEE_MANAGER_DELAY = 72 hours; // 259_200 -- exercise fee and rent dial
    uint32 internal constant CONFIG_ADMIN_DELAY = 24 hours; // 86_400
    uint32 internal constant TREASURY_ADMIN_DELAY = 24 hours; // 86_400
    uint32 internal constant LISTING_DELAY = 1 hours; // 3_600
    uint32 internal constant OPS_ADMIN_DELAY = 0; // hot-key rotation is instant on purpose
    uint32 internal constant GUARDIAN_DELAY = 0; // a brake that waits is not a brake
    uint32 internal constant PRICER_DELAY = 0;
    uint32 internal constant QUOTER_DELAY = 0;
    uint32 internal constant BUYBACK_DELAY = 0;

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The execution delay the manifest gives `role`, seconds.
    /// @dev Reverts is deliberately absent: an unknown role id answers 0, which is what an unmapped selector would
    ///      effectively get. `VerifyV8` and the access-matrix test compare this against the chain and the JSON.
    /// @param role Role id.
    /// @return Seconds between `schedule` and `execute` for a member of `role`.
    function delayOf(uint64 role) internal pure returns (uint32) {
        if (role == ADMIN) return ADMIN_DELAY;
        if (role == FEE_MANAGER) return FEE_MANAGER_DELAY;
        if (role == MARKET_FEE_MANAGER) return MARKET_FEE_MANAGER_DELAY;
        if (role == CONFIG_ADMIN) return CONFIG_ADMIN_DELAY;
        if (role == TREASURY_ADMIN) return TREASURY_ADMIN_DELAY;
        if (role == LISTING) return LISTING_DELAY;
        return 0;
    }

    /// @notice The manifest name of `role`, exactly as `script/v2/roles.v8.json` spells it.
    /// @param role Role id.
    /// @return The name, or an empty string for an id the manifest does not define.
    function nameOf(uint64 role) internal pure returns (string memory) {
        if (role == ADMIN) return "ADMIN";
        if (role == FEE_MANAGER) return "FEE_MANAGER";
        if (role == MARKET_FEE_MANAGER) return "MARKET_FEE_MANAGER";
        if (role == CONFIG_ADMIN) return "CONFIG_ADMIN";
        if (role == TREASURY_ADMIN) return "TREASURY_ADMIN";
        if (role == LISTING) return "LISTING";
        if (role == OPS_ADMIN) return "OPS_ADMIN";
        if (role == GUARDIAN) return "GUARDIAN";
        if (role == PRICER) return "PRICER";
        if (role == QUOTER) return "QUOTER";
        if (role == BUYBACK) return "BUYBACK";
        return "";
    }
}
