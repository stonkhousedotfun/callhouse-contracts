// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {V2Types} from "./V2Types.sol";

/// @title IClearinghouse
/// @notice The v2 options clearinghouse: one ERC-1155 for every market (ADR-01, ADR-02, architecture §3.5). A series is
///         European, fully collateralised, settled in cash value at expiry from the SettlementOracle, and paid out
///         without the holder acting. Every unit of a series settles identically: there is no assignment.
/// @dev ERC-1155 ids come in pairs: `longId` (low bit 0) and `shortId = longId | 1`. Balances are 0.01-share units.
///      Prices and strikes are USDG base units (6 dp) per whole share. Ledger amounts are base units of the asset.
///      Collateral per unit: a put locks strike / 100 USDG base units, a call locks UNIT (1e16) underlying base units.
///
///      Trust model (ADR-09): GUARDIAN_ROLE can pause series creation and mints only; DEFAULT_ADMIN_ROLE registers
///      and configures markets, sets the fee recipient, the payout adapter and the calendar/oracle for NEW series.
///      No role can move, freeze or seize user collateral or tokens. close, redeem, withdraw are never pausable.
///      The admin and guardian setters are implementation surface and not frozen here; their events are.
interface IClearinghouse is IERC1155 {
    // ids

    /// @notice The long token id of a series. Pure; says nothing about whether the series exists.
    /// @dev `uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))) & ~uint256(1)`, exactly V2Ids.longIdOf.
    ///      Off-chain mirrors (seriesId.ts) are tested against ops/fixtures/v2/series-ids.json.
    /// @param underlying 18-dp Stock Token.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @param expiry Unix seconds.
    /// @return Long id, low bit 0.
    function longIdOf(address underlying, bool isPut, uint128 strike, uint40 expiry) external pure returns (uint256);

    /// @notice The short token id paired with `longId`: `longId | 1`.
    /// @param longId Long id of the series.
    /// @return Short id, low bit 1.
    function shortIdOf(uint256 longId) external pure returns (uint256);

    /// @notice Whether `id` is a short token id (`id & 1 == 1`).
    /// @param id Any ERC-1155 id of this contract.
    /// @return True for a short id.
    function isShortId(uint256 id) external pure returns (bool);

    // markets / series

    /// @notice USDG: 6-dp put collateral, premium currency and converted call payout currency.
    /// @return USDG token address.
    function usdg() external view returns (address);

    /// @notice The IExpiryCalendar validating expiries of NEW series (admin-settable pointer).
    /// @return Calendar address.
    function calendar() external view returns (address);

    /// @notice Market row of `underlying`; all zero when unregistered.
    /// @param underlying 18-dp Stock Token.
    /// @return The market configuration.
    function market(address underlying) external view returns (V2Types.MarketConfig memory);

    /// @notice Stored series of `longId`; all zero when it was never created.
    /// @param longId Long id (a short id is not accepted as a key).
    /// @return The series, including its settlement amounts once settled.
    function series(uint256 longId) external view returns (V2Types.Series memory);

    /// @notice Whether {createSeries} has created `longId`.
    /// @param longId Long id.
    /// @return True when the series exists.
    function seriesExists(uint256 longId) external view returns (bool);

    /// @notice Creates a series, or returns the id of the existing one.
    /// @dev Anyone. Idempotent. Checks: market enabled (MarketDisabled) and creation not guardian-paused
    ///      (CreatePaused); strike > 0 and a multiple of the market strikeTick (BadStrike); calendar.isValidExpiry and
    ///      now + MIN_SERIES_LEAD <= expiry <= now + MAX_TENOR (BadExpiry); when oracle.trySpot is ok,
    ///      spot / 2 <= strike <= spot * 2 (BadStrike). Pins the market's oracle and exerciseFeeBps into the series,
    ///      and calls oracle.pin(underlying, expiry) so the oracle pins the settlement configuration of the expiry (a
    ///      no-op after its first series; INTERFACE_VERSION 6). A revert from pin reverts the creation (NoSource when
    ///      the market has no price source, NotAuthorized when the oracle is not configured with this Clearinghouse,
    ///      SourceNotPinned when a price source cannot pin, PinMismatch when the expiry was pinned outside this
    ///      Clearinghouse to a configuration that is not the current one).
    ///      When the id exists its stored (underlying, isPut, strike, expiry) must equal the arguments
    ///      (SeriesIdCollision), and nothing else is called.
    ///      INTERFACE_VERSION 7: the market's mintFeePpm is pinned into the series beside its oracle and
    ///      exerciseFeeBps and reported by SeriesCreated, so a later market fee change reaches new series only.
    /// @param underlying 18-dp Stock Token of a registered market.
    /// @param isPut True for a put.
    /// @param strike USDG base units (6 dp) per whole share.
    /// @param expiry Unix seconds, 16:00 New York on a session day.
    /// @return longId Long id of the series.
    function createSeries(address underlying, bool isPut, uint128 strike, uint40 expiry)
        external
        returns (uint256 longId);

