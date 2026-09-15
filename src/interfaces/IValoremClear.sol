// SPDX-License-Identifier: GPL-2.0-or-later
// Valorem Labs Inc. (c) 2023. Interface and NatSpec transcribed from valorem-labs-inc/clear
// @ 6436c82. That tree's LICENSE is BUSL 1.1 with Change Date 2026-02-01 (passed) and Change
// License GPL-2.0-or-later, so the upstream code — and this transcription of it — is GPL now.
// The Overcall-authored additions in this file are released under the same licence.
pragma solidity ^0.8.28;

/// @title IValoremClear
/// @notice A faithful SUBSET of the Valorem Clear clearinghouse ABI.
/// @dev PROVENANCE, AS IT APPLIES TO THIS REPOSITORY. This file is a verbatim copy of
///      `src/interfaces/IValoremClear.sol` from the Blockscout-verified source of Overcall's NVDA
///      registry on chain 4663 (`0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA`; recon R1 in
///      stonkhousedotfun/callhouse `ops/recon/`, which keeps the same file under `ops/abis/`). Overcall wrote
///      this interface as a hand transcription of Valorem's clearinghouse at upstream commit
///      `6436c82` (`valorem-labs-inc/clear`, formerly valorem-core, `6436c823f560af493af119d6148fb3237037aca4`; recon
///      R4 recompiled that commit and matched the deployed Clear
///      `0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`). Comments only have changed from the verified
///      copy: this provenance paragraph, and wording that pointed at files in Overcall's tree.
///      Those files — a vendored `lib/clear` tree, `script/lib/ValoremDeployer.sol`,
///      `src/vendor/ValoremArtifacts.sol`, `test/e2e/ValoremLifecycle.t.sol` — belong to Overcall's
///      non-public repository and do not exist here, so "vendored" now reads "upstream".
///
///      Every struct, enum, event, error and function signature below was transcribed from
///      upstream `src/interfaces/IValoremOptionsClearinghouse.sol` and
///      `lib/solmate/src/tokens/ERC1155.sol`, preserving field names, types, declaration order and
///      `indexed` flags. If Valorem's deployment ever moves, re-transcribe rather than adapt.
///
///      This file is deliberately a hand copy and imports nothing from Valorem. Valorem is pinned
///      to `pragma solidity 0.8.16`; this codebase is `^0.8.28`. The two must never enter the same
///      compilation unit, so the upstream interface cannot be imported here.
///
///      Two deviations, both ABI-identical to the upstream declarations:
///        - `tokenURIGenerator()` returns `address` rather than `ITokenURIGenerator`, so that the
///          0.8.16 `ITokenURIGenerator` need not be copied as well.
///        - `sweepFees(address[])` is declared `calldata` here; the upstream interface says `memory`
///          and the implementation says `calldata`. Location does not affect the external selector.
///
///      ## Token id encoding
///
///      Option and claim ids share one ERC-1155 id space, split at bit 96:
///
///          tokenId = (uint256(optionKey) << 96) | uint256(claimKey)
///
///      where `optionKey` is the upper 160 bits and `claimKey` the lower 96 (masked with
///      `0xFFFFFFFFFFFFFFFFFFFFFFFF`). `claimKey == 0` denotes the fungible long option token;
///      `claimKey >= 1` denotes an individual short-position claim NFT of that option type, numbered
///      by an auto-incrementing counter (`Option.nextClaimKey`). Hence the first `write()` against a
///      fresh option type returns `claimId == optionId + 1`.
///
///      The option key is the hash of the SIX option tuple fields, so an option id is precomputable
///      off-chain:
///
///          uint160 optionKey = uint160(bytes20(keccak256(abi.encode(
///              underlyingAsset, underlyingAmount, exerciseAsset, exerciseAmount,
///              exerciseTimestamp, expiryTimestamp
///          ))));
///          uint256 optionId = uint256(optionKey) << 96;
///
///      SIX fields, not eight. The upstream `IValoremOptionsClearinghouse.sol` NatSpec documents an
///      eight-field encode that also hashes `settlementSeed` and `nextClaimKey` as
///      `uint160(0), uint96(0)`; that comment is STALE and does not match the code it annotates.
///      `ValoremOptionsClearinghouse.newOptionType` (lines 341-354 of the upstream implementation)
///      hashes the six tuple fields only, and `abi.encode` pads each argument to its own 32-byte
///      word, so eight words hash to a different digest than six. The IMPLEMENTATION is
///      authoritative. Overcall's `test_Cycle_OptionIdIsPrecomputable` (in their repository, not
///      this one) pins the six-field formula against the deployed bytecode.
///
///      `tokenType(id)` then reports `Option`, `Claim`, or `None` if the id was never initialised.
interface IValoremClear {
    /*//////////////////////////////////////////////////////////////
    //  Data Structures
    //////////////////////////////////////////////////////////////*/

