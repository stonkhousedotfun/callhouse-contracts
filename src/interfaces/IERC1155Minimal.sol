// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The ERC-1155 surface the vault needs from the Valorem clearinghouse.
interface IERC1155Minimal {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