    /// @notice Collateral asset of a series: USDG for puts, the underlying for calls.
    /// @param longId Long id.
    /// @return Asset address.
    function collateralAsset(uint256 longId) external view returns (address);

    /// @notice Collateral locked per unit written.
    /// @param longId Long id.
    /// @return Put: strike / 100 USDG base units. Call: UNIT (1e16) underlying base units.
    function collateralPerUnit(uint256 longId) external view returns (uint256);

    /// @notice Mint cutoff of a series: expiry - SETTLEMENT_WINDOW. {mint} requires now < mintCutoff, so no unit is
    ///         written once the averaging window has started.
    /// @param longId Long id.
    /// @return Unix seconds.
    function mintCutoff(uint256 longId) external view returns (uint40);

    /// @notice Collateral locked behind a series.
    /// @dev Before settlement equals long supply * collateralPerUnit (invariant 1).
    /// @param longId Long id.
    /// @return Collateral-asset base units.
    function locked(uint256 longId) external view returns (uint256);

    /// Sum of long supply over every series of (underlying, expiry). Gates oracle bounties.
    /// @dev Anyone. The SettlementOracle pays SNAPSHOT and FINALIZE bounties only when this is > 0.
    /// @param underlying 18-dp Stock Token.
    /// @param expiry Unix seconds.
    /// @return units 0.01-share units.
    function openInterest(address underlying, uint40 expiry) external view returns (uint256 units);

    /// @notice Per-unit settlement amounts the series would get at `price`, with its pinned exerciseFeeBps.
    /// @dev Anyone. OptionMath: call gross = P > K ? UNIT * (P - K) / P : 0; put gross = P < K ? (K - P) / 100 : 0;
    ///      fee = gross == 0 ? 0 : min(collateralPerUnit * bps / 1e4, gross * 1000 / 1e4). long + fee + short ==
    ///      collateralPerUnit for every input.
    /// @param longId Long id of an existing series (UnknownSeries).
    /// @param price Settlement price, USDG base units (6 dp) per whole share.
    /// @return longPerUnit Collateral-asset base units to the long, net of fee.
    /// @return feePerUnit Collateral-asset base units of exercise fee.
    /// @return shortPerUnit Collateral-asset base units back to the short.
    function previewSettlement(uint256 longId, uint256 price)
        external
        view
        returns (uint256 longPerUnit, uint256 feePerUnit, uint256 shortPerUnit);

    /// @notice The collateral rent {mint} would charge for `units` of this series in this block (INTERFACE_VERSION 7).
    /// @dev Anyone. ceil(units * collateralPerUnit * series.mintFeePpm * (expiry - now) / (PPM * MINT_FEE_PERIOD)); 0
    ///      when the series' pinned mintFeePpm is 0 and at or after expiry. Equal, base unit for base unit, to what
    ///      {mint} takes from the writer's free ledger in the same block, on top of the collateral.
    /// @param longId Long id of an existing series (UnknownSeries).
    /// @param units 0.01-share units.
    /// @return fee Collateral-asset base units.
    function mintFee(uint256 longId, uint64 units) external view returns (uint256 fee);

    /// @notice The rent {close} would pay back for `units` of this series now (INTERFACE_VERSION 7).
    /// @dev Anyone. The same product floored instead of ceiled, so it is never above what the units were charged; 0
    ///      when the series is settled, at or after expiry, or its pinned mintFeePpm is 0, and never above the
    ///      series' mintFeesHeld. Equal, base unit for base unit, to what {close} credits in the same block, on top
    ///      of the freed collateral.
    /// @param longId Long id of an existing series (UnknownSeries).
    /// @param units 0.01-share units.
    /// @return refund Collateral-asset base units.
    function closeRefund(uint256 longId, uint64 units) external view returns (uint256 refund);

