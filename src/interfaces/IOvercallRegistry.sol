// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IOvercallRegistry
/// @notice The read and admin surface of {OvercallRegistry}, the one contract Overcall writes.
/// @dev The registry is a configuration record and nothing else. It states which Valorem Clear option
///      types make up the current weekly cycle, so the front end can display exactly those and no
///      look-alike that anyone could have created with the permissionless `newOptionType`.
///
///      It never holds, moves or is approved for a single token. There is no `payable`, no `receive`,
///      no `fallback`, no ERC-20 or ERC-1155 call anywhere in it, and it is never an intermediary in
///      the fund path: users call the clearinghouse directly, so they remain the writer and the owner
///      of their own Claim NFT. See V2 §4 and §10.
interface IOvercallRegistry {
    /*//////////////////////////////////////////////////////////////
    //  Data Structures
    //////////////////////////////////////////////////////////////*/

    /// @notice The full description of one cycle, in one read.
    /// @dev Returned by {cycle} for the current one and by {cycleAt} for any recorded one, so the
    ///      front end fetches a whole grid in a single call rather than six.
    struct Cycle {
        /// @custom:member number The 1-based cycle counter; 0 before any cycle has been set.
        uint32 number;
        /// @custom:member exerciseTimestamp The timestamp from which every option of the cycle can be exercised.
        uint40 exerciseTimestamp;
        /// @custom:member expiryTimestamp The timestamp at which every option of the cycle expires.
        uint40 expiryTimestamp;
        /// @custom:member lotSize The lot size THIS cycle was validated against, in 18-decimal units.
        ///                        Snapshotted at {setCycle}, so it keeps matching the `underlyingAmount`
        ///                        of `optionIds` even after {setLotSize} moves the forward-looking
        ///                        {lotSize} once the cycle has expired.
        uint96 lotSize;
        /// @custom:member optionIds The approved Valorem option ids, ordered by ascending strike.
        uint256[] optionIds;
    }

    /*//////////////////////////////////////////////////////////////
    //  Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new cycle replaces the previous one.
    /// @param number The new cycle number.
    /// @param optionIds The approved option ids, ordered by ascending strike.
    /// @param exerciseAt The shared exercise timestamp of every id.
    /// @param expireAt The shared expiry timestamp of every id.
    /// @param lotSize The lot size every id was validated against.
    event CycleSet(uint32 indexed number, uint256[] optionIds, uint40 exerciseAt, uint40 expireAt, uint96 lotSize);

    /// @notice Emitted when the lot size changes.
    /// @param previousLotSize The lot size before the change.
    /// @param newLotSize The lot size after the change.
    event LotSizeSet(uint96 previousLotSize, uint96 newLotSize);

    /*//////////////////////////////////////////////////////////////
    //  Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the underlying and exercise assets are the same address.
    /// @dev Valorem rejects this too; failing here keeps the registry's own invariants total.
    error IdenticalAssets(address asset);

    /// @notice Thrown when a zero lot size is supplied.
    error ZeroLotSize();

    /// @notice Thrown when {setCycle} is given an empty array.
    error EmptyCycle();

    /// @notice Thrown when {setCycle} is given more ids than the grid allows.
    /// @param provided The number of ids supplied.
    /// @param maximum The maximum number of strikes per cycle.
    error TooManyStrikes(uint256 provided, uint256 maximum);

    /// @notice Thrown when the exercise timestamp is not strictly in the future.
    /// @param exerciseAt The supplied exercise timestamp.
    /// @param currentTime The current block timestamp.
    error ExerciseNotInFuture(uint40 exerciseAt, uint40 currentTime);

    /// @notice Thrown when the exercise window is shorter than {MIN_EXERCISE_WINDOW}.
    /// @dev V2 §7: the chain runs a single sequencer, so a short window could strand an in-the-money
    ///      holder during an outage. Twenty-four hours is a floor, not a target.
    /// @param exerciseAt The supplied exercise timestamp.
    /// @param expireAt The supplied expiry timestamp.
    /// @param minimumWindow The minimum permitted window, in seconds.
    error ExerciseWindowTooShort(uint40 exerciseAt, uint40 expireAt, uint256 minimumWindow);

