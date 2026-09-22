// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Managed} from "../../access/Managed.sol";
import {IExpiryCalendar} from "../../interfaces/IExpiryCalendar.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../interfaces/ISettlementOracle.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";
import {HouseVault} from "./HouseVault.sol";

/// @title HouseVaultFactory
/// @notice Deploys one {HouseVault} per market and keeps the index of them. LISTING creates; nobody else.
/// @dev THE OPERATIONAL CONSEQUENCE, AND IT IS NOT SOLVED HERE ON PURPOSE. An `AccessManager` maps
///      (TARGET, SELECTOR) -> role id, and the target is the individual contract address. A vault deployed by this
///      factory is therefore born with NO selector mapped to any role: the mm-bot's QUOTER key cannot quote it, and
///      TREASURY_ADMIN cannot set its limits, until the Admin Safe sends that vault its OWN
///      `setTargetFunctionRole` batch -- one call per role id, naming the new vault as the target -- and that batch
///      goes through ADMIN's 48 h execution delay like every other role change.
///
///      SO: A NEW MARKET IS NOT TRADEABLE THE MOMENT THIS FUNCTION RETURNS. It is tradeable 48 hours after the Safe
///      schedules the mapping. Plan a listing around that, and expect the vault to sit inert and fully funded in
///      between; every depositor path ({requestDeposit}, {requestWithdraw}, {rollEpoch}, {claim}) is unrestricted and
///      works immediately, so depositor money is never trapped by the wait -- only quoting is.
///
///      WHAT WE DELIBERATELY DO NOT DO ABOUT IT. Granting this factory a role so it could map its own children, or
///      giving the vault a role over the manager, would mean a contract that can widen the access graph without the
///      Safe and without the delay. That is a strictly larger blast radius than a scheduled batch: an exploit of the
///      factory would become an exploit of every vault it could then authorise. The 48 h wait is the price of the
///      manager being the only thing that decides who may call what, and it is worth paying.
contract HouseVaultFactory is Managed {
    /// @notice The OrderBook every vault this factory makes will quote on.
    IOrderBook public immutable orderBook;
    /// @notice The expiry calendar every vault takes its weekly boundary from.
    IExpiryCalendar public immutable calendar;
    /// @notice The settlement oracle every vault is BORN pricing its boundary with.
    /// @dev A SEED, NOT A BINDING (T-OP-058). Each vault copies this into its own `HouseVault.oracle` at
    ///      construction and can be moved off it afterwards by `HouseVault.setOracle` (CONFIG_ADMIN). This value
    ///      stays immutable on purpose: a stale seed means only that the NEXT vault starts on the old oracle and
    ///      needs one setter call, whereas a live vault that cannot move is the F6 defect the setter fixed. A
    ///      factory that should seed a new oracle is a new factory; this one holds no state a vault depends on.
    ISettlementOracle public immutable oracle;
    /// @notice The FeeSplitter every vault pays its performance fee to.
    address public immutable splitter;

    /// @notice The vault for an underlying, or the zero address when there is none.
    mapping(address underlying => address vault) public vaultOf;

    address[] private _vaults;

    /// @notice LISTING created `vault` for `underlying`.
    event VaultCreated(address indexed underlying, address indexed vault, string name, string symbol);

    constructor(
        IOrderBook orderBook_,
        address authority_,
        IExpiryCalendar calendar_,
        ISettlementOracle oracle_,
        address splitter_
    ) Managed(authority_) {
        // SEC-29. `orderBook_` is checked with the other sources. It is immutable here and is handed to EVERY
        // vault this factory deploys, so a zero address is not a bad listing but a dead factory: each
        // {createVault} would build a vault whose book calls revert, and no setter exists to repair either.
        if (address(orderBook_) == address(0) || address(calendar_) == address(0) || address(oracle_) == address(0)) {
            revert V2Errors.NoSource();
        }
        if (splitter_ == address(0)) revert V2Errors.NotAuthorized();
        orderBook = orderBook_;
        calendar = calendar_;
        oracle = oracle_;
        splitter = splitter_;
    }

    /// @notice Deploys the House vault for `underlying`. LISTING only.
    /// @dev One vault per underlying: a second call for the same underlying reverts, because two vaults quoting the
    ///      same market from the same bot key would each measure their own exposure and neither would see the other's.
    ///      REMEMBER the 48 h role mapping in the contract NatSpec: the returned vault cannot be quoted until the
    ///      Admin Safe has mapped its selectors.
    /// @param underlying The 18-dp Stock Token.
    /// @param limits The new vault's guard rails.
    /// @param name ERC-20 name, e.g. "Stonkhouse House NVDA".
    /// @param symbol ERC-20 symbol, e.g. "hNVDA".
    /// @return vault The new vault.
    function createVault(
        address underlying,
        HouseVault.Limits calldata limits,
        string calldata name,
        string calldata symbol
    ) external restricted returns (address vault) {
        if (underlying == address(0)) revert V2Errors.UnsupportedAsset();
        if (vaultOf[underlying] != address(0)) revert V2Errors.SeriesIdCollision();
        vault = address(
            new HouseVault(orderBook, authority(), IERC20(underlying), calendar, oracle, splitter, limits, name, symbol)
        );
        vaultOf[underlying] = vault;
        _vaults.push(vault);
        emit VaultCreated(underlying, vault, name, symbol);
    }

    /// @notice Every vault this factory has made, in creation order.
    function vaults() external view returns (address[] memory) {
        return _vaults;
    }
}