    // ledger

    /// @notice Pulls `amount` of `asset` from the caller and credits the measured balance delta to `to`'s free ledger.
    /// @dev Anyone (ERC-20 approval to this contract). Only USDG and registered underlyings (UnsupportedAsset).
    /// @param asset USDG or a registered underlying.
    /// @param amount Asset base units.
    /// @param to Account credited.
    function deposit(address asset, uint256 amount, address to) external;

    /// @notice Sends `amount` of the caller's free `asset` to `to`.
    /// @dev Caller's own free balance only (InsufficientCollateral(have, need)). Never pausable.
    /// @param asset Asset address.
    /// @param amount Asset base units.
    /// @param to Recipient.
    function withdraw(address asset, uint256 amount, address to) external;

    /// @notice Free (unlocked) ledger balance.
    /// @param account Ledger account.
    /// @param asset Asset address.
    /// @return Asset base units.
    function free(address account, address asset) external view returns (uint256);

    /// @notice Approves or revokes `operator` for the caller's account.
    /// @dev Caller sets its own operators. An operator may {mint} from the account's free collateral and may {redeem}
    ///      for the account when third-party redemption is off. Nothing else: there is deliberately no redeemTo, so
    ///      an operator can never choose where a payout goes.
    /// @param operator Operator address (the UI only proposes the OrderBook and the AutoRoller).
    /// @param approved True to approve.
    function setOperator(address operator, bool approved) external;

    /// @notice Whether `operator` is approved for `account`.
    /// @param account Ledger account.
    /// @param operator Candidate operator.
    /// @return True when approved.
    function isOperator(address account, address operator) external view returns (bool);

    /// @notice Caller's payout preference for ITM call longs: true = Stock Tokens in kind, false (default) = try USDG.
    /// @dev Caller only. The USDG conversion runs through the PayoutAdapter and the Clearinghouse itself checks
    ///      usdgOut >= value at the floor price * (1 - min(maxPayoutSlippageBps + the adapter's routeFeeBps(asset)
    ///      clamped to MAX_ROUTE_FEE_BPS, MAX_PAYOUT_SLIPPAGE_CEIL_BPS)) (INTERFACE_VERSION 6); any failure pays in kind.
    ///      The floor price is the higher of the settlement price and any spot the series' oracle itself reports as ok
    ///      (INTERFACE_VERSION 7: the market's own spotMaxAge, 25 h at launch, and no extra bound here — the real feed
    ///      cadence rarely prints within an hour, so the old hour meant automated redemptions paid in kind; the error
    ///      that admits is bounded by the feed's own deviation threshold). Without an ok spot the floor is the
    ///      settlement price for the holder, its operator, or anyone until 30 minutes after expiry, and a later
    ///      third-party redemption pays in kind.
    /// @param inKind True to skip the USDG conversion.
    function setPayoutInKind(bool inKind) external;

    /// @notice Caller's payout destination: true = credit the free ledger, false (default) = transfer to the wallet.
    /// @dev Caller only. Meant for AutoRoller writers, whose collateral stays in the ledger between rolls.
    /// @param toLedger True to credit the ledger.
    function setPayoutToLedger(bool toLedger) external;

    /// false = only the holder or its operator may redeem this account. Escrow contracts
    /// (the OrderBook) MUST set false. Default true.
    /// @dev Caller only. Otherwise anyone could burn an escrow's tokens and push the payout to a contract that
    ///      cannot attribute it to its makers.
    /// @param allowed False to opt out of third-party redemption.
    function setThirdPartyRedeem(bool allowed) external;

    /// @notice Whether anyone may {redeem} for `account`.
    /// @param account Holder.
    /// @return True unless the account opted out.
    function thirdPartyRedeemAllowed(address account) external view returns (bool);

    // positions