    /// @notice Thrown when a supplied id is not an option token of the clearinghouse.
    /// @dev Catches a claim NFT id, a never-created id, and any id belonging to another contract.
    /// @param optionId The offending id.
    error NotAnOptionType(uint256 optionId);

    /// @notice Thrown when an option's underlying asset is not the registry's collateral token.
    /// @param optionId The offending id.
    /// @param expected The registry's collateral token.
    /// @param actual The option's underlying asset.
    error UnderlyingAssetMismatch(uint256 optionId, address expected, address actual);

    /// @notice Thrown when an option's exercise asset is not the registry's exercise token.
    /// @param optionId The offending id.
    /// @param expected The registry's exercise token.
    /// @param actual The option's exercise asset.
    error ExerciseAssetMismatch(uint256 optionId, address expected, address actual);

    /// @notice Thrown when an option's underlying amount is not the registry's lot size.
    /// @param optionId The offending id.
    /// @param expected The registry's lot size.
    /// @param actual The option's underlying amount.
    error LotSizeMismatch(uint256 optionId, uint96 expected, uint96 actual);

    /// @notice Thrown when an option's exercise timestamp differs from the cycle's.
    /// @param optionId The offending id.
    /// @param expected The cycle's exercise timestamp.
    /// @param actual The option's exercise timestamp.
    error ExerciseTimestampMismatch(uint256 optionId, uint40 expected, uint40 actual);

    /// @notice Thrown when an option's expiry timestamp differs from the cycle's.
    /// @param optionId The offending id.
    /// @param expected The cycle's expiry timestamp.
    /// @param actual The option's expiry timestamp.
    error ExpiryTimestampMismatch(uint256 optionId, uint40 expected, uint40 actual);

    /// @notice Thrown when an option carries a zero strike.
    /// @param optionId The offending id.
    error ZeroStrike(uint256 optionId);

    /// @notice Thrown when the ids are not ordered by strictly increasing strike.
    /// @dev A strict order is simultaneously the ladder's sort guarantee and its duplicate check, and
    ///      the equivalence is exact in both directions. Two identical ids carry the same strike, so a
    ///      duplicate always trips this error. Conversely, once assets, lot size and both timestamps
    ///      are pinned equal by the checks above, the Valorem option key is a hash of that tuple plus
    ///      the strike — so two ids with an equal strike ARE the same id. "Duplicate" and "equal
    ///      strike" are therefore the same condition, and one comparison covers both.
    /// @param optionId The id that broke the order.
    /// @param previousStrike The strike of the preceding id.
    /// @param strike The strike of the offending id.
    error StrikesNotAscending(uint256 optionId, uint96 previousStrike, uint96 strike);

    /// @notice Thrown when a change that a live cycle depends on is attempted before its expiry.
    /// @dev Raised by {setLotSize} for any change while {isCycleLive}, and by {setCycle} whenever
    ///      {canReplaceCycle} is false — that is, while the cycle is live AND something has been
    ///      written against it. Both callers protect the same thing: the approved ids of a live cycle
    ///      are the only ones the front end shows and the only ones {isApproved} recognises, so
    ///      replacing them once positions exist would hide those positions from the holders who must
    ///      exercise them and the writers who must redeem them.
    /// @param expiryTimestamp The expiry the caller must wait past.
    error CycleStillLive(uint40 expiryTimestamp);

    /// @notice Thrown by {cycleAt} when `index` is beyond the recorded history.
    /// @param index The requested index.
    /// @param count The number of cycles recorded so far, i.e. the exclusive upper bound.
    error CycleIndexOutOfBounds(uint256 index, uint256 count);

    /// @notice Thrown by {renounceOwnership}, which is permanently disabled.
    /// @dev An ownerless registry can never set another cycle, so the front end would serve a stale,
    ///      expired ladder for good with no on-chain way back. {Ownable2Step} handover is the only
    ///      supported way to change the admin.
    error RenounceDisabled();

    /*//////////////////////////////////////////////////////////////
    //  Admin
    //////////////////////////////////////////////////////////////*/

