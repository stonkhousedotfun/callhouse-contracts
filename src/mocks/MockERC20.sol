// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 with configurable decimals that stands in for USDG (Global Dollar, 6 dp)
///         INCLUDING the issuer powers that can hurt the vault.
/// @dev Mirrors what was proven on the live Paxos token on chain 4663 (integrations/usdg.md, B1-B7):
///      - `pause()` blocks `transfer`, `transferFrom` AND `approve` (`ContractPaused`). Views, freeze,
///        unfreeze, wipe and supply-controller mint/burn keep working while paused.
///      - `freeze(address)` is enforced on the SENDER, the RECIPIENT and the `transferFrom` SPENDER
///        (`AddressFrozen`). A frozen Seaport or a frozen conduit therefore blocks every fill that
///        pulls USDG through it, not only transfers to or from the frozen address itself.
///      - A ZERO-VALUE transfer to or from a frozen address still reverts: the live token runs the
///        frozen check before its zero-value early exit. Valorem's `redeem` only survives a frozen leg
///        because Valorem skips zero transfers itself, not because the token would.
///      - `approve` reverts when the owner or the spender is frozen.
///      - `wipeFrozenAddress` requires the target to be frozen, burns its whole balance and LEAVES IT
///        FROZEN.
///      - A supply controller can `burnFrom` ANY non-frozen address with no allowance, instantly, and
///        while paused (the live `decreaseSupplyFromAddress`; one EOA can grant itself that right).
///
///      Error selectors match the live token so a test that expects `ContractPaused()` / `AddressFrozen()`
///      / `AddressNotFrozen()` reads the same against the fork: 0xab35696f / 0x1fd1cc44 / 0xba55e0f0.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    bool public paused;
    mapping(address => bool) private _frozen;
    mapping(address => bool) public isSupplyController;

    error ContractPaused();
    error AddressFrozen();
    error AddressNotFrozen();
    error NotSupplyController(address caller);

    event Pause();
    event Unpause();
    event FreezeAddress(address indexed addr);
    event UnfreezeAddress(address indexed addr);
    event FrozenAddressWiped(address indexed addr);
    event SupplyDecreased(address indexed from, uint256 value);

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
        // The deployer (the test contract) is a supply controller with `allowAnyMintAndBurnAddress`,
        // the shape of the live OFT-wrapper controller.
        isSupplyController[msg.sender] = true;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /*//////////////////////////////////////////////////////////////
                              SUPPLY CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint. Permissionless in the mock so fixtures can fund actors; allowed while paused, as
    ///         the live `increaseSupplyToAddress` is.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice The live `decreaseSupplyFromAddress`: a supply controller burns from ANY address with
    ///         no allowance. Reverts `AddressFrozen` when the target is frozen; works while paused.
    /// @notice ERC-20 burn of the caller's own balance. Used by V4BuybackExecutor.execute.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (!isSupplyController[msg.sender]) revert NotSupplyController(msg.sender);
        if (_frozen[from]) revert AddressFrozen();
        _burn(from, amount);
        emit SupplyDecreased(from, amount);
    }

    function setSupplyController(address who, bool on) external {
        isSupplyController[who] = on;
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE / FREEZE
    //////////////////////////////////////////////////////////////*/

    function pause() external {
        paused = true;
        emit Pause();
    }

    function unpause() external {
        paused = false;
        emit Unpause();
    }

    function freeze(address who) external {
        _frozen[who] = true;
        emit FreezeAddress(who);
    }

    function unfreeze(address who) external {
        _frozen[who] = false;
        emit UnfreezeAddress(who);
    }

    function isFrozen(address who) external view returns (bool) {
        return _frozen[who];
    }

    /// @notice Burn a frozen address's whole balance. The address stays frozen afterwards.
    function wipeFrozenAddress(address who) external {
        if (!_frozen[who]) revert AddressNotFrozen();
        uint256 bal = balanceOf(who);
        _burn(who, bal);
        emit FrozenAddressWiped(who);
        emit SupplyDecreased(who, bal);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-20 GATES
    //////////////////////////////////////////////////////////////*/

    /// @dev Pause blocks approvals too, and a frozen owner or spender cannot approve.
    function approve(address spender, uint256 value) public override returns (bool) {
        if (paused) revert ContractPaused();
        if (_frozen[msg.sender] || _frozen[spender]) revert AddressFrozen();
        return super.approve(spender, value);
    }

    /// @dev The SPENDER is checked here; `from` and `to` are checked in {_update}.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (paused) revert ContractPaused();
        if (_frozen[msg.sender]) revert AddressFrozen();
        return super.transferFrom(from, to, value);
    }

    /// @dev Transfers (from and to both non-zero) are gated; mints and burns are not, matching the
    ///      live supply-controller paths that keep working under a pause. The frozen check runs for
    ///      zero-value transfers as well, on purpose.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (paused) revert ContractPaused();
            if (_frozen[from] || _frozen[to]) revert AddressFrozen();
        }
        super._update(from, to, value);
    }
}