    /// @notice The type of an ERC1155 subtoken in the clearinghouse.
    enum TokenType {
        None,
        Option,
        Claim
    }

    /// @notice Data comprising the unique tuple of an option type associated with an ERC-1155 option token.
    struct Option {
        /// @custom:member underlyingAsset The underlying ERC20 asset which the option is collateralized with.
        address underlyingAsset;
        /// @custom:member underlyingAmount The amount of the underlying asset contained within an option contract of this type.
        uint96 underlyingAmount;
        /// @custom:member exerciseAsset The ERC20 asset which the option can be exercised using.
        address exerciseAsset;
        /// @custom:member exerciseAmount The amount of the exercise asset required to exercise each option contract of this type.
        uint96 exerciseAmount;
        /// @custom:member exerciseTimestamp The timestamp after which this option can be exercised.
        uint40 exerciseTimestamp;
        /// @custom:member expiryTimestamp The timestamp before which this option can be exercised.
        uint40 expiryTimestamp;
        /// @custom:member settlementSeed Deterministic seed used for option fair exercise assignment.
        uint160 settlementSeed;
        /// @custom:member nextClaimKey The next claim key available for this option type.
        uint96 nextClaimKey;
    }

    /// @notice Data about a claim to a short position written on an option type.
    /// @dev `amountWritten` and `amountExercised` are 1e18-scaled scalars, not raw contract counts.
    struct Claim {
        /// @custom:member amountWritten The number of option contracts written against this claim expressed as a 1e18 scalar value.
        uint256 amountWritten;
        /// @custom:member amountExercised The amount of option contracts exercised against this claim expressed as a 1e18 scalar value.
        uint256 amountExercised;
        /// @custom:member optionId The option ID of the option type this claim is for.
        uint256 optionId;
    }

    /// @notice Data about the ERC20 assets and liabilities for a given option (long) or claim (short)
    ///         token, in terms of the underlying and exercise ERC20 tokens.
    struct Position {
        /// @custom:member underlyingAsset The address of the ERC20 underlying asset.
        address underlyingAsset;
        /// @custom:member underlyingAmount The amount, in wei, of the underlying asset represented by this position.
        int256 underlyingAmount;
        /// @custom:member exerciseAsset The address of the ERC20 exercise asset.
        address exerciseAsset;
        /// @custom:member exerciseAmount The amount, in wei, of the exercise asset represented by this position.
        int256 exerciseAmount;
    }