    /// @notice Replaces the active cycle with a validated grid of option ids.
    /// @dev Every id is read back from the clearinghouse and checked against the registry's own
    ///      immutables, the shared timestamps and the lot size, so an approved id can never point at a
    ///      look-alike option type. Strikes are not computed here — ops derives the ladder off-chain
    ///      and this call only records what was approved. Replaces the previous cycle wholesale.
    ///
    ///      One cycle at a time, by construction (V2 §10). A live cycle may be replaced only while
    ///      {canReplaceCycle} holds — nothing has been written against any of its ids — which lets a
    ///      fat-fingered ladder be corrected on the spot. Once one contract is written the cycle is
    ///      locked until expiry and any call reverts {CycleStillLive}, so a mid-week replacement can
    ///      never de-approve ids that holders still have to exercise and writers still have to
    ///      redeem, and two expiries can never be advertised at once.
    ///
    ///      The cost of that guarantee: `write` is permissionless, so one third party writing a
    ///      single contract on an approved id closes the correction window until expiry. That is a
    ///      griefing vector against operator-error recovery, never against funds — the real guard is
    ///      ops verifying the ladder BEFORE `newOptionType`, since the ids are immutable once
    ///      created. A cycle set with a mistaken far-future window and a written position cannot be
    ///      withdrawn at all; the registry holds nothing, so the recovery is a redeploy and a
    ///      front-end repoint, which is also the documented recovery for a wrong asset.
    /// @param optionIds The Valorem option ids of the cycle, ordered by ascending strike.
    /// @param exerciseAt The shared exercise timestamp, strictly in the future.
    /// @param expireAt The shared expiry timestamp, at least {MIN_EXERCISE_WINDOW} after `exerciseAt`.
    function setCycle(uint256[] calldata optionIds, uint40 exerciseAt, uint40 expireAt) external;

    /// @notice Sets the underlying amount collateralising one contract, for future cycles.
    /// @dev Only callable when no cycle is live, so the lot size a cycle was validated against cannot
    ///      change underneath it. Never retroactive: the option types of a past cycle keep the
    ///      `underlyingAmount` they were created with.
    /// @param newLotSize The new lot size, in 18-decimal units of the collateral token.
    function setLotSize(uint96 newLotSize) external;

    /*//////////////////////////////////////////////////////////////
    //  Views
    //////////////////////////////////////////////////////////////*/

    /// @notice The minimum exercise window, in seconds.
    /// @return The minimum number of seconds between `exerciseAt` and `expireAt`.
    function MIN_EXERCISE_WINDOW() external view returns (uint256);

    /// @notice The maximum number of strikes in one cycle.
    /// @return The maximum array length accepted by {setCycle}.
    function MAX_STRIKES() external view returns (uint256);

    /// @notice The Valorem Clear instance whose option types this registry approves.
    /// @return The clearinghouse address.
    function clearinghouse() external view returns (address);

    /// @notice The collateral (underlying) token every approved option must be written on.
    /// @return The collateral token address.
    function collateralToken() external view returns (address);

    /// @notice The exercise (settlement) token every approved option must be struck in.
    /// @return The exercise token address.
    function exerciseToken() external view returns (address);

    /// @notice The underlying amount collateralising one contract, for the NEXT cycle.
    /// @dev Forward-looking: {setLotSize} may move it once no cycle is live, which does not touch the
    ///      already-created option types of the last cycle. Use {cycleLotSize} for the size the
    ///      currently listed ids actually carry.
    /// @return The lot size, in 18-decimal units.
    function lotSize() external view returns (uint96);

    /// @notice The lot size the currently recorded cycle was validated against.
    /// @dev Snapshotted by {setCycle} and never moved afterwards, so it always equals the
    ///      `underlyingAmount` of every id in {activeOptionIds} — including after expiry, when
    ///      {setLotSize} is free to change {lotSize} for the next cycle while writers are still
    ///      redeeming against these ids. 0 before the first cycle.
    /// @return The lot size of the recorded cycle, in 18-decimal units.
    function cycleLotSize() external view returns (uint96);