    /// @notice Writes `units` of a series: locks units * collateralPerUnit from `writer`'s free ledger, mints `units`
    ///         long to `longTo` and `units` short to `writer`.
    /// @dev `writer` or an operator of `writer` (NotAuthorized). Market enabled (MarketDisabled) and not
    ///      mint-paused (MintPaused); series exists (UnknownSeries); now < mintCutoff (PastCutoff); units > 0
    ///      (BadUnits); enough free collateral (InsufficientCollateral(have, need)). State first, ERC-1155 acceptance
    ///      callbacks last.
    ///      INTERFACE_VERSION 7: `need` is the collateral PLUS the series' collateral rent for the time left to expiry
    ///      ({mintFee}), so a writer with exactly units * collateralPerUnit free is short by the rent. The rent is
    ///      taken from the free ledger and held on the series until {close} refunds it pro rata or {settle} accrues
    ///      it; {locked}, the settlement identity and every payout are untouched by it.
    /// @param longId Long id.
    /// @param units 0.01-share units.
    /// @param writer Account whose collateral is locked and who receives the shorts.
    /// @param longTo Receiver of the longs.
    function mint(uint256 longId, uint64 units, address writer, address longTo) external;

    /// @notice Burns `units` long and `units` short of the caller and frees units * collateralPerUnit to its ledger.
    /// @dev Caller's own tokens. Allowed until the series is settled (AlreadySettled). Never pausable.
    ///      INTERFACE_VERSION 7: the unused collateral rent of those units ({closeRefund}) is credited to whoever
    ///      closes, in the collateral asset, on top of the freed collateral; at or after expiry it is 0. A writer who
    ///      buys its longs back and closes therefore pays rent only for the time the pair was open.
    /// @param longId Long id.
    /// @param units 0.01-share units.
    function close(uint256 longId, uint64 units) external;

    // settlement (anyone)

    /// @notice Settles a series once its expiry's price is final.
    /// @dev Anyone. Idempotent. Requires now >= expiry (NotExpired). Reads series.oracle.settlementPrice; when not
    ///      Finalized tries oracle.finalize in try/catch; still not final returns false. On success stores the three
    ///      per-unit amounts and emits SeriesSettled. Already settled returns false. Pays the SETTLE bounty only when
    ///      the long supply is > 0 and its collateral, valued at the settlement price, is non-zero and worth at least
    ///      minRedeemPayout.
    ///      INTERFACE_VERSION 7: the rent the series still holds is moved to {accruedFees} of its collateral asset and
    ///      reported by MintFeesAccrued, after SeriesSettled and before the bounty's logs.
    /// @param longId Long id.
    /// @return advanced True only for the call that settled the series.
    function settle(uint256 longId) external returns (bool advanced);

    /// @notice Burns `holder`'s whole balance of `tokenId` (long or short) and pays balance * per-unit payout.
    /// @dev Anyone, unless `holder` opted out of third-party redemption: then only `holder` or its operator
    ///      (ThirdPartyRedeemDisabled). Series settled (NotSettled). Long side adds balance * feePerUnit to
    ///      accruedFees. Puts pay USDG; shorts get their collateral remainder in kind; ITM call longs are converted to
    ///      USDG unless the holder chose in kind (see {setPayoutInKind}). A transfer that reverts credits the holder's
    ///      free ledger instead, so redemption never reverts because a recipient is blocked. Zero-value balances are
    ///      just burned. Never pausable; needs no oracle. Pays the REDEEM bounty only above the minimum payout.
    /// @param tokenId Long or short id.
    /// @param holder Account redeemed; the payout always goes to `holder` (wallet or ledger).
    /// @return paid Base units delivered, in USDG when inUsdg, else in the collateral asset.
    /// @return inUsdg True when `paid` is USDG (put collateral or a converted call payout).
    function redeem(uint256 tokenId, address holder) external returns (uint256 paid, bool inUsdg);

    /// @notice {redeem} for many holders of one id; each holder runs in try/catch so one cannot block the batch.
    /// @dev Anyone (per-holder opt-outs still apply and are skipped).
    /// @param tokenId Long or short id.
    /// @param holders Accounts to redeem.
    /// @return redeemed Number of holders whose balance was redeemed.
    function redeemBatch(uint256 tokenId, address[] calldata holders) external returns (uint256 redeemed);

    // fees

    /// @notice Receiver of swept protocol fees (set by DEFAULT_ADMIN_ROLE).
    /// @return Fee recipient address.
    function feeRecipient() external view returns (address);

    /// @notice Exercise fees, and settled collateral rent (INTERFACE_VERSION 7), accrued and not yet swept.
    /// @param asset Asset address.
    /// @return Asset base units.
    function accruedFees(address asset) external view returns (uint256);

    /// @notice Sends every accrued fee of `asset` to {feeRecipient}.
    /// @dev Anyone.
    /// @param asset Asset address.
    function sweepFees(address asset) external;

