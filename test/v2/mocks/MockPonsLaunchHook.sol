// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A stand-in for the third-party Pons v2 launch hook's per-pool fee record, for the V4BuybackExecutor suites.
/// @dev The real `PonsV2MemeHook` freezes `hookFeeBps` and `creatorTaxBps` per pool at `registerPool` and has no
///      setter for them (C3-602). This mock exposes {setLaunch} so a unit test can put the record where a hook the
///      protocol does not control might one day put it — an unregistered pool, another token, a raised per-pool fee —
///      and check that the executor refuses BEFORE it spends anything. It also carries a GLOBAL `hookFeeBps()`, set
///      independently, so a test can prove the executor never reads it.
contract MockPonsLaunchHook {
    struct Launch {
        bool registered;
        bool memecoinIsCurrency0;
        address memecoin;
        address quoteToken;
        uint16 creatorTaxBps;
        uint16 hookFeeBps;
    }

    address public poolManager;
    /// @notice The global getter that seeds FUTURE launches only. The executor must never read this.
    uint256 public hookFeeBps;

    mapping(bytes32 poolId => Launch) internal _launches;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function setPoolManager(address poolManager_) external {
        poolManager = poolManager_;
    }

    function setGlobalHookFeeBps(uint256 bps) external {
        hookFeeBps = bps;
    }

    function setLaunch(bytes32 poolId, Launch calldata launch) external {
        _launches[poolId] = launch;
    }

    /// @notice The hook's per-pool record, in the live layout (13 fields, four of them the ones that matter here).
    function launches(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 poolHookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        )
    {
        Launch memory l = _launches[poolId];
        return (
            l.registered,
            l.memecoinIsCurrency0,
            l.memecoin,
            l.quoteToken,
            address(0),
            address(0),
            address(0),
            l.creatorTaxBps,
            3000,
            5000,
            l.hookFeeBps,
            300,
            false
        );
    }
}