    /// @notice The current cycle number; 0 before the first {setCycle}.
    /// @return The cycle number.
    function cycleNumber() external view returns (uint32);

    /// @notice The exercise timestamp shared by every option of the current cycle.
    /// @return The exercise timestamp.
    function exerciseTimestamp() external view returns (uint40);

    /// @notice The expiry timestamp shared by every option of the current cycle.
    /// @return The expiry timestamp.
    function expiryTimestamp() external view returns (uint40);

    /// @notice The instant after which Overcall stops accepting writes for the current cycle.
    /// @dev Equal to {exerciseTimestamp}, and 0 before the first {setCycle}.
    ///
    ///      **This is an Overcall product rule, not a clearinghouse rule.** Valorem Clear itself
    ///      accepts `write` right up to `expiryTimestamp` — a full 24 hours later, all the way
    ///      through the exercise window. Overcall closes writes a day earlier, at the exercise
    ///      timestamp, and the reason is exercise assignment.
    ///
    ///      Valorem assigns exercises to *buckets*, not to writers. `_addOrUpdateBucket` opens a new
    ///      bucket only when the current one has `amountExercised != 0`, so every writer who writes
    ///      BEFORE the first exercise of the cycle lands in bucket 0 together, and an exercise
    ///      against bucket 0 is split strictly pro rata by `amountWritten`
    ///      (`_getAssetAmountsForClaimIndex`). One bucket means assignment is exactly each writer's
    ///      share of the open interest at that strike — which is the only assignment story a covered
    ///      call product can state truthfully and simply.
    ///
    ///      The moment somebody writes AFTER an exercise has landed, a second bucket opens and that
    ///      property is gone. Which bucket is drawn first is
    ///      `settlementSeed % unexercisedBucketIndices.length`, and in the deployed master
    ///      `settlementSeed` is set to `optionKey` at `newOptionType` and never written again — so
    ///      the draw is uniform over BUCKETS regardless of how many contracts each holds, and it is
    ///      fully predictable from the option id. Those are Zellic April 2023 findings 3.2 (Medium,
    ///      "Probability of bucket exercise() not correlated with size") and 3.3 (Informational,
    ///      "Bucket for exercise() is known in advance to users"), both acknowledged and NEVER fixed
    ///      upstream. Valorem Clear has been dormant since November 2023 and no further releases are
    ///      expected, so neither will be.
    ///
    ///      Overcall does not patch the clearinghouse — it is deployed untouched — so it removes the
    ///      precondition instead: no writes after the first exercise can happen if no writes are
    ///      accepted after the exercise window opens. A cycle whose writers all wrote before
    ///      `exerciseTimestamp` is a single-bucket cycle, and 3.2 and 3.3 cannot bite in it.
    ///
    ///      The registry cannot enforce this. It holds nothing, gates nothing and is not in the fund
    ///      path; `write` is permissionless and goes straight to the clearinghouse. This value is
    ///      published so that the Overcall front end and any integrator can honour the same deadline,
    ///      and so the rule is verifiable on-chain rather than being a claim on a web page.
    ///      **Integrators MUST respect it**: writing past it is accepted by Valorem and silently
    ///      moves the writer onto uniform-per-bucket assignment instead of pro-rata.
    /// @return The exercise timestamp of the current cycle, or 0 when no cycle has been set.
    function writeDeadline() external view returns (uint40);

    /// @notice Whether Overcall is accepting writes for the current cycle right now.
    /// @dev True only while a cycle exists and `block.timestamp < writeDeadline()`. The bound is
    ///      strict: at the deadline exactly, the exercise window has opened and writing is closed,
    ///      which matches the clearinghouse treating `exerciseTimestamp` as inclusive for `exercise`.
    ///
    ///      Advisory, exactly like {writeDeadline}. False here does NOT mean the clearinghouse will
    ///      reject a write — it accepts them until expiry. It means Overcall's pro-rata guarantee no
    ///      longer covers one. See {writeDeadline} for why.
    /// @return True while writes are open under the Overcall rule.
    function isWritingOpen() external view returns (bool);

