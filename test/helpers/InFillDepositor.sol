// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vault} from "../../src/Vault.sol";

/// @dev A contract buyer that tries to buy into the vault from inside its ERC-1155 receive hook, which
///      Seaport runs after the vault's `authorizeOrder` has written the fill and before the buyer's USDG
///      has moved. Every attempt is caught and recorded, so the fill itself completes and the test reads
///      what was refused. Shared with the real-Seaport case in test/unit/VaultRealSeaport.t.sol.
contract InFillDepositor {
    Vault internal immutable vault;

    uint256 public depositAmount;
    uint256 public hookCalls;
    uint256 public maxDepositInHook;
    uint256 public maxMintInHook;
    uint256 public usdgInVaultInHook;
    bytes public depositRevert;
    bytes public mintRevert;

    constructor(Vault vault_) {
        vault = vault_;
    }

    function arm(uint256 amount) external {
        depositAmount = amount;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        hookCalls++;
        if (depositAmount == 0) return this.onERC1155Received.selector;
        maxDepositInHook = vault.maxDeposit(address(this));
        maxMintInHook = vault.maxMint(address(this));
        usdgInVaultInHook = vault.usdg().balanceOf(address(vault));
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(Vault.deposit, (depositAmount, address(this))));
        if (!ok) depositRevert = ret;
        (ok, ret) = address(vault).call(abi.encodeCall(Vault.mint, (depositAmount, address(this))));
        if (!ok) mintRevert = ret;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function approveAll(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }
}