    /*//////////////////////////////////////////////////////////////
    //  Events — Write
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new option type is created.
    /// @dev Note `optionId` is NOT indexed while `expiryTimestamp` IS, exactly as upstream.
    /// @param optionId The token id of the new option type created.
    /// @param exerciseAsset The ERC20 contract address of the exercise asset.
    /// @param underlyingAsset The ERC20 contract address of the underlying asset.
    /// @param exerciseAmount The amount, in wei, of the exercise asset required to exercise each contract.
    /// @param underlyingAmount The amount, in wei of the underlying asset in each contract.
    /// @param exerciseTimestamp The timestamp after which this option type can be exercised.
    /// @param expiryTimestamp The timestamp before which this option type can be exercised.
    event NewOptionType(
        uint256 optionId,
        address indexed exerciseAsset,
        address indexed underlyingAsset,
        uint96 exerciseAmount,
        uint96 underlyingAmount,
        uint40 exerciseTimestamp,
        uint40 indexed expiryTimestamp
    );

    /// @notice Emitted when new options contracts are written.
    /// @param optionId The token id of the option type written.
    /// @param writer The address of the writer.
    /// @param claimId The claim token id of the new or existing short position written against.
    /// @param amount The amount of options contracts written.
    event OptionsWritten(uint256 indexed optionId, address indexed writer, uint256 indexed claimId, uint112 amount);

    /// @notice Emitted when options contracts are written into a bucket.
    /// @param optionId The token id of the option type written.
    /// @param claimId The claim token id of the new or existing short position written against.
    /// @param bucketIndex The index of the bucket to which the options were written.
    /// @param amount The amount of options contracts written.
    event BucketWrittenInto(
        uint256 indexed optionId, uint256 indexed claimId, uint96 indexed bucketIndex, uint112 amount
    );

    /*//////////////////////////////////////////////////////////////
    //  Events — Redeem
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a claim is redeemed.
    /// @dev The declaration order is `(claimId, optionId, redeemer, ...)`, which is the reverse of
    ///      the first two entries in the upstream NatSpec block; the declaration is authoritative.
    /// @param claimId The token id of the claim being redeemed.
    /// @param optionId The token id of the option type of the claim being redeemed.
    /// @param redeemer The address redeeming the claim.
    /// @param exerciseAmountRedeemed The amount of the option.exerciseAsset redeemed.
    /// @param underlyingAmountRedeemed The amount of option.underlyingAsset redeemed.
    event ClaimRedeemed(
        uint256 indexed claimId,
        uint256 indexed optionId,
        address indexed redeemer,
        uint256 exerciseAmountRedeemed,
        uint256 underlyingAmountRedeemed
    );

    /*//////////////////////////////////////////////////////////////
    //  Events — Exercise
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when option contract(s) is(are) exercised.
    /// @param optionId The token id of the option type exercised.
    /// @param exerciser The address that exercised the option contract(s).
    /// @param amount The amount of option contracts exercised.
    event OptionsExercised(uint256 indexed optionId, address indexed exerciser, uint112 amount);

    /// @notice Emitted when a bucket is assigned exercise.
    /// @param optionId The token id of the option type exercised.
    /// @param bucketIndex The index of the bucket which is being assigned exercise.
    /// @param amountAssigned The amount of options contracts assigned exercise in the given bucket.
    event BucketAssignedExercise(uint256 indexed optionId, uint96 indexed bucketIndex, uint112 amountAssigned);

    /*//////////////////////////////////////////////////////////////
    //  Events — Fees
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when protocol fees are accrued for a given asset.
    /// @dev Emitted on write() when fees are accrued on the underlying asset, or exercise() when fees
    ///      are accrued on the exercise asset. Will not be emitted when feesEnabled is false.
    /// @param optionId The token id of the option type being written or exercised.
    /// @param asset The ERC20 asset in which fees were accrued.
    /// @param payer The address paying the fee.
    /// @param amount The amount, in wei, of fees accrued.
    event FeeAccrued(uint256 indexed optionId, address indexed asset, address indexed payer, uint256 amount);

    /// @notice Emitted when accrued protocol fees for a given ERC20 asset are swept to the feeTo address.
    /// @param asset The ERC20 asset of the protocol fees swept.
    /// @param feeTo The account to which fees were swept.
    /// @param amount The total amount swept.
    event FeeSwept(address indexed asset, address indexed feeTo, uint256 amount);

    /// @notice Emitted when protocol fees are enabled or disabled.
    /// @dev Neither parameter is indexed, exactly as upstream.
    /// @param feeTo The address which enabled or disabled fees.
    /// @param enabled Whether fees are enabled or disabled.
    event FeeSwitchUpdated(address feeTo, bool enabled);

    /*//////////////////////////////////////////////////////////////
    //  Events — Access control
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when feeTo address is updated.
    /// @param newFeeTo The new feeTo address.
    event FeeToUpdated(address indexed newFeeTo);

    /// @notice Emitted when TokenURIGenerator is updated.
    /// @param newTokenURIGenerator The new TokenURIGenerator address.
    event TokenURIGeneratorUpdated(address indexed newTokenURIGenerator);

    /*//////////////////////////////////////////////////////////////
    //  Events — ERC-1155 (solmate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on a single-id ERC-1155 transfer, mint or burn.
    event TransferSingle(
        address indexed operator, address indexed from, address indexed to, uint256 id, uint256 amount
    );