    /// @notice Whether `optionId` belongs to the current cycle.
    /// @dev Stays true after the cycle expires and until the next {setCycle} replaces it — writers
    ///      still need their expired ids recognised in order to redeem. A caller that means "tradable
    ///      right now" must pair this with {isCycleLive}.
    ///
    ///      Valorem allows a Claim NFT to be redeemed at any time after expiry, so a writer may come
    ///      back weeks later, after several cycles have gone by. This function answers only about the
    ///      CURRENT cycle; for a historic id, ask {cycleOf}, which never forgets.
    /// @param optionId The option id to test.
    /// @return True when the id is approved.
    function isApproved(uint256 optionId) external view returns (bool);

    /// @notice The cycle an option id was approved in, of any age.
    /// @dev The permanent record behind {isApproved}: an id approved in cycle 7 keeps reporting 7
    ///      forever, which is what lets the front end verify a late redeemer's expired id instead of
    ///      replaying {CycleSet} logs. Re-approving an id in a later cycle overwrites it with the
    ///      newer number.
    /// @param optionId The option id to look up.
    /// @return The 1-based cycle number, or 0 if the id was never approved.
    function cycleOf(uint256 optionId) external view returns (uint32);

    /// @notice The approved option ids of the current cycle, ordered by ascending strike.
    /// @return The option ids.
    function activeOptionIds() external view returns (uint256[] memory);

    /// @notice The current cycle in full.
    /// @return The {Cycle} struct.
    function cycle() external view returns (Cycle memory);

    /// @notice Whether the current cycle has not yet expired.
    /// @dev False before the first cycle, since `expiryTimestamp` is then 0.
    /// @return True while `block.timestamp < expiryTimestamp`.
    function isCycleLive() external view returns (bool);

    /// @notice Whether {setCycle} would be accepted right now, ignoring access control.
    /// @dev The overlap guard, exposed so ops can check before signing rather than by reverting. True
    ///      when no cycle has been set, when the recorded one has expired, or when it is live but
    ///      `nextClaimKey == 1` on every approved id — Valorem's own counter, which starts at 1 and
    ///      increments on the first write by any address, so this reads as "no short position exists
    ///      against this ladder".
    ///
    ///      It follows that a live cycle stops being replaceable the moment ANYONE writes a single
    ///      contract on any approved id, not only the operator. Treat it as a last-resort correction
    ///      hatch, never as the normal way to change a live week.
    /// @return True when a replacement would pass the overlap guard.
    function canReplaceCycle() external view returns (bool);

    /// @notice The number of cycles recorded since deployment.
    /// @dev Equal to {cycleNumber}, and the exclusive upper bound of {cycleAt}. 0 before the first
    ///      {setCycle}.
    /// @return The number of recorded cycles.
    function cycleCount() external view returns (uint256);

    /// @notice A past or present cycle, by 0-based index.
    /// @dev `cycleAt(n - 1)` is the cycle numbered `n`, and `cycleAt(cycleCount() - 1)` equals
    ///      {cycle}. Entries are never mutated after they are appended, so a writer coming back to
    ///      redeem weeks later can read the exact ladder, window and lot size their claim belongs to
    ///      without the front end scanning a single log.
    /// @param index The 0-based index into the history.
    /// @return The recorded {Cycle}.
    function cycleAt(uint256 index) external view returns (Cycle memory);

    /// @notice The strike, per contract, of any option or claim id known to the clearinghouse.
    /// @dev A convenience read forwarded straight to the clearinghouse; NO approval check is
    ///      performed, so pair it with {isApproved} or {cycleOf} when the answer has to be about a
    ///      grid the registry vouched for. Two consequences of forwarding: a CLAIM id resolves to its
    ///      parent option type's strike, because Valorem's `option()` decodes only the upper 160 bits;
    ///      and an id the clearinghouse never issued bubbles Valorem's own `TokenNotFound`, not a
    ///      registry error. A strike of $255.00 against USDG's six decimals reads back as `255_000000`.
    /// @param optionId The option (or claim) id to read.
    /// @return strike The `exerciseAmount` of the option type.
    function strikePerContract(uint256 optionId) external view returns (uint96 strike);
}
