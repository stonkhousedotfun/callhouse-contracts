// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";

/// @notice A bucket-faithful stand-in for ValoremOptionsClearinghouse (valorem-labs-inc/clear @ 6436c823).
/// @dev WHY THE MOCK MODELS BUCKETS. The audit's F-01 turned on Valorem's assignment model, and the
///      previous mock could not express it (FIFO by claim index). Upstream works like this, and so
///      does this mock, function for function:
///      - `write` checks only `amount != 0`, the type exists and `expiry > now`. ANYONE can write any
///        live option id until expiry, including during the exercise window.
///      - The first write creates bucket 0. A later write joins the LAST bucket while that bucket's
///        `amountExercised == 0`; otherwise it opens a new bucket. Exercise is impossible before
///        `exerciseTimestamp`, so every write by every writer before the first exercise shares bucket 0.
///      - A claim keeps one `ClaimIndex` per bucket it wrote into (`_addOrUpdateClaimIndex`).
///      - `exercise` assigns to buckets starting at `settlementSeed % numUnexercisedBuckets`, walking
///        with swap-and-pop over the unexercised-bucket list (`_assignExercise`). The seed is the
///        option key, fixed at creation and never re-seeded, so the whole order is public.
///      - Within a bucket assignment is PRO RATA BY AMOUNT WRITTEN, whoever sold (`claim`,
///        `_getAssetAmountsForClaimIndex`), with upstream's exact rounding.
///      - `redeem` after expiry pops the claim indices, burns the claim NFT, then pushes the EXERCISE
///        asset first and the underlying second, each only if > 0. Either transfer reverting reverts the
///        whole redeem. After redeem `claim`/`position` revert `TokenNotFound` and `tokenType` is None.
///      - `position(optionId)` reverts `ExpiredOption` once expired; `option()` ignores the claim key.
///      - The engine fee (15 bps, 1-wei floor) is pulled ON TOP of collateral on write and on top of
///        the strike on exercise when the switch is on; a top-up is charged like a fresh write.
///      - ERC-1155 receiver hooks are called on mints and on transfers to a contract, as solmate does,
///        with `msg.sender == this` inside the hook in every case.
///      Not modelled: the URI generator and fee sweeping. The vault reads neither.
///
///      Test helpers (not upstream): permissionless `setFeesEnabled(bool)` / `setFeeBps` / `setFeeTo`,
///      and the bucket / supply views used by the differential test and the invariants.
contract MockClear is IValoremClear {
    using SafeERC20 for IERC20;

    struct Bucket {
        uint112 amountWritten;
        uint112 amountExercised;
    }

    struct ClaimIndex {
        uint112 amountWritten;
        uint96 bucketIndex;
    }

    struct OptionTypeState {
        Option option;
        Bucket[] buckets;
        uint96[] unexercisedBucketIndices;
        mapping(uint96 => ClaimIndex[]) claimIndices;
    }

    uint8 private constant OPTION_KEY_PADDING = 96;
    uint96 private constant CLAIM_KEY_MASK = type(uint96).max;

    mapping(uint160 => OptionTypeState) internal optionTypeStates;
    mapping(address => mapping(uint256 => uint256)) internal _balances;
    mapping(address => mapping(address => bool)) internal _operatorApproval;

    /// @dev Mock-only: outstanding option tokens per option id (minted minus burnt), so a test can
    ///      assert upstream's implicit invariant "long supply == unexercised collateral".
    mapping(uint256 => uint256) internal _optionSupply;

    bool internal _feesEnabled;
    uint8 internal _feeBps = 15;
    address internal _feeTo;
    mapping(address => uint256) internal _feeBalance;

    error UnsafeRecipient();
    error NotApproved();

    /*//////////////////////////////////////////////////////////////
                             TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setFeesEnabled(bool on) external {
        _feesEnabled = on;
        emit FeeSwitchUpdated(msg.sender, on);
    }

    function setFeeBps(uint8 b) external {
        _feeBps = b;
    }

    function setFeeTo(address t) external {
        _feeTo = t;
    }

    /// @notice Outstanding option tokens of `optionId` (mock-only).
    function optionSupply(uint256 optionId_) external view returns (uint256) {
        return _optionSupply[_typeId(optionId_)];
    }

    /// @notice Contracts written and not yet assigned across every bucket of `optionId` (mock-only).
    function unexercisedContracts(uint256 optionId_) external view returns (uint256 total) {
        Bucket[] storage buckets = optionTypeStates[uint160(optionId_ >> OPTION_KEY_PADDING)].buckets;
        for (uint256 i; i < buckets.length; i++) {
            total += buckets[i].amountWritten - buckets[i].amountExercised;
        }
    }

    /// @notice Number of buckets opened on `optionId` (mock-only).
    function bucketCount(uint256 optionId_) external view returns (uint256) {
        return optionTypeStates[uint160(optionId_ >> OPTION_KEY_PADDING)].buckets.length;
    }

    /// @notice A bucket's written / exercised totals (mock-only).
    function bucket(uint256 optionId_, uint96 index) external view returns (uint112 written, uint112 exercised) {
        Bucket storage b = optionTypeStates[uint160(optionId_ >> OPTION_KEY_PADDING)].buckets[index];
        return (b.amountWritten, b.amountExercised);
    }

    /// @notice The bucket indices still holding unassigned collateral, in upstream's list order (mock-only).
    function unexercisedBucketIndices(uint256 optionId_) external view returns (uint96[] memory) {
        return optionTypeStates[uint160(optionId_ >> OPTION_KEY_PADDING)].unexercisedBucketIndices;
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
        uint160 optionKey = uint160(
            bytes20(
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
        optionId = uint256(optionKey) << OPTION_KEY_PADDING;

        if (_isOptionInitialized(optionKey)) revert OptionsTypeExists(optionId);
        if (expiryTimestamp < block.timestamp + 1 minutes) revert ExpiryWindowTooShort(expiryTimestamp);
        if (expiryTimestamp < exerciseTimestamp + 1 minutes) revert ExerciseWindowTooShort(exerciseTimestamp);
        if (exerciseAsset == underlyingAsset) revert InvalidAssets(exerciseAsset, underlyingAsset);
        if (
            IERC20(underlyingAsset).totalSupply() < underlyingAmount
                || IERC20(exerciseAsset).totalSupply() < exerciseAmount
        ) {
            revert InvalidAssets(underlyingAsset, exerciseAsset);
        }

        optionTypeStates[optionKey].option = Option({
            underlyingAsset: underlyingAsset,
            underlyingAmount: underlyingAmount,
            exerciseAsset: exerciseAsset,
            exerciseAmount: exerciseAmount,
            exerciseTimestamp: exerciseTimestamp,
            expiryTimestamp: expiryTimestamp,
            settlementSeed: optionKey,
            nextClaimKey: 1
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

    /*//////////////////////////////////////////////////////////////
                                WRITE
    //////////////////////////////////////////////////////////////*/

    function write(uint256 tokenId, uint112 amount) external returns (uint256) {
        if (amount == 0) revert AmountWrittenCannotBeZero();

        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(tokenId);
        uint256 encodedOptionId = uint256(optionKey) << OPTION_KEY_PADDING;
        OptionTypeState storage state = optionTypeStates[optionKey];

        uint40 expiry = state.option.expiryTimestamp;
        if (expiry == 0) revert InvalidOption(encodedOptionId);
        if (expiry <= block.timestamp) revert ExpiredOption(encodedOptionId, expiry);

        uint96 bucketIndex = _addOrUpdateBucket(state, amount);

        uint256 rxAmount = uint256(state.option.underlyingAmount) * amount;
        address underlyingAsset = state.option.underlyingAsset;

        uint256 fee;
        if (_feesEnabled) fee = _calculateRecordAndEmitFee(encodedOptionId, underlyingAsset, rxAmount);

        if (claimKey == 0) {
            uint96 nextClaimKey = state.option.nextClaimKey++;
            tokenId = _encodeTokenId(optionKey, nextClaimKey);
            _addOrUpdateClaimIndex(state, nextClaimKey, bucketIndex, amount);

            emit OptionsWritten(encodedOptionId, msg.sender, tokenId, amount);
            emit BucketWrittenInto(encodedOptionId, tokenId, bucketIndex, amount);

            IERC20(underlyingAsset).safeTransferFrom(msg.sender, address(this), rxAmount + fee);

            uint256[] memory ids = new uint256[](2);
            ids[0] = encodedOptionId;
            ids[1] = tokenId;
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = amount;
            amounts[1] = 1;
            _optionSupply[encodedOptionId] += amount;
            _batchMint(msg.sender, ids, amounts);
        } else {
            if (_balances[msg.sender][tokenId] != 1) revert CallerDoesNotOwnClaimId(tokenId);
            _addOrUpdateClaimIndex(state, claimKey, bucketIndex, amount);

            emit OptionsWritten(encodedOptionId, msg.sender, tokenId, amount);
            emit BucketWrittenInto(encodedOptionId, tokenId, bucketIndex, amount);

            IERC20(underlyingAsset).safeTransferFrom(msg.sender, address(this), rxAmount + fee);

            _optionSupply[encodedOptionId] += amount;
            _mint(msg.sender, encodedOptionId, amount);
        }

        return tokenId;
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    function redeem(uint256 claimId) external {
        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(claimId);
        if (claimKey == 0) revert InvalidClaim(claimId);
        if (_balances[msg.sender][claimId] != 1) revert CallerDoesNotOwnClaimId(claimId);

        OptionTypeState storage state = optionTypeStates[optionKey];
        Option memory optionRecord = state.option;
        if (optionRecord.expiryTimestamp > block.timestamp) revert ClaimTooSoon(claimId, optionRecord.expiryTimestamp);

        ClaimIndex[] storage claimIndices = state.claimIndices[claimKey];
        uint256 len = claimIndices.length;
        uint256 totalUnderlying;
        uint256 totalExercise;
        for (uint256 i = len; i > 0; i--) {
            (uint256 u, uint256 e) = _getAssetAmountsForClaimIndex(
                optionRecord.underlyingAmount, optionRecord.exerciseAmount, state, claimIndices, i - 1
            );
            totalUnderlying += u;
            totalExercise += e;
            claimIndices.pop();
        }

        emit ClaimRedeemed(
            claimId, uint256(optionKey) << OPTION_KEY_PADDING, msg.sender, totalExercise, totalUnderlying
        );

        _burn(msg.sender, claimId, 1);

        if (totalExercise > 0) IERC20(optionRecord.exerciseAsset).safeTransfer(msg.sender, totalExercise);
        if (totalUnderlying > 0) IERC20(optionRecord.underlyingAsset).safeTransfer(msg.sender, totalUnderlying);
    }

    /*//////////////////////////////////////////////////////////////
                               EXERCISE
    //////////////////////////////////////////////////////////////*/

    function exercise(uint256 optionId_, uint112 amount) external {
        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(optionId_);
        if (claimKey != 0) revert InvalidOption(optionId_);

        OptionTypeState storage state = optionTypeStates[optionKey];
        Option storage optionRecord = state.option;

        if (optionRecord.expiryTimestamp <= block.timestamp) {
            revert ExpiredOption(optionId_, optionRecord.expiryTimestamp);
        }
        if (optionRecord.exerciseTimestamp > block.timestamp) {
            revert ExerciseTooEarly(optionId_, optionRecord.exerciseTimestamp);
        }
        if (_balances[msg.sender][optionId_] < amount) revert CallerHoldsInsufficientOptions(optionId_, amount);

        uint256 rxAmount = uint256(optionRecord.exerciseAmount) * amount;
        uint256 txAmount = uint256(optionRecord.underlyingAmount) * amount;
        address exerciseAsset = optionRecord.exerciseAsset;
        address underlyingAsset = optionRecord.underlyingAsset;

        _assignExercise(optionId_, state, optionRecord, amount);

        uint256 fee;
        if (_feesEnabled) fee = _calculateRecordAndEmitFee(optionId_, exerciseAsset, rxAmount);
        emit OptionsExercised(optionId_, msg.sender, amount);

        _optionSupply[optionId_] -= amount;
        _burn(msg.sender, optionId_, amount);

        IERC20(exerciseAsset).safeTransferFrom(msg.sender, address(this), rxAmount + fee);
        IERC20(underlyingAsset).safeTransfer(msg.sender, txAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function option(uint256 tokenId) external view returns (Option memory optionInfo) {
        (uint160 optionKey,) = _decodeTokenId(tokenId);
        if (!_isOptionInitialized(optionKey)) revert TokenNotFound(tokenId);
        optionInfo = optionTypeStates[optionKey].option;
    }

    function claim(uint256 claimId) external view returns (Claim memory claimInfo) {
        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(claimId);
        if (!_isClaimInitialized(optionKey, claimKey)) revert TokenNotFound(claimId);

        OptionTypeState storage state = optionTypeStates[optionKey];
        ClaimIndex[] storage claimIndices = state.claimIndices[claimKey];
        uint256 amountWritten;
        uint256 amountExercised;
        for (uint256 i; i < claimIndices.length; i++) {
            ClaimIndex storage ci = claimIndices[i];
            Bucket storage b = state.buckets[ci.bucketIndex];
            amountWritten += ci.amountWritten;
            // FixedPointMathLib.divWadDown(bucket.amountExercised * claimIndex.amountWritten, bucket.amountWritten)
            amountExercised += (uint256(b.amountExercised) * uint256(ci.amountWritten) * 1e18)
                / uint256(b.amountWritten);
        }

        claimInfo = Claim({
            amountWritten: amountWritten * 1e18,
            amountExercised: amountExercised,
            optionId: uint256(optionKey) << OPTION_KEY_PADDING
        });
    }

    function position(uint256 tokenId) external view returns (Position memory positionInfo) {
        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(tokenId);
        TokenType t = tokenType(tokenId);
        if (t == TokenType.None) revert TokenNotFound(tokenId);

        OptionTypeState storage state = optionTypeStates[optionKey];
        Option storage optionRecord = state.option;

        if (t == TokenType.Option) {
            uint40 expiry = optionRecord.expiryTimestamp;
            if (expiry <= block.timestamp) revert ExpiredOption(tokenId, expiry);
            return Position({
                underlyingAsset: optionRecord.underlyingAsset,
                underlyingAmount: int256(uint256(optionRecord.underlyingAmount)),
                exerciseAsset: optionRecord.exerciseAsset,
                exerciseAmount: -int256(uint256(optionRecord.exerciseAmount))
            });
        }

        ClaimIndex[] storage claimIndices = state.claimIndices[claimKey];
        uint256 totalUnderlying;
        uint256 totalExercise;
        for (uint256 i; i < claimIndices.length; i++) {
            (uint256 u, uint256 e) = _getAssetAmountsForClaimIndex(
                optionRecord.underlyingAmount, optionRecord.exerciseAmount, state, claimIndices, i
            );
            totalUnderlying += u;
            totalExercise += e;
        }
        positionInfo = Position({
            underlyingAsset: optionRecord.underlyingAsset,
            underlyingAmount: int256(totalUnderlying),
            exerciseAsset: optionRecord.exerciseAsset,
            exerciseAmount: int256(totalExercise)
        });
    }

    function tokenType(uint256 tokenId) public view returns (TokenType) {
        (uint160 optionKey, uint96 claimKey) = _decodeTokenId(tokenId);
        if (!_isOptionInitialized(optionKey)) return TokenType.None;
        if ((tokenId & CLAIM_KEY_MASK) == 0) return TokenType.Option;
        if (_isClaimInitialized(optionKey, claimKey)) return TokenType.Claim;
        return TokenType.None;
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

    function feeBalance(address token) external view returns (uint256) {
        return _feeBalance[token];
    }

    function tokenURIGenerator() external pure returns (address) {
        return address(0);
    }

    function uri(uint256) external pure returns (string memory) {
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ADMIN (STUBS)
    //////////////////////////////////////////////////////////////*/

    function acceptFeeTo() external pure {}
    function setTokenURIGenerator(address) external pure {}
    function sweepFees(address[] calldata) external pure {}

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

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        if (from != msg.sender && !_operatorApproval[from][msg.sender]) revert NotApproved();
        _balances[from][id] -= amount;
        _balances[to][id] += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);
        _checkReceiver(from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        if (from != msg.sender && !_operatorApproval[from][msg.sender]) {
            revert NotApproved();
        }
        for (uint256 i; i < ids.length; i++) {
            _balances[from][ids[i]] -= amounts[i];
            _balances[to][ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
        _checkBatchReceiver(from, to, ids, amounts, data);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 || interfaceId == 0x01ffc9a7 || interfaceId == 0x0e89341c;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 id, uint256 amount) internal {
        _balances[to][id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
        _checkReceiver(address(0), to, id, amount, "");
    }

    function _batchMint(address to, uint256[] memory ids, uint256[] memory amounts) internal {
        for (uint256 i; i < ids.length; i++) {
            _balances[to][ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, amounts);
        _checkBatchReceiver(address(0), to, ids, amounts, "");
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        _balances[from][id] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /// @dev solmate's acceptance check: a contract recipient must return the hook selector.
    function _checkReceiver(address from, address to, uint256 id, uint256 amount, bytes memory data) internal {
        if (to.code.length == 0) {
            if (to == address(0)) revert UnsafeRecipient();
            return;
        }
        if (
            IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data)
                != IERC1155Receiver.onERC1155Received.selector
        ) revert UnsafeRecipient();
    }

    function _checkBatchReceiver(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            if (to == address(0)) revert UnsafeRecipient();
            return;
        }
        if (
            IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data)
                != IERC1155Receiver.onERC1155BatchReceived.selector
        ) revert UnsafeRecipient();
    }

    function _isOptionInitialized(uint160 optionKey) internal view returns (bool) {
        return optionTypeStates[optionKey].option.underlyingAsset != address(0);
    }

    function _isClaimInitialized(uint160 optionKey, uint96 claimKey) internal view returns (bool) {
        return optionTypeStates[optionKey].claimIndices[claimKey].length > 0;
    }

    /// @dev Upstream's exact per-index payout, integer division and all. Unassigned collateral and
    ///      strike proceeds are both the claim index's share BY AMOUNT WRITTEN of its bucket.
    function _getAssetAmountsForClaimIndex(
        uint256 underlyingAssetAmount,
        uint256 exerciseAssetAmount,
        OptionTypeState storage state,
        ClaimIndex[] storage claimIndexArray,
        uint256 index
    ) internal view returns (uint256 underlyingAmount, uint256 exerciseAmount) {
        ClaimIndex storage ci = claimIndexArray[index];
        Bucket storage b = state.buckets[ci.bucketIndex];
        uint256 ciWritten = ci.amountWritten;
        uint256 bWritten = b.amountWritten;
        uint256 bExercised = b.amountExercised;
        underlyingAmount = ((bWritten - bExercised) * underlyingAssetAmount * ciWritten) / bWritten;
        exerciseAmount = (bExercised * exerciseAssetAmount * ciWritten) / bWritten;
    }

    function _encodeTokenId(uint160 optionKey, uint96 claimKey) internal pure returns (uint256 tokenId) {
        tokenId = (uint256(optionKey) << OPTION_KEY_PADDING) | uint256(claimKey);
    }

    function _decodeTokenId(uint256 tokenId) internal pure returns (uint160 optionKey, uint96 claimKey) {
        optionKey = uint160(tokenId >> OPTION_KEY_PADDING);
        claimKey = uint96(tokenId & CLAIM_KEY_MASK);
    }

    function _typeId(uint256 tokenId) internal pure returns (uint256) {
        return (tokenId >> OPTION_KEY_PADDING) << OPTION_KEY_PADDING;
    }

    /// @dev Upstream `_assignExercise`: start at `seed % n`, consume buckets with swap-and-pop.
    function _assignExercise(
        uint256 optionId_,
        OptionTypeState storage state,
        Option storage optionRecord,
        uint112 amount
    ) internal {
        Bucket[] storage buckets = state.buckets;
        uint96[] storage unexercised = state.unexercisedBucketIndices;
        uint96 numUnexercised = uint96(unexercised.length);
        uint96 exerciseIndex = uint96(optionRecord.settlementSeed % numUnexercised);

        while (amount > 0) {
            uint96 bucketIndex = unexercised[exerciseIndex];
            Bucket storage b = buckets[bucketIndex];

            uint112 available = b.amountWritten - b.amountExercised;
            uint112 presentlyExercised;
            if (available <= amount) {
                amount -= available;
                presentlyExercised = available;
                numUnexercised--;
                uint96 overwrite = unexercised[numUnexercised];
                unexercised[exerciseIndex] = overwrite;
                unexercised.pop();
            } else {
                presentlyExercised = amount;
                amount = 0;
            }
            b.amountExercised += presentlyExercised;

            emit BucketAssignedExercise(optionId_, bucketIndex, presentlyExercised);

            if (amount != 0) exerciseIndex = (exerciseIndex + 1) % numUnexercised;
        }
    }

    /// @dev Upstream `_addOrUpdateBucket`: join the last bucket while it is untouched, else open one.
    function _addOrUpdateBucket(OptionTypeState storage state, uint112 amount) internal returns (uint96) {
        Bucket[] storage buckets = state.buckets;
        uint96 writtenBucketIndex = uint96(buckets.length);

        if (buckets.length == 0) {
            buckets.push(Bucket(amount, 0));
            state.unexercisedBucketIndices.push(writtenBucketIndex);
            return writtenBucketIndex;
        }

        uint96 currentBucketIndex = writtenBucketIndex - 1;
        Bucket storage current = buckets[currentBucketIndex];
        if (current.amountExercised != 0) {
            buckets.push(Bucket(amount, 0));
            state.unexercisedBucketIndices.push(writtenBucketIndex);
        } else {
            current.amountWritten += amount;
            writtenBucketIndex = currentBucketIndex;
        }
        return writtenBucketIndex;
    }

    /// @dev Upstream `_addOrUpdateClaimIndex`: one index per bucket, extended in place for the same bucket.
    function _addOrUpdateClaimIndex(OptionTypeState storage state, uint96 claimKey, uint96 bucketIndex, uint112 amount)
        internal
    {
        ClaimIndex[] storage claimIndices = state.claimIndices[claimKey];
        uint256 len = claimIndices.length;
        if (len == 0) {
            claimIndices.push(ClaimIndex({amountWritten: amount, bucketIndex: bucketIndex}));
            return;
        }
        ClaimIndex storage last = claimIndices[len - 1];
        if (last.bucketIndex < bucketIndex) {
            claimIndices.push(ClaimIndex({amountWritten: amount, bucketIndex: bucketIndex}));
            return;
        }
        last.amountWritten += amount;
    }

    function _calculateRecordAndEmitFee(uint256 optionId_, address assetAddress, uint256 assetAmount)
        internal
        returns (uint256 fee)
    {
        fee = (assetAmount * uint256(_feeBps)) / 10_000;
        if (fee == 0) fee = 1;
        _feeBalance[assetAddress] += fee;
        emit FeeAccrued(optionId_, assetAddress, msg.sender, fee);
    }
}