    /// @notice Emitted on a batched ERC-1155 transfer, mint or burn.
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );

    /// @notice Emitted when an operator's blanket approval for `owner` changes.
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Emitted when the metadata URI for `id` changes.
    event URI(string value, uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
    //  Errors — Access control
    //////////////////////////////////////////////////////////////*/

    /// @notice The caller doesn't have permission to access that function.
    /// @param accessor The requesting address.
    /// @param permissioned The address which has the requisite permissions.
    error AccessControlViolation(address accessor, address permissioned);

    /*//////////////////////////////////////////////////////////////
    //  Errors — Input
    //////////////////////////////////////////////////////////////*/

    /// @notice The amount of option contracts written must be greater than zero.
    error AmountWrittenCannotBeZero();

    /// @notice This claim is not owned by the caller.
    /// @param claimId Supplied claim ID.
    error CallerDoesNotOwnClaimId(uint256 claimId);

    /// @notice The caller does not have enough option contracts to exercise the amount specified.
    /// @param optionId The supplied option id.
    /// @param amount The amount of option contracts which the caller attempted to exercise.
    error CallerHoldsInsufficientOptions(uint256 optionId, uint112 amount);

    /// @notice Claims cannot be redeemed before expiry.
    /// @param claimId Supplied claim ID.
    /// @param expiry timestamp at which the option type expires.
    error ClaimTooSoon(uint256 claimId, uint40 expiry);

    /// @notice This option cannot yet be exercised.
    /// @param optionId Supplied option ID.
    /// @param exercise The time after which the option optionId be exercised.
    error ExerciseTooEarly(uint256 optionId, uint40 exercise);

    /// @notice The option exercise window is too short.
    /// @param exercise The timestamp supplied for exercise.
    error ExerciseWindowTooShort(uint40 exercise);

    /// @notice The optionId specified expired has already expired.
    /// @param optionId The id of the expired option.
    /// @param expiry The expiry time for the supplied option Id.
    error ExpiredOption(uint256 optionId, uint40 expiry);

    /// @notice The expiry timestamp is too soon.
    /// @param expiry Timestamp of expiry.
    error ExpiryWindowTooShort(uint40 expiry);

    /// @notice Invalid (zero) address.
    /// @param input The address input.
    error InvalidAddress(address input);

    /// @notice The assets specified are invalid or duplicate.
    /// @param asset1 Supplied ERC20 asset.
    /// @param asset2 Supplied ERC20 asset.
    error InvalidAssets(address asset1, address asset2);

    /// @notice The token specified is not a claim token.
    /// @param token The supplied token id.
    error InvalidClaim(uint256 token);

    /// @notice The token specified is not an option token.
    /// @param token The supplied token id.
    error InvalidOption(uint256 token);

    /// @notice This option contract type already exists and thus cannot be created.
    /// @param optionId The token id of the option type which already exists.
    error OptionsTypeExists(uint256 optionId);

    /// @notice The requested token is not found.
    /// @param token The token requested.
    error TokenNotFound(uint256 token);

    /*//////////////////////////////////////////////////////////////
    //  Views — Option information
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets information about an option.
    /// @param tokenId The tokenId of an option or claim.
    /// @return optionInfo The Option for the given tokenId.
    function option(uint256 tokenId) external view returns (Option memory optionInfo);

    /// @notice Gets information about a claim.
    /// @param claimId The tokenId of the claim.
    /// @return claimInfo The Claim for the given claimId.
    function claim(uint256 claimId) external view returns (Claim memory claimInfo);

    /// @notice Gets information about the ERC20 token positions of an option or claim.
    /// @param tokenId The tokenId of the option or claim.
    /// @return positionInfo The underlying and exercise token positions for the given tokenId.
    function position(uint256 tokenId) external view returns (Position memory positionInfo);

    /*//////////////////////////////////////////////////////////////
    //  Views — Token information
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets the TokenType for a given tokenId.
    /// @dev Accounts for the `optionKey << 96 | claimKey` split described in the header, and for
    ///      whether the id has been initialised yet — an unknown id reports {TokenType.None}.
    /// @param tokenId The token id to get the TokenType of.
    /// @return typeOfToken The enum TokenType of the tokenId.
    function tokenType(uint256 tokenId) external view returns (TokenType typeOfToken);

    /// @notice Gets the contract address for generating token URIs for tokens.
    /// @dev Vendored as `ITokenURIGenerator`; declared `address` here, which is ABI-identical.
    /// @return uriGenerator the address of the URI generator contract.
    function tokenURIGenerator() external view returns (address uriGenerator);

    /// @notice The ERC-1155 metadata URI for `tokenId`, a base64 data URI built by the generator.
    /// @param tokenId The option or claim token id.
    /// @return The token URI.
    function uri(uint256 tokenId) external view returns (string memory);

    /*//////////////////////////////////////////////////////////////
    //  Views — Fee information
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets the balance of protocol fees for a given token which have not been swept yet.
    /// @param token The token for the un-swept fee balance.
    /// @return The balance of un-swept fees.
    function feeBalance(address token) external view returns (uint256);

    /// @notice Gets the protocol fee, expressed in basis points.
    /// @dev A `uint8 public constant` equal to 15 in the deployed contract; it cannot be changed.
    /// @return fee The protocol fee.
    function feeBps() external view returns (uint8 fee);

    /// @notice Checks if protocol fees are enabled.
    /// @dev False on a freshly deployed clearinghouse; the constructor never assigns it.
    /// @return enabled Whether or not protocol fees are enabled.
    function feesEnabled() external view returns (bool enabled);

    /// @notice Returns the address to which protocol fees are swept.
    /// @dev Also the sole privileged role: `setFeesEnabled`, `setFeeTo`, `setTokenURIGenerator` and
    ///      `sweepFees` are all `onlyFeeTo`.
    /// @return The address to which fees are swept.
    function feeTo() external view returns (address);

    /*//////////////////////////////////////////////////////////////
    //  Write Options
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new option contract type if it doesn't already exist.
    /// @dev The resulting `optionId` is precomputable off-chain as
    ///      `uint256(uint160(bytes20(keccak256(abi.encode(underlyingAsset, underlyingAmount, exerciseAsset,
    ///      exerciseAmount, exerciseTimestamp, expiryTimestamp))))) << 96` — the six tuple fields and
    ///      nothing else. See the header: the upstream NatSpec's eight-field variant is stale and the
    ///      implementation is authoritative.
    /// @param underlyingAsset The contract address of the ERC20 underlying asset.
    /// @param underlyingAmount The amount of underlyingAsset, in wei, collateralizing each option contract.
    /// @param exerciseAsset The contract address of the ERC20 exercise asset.
    /// @param exerciseAmount The amount of exerciseAsset, in wei, required to exercise each option contract.
    /// @param exerciseTimestamp The timestamp after which this option can be exercised.
    /// @param expiryTimestamp The timestamp before which this option can be exercised.
    /// @return optionId The token id for the new option type created by this call.
    function newOptionType(
        address underlyingAsset,
        uint96 underlyingAmount,
        address exerciseAsset,
        uint96 exerciseAmount,
        uint40 exerciseTimestamp,
        uint40 expiryTimestamp
    ) external returns (uint256 optionId);

    /// @notice Writes a specified amount of the specified option, returning claim NFT id.
    /// @dev There is exactly one `write` in Valorem Clear — no overload. Pass an `optionId` to open a
    ///      fresh claim, or an existing `claimId` to add to it.
    /// @param tokenId The desired token id to write against, input an optionId to get a new claim, or
    ///        a claimId to add to an existing claim.
    /// @param amount The desired number of option contracts to write.
    /// @return claimId The token id of the claim NFT which was input or created.
    function write(uint256 tokenId, uint112 amount) external returns (uint256 claimId);

    /*//////////////////////////////////////////////////////////////
    //  Redeem Claims
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeems a claim NFT, transfers the underlying/exercise tokens to the caller. Can be
    ///         called after option expiry timestamp (inclusive).
    /// @param claimId The ID of the claim to redeem.
    function redeem(uint256 claimId) external;

    /*//////////////////////////////////////////////////////////////
    //  Exercise Options
    //////////////////////////////////////////////////////////////*/

    /// @notice Exercises specified amount of optionId, transferring in the exercise asset, and
    ///         transferring out the underlying asset if requirements are met. Can be called from
    ///         exercise timestamp (inclusive), until option expiry timestamp (exclusive).
    /// @param optionId The option token id of the option type to exercise.
    /// @param amount The amount of option contracts to exercise.
    function exercise(uint256 optionId, uint112 amount) external;

    /*//////////////////////////////////////////////////////////////
    //  Protocol Admin
    //////////////////////////////////////////////////////////////*/

    /// @notice Enables or disables protocol fees.
    /// @param enabled Whether or not protocol fees should be enabled.
    function setFeesEnabled(bool enabled) external;

    /// @notice Nominates a new address to which fees should be swept, requiring the new feeTo address
    ///         to accept before the update is complete. See also {acceptFeeTo}.
    /// @param newFeeTo The new address to which fees should be swept.
    function setFeeTo(address newFeeTo) external;

    /// @notice Accepts the new feeTo address and completes the update. See also {setFeeTo}.
    function acceptFeeTo() external;

    /// @notice Updates the contract address for generating token URIs for tokens.
    /// @param newTokenURIGenerator The address of the new ITokenURIGenerator contract.
    function setTokenURIGenerator(address newTokenURIGenerator) external;

    /// @notice Sweeps fees to the feeTo address if there is more than 1 wei for feeBalance for a
    ///         given token.
    /// @dev Vendored as `memory` in the interface and `calldata` in the implementation; the external
    ///      selector is the same either way.
    /// @param tokens An array of tokens to sweep fees for.
    function sweepFees(address[] calldata tokens) external;

    /*//////////////////////////////////////////////////////////////
    //  ERC-1155 (solmate)
    //////////////////////////////////////////////////////////////*/

    /// @notice The amount of token `id` held by `owner`.
    /// @dev A public mapping on the implementation; long option tokens are fungible, claim NFTs have
    ///      a balance of exactly 1.
    /// @param owner The account to query.
    /// @param id The option or claim token id.
    /// @return The balance.
    function balanceOf(address owner, uint256 id) external view returns (uint256);

    /// @notice Whether `operator` may move every token of `owner`.
    /// @dev This is the approval Seaport's conduit or the Seaport contract itself requires in order
    ///      to fill an order whose offer item is a Valorem option or claim token.
    /// @param owner The token owner.
    /// @param operator The operator to query.
    /// @return True when approved.
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice Grants or revokes `operator` blanket approval over the caller's tokens.
    /// @param operator The operator to approve.
    /// @param approved True to approve, false to revoke.
    function setApprovalForAll(address operator, bool approved) external;

    /// @notice Transfers `amount` of token `id` from `from` to `to`.
    /// @dev solmate's implementation requires `msg.sender == from || isApprovedForAll[from][msg.sender]`
    ///      and calls `onERC1155Received` on contract recipients.
    /// @param from The sender.
    /// @param to The recipient.
    /// @param id The option or claim token id.
    /// @param amount The amount to transfer.
    /// @param data Arbitrary data forwarded to the recipient hook.
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;

    /// @notice The balances of several `(owner, id)` pairs in one call.
    /// @dev The natural read for a cycle grid: one call returns the caller's position in all five
    ///      strikes. solmate reverts `"LENGTH_MISMATCH"` when the two arrays differ in length.
    /// @param owners The accounts to query, one per entry of `ids`.
    /// @param ids The option or claim token ids to query, one per entry of `owners`.
    /// @return balances The balance of `ids[i]` held by `owners[i]`, in order.
    function balanceOfBatch(address[] calldata owners, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory balances);

    /// @notice Transfers several token ids from `from` to `to` in one call.
    /// @dev Same authorisation as {safeTransferFrom} — `msg.sender == from || isApprovedForAll[from][msg.sender]`
    ///      — and calls `onERC1155BatchReceived` on contract recipients. Reverts `"LENGTH_MISMATCH"`
    ///      when `ids` and `amounts` differ in length.
    /// @param from The sender.
    /// @param to The recipient.
    /// @param ids The option or claim token ids to transfer.
    /// @param amounts The amount to transfer of each id, in order.
    /// @param data Arbitrary data forwarded to the recipient hook.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    /// @notice ERC-165 support, as solmate's ERC1155 implements it.
    /// @dev Returns true for exactly three ids and nothing else: `0x01ffc9a7` (ERC-165),
    ///      `0xd9b67a26` (ERC-1155) and `0x0e89341c` (ERC-1155 metadata URI). Wallets and
    ///      marketplaces probe `0xd9b67a26` before rendering an option token, so the front end can
    ///      rely on it.
    /// @param interfaceId The ERC-165 interface id to probe.
    /// @return True when the interface is supported.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