    /// @notice DEFAULT_ADMIN_ROLE registered a market. The tuple gained mintFeePpm in INTERFACE_VERSION 7, so this
    ///         topic changed; a v6 decoder mis-reads it rather than failing.
    event MarketRegistered(address indexed underlying, V2Types.MarketConfig config);
    /// @notice DEFAULT_ADMIN_ROLE changed a market's configuration (new series only for oracle, exercise fee and mint
    ///         fee). Same tuple change and same warning as {MarketRegistered}.
    event MarketConfigSet(address indexed underlying, V2Types.MarketConfig config);
    /// @notice GUARDIAN_ROLE paused or resumed mints of a market.
    event MintPausedSet(address indexed underlying, bool paused);
    /// @notice GUARDIAN_ROLE paused or resumed series creation.
    event CreatePausedSet(bool paused);
    /// @notice A series was created. strike: USDG 6 dp per whole share; expiry: unix seconds; mintFeePpm: the rent
    ///         rate pinned from the market (INTERFACE_VERSION 7, appended).
    event SeriesCreated(
        uint256 indexed longId,
        address indexed underlying,
        bool isPut,
        uint128 strike,
        uint40 expiry,
        address oracle,
        uint16 exerciseFeeBps,
        uint32 mintFeePpm
    );
    /// @notice `amount` (asset base units, measured delta) credited to `account`, pulled from `from`.
    event Deposited(address indexed account, address indexed asset, uint256 amount, address from);
    /// @notice `amount` (asset base units) left `account`'s free ledger for `to`.
    event Withdrawn(address indexed account, address indexed asset, uint256 amount, address to);
    /// @notice `account` approved or revoked `operator`.
    event OperatorSet(address indexed account, address indexed operator, bool approved);
    /// @notice `account` changed its payout preferences.
    event PayoutPrefsSet(address indexed account, bool inKind, bool toLedger);
    /// @notice `account` allowed or disallowed third-party redemption.
    event ThirdPartyRedeemSet(address indexed account, bool allowed);
    /// @notice `units` (0.01-share) written by `writer`; `collateral` locked and `fee` charged as collateral rent,
    ///         both in collateral-asset base units (`fee` appended in INTERFACE_VERSION 7).
    event Minted(
        uint256 indexed longId,
        address indexed writer,
        address indexed longTo,
        uint64 units,
        uint256 collateral,
        uint256 fee
    );
    /// @notice `units` (0.01-share) closed by `account`; `collateralFreed` and the unused rent `feeRefund` credited to
    ///         its ledger, both in collateral-asset base units (`feeRefund` appended in INTERFACE_VERSION 7).
    event Closed(
        uint256 indexed longId, address indexed account, uint64 units, uint256 collateralFreed, uint256 feeRefund
    );
    /// @notice Series settled. settlementPrice: USDG 6 dp per share; per-unit amounts in collateral-asset base units.
    event SeriesSettled(
        uint256 indexed longId,
        uint256 settlementPrice,
        uint256 longPayoutPerUnit,
        uint256 feePerUnit,
        uint256 shortPayoutPerUnit
    );
    /// asset = what was actually delivered (USDG when converted); amountInKind = collateral-asset amount owed
    /// @dev `units` burned (0.01-share); `amount` in `asset` base units; `toLedger` when credited, not transferred.
    event Redeemed(
        uint256 indexed tokenId,
        address indexed holder,
        address to,
        uint64 units,
        address asset,
        uint256 amount,
        uint256 amountInKind,
        bool toLedger
    );
    /// @notice A settled series moved the collateral rent it still held (asset base units) into {accruedFees}
    ///         (INTERFACE_VERSION 7). Emitted by {settle} only when the amount is non-zero.
    event MintFeesAccrued(uint256 indexed longId, address indexed asset, uint256 amount);
    /// @notice Accrued fees (asset base units) swept to `to`.
    event FeesSwept(address indexed asset, address indexed to, uint256 amount);
    /// @notice DEFAULT_ADMIN_ROLE set the fee recipient.
    event FeeRecipientSet(address indexed recipient);
    /// @notice DEFAULT_ADMIN_ROLE set the PayoutAdapter and its slippage bound (<= MAX_PAYOUT_SLIPPAGE_CEIL_BPS),
    ///         measured above each route's pool fee (INTERFACE_VERSION 6).
    event PayoutAdapterSet(address indexed adapter, uint16 maxSlippageBps);
}
