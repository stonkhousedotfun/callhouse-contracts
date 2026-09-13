// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";

/// @notice A faithful-enough stand-in for ValoremOptionsClearinghouse.
/// @dev Models the behaviour the vault actually depends on:
///      - `write` pulls collateral, mints option ERC-1155 and one claim NFT to the writer
///      - option ids carry the type in the upper 160 bits and the claim index in the lower 96
///      - `Claim.amountWritten` / `amountExercised` are 1e18-SCALED SCALARS, as upstream
///      - `redeem` only works after expiry and only for the claim's owner
///      - partial assignment: 0..n of a claim may be exercised, and redeem pays a mix of
///        leftover underlying plus strike proceeds
///      - top-up: `write(claimId, n)` adds to a claim the caller owns and returns the same id, as
///        upstream `valorem-labs-inc/clear` @ 6436c823 does. Upstream records a claim index per
///        bucket written into (a new bucket only once the option type's last bucket has been
///        exercised, so every pre-exercise write shares one bucket) and `claim`/`position` sum
///        over the claim's indices. The mock keeps one running total per claim, which is that
///        sum, so the vault's claim views see exactly what upstream reports for a topped-up claim.
///      Not modelled: bucketed fair assignment across many writers, the URI generator, fee
///      sweeping. The vault does not read any of those.
contract MockClear is IValoremClear {
    using SafeERC20 for IERC20;

    struct OptionType {
        address underlyingAsset;
        uint96 underlyingAmount;
        address exerciseAsset;
        uint96 exerciseAmount;
        uint40 exerciseTimestamp;
        uint40 expiryTimestamp;
        uint96 nextClaimKey;
        bool exists;
    }

    struct ClaimData {
        uint256 optionId;
        uint112 written;
        uint112 exercised;
        address owner;
        bool redeemed;
    }

    mapping(uint256 => OptionType) internal optionTypes;
    mapping(uint256 => ClaimData) internal claims;
    mapping(address => mapping(uint256 => uint256)) internal _balances;
    mapping(address => mapping(address => bool)) internal _operatorApproval;

    bool internal _feesEnabled;
    uint8 internal _feeBps = 15;
    address internal _feeTo;

    error NotExpired();
    error NotOwner();
    error AlreadyRedeemed();
    error UnknownOption();
    error TooEarlyToExercise();
    error Expired();

    /*//////////////////////////////////////////////////////////////
                             TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setFeesEnabled(bool on) external {
        _feesEnabled = on;
    }

    function setFeeBps(uint8 b) external {
        _feeBps = b;
    }

    function setFeeTo(address t) external {
        _feeTo = t;
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION TYPES
    //////////////////////////////////////////////////////////////*/

    function newOptionType(
        address underlyingAsset,
        uint96 underlyingAmount,
        address exerciseAsset,
        uint96 exerciseAmount,
        uint40 exerciseTimestamp,
        uint40 expiryTimestamp
    ) external returns (uint256 optionId) {
        uint160 key = uint160(
            uint256(
                keccak256(
                    abi.encode(
                        underlyingAsset,
                        underlyingAmount,
                        exerciseAsset,
                        exerciseAmount,
                        exerciseTimestamp,
                        expiryTimestamp
                    )
                )
            )
        );
        optionId = uint256(key) << 96;
        optionTypes[optionId] = OptionType({
            underlyingAsset: underlyingAsset,
            underlyingAmount: underlyingAmount,
            exerciseAsset: exerciseAsset,
            exerciseAmount: exerciseAmount,
            exerciseTimestamp: exerciseTimestamp,
            expiryTimestamp: expiryTimestamp,
            nextClaimKey: 1,
            exists: true
        });
        emit NewOptionType(
            optionId,
            exerciseAsset,
            underlyingAsset,
            exerciseAmount,
            underlyingAmount,
            exerciseTimestamp,
            expiryTimestamp
        );
    }

    function option(uint256 tokenId) external view returns (Option memory) {
        uint256 typeId = (tokenId >> 96) << 96;
        OptionType storage o = optionTypes[typeId];
        if (!o.exists) revert UnknownOption();
        return Option({
            underlyingAsset: o.underlyingAsset,
            underlyingAmount: o.underlyingAmount,
            exerciseAsset: o.exerciseAsset,
            exerciseAmount: o.exerciseAmount,
            exerciseTimestamp: o.exerciseTimestamp,
            expiryTimestamp: o.expiryTimestamp,
            settlementSeed: uint160(typeId >> 96),
            nextClaimKey: o.nextClaimKey
        });
    }

    /*//////////////////////////////////////////////////////////////
                                WRITE
    //////////////////////////////////////////////////////////////*/

    function write(uint256 tokenId, uint112 amount) external returns (uint256 claimId) {
        if (tokenId & type(uint96).max != 0) return _topUp(tokenId, amount);
        uint256 typeId = (tokenId >> 96) << 96;
        OptionType storage o = optionTypes[typeId];
        if (!o.exists) revert UnknownOption();
        if (block.timestamp >= o.expiryTimestamp) revert Expired();

        uint256 collateral = uint256(amount) * uint256(o.underlyingAmount);

        // Upstream charges the engine fee ON TOP of the collateral when the switch is on, so the
        // writer must have approved collateral + fee. Modelling it here is what makes the
        // "acceptValoremFee actually lets the vault write" property testable.
        uint256 pull = collateral;
        if (_feesEnabled) {
            uint256 fee = (collateral * uint256(_feeBps)) / 10_000;
            if (fee == 0) fee = 1;
            pull += fee;
            emit FeeAccrued(typeId, o.underlyingAsset, msg.sender, fee);
        }
        IERC20(o.underlyingAsset).safeTransferFrom(msg.sender, address(this), pull);

        claimId = typeId | uint256(o.nextClaimKey);
        o.nextClaimKey += 1;

        claims[claimId] =
            ClaimData({optionId: typeId, written: amount, exercised: 0, owner: msg.sender, redeemed: false});

        _balances[msg.sender][typeId] += amount;
        _balances[msg.sender][claimId] += 1;

        emit TransferSingle(msg.sender, address(0), msg.sender, typeId, amount);
        emit TransferSingle(msg.sender, address(0), msg.sender, claimId, 1);
        emit OptionsWritten(typeId, msg.sender, claimId, amount);
    }

    /// @dev Upstream's add-to-an-existing-claim branch: zero amount, an unknown or expired option
    ///      and a caller who does not hold the claim NFT all revert; the fee is charged as on a
    ///      fresh write; only option tokens are minted; the claim id passed in is returned.
    function _topUp(uint256 claimId, uint112 amount) internal returns (uint256) {
        if (amount == 0) revert AmountWrittenCannotBeZero();
        ClaimData storage c = claims[claimId];
        OptionType storage o = optionTypes[c.optionId];
        if (!o.exists) revert UnknownOption();
        if (block.timestamp >= o.expiryTimestamp) revert Expired();
        if (_balances[msg.sender][claimId] != 1 || c.redeemed) revert CallerDoesNotOwnClaimId(claimId);

        uint256 pull = uint256(amount) * uint256(o.underlyingAmount);
        if (_feesEnabled) {
            uint256 fee = (pull * uint256(_feeBps)) / 10_000;
            if (fee == 0) fee = 1;
            pull += fee;
            emit FeeAccrued(c.optionId, o.underlyingAsset, msg.sender, fee);
        }
        IERC20(o.underlyingAsset).safeTransferFrom(msg.sender, address(this), pull);

        c.written += amount;
        _balances[msg.sender][c.optionId] += amount;

        emit TransferSingle(msg.sender, address(0), msg.sender, c.optionId, amount);
        emit OptionsWritten(c.optionId, msg.sender, claimId, amount);
        return claimId;
    }

    /*//////////////////////////////////////////////////////////////
                               EXERCISE
    //////////////////////////////////////////////////////////////*/

    /// @dev Assignment lands on the first claim written against the type that still has
    ///      unexercised size. That is a simplification of Valorem's bucketed randomisation, but
    ///      it produces the same shape of outcome the vault must handle: 0..n assigned.
    function exercise(uint256 optionId_, uint112 amount) external {
        uint256 typeId = (optionId_ >> 96) << 96;
        OptionType storage o = optionTypes[typeId];
        if (!o.exists) revert UnknownOption();
        if (block.timestamp < o.exerciseTimestamp) revert TooEarlyToExercise();
        if (block.timestamp >= o.expiryTimestamp) revert Expired();

        _balances[msg.sender][typeId] -= amount;

        IERC20(o.exerciseAsset).safeTransferFrom(msg.sender, address(this), uint256(amount) * uint256(o.exerciseAmount));
        IERC20(o.underlyingAsset).safeTransfer(msg.sender, uint256(amount) * uint256(o.underlyingAmount));

        _assign(typeId, amount);

        emit TransferSingle(msg.sender, msg.sender, address(0), typeId, amount);
        emit OptionsExercised(typeId, msg.sender, amount);
    }

    function _assign(uint256 typeId, uint112 amount) internal {
        uint96 next = optionTypes[typeId].nextClaimKey;
        uint112 left = amount;
        for (uint96 i = 1; i < next && left > 0; i++) {
            ClaimData storage c = claims[typeId | uint256(i)];
            uint112 free = c.written - c.exercised;
            if (free == 0) continue;
            uint112 take = free < left ? free : left;
            c.exercised += take;
            left -= take;
            emit BucketAssignedExercise(typeId, i, take);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    function redeem(uint256 claimId) external {
        ClaimData storage c = claims[claimId];
        if (c.owner != msg.sender) revert NotOwner();
        if (c.redeemed) revert AlreadyRedeemed();

        OptionType storage o = optionTypes[c.optionId];
        if (block.timestamp < o.expiryTimestamp) revert NotExpired();

        uint256 underlyingBack = uint256(c.written - c.exercised) * uint256(o.underlyingAmount);
        uint256 exerciseBack = uint256(c.exercised) * uint256(o.exerciseAmount);

        c.redeemed = true;
        _balances[msg.sender][claimId] = 0;

        if (underlyingBack != 0) IERC20(o.underlyingAsset).safeTransfer(msg.sender, underlyingBack);
        if (exerciseBack != 0) IERC20(o.exerciseAsset).safeTransfer(msg.sender, exerciseBack);

        emit TransferSingle(msg.sender, msg.sender, address(0), claimId, 1);
        emit ClaimRedeemed(claimId, c.optionId, msg.sender, exerciseBack, underlyingBack);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function claim(uint256 claimId) external view returns (Claim memory) {
        ClaimData storage c = claims[claimId];
        return Claim({
            amountWritten: uint256(c.written) * 1e18, amountExercised: uint256(c.exercised) * 1e18, optionId: c.optionId
        });
    }

    function position(uint256 tokenId) external view returns (Position memory) {
        ClaimData storage c = claims[tokenId];
        OptionType storage o = optionTypes[c.optionId];
        if (c.owner == address(0) || c.redeemed) {
            return
                Position({
                    underlyingAsset: address(0), underlyingAmount: 0, exerciseAsset: address(0), exerciseAmount: 0
                });
        }
        return Position({
            underlyingAsset: o.underlyingAsset,
            underlyingAmount: int256(uint256(c.written - c.exercised) * uint256(o.underlyingAmount)),
            exerciseAsset: o.exerciseAsset,
            exerciseAmount: int256(uint256(c.exercised) * uint256(o.exerciseAmount))
        });
    }

    function tokenType(uint256 tokenId) external view returns (TokenType) {
        if (tokenId == 0) return TokenType.None;
        if (tokenId & type(uint96).max == 0) {
            return optionTypes[tokenId].exists ? TokenType.Option : TokenType.None;
        }
        return claims[tokenId].owner != address(0) ? TokenType.Claim : TokenType.None;
    }

    function feesEnabled() external view returns (bool) {
        return _feesEnabled;
    }

    function feeBps() external view returns (uint8) {
        return _feeBps;
    }

    function feeTo() external view returns (address) {
        return _feeTo;
    }

    function feeBalance(address) external pure returns (uint256) {
        return 0;
    }

    function tokenURIGenerator() external pure returns (address) {
        return address(0);
    }

    function uri(uint256) external pure returns (string memory) {
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                               ERC-1155
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address owner, uint256 id) public view returns (uint256) {
        return _balances[owner][id];
    }

    function balanceOfBatch(address[] calldata owners, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory out)
    {
        out = new uint256[](owners.length);
        for (uint256 i; i < owners.length; i++) {
            out[i] = _balances[owners[i]][ids[i]];
        }
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApproval[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApproval[owner][operator];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(from == msg.sender || _operatorApproval[from][msg.sender], "not approved");
        _balances[from][id] -= amount;
        _balances[to][id] += amount;
        if (claims[id].owner == from && amount == 1) claims[id].owner = to;
        emit TransferSingle(msg.sender, from, to, id, amount);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata
    ) external {
        require(from == msg.sender || _operatorApproval[from][msg.sender], "not approved");
        for (uint256 i; i < ids.length; i++) {
            _balances[from][ids[i]] -= amounts[i];
            _balances[to][ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 || interfaceId == 0x01ffc9a7;
    }

    function setFeesEnabled(bool, bytes calldata) external pure {}
    function acceptFeeTo() external pure {}
    function setFeeTo(address, bytes calldata) external pure {}
    function setTokenURIGenerator(address) external pure {}
    function sweepFees(address[] calldata) external pure {}
}
