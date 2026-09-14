// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Policy, PolicyParams} from "./Policy.sol";
import {Distributor} from "./Distributor.sol";
import {AdapterValorem} from "./AdapterValorem.sol";
import {AdapterSeaport} from "./AdapterSeaport.sol";
import {IValoremClear} from "./interfaces/IValoremClear.sol";
import {IOvercallRegistry} from "./interfaces/IOvercallRegistry.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {ISeaport, OrderComponents} from "./interfaces/ISeaport.sol";
import {ValoremLib} from "./lib/ValoremLib.sol";

/// @title Vault
/// @notice A pooled covered-call account for one Robinhood Chain Stock Token.
/// @dev Deposit the Stock Token, receive shares. Each cycle a keeper writes an Overcall call
///      on Valorem against the idle balance, lists the option on Seaport for USDG, and after
///      expiry redeems the claim and distributes the premium. Yield is USDG or it is nothing.
///
///      WHAT THIS CONTRACT DELIBERATELY DOES NOT DO
///      - It never marks the short call to market. The share price moves only when the asset
///        balance moves. Premium arrives as a separate USDG claim, not as a price jump.
///      - It never reads a price feed in the settlement path. The oracle gates a write and
///        feeds the UI; redeem, harvest and the redeem queue do not consult it.
///      - It never rebases. `uiMultiplier()` is a display concern; all internal maths use raw
///        balances.
///      - It is not upgradeable. A fix means Vault v2 and a migration.
contract Vault is ERC20, AccessControl, ReentrancyGuard, Distributor, AdapterValorem, AdapterSeaport {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes and executes the weekly roll. Hot key. Can never move funds out.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Emergency brake. Can halt writes and kill listings, nothing else.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Phase {
        Idle,
        Listed,
        Exercisable,
        Settling
    }

    /// @dev One settled batch of redemptions. Amounts are drawn down as people claim, and the
    ///      last claimant of an epoch takes whatever is left, so the division leaves no dust
    ///      stranded in the vault.
    struct Epoch {
        uint256 sharesRemaining;
        uint256 assetsRemaining;
        uint256 usdgRemaining;
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Stock Token this vault writes calls against.
    IERC20 public immutable asset;

    /// @notice The Overcall registry for this market. One registry per collateral token.
    IOvercallRegistry public immutable registry;

    /// @notice Spot source for the OTM band gate and the UI. Never consulted at settlement.
    IChainlinkFeed public immutable priceFeed;

    /// @dev Absolute bounds on {maxPriceAge}, compiled in so governance cannot disable the
    ///      staleness check entirely or widen it past a week.
    uint32 internal constant MIN_PRICE_AGE = 1 hours;
    uint32 internal constant MAX_PRICE_AGE_CEIL = 7 days;

    // The longest cycle the vault will underwrite (21 days from the write) is compiled into
    // {ValoremLib.MAX_CYCLE_TENOR}, next to the write gate that enforces it.

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    Phase public phase;

    /// @notice Governance-settable bounds, always inside {Policy}'s hard caps.
    PolicyParams public policy;

    /// @notice Receives the protocol fee on harvested premium.
    address public feeRecipient;

    /// @notice Maximum asset base units the vault will hold from deposits.
    uint256 public depositCap;

    /// @notice When true, `rollOpen`, `writeMore` and `approveListing` are blocked. Nothing else is.
    bool public writesHalted;

    /// @notice Governance has looked at the Valorem engine fee and accepted paying it.
    bool public valoremFeeAccepted;

    /// @notice How stale the spot price may be before a write is refused.
    /// @dev THIS MUST BE DAYS, NOT HOURS, AND THAT IS NOT SLOPPINESS.
    ///      The NVDA/USD feed on this chain is a `us_equities_24/5` feed: it stops updating when
    ///      the US equity market closes and restarts at 20:00 ET Sunday. Observed gaps are 17h
    ///      intra-week, ~52h over a normal weekend, and ~78h over a three-day holiday weekend.
    ///      Overcall's write window stays open across all of that, so a 24-hour rule would have
    ///      blocked `rollOpen` every Saturday and Sunday and guaranteed a 0% week.
    ///      A stale weekend price is also the economically correct one: the market is shut, so
    ///      Friday's close IS spot. The check is here to catch a genuinely broken feed, not to
    ///      insist on freshness the feed never promised. Launch value is 4 days.
    ///      See ops/recon/R5-price-feed.md for the round-by-round evidence.
    ///
    ///      NOTE: chain 4663 publishes no Chainlink L2 sequencer uptime feed, so the usual
    ///      sequencer-down guard cannot be implemented. A sequencer outage shows up instead as a
    ///      stale price, which this check does catch.
    uint32 public maxPriceAge;

    /// @notice The registry cycle number this vault is currently written into.
    uint32 public cycleNumber;

    /// @dev Snapshot of the cycle's timings, taken at `rollOpen`. Held locally because the
    ///      registry will roll forward to the next cycle while this one is still settling.
    uint40 public cycleExerciseTs;
    uint40 public cycleExpiryTs;

    /// @notice Strike of the option written this cycle, USDG base units per contract.
    uint256 public cycleStrikeUsdg;

    /// @notice Asset base units promised to settled redemption epochs, excluded from NAV.
    uint256 public reservedAssets;

    /// @notice USDG base units promised to settled redemption epochs.
    uint256 public usdgReservedForQueue;

    /// @notice Protocol fee accrued but not yet swept to the fee recipient.
    /// @dev The harvest is checkpointed on every deposit so that new shares cannot dilute
    ///      premium that was earned before they existed. Those checkpoints must not make an
    ///      external call, so the fee is accumulated here and swept once, at `rollClose`.
    uint256 public pendingFeeUsdg;

    /// @notice Shares currently escrowed awaiting the next settlement.
    uint256 public queuedShares;

    /// @notice Current epoch id. Incremented every time the queue settles.
    uint256 public epochId;

    mapping(uint256 => Epoch) public epochs;
    mapping(address => uint256) public queuedSharesOf;
    mapping(address => uint256) public queuedEpochOf;

    /// @notice Asset base units settled out of an epoch and waiting to be collected.
    mapping(address => uint256) public owedAssets;

    /// @notice USDG base units settled out of an epoch and waiting to be collected.
    mapping(address => uint256) public owedQueueUsdg;

    /// @dev Per-account sum of `shares * accUsdgPerShare` over the account's queue entries in its
    ///      current epoch, taken at the moment each entry was escrowed (the reward debt).
    ///
    ///      WHY THIS EXISTS. The escrow's USDG accrual is one pot, but it is earned tranche by
    ///      tranche on whatever the escrow held when each tranche was indexed. Splitting the pot pro
    ///      rata by final shares let a later queuer take part of what an earlier queuer's shares
    ///      earned before the later shares arrived: a deposit that indexed premium between two queue
    ///      entries moved a third of the earlier queuer's week to the later one, and a newcomer who
    ///      deposited (indexing the premium) and queued could take most of it on purpose. Each entry
    ///      now receives exactly `shares * epochIndex - debt`, the index growth its own shares sat
    ///      through in escrow.
    mapping(address => uint256) private _queueAccDebt;

    /// @dev `accUsdgPerShare` at the moment each epoch settled.
    mapping(uint256 => uint256) private _epochAccUsdgPerShare;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event QueueRedeem(address indexed owner, uint256 shares, uint256 epochId);
    event CompleteRedeem(
        address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 usdgOut
    );
    /// @dev A queue entry moved out of its epoch and into the owner's owed balances. Fired by
    ///      BOTH callers of `_settleEpochEntry`: by `completeRedeem` immediately before the
    ///      payout (where `CompleteRedeem` then reports the same numbers leaving the vault) and
    ///      by `queueRedeem` auto-settling an earlier epoch, which would otherwise change
    ///      `owedAssets`/`owedQueueUsdg` with no event at all. Without this an off-chain reader
    ///      sees value leave an epoch it never sees claimed, and the unclaimed-epoch alert
    ///      fires on money that is simply waiting to be collected.
    event QueueEntrySettled(
        address indexed owner, uint256 indexed epochId, uint256 shares, uint256 assets, uint256 usdgOut
    );
    event QueueSettled(uint256 indexed epochId, uint256 shares, uint256 assets, uint256 usdgOut);
    /// @dev A `completeRedeem` paid its Stock Token leg but could not move its USDG leg (USDG
    ///      paused, the vault or the receiver frozen). `usdgOwed` stays booked to the owner and
    ///      is collected by a later `completeRedeem`; see {_payoutOwed}.
    event UsdgLegDeferred(address indexed owner, address indexed receiver, uint256 usdgOwed);
    /// @dev A settled redeemer was paid less than booked because the asset balance sits below
    ///      `reservedAssets` (an issuer `adminBurn`). Every uncollected reserved claimant takes the
    ///      same fraction; see {_payoutOwed}.
    event ReserveHaircut(address indexed owner, uint256 booked, uint256 paid);
    event RollOpen(uint32 indexed cycleNumber, uint256 indexed optionId, uint112 contractsCount, uint256 strikeUsdg);
    event BookLocked(uint32 indexed cycleNumber);
    event RollClose(
        uint32 indexed cycleNumber, uint256 assetsReturned, uint256 usdgFromAssignment, uint256 contractsAssignedCount
    );
    event Harvest(uint32 indexed cycleNumber, uint256 grossUsdg, uint256 feeUsdg, uint256 netUsdg);
    event WritesHalted(bool halted);
    event PolicyUpdated(PolicyParams params);
    event FeeRecipientUpdated(address feeRecipient);
    event DepositCapUpdated(uint256 cap);
    event ValoremFeeAccepted(bool accepted);
    event MaxPriceAgeUpdated(uint32 seconds_);
    event FeeSwept(address indexed feeRecipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error WrongPhase(Phase expected, Phase actual);
    error WritesAreHalted();
    error WritingNotOpen();
    error NoCycle();
    error RegistryAssetMismatch(address expected, address got);
    error OptionNotApproved(uint256 optionId);
    error OptionNotInCurrentCycle(uint256 optionId, uint32 optionCycle, uint32 currentCycle);
    error ValoremFeeNotAccepted(uint8 feeBps);
    error OraclePaused();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error NotYetExercisable(uint40 exerciseTs);
    error NotYetExpired(uint40 expiryTs);
    error UseQueue();
    error NothingQueued();
    error EpochNotSettled(uint256 epochId, uint256 currentEpoch);
    error DepositCapExceeded(uint256 wouldBe, uint256 cap);
    error ZeroShares();
    error ZeroAssets();
    error InsufficientFreeShares(uint256 free, uint256 requested);
    error GuardianTooEarly(uint40 allowedAt);
    error ZeroAddr();
    error PriceAgeOutOfBounds(uint32 got, uint32 minAge, uint32 maxAge);
    /// @dev Covers both an inverted cycle window and one whose tenor exceeds MAX_CYCLE_TENOR.
    ///      The two timestamps tell you which.
    error BadCycleWindow(uint40 exerciseTs, uint40 expiryTs);
    /// @dev The one deposit refusal. Every reason is enumerated in {_depositRefused}.
    error DepositsClosed();
    /// @dev `completeRedeem` had only USDG left to pay and the USDG transfer failed (pause,
    ///      frozen vault, frozen receiver). Nothing moved; the USDG stays owed and collectable.
    error UsdgLegBlocked(uint256 usdgOwed);
    error WriteWindowClosed(uint40 exerciseTs);
    error ListingStillValid();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    struct Config {
        IERC20 asset;
        IERC20 usdg;
        IValoremClear clear;
        ISeaport seaport;
        IOvercallRegistry registry;
        IChainlinkFeed priceFeed;
        uint32 maxPriceAge;
        address overcallFeeRecipient;
        bytes32 conduitKey;
        address seaportZone;
        address admin;
        address feeRecipient;
        uint256 depositCap;
        string name;
        string symbol;
    }

    constructor(Config memory c)
        ERC20(c.name, c.symbol)
        Distributor(c.usdg)
        AdapterValorem(c.clear)
        AdapterSeaport(c.seaport, c.overcallFeeRecipient, c.conduitKey, c.seaportZone)
    {
        if (address(c.asset) == address(0) || c.admin == address(0) || c.feeRecipient == address(0)) revert ZeroAddr();

        // The registry is per-market and immutable on its own side. Bind to it only if it
        // genuinely describes this vault's pair; a mismatched registry would let the keeper
        // write calls collateralised by the wrong token.
        if (c.registry.collateralToken() != address(c.asset)) {
            revert RegistryAssetMismatch(address(c.asset), c.registry.collateralToken());
        }
        if (c.registry.exerciseToken() != address(c.usdg)) {
            revert RegistryAssetMismatch(address(c.usdg), c.registry.exerciseToken());
        }
        if (c.registry.clearinghouse() != address(c.clear)) {
            revert RegistryAssetMismatch(address(c.clear), c.registry.clearinghouse());
        }

        asset = c.asset;
        registry = c.registry;
        priceFeed = c.priceFeed;
        _setMaxPriceAge(c.maxPriceAge);
        feeRecipient = c.feeRecipient;
        depositCap = c.depositCap;

        PolicyParams memory p = Policy.launchDefaults();
        Policy.validate(p);
        policy = p;

        _grantRole(DEFAULT_ADMIN_ROLE, c.admin);

        // Seaport pulls the option tokens straight out of the vault on fill.
        _approveOptionTransfers(address(c.clear));

        epochId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-20 / SHARES
    //////////////////////////////////////////////////////////////*/

    /// @dev Shares track the Stock Token's 18 decimals so one share is one token at launch.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @dev Settles USDG accrual on both sides of every balance change; see {Distributor}.
    ///
    ///      There is deliberately NO "these shares are locked" check here. Queueing moves the
    ///      shares into escrow on this contract, so a queued share has already left the owner's
    ///      balance and there is nothing left to lock. An earlier draft did both — escrowed the
    ///      shares AND subtracted `queuedSharesOf` from the owner's balance — which double
    ///      counted them and made queueing a full balance impossible. The two designs are
    ///      alternatives, not layers.
    function _update(address from, address to, uint256 value) internal override(ERC20, Distributor) {
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                              ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Asset base units backing the live share supply.
    /// @dev Idle balance plus whatever is still locked behind this cycle's Valorem claim, less
    ///      what is already promised to settled redeemers, floored at zero. USDG is not included:
    ///      it is distributed through {Distributor}, not through the share price. Unsold option
    ///      inventory is valued at zero.
    ///
    ///      WHY THE RESERVE IS SUBTRACTED FROM THE WHOLE, NOT FROM THE IDLE PART. The Stock Token
    ///      issuer can `adminBurn` from any address, pause or blocklist notwithstanding. An earlier
    ///      draft clamped `balance - reserved` at zero and then ADDED the locked collateral, so a
    ///      burn that took the balance below the reserve while a call was open left NAV overstated
    ///      by the shortfall (47e18 read against a true 30e18 in the audit PoC, AUDIT-FINDINGS
    ///      F-05) and a depositor bought in above true value. The settled redeemers' claim is on
    ///      the vault's collateral as a whole, so it comes off the whole; only the final figure
    ///      saturates. Deposits are refused for as long as the balance sits below the reserve
    ///      ({_depositRefused}).
    function totalAssets() public view returns (uint256) {
        uint256 gross = asset.balanceOf(address(this)) + lockedAssets();
        uint256 reserved = reservedAssets;
        return gross > reserved ? gross - reserved : 0;
    }

    /// @notice Idle asset base units available to write against right now.
    function idleAssets() public view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        return idle > reserved ? idle - reserved : 0;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding r) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 1, totalAssets() + 1, r);
    }

    function _convertToAssets(uint256 shares, Math.Rounding r) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 1, r);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @notice Assets a redemption would pay, IF it can be done instantly.
    /// @dev Returns 0 whenever the queue is the only path. TECHSPEC 4.3 is explicit that the
    ///      preview must not quote a number the caller cannot actually get right now.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        if (!canRedeemInstantly()) return 0;
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        if (!canRedeemInstantly()) return 0;
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @notice True when a redemption settles in the same transaction.
    function canRedeemInstantly() public view returns (bool) {
        return phase == Phase.Idle && contractsWritten == 0;
    }

    /// @notice How much more asset the vault will accept.
    /// @dev Measured on {totalAssets}, not on the raw balance. Collateral written into Valorem
    ///      has left the balance but is still the vault's responsibility, so a balance-based cap
    ///      re-opened the moment the keeper wrote a call and let deposits blow straight through
    ///      it mid-cycle. `totalAssets` also excludes assets already promised to settled
    ///      redeemers, which is the other half of the same mistake.
    function maxDeposit(address) public view returns (uint256) {
        // Quote zero whenever the deposit would revert. A non-zero figure the caller cannot act
        // on is the same dishonesty as a preview quoting an instant redemption while the queue
        // is the only path. ONE predicate serves both this quote and {_requireDepositPhase}, so
        // the quote goes to zero at the same instant the deposit starts reverting.
        if (_depositRefused()) return 0;

        uint256 held = totalAssets();
        if (held >= depositCap) return 0;
        return depositCap - held;
    }

    /// @dev Every reason a deposit is refused, in one place. `maxDeposit`/`maxMint` quote zero
    ///      and `deposit`/`mint` revert {DepositsClosed} on exactly the same conditions; an earlier
    ///      draft kept two copies and per-reason errors, and the two drifted.
    ///
    ///      1. PHASE. Only Idle and Listed accept deposits.
    ///      2. THE EXERCISE WINDOW. In Listed, deposits close at `cycleExerciseTs` whether or not
    ///         anyone calls `lockBook`; see the long note on {_requireDepositPhase}.
    ///      3. UNCLAIMED ASSIGNMENT PROCEEDS. Clock-independent second line of defence: if any
    ///         contract has been assigned and the claim not yet redeemed, NAV has already fallen by
    ///         the collateral that left while the offsetting strike USDG is still inside Valorem.
    ///      4. A STRANDED CLAIM. `claimKey != 0` while Idle means `rollClose` could not redeem the
    ///         claim (a USDG pause or freeze in an assigned week). The strike proceeds are owed to
    ///         the holders of record at that close, so nobody may buy in until they are collected.
    ///      5. THE RESERVE IS UNBACKED. `asset.balanceOf(this) < reservedAssets` can only follow an
    ///         issuer `adminBurn` (or a Valorem fee taken past the utilisation ceiling). While it
    ///         holds, NAV reads zero on the idle side and any new deposit would be paid straight
    ///         out to earlier settled redeemers (AUDIT-FINDINGS F-05). Deposits reopen once the
    ///         reserve is collected (with its pro-rata haircut, {_payoutOwed}) or refilled by
    ///         returning collateral.
    function _depositRefused() private view returns (bool) {
        Phase p = phase;
        if (p != Phase.Idle && p != Phase.Listed) return true;
        if (p == Phase.Listed && block.timestamp >= cycleExerciseTs) return true;
        if (claimKey != 0 && (p == Phase.Idle || claimedExerciseProceeds() != 0)) return true;
        return asset.balanceOf(address(this)) < reservedAssets;
    }

    /// @notice Shares mintable right now, mirroring {maxDeposit}.
    function maxMint(address receiver) external view returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == 0 ? 0 : previewDeposit(assets);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit `assets` and receive shares.
    /// @dev Allowed in Idle and Listed (until `cycleExerciseTs`; see {_requireDepositPhase}).
    ///
    ///      A DEPOSIT DURING LISTED BUYS INTO THE OPEN SHORT. Shares are priced on {totalAssets},
    ///      which values the short call at zero, so a deposit made while a call is open pays
    ///      par-style NAV for a book that is already short that call. If the week ends assigned,
    ///      the loss is socialised through the share price to EVERY share, the late ones
    ///      included: the depositor cannot be assigned "against their own collateral" only, and
    ///      nothing here pretends otherwise. On top of that, {writeMore} lets the keeper write a
    ///      further tranche against idle balance that includes the new deposit, so late money
    ///      can also be written against directly. What a late depositor does NOT get is premium
    ///      indexed before their shares existed ({_checkpointHarvest}).
    ///
    ///      This is intended, and it is why the deposit window shuts at `cycleExerciseTs`: before
    ///      that nothing can be assigned, so the NAV a late depositor pays is not yet marked down
    ///      by an assignment whose strike proceeds are still inside Valorem.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        _requireDepositPhase();

        uint256 held = totalAssets();
        if (held + assets > depositCap) revert DepositCapExceeded(held + assets, depositCap);

        // Fix the USDG index before new shares exist, so they cannot claim premium earned
        // before they arrived.
        _checkpointHarvest();

        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares`, paying whatever assets that costs.
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        _requireDepositPhase();

        _checkpointHarvest();

        assets = previewMint(shares);
        if (assets == 0) revert ZeroAssets();

        uint256 held = totalAssets();
        if (held + assets > depositCap) revert DepositCapExceeded(held + assets, depositCap);

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Deposits are open in Idle and in Listed, but Listed only counts UNTIL THE EXERCISE
    ///      WINDOW OPENS.
    ///
    ///      THIS TIMESTAMP IS LOad-BEARING AND THE PHASE ENUM IS NOT A SUBSTITUTE.
    ///      Assignment happens entirely inside Valorem: a buyer calls `exercise`, takes the
    ///      collateral and leaves the strike USDG in the claim, with no callback into this
    ///      vault. `lockedAssets()` reads the claim live, so `totalAssets()` COLLAPSES in the
    ///      exerciser's own transaction, while the offsetting strike proceeds stay invisible
    ///      until `rollClose` redeems the claim.
    ///
    ///      `lockBook()` is permissionless and nobody is obliged to call it, and `rollClose`
    ///      accepts Listed, so the vault can legitimately sit in Listed for the entire
    ///      24-hour exercise window. Gating on the phase alone therefore left a window where
    ///      anyone could exercise, watch the share price crash in the same block, mint shares
    ///      against the crashed NAV, and collect a pro-rata slice of strike proceeds they were
    ///      never at risk for — taking it directly from the depositors whose collateral was
    ///      actually assigned. Closing on the timestamp removes the window whether or not
    ///      anyone calls `lockBook`, and whether or not the keeper is alive.
    ///
    ///      ONE ERROR FOR EVERY REASON. {DepositsClosed} carries no argument on purpose: the
    ///      conditions are enumerated in {_depositRefused}, `maxDeposit` returns 0 for each of
    ///      them, and a client that wants the reason reads the phase, the clock and the reserve
    ///      rather than decoding five selectors.
    function _requireDepositPhase() private view {
        if (_depositRefused()) revert DepositsClosed();
    }

    /*//////////////////////////////////////////////////////////////
                          INSTANT REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn `shares` for assets, only while the vault is flat.
    /// @dev Reverts with {UseQueue} whenever a call is open. Nothing about a halt blocks this
    ///      path: halting stops new writes, never a withdrawal of idle collateral.
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        if (!canRedeemInstantly()) revert UseQueue();
        if (shares == 0) revert ZeroShares();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        assets = _convertToAssets(shares, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();

        _burn(owner, shares);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Withdraw exactly `assets`, only while the vault is flat.
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        if (!canRedeemInstantly()) revert UseQueue();
        if (assets == 0) revert ZeroAssets();

        shares = _convertToShares(assets, Math.Rounding.Ceil);
        if (shares == 0) revert ZeroShares();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            QUEUED REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Commit `shares` to the next settlement.
    /// @dev Shares move into escrow on this contract. They keep earning their share of this
    ///      week's premium right up to settlement, and that accrual is paid out with the
    ///      redemption rather than left to the holders who stayed.
    ///
    ///      Never blocked by a halt or by the phase. If the issuer freezes the Stock Token
    ///      this still succeeds; only the payout at settlement would fail, which is the
    ///      honest place for that failure to surface.
    ///
    ///      An entry settles at the next `rollClose`, or, while the vault is Idle, whenever
    ///      anyone calls {settleQueue}. The second path is what stops a queue made while flat
    ///      from waiting on a `rollOpen` that may never come.
    function queueRedeem(uint256 shares) external nonReentrant returns (uint256 queuedEpoch) {
        if (shares == 0) revert ZeroShares();

        // An earlier, already-settled entry is moved into the owner's owed balances so that a
        // single queue slot per account stays sufficient.
        //
        // It is deliberately NOT paid out here. An earlier draft called the full
        // `_completeRedeem`, which transfers the asset; under an issuer freeze that transfer
        // reverts, and a holder with an uncollected epoch could no longer queue at all. Halting
        // and freezing must never trap a depositor, so queueing moves numbers only.
        if (queuedSharesOf[msg.sender] != 0 && queuedEpochOf[msg.sender] != epochId) {
            _settleEpochEntry(msg.sender);
        }

        // Escrowed shares have already left this balance, so the free amount is simply the
        // balance.
        uint256 free = balanceOf(msg.sender);
        if (shares > free) revert InsufficientFreeShares(free, shares);

        queuedEpoch = epochId;
        queuedEpochOf[msg.sender] = queuedEpoch;
        queuedSharesOf[msg.sender] += shares;
        queuedShares += shares;

        // Settle before escrowing so the depositor keeps every cent already earned, and record the
        // index these shares enter escrow at: they earn only what is indexed from here on.
        _settleAccount(msg.sender);
        _queueAccDebt[msg.sender] += shares * accUsdgPerShare;
        _transfer(msg.sender, address(this), shares);

        emit QueueRedeem(msg.sender, shares, queuedEpoch);
    }

    /// @notice Collect a settled redemption.
    function completeRedeem(address receiver) external nonReentrant returns (uint256 assets, uint256 usdgOut) {
        return _completeRedeem(msg.sender, receiver);
    }

    function _completeRedeem(address owner, address receiver) private returns (uint256 assets, uint256 usdgOut) {
        uint256 queued = queuedSharesOf[owner];
        uint256 e = queuedEpochOf[owner];

        // Settle a queue entry only once its epoch has closed. A fresh entry in the current
        // epoch is left alone rather than reverting, so that money already parked from an
        // earlier epoch can still be collected by someone who has since queued again.
        uint256 shares = (queued != 0 && e < epochId) ? _settleEpochEntry(owner) : 0;

        // Judged on what was BOOKED, not on what was paid: a reserve haircut can round a booked
        // asset leg down to zero, and that collection still happened.
        bool hadAssets = owedAssets[owner] != 0;
        (assets, usdgOut) = _payoutOwed(owner, receiver);

        if (shares == 0 && !hadAssets && usdgOut == 0) {
            if (queued != 0) revert EpochNotSettled(e, epochId);
            // The only thing left to collect was USDG and it could not move. Say so rather than
            // "nothing queued": the money is still owed and the caller should retry later or to
            // another receiver.
            uint256 blocked = owedQueueUsdg[owner];
            if (blocked != 0) revert UsdgLegBlocked(blocked);
            revert NothingQueued();
        }

        emit CompleteRedeem(owner, receiver, shares, assets, usdgOut);
    }

    /// @dev Move a settled queue position out of its epoch and into the owner's owed balances.
    ///      Pure bookkeeping: it moves no tokens, which is what lets `queueRedeem` call it
    ///      while the Stock Token is frozen.
    /// @return shares The queued shares that were settled, or 0 if there was nothing to settle.
    function _settleEpochEntry(address owner) private returns (uint256 shares) {
        shares = queuedSharesOf[owner];
        if (shares == 0) return 0;

        uint256 e = queuedEpochOf[owner];
        if (e >= epochId) revert EpochNotSettled(e, epochId);

        Epoch storage ep = epochs[e];

        // Assets draw down proportionally: every escrowed share is worth the same slice of the
        // settled book. USDG does not, because shares escrowed at different index values earned
        // different amounts; see `_queueAccDebt`. The final claimant has
        // `shares == ep.sharesRemaining` and takes exactly what is left of both, so rounding never
        // strands a unit.
        uint256 assets = (ep.assetsRemaining * shares) / ep.sharesRemaining;
        uint256 usdgOut = _entryUsdg(owner, e, shares, ep);
        _queueAccDebt[owner] = 0;

        ep.assetsRemaining -= assets;
        ep.usdgRemaining -= usdgOut;
        ep.sharesRemaining -= shares;

        queuedSharesOf[owner] = 0;
        queuedEpochOf[owner] = 0;
        owedAssets[owner] += assets;
        owedQueueUsdg[owner] += usdgOut;

        emit QueueEntrySettled(owner, e, shares, assets, usdgOut);
    }

    /// @dev Pay out whatever `owner` is owed. This is the only leg that touches tokens, so it
    ///      is the only leg an issuer action can stop.
    ///
    ///      THE TWO LEGS ARE INDEPENDENT (AUDIT-FINDINGS F-03). Almost every settled entry
    ///      carries some USDG, because the escrow earns the week's indexed premium. An earlier
    ///      draft moved both legs in one breath with `safeTransfer`, so a USDG pause or a USDG
    ///      freeze of the vault reverted the Stock Token leg too: settled queuers' PRINCIPAL was
    ///      held hostage by a stablecoin-side event while everyone who had not queued redeemed
    ///      instantly (the instant path never touches USDG). Now the Stock Token leg is paid
    ///      first with `safeTransfer` (an issuer freeze of the Stock Token still reverts the whole
    ///      call, and that is the honest place for it to surface: there is nothing to pay
    ///      principal with), and the USDG leg is attempted on its own through {_tryTransfer}.
    ///      `owedQueueUsdg`, `usdgReservedForQueue` and `_debitUsdgOut` move ONLY on success, so a
    ///      failed USDG leg leaves the USDG exactly where it was, collectable by a later call or
    ///      to another receiver ({UsdgLegDeferred}).
    ///
    ///      THE RESERVE IS HAIRCUT PRO RATA WHEN IT IS UNBACKED (AUDIT-FINDINGS F-05, decision
    ///      D6). `reservedAssets` is carved out of the idle balance and is senior to live shares
    ///      on it ({totalAssets} subtracts it in full), but the Stock Token issuer can `adminBurn`
    ///      the balance below it. An earlier draft then paid whoever collected first in full and
    ///      reverted for the rest, and once deposits reopened, the last claimants were paid out of
    ///      a newcomer's principal. Now every uncollected reserved claimant takes the same
    ///      fraction `balance / reservedAssets` of what is booked to them. The fraction is
    ///      invariant under collection: paying `a × b / r` leaves `b' / r' = b(r − a) / (r(r − a))
    ///      = b / r`, so the order in which people collect does not matter. The haircut is
    ///      permanent even if the issuer later restores tokens; those would accrue to live
    ///      shares through NAV, which is the accepted trade for never paying a shortfall out of
    ///      someone else's deposit. Live shares' idle backing is already zero while the balance
    ///      is below the reserve, so nothing is taken from them here.
    function _payoutOwed(address owner, address receiver) private returns (uint256 assets, uint256 usdgOut) {
        assets = owedAssets[owner];
        usdgOut = owedQueueUsdg[owner];
        if (assets == 0 && usdgOut == 0) return (0, 0);

        if (assets != 0) {
            uint256 booked = assets;
            owedAssets[owner] = 0;
            uint256 r = reservedAssets;
            reservedAssets = r - booked;
            assets = _haircut(booked, r);
            if (assets != booked) emit ReserveHaircut(owner, booked, assets);
            if (assets != 0) asset.safeTransfer(receiver, assets);
        }
        if (usdgOut != 0) {
            if (_tryTransfer(usdg, receiver, usdgOut)) {
                owedQueueUsdg[owner] = 0;
                usdgReservedForQueue -= usdgOut;
                _debitUsdgOut(usdgOut);
            } else {
                emit UsdgLegDeferred(owner, receiver, usdgOut);
                usdgOut = 0;
            }
        }
    }

    /// @dev What `booked` asset base units of a reserve of `reserved` actually pay right now:
    ///      the whole amount while the balance backs the reserve, the pro-rata fraction otherwise.
    ///      Shared by {_payoutOwed} and {previewCompleteRedeem} so the preview quotes exactly
    ///      what the payout moves. Rounds down; the base units it leaves behind fall to live
    ///      shares through NAV once the reserve is fully collected.
    function _haircut(uint256 booked, uint256 reserved) private view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal < reserved ? booked.mulDiv(bal, reserved) : booked;
    }

    /// @dev Best-effort ERC-20 transfer that never reverts the caller. A raw call rather than
    ///      SafeERC20 so a paused or blocklisting token cannot take the caller down with it. A
    ///      missing return value is treated as success, matching the non-compliant-ERC20
    ///      convention SafeERC20 follows. Shared by {_payoutOwed} (the USDG leg) and {_tryPayFee}.
    function _tryTransfer(IERC20 token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @notice What a queued position is worth once its epoch has settled.
    /// @dev Quotes the asset leg after the reserve haircut ({_haircut}), so it is exactly what
    ///      `completeRedeem` pays now. The USDG leg is quoted as booked; whether it MOVES depends
    ///      on the stablecoin's pause and freeze state at the time of the call.
    function previewCompleteRedeem(address owner) external view returns (uint256 assets, uint256 usdgOut) {
        // Anything already settled out of an epoch but not yet collected.
        assets = owedAssets[owner];
        usdgOut = owedQueueUsdg[owner];

        uint256 shares = queuedSharesOf[owner];
        uint256 e = queuedEpochOf[owner];
        if (shares != 0 && e < epochId) {
            Epoch storage ep = epochs[e];
            if (ep.sharesRemaining != 0) {
                assets += (ep.assetsRemaining * shares) / ep.sharesRemaining;
                usdgOut += _entryUsdg(owner, e, shares, ep);
            }
        }
        if (assets != 0) assets = _haircut(assets, reservedAssets);
    }

    /// @dev USDG owed to `owner`'s entry of `shares` in settled epoch `e`: the index growth those
    ///      shares sat through in escrow, capped at what the epoch still holds. The last claimant
    ///      takes the remainder, which absorbs the floor rounding of every earlier entry and of the
    ///      escrow's own accrual.
    function _entryUsdg(address owner, uint256 e, uint256 shares, Epoch storage ep) private view returns (uint256) {
        if (shares == ep.sharesRemaining) return ep.usdgRemaining;
        uint256 earned = (shares * _epochAccUsdgPerShare[e] - _queueAccDebt[owner]) / ACC_PRECISION;
        return earned < ep.usdgRemaining ? earned : ep.usdgRemaining;
    }

    /*//////////////////////////////////////////////////////////////
                             PHASE MACHINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Write this cycle's calls and move to Listed.
    /// @param optionId_ The Overcall rung to write. Must be approved in the live cycle.
    /// @param contractsCount Whole lots to write.
    function rollOpen(uint256 optionId_, uint112 contractsCount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (phase != Phase.Idle) revert WrongPhase(Phase.Idle, phase);

        (uint256 strikeUsdg, uint32 number, uint40 exerciseTs, uint40 expiryTs) = _write(optionId_, contractsCount);

        cycleNumber = number;
        cycleExerciseTs = exerciseTs;
        cycleExpiryTs = expiryTs;
        cycleStrikeUsdg = strikeUsdg;
        _resetListingBudget();
        phase = Phase.Listed;

        emit RollOpen(number, optionId_, contractsCount, strikeUsdg);
    }

    /// @notice Write another tranche of this cycle's option into the SAME Valorem claim.
    /// @dev WHY THIS EXISTS. Valorem assigns exercise across EVERY writer of an option id, pro
    ///      rata by what each wrote (upstream 6436c82 puts every write before the first exercise
    ///      into one bucket, and a claim's share of a bucket's assignment is its share of the
    ///      bucket's writes). It does not care who SOLD. A vault that wrote 50 and sold 10, next
    ///      to other writers who wrote 50 and sold all of it, expects 30 assigned on an
    ///      in-the-money expiry while only 10 of its contracts ever earned a premium. The unsold
    ///      inventory is pure exposure. Writing in tranches sized to each listing bounds that
    ///      exposure by the live listing's unfilled part instead of the whole week's size.
    ///
    ///      Passing the existing claim id to `clear.write` adds to the claim rather than opening
    ///      a second one, so `claimKey`, the settlement path and every claim view are unchanged:
    ///      `rollClose` still redeems exactly one claim, whatever it holds.
    ///
    ///      Every check a fresh write makes is re-run at today's state (see {ValoremLib.write}):
    ///      halt, the registry's write window and approval, the live cycle still being this
    ///      vault's cycle, the Valorem fee, the oracle, the strike band AT LIVE SPOT, and size
    ///      on the claim's TOTAL against idle plus locked. Additionally no tranche may be written
    ///      once `cycleExerciseTs` is reached, because the deposit gate rests on nothing being
    ///      assignable before then.
    /// @param n Whole lots to add.
    function writeMore(uint112 n) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (phase != Phase.Listed) revert WrongPhase(Phase.Listed, phase);
        _write(optionId, n);
    }

    /// @dev The shared tail of {rollOpen} and {writeMore}. Passes storage as it stands: in Idle
    ///      `claimKey` is zero, which is what tells the library this is a fresh claim and makes it
    ///      ignore the previous cycle's `cycleNumber`, `cycleExerciseTs` and `cycleStrikeUsdg`.
    ///      Sizing is on {totalAssets} = idle + locked, which in Idle is just idle.
    function _write(uint256 optionId_, uint112 n)
        private
        returns (uint256 strikeUsdg, uint32 number, uint40 exerciseTs, uint40 expiryTs)
    {
        if (writesHalted) revert WritesAreHalted();

        uint256 key;
        uint256 collateral;
        (key, collateral, strikeUsdg, number, exerciseTs, expiryTs) = ValoremLib.write(
            clear,
            ValoremLib.Write({
                registry: registry,
                feed: priceFeed,
                asset: asset,
                exerciseAsset: address(usdg),
                optionId: optionId_,
                claimId: claimKey,
                strikeUsdg: cycleStrikeUsdg,
                sizingAssets: totalAssets(),
                written: contractsWritten,
                n: n,
                cycleNumber: cycleNumber,
                cycleExerciseTs: cycleExerciseTs,
                maxPriceAge: maxPriceAge,
                feeAccepted: valoremFeeAccepted
            }),
            policy
        );

        _recordWrite(optionId_, key, n, collateral);
    }

    /// @notice Authorise a Seaport listing for this cycle's option tokens.
    /// @dev The keeper proposes the whole order; this contract checks every field against its
    ///      own state before authorising it. A compromised keeper cannot list the inventory
    ///      to itself, for a dollar, or past the exercise window.
    function approveListing(OrderComponents calldata components) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (phase != Phase.Listed) revert WrongPhase(Phase.Listed, phase);
        if (writesHalted) revert WritesAreHalted();

        uint256 available = clear.balanceOf(address(this), optionId);

        (, uint256 grossUsdg, uint256 amount) = _approveListing(
            components, optionId, available, address(usdg), address(clear), cycleExerciseTs, cycleStrikeUsdg
        );

        // The economic floors are checked here rather than in the adapter because they need the
        // live spot, and the adapter is deliberately free of oracle knowledge. They are the SAME
        // two floors {invalidateStaleListing} reads (see {_listingFloors}): the strike must still
        // clear the band floor at live spot (a rally must not let the keeper sell a rung that is
        // now near the money, exactly as {writeMore} refuses to write more of it) and the gross
        // must clear the premium floor. Only the band's LOWER bound: after a sell-off the strike
        // sits above the band ceiling, which makes the call safer to sell, not riskier.
        _requireOracleLive();
        (uint256 minStrike, uint256 minGross) = _listingFloors(amount);
        if (cycleStrikeUsdg < minStrike) revert Policy.StrikeBelowBand(cycleStrikeUsdg, minStrike);
        if (grossUsdg < minGross) revert Policy.PremiumBelowMinimum(grossUsdg, minGross);
    }

    /// @notice Kill the live listing once the policy would no longer authorise it. Anyone.
    /// @dev WHY THIS EXISTS. A listing is a fixed price that lives until `cycleExerciseTs`. After
    ///      a mid-week rally the strike can sit inside the band floor and the premium below the
    ///      floor for the new spot, and a buyer can fill at the stale price one second before the
    ///      exercise window opens and exercise straight away. The keeper can reprice, but with a
    ///      dead keeper only the guardian could stop it.
    ///
    ///      So anybody may bump the Seaport counter, but ONLY when {approveListing} would refuse
    ///      this exact listing at live spot: the cycle's strike is below the band floor, or the
    ///      listing's gross is below the premium floor for its size. Both paths read those floors
    ///      from the one {_listingFloors}, so a listing {approveListing} has just accepted cannot
    ///      be killed at the same spot (it refuses a strike below the band floor too, not only a
    ///      thin premium). A paused Stock Token oracle
    ///      counts as stale (a fresh approval would revert `OraclePaused`); a stale feed reverts,
    ///      because with no price nobody can show the listing is mispriced. Nobody can kill a
    ///      listing the policy would still authorise, so this is not a griefing lever.
    function invalidateStaleListing() external nonReentrant {
        if (listingHash == bytes32(0)) revert NoLiveListing();
        if (!_oraclePaused()) {
            (uint256 minStrike, uint256 minGross) = _listingFloors(listingAmount);
            if (cycleStrikeUsdg >= minStrike && listingGrossUsdg >= minGross) revert ListingStillValid();
        }
        _invalidateAllListings();
    }

    /// @notice Cancel the live listing on Seaport.
    function cancelListing(OrderComponents calldata components) external nonReentrant {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, KEEPER_ROLE);
        }
        _cancelListing(components);
    }

    /// @notice Invalidate every outstanding listing at once by bumping the Seaport counter.
    /// @dev The guardian's tool of last resort: it needs no order data, so it still works when
    ///      the keeper is gone and nobody can reconstruct the components.
    function invalidateAllListings() external nonReentrant {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        _invalidateAllListings();
    }

    /// @notice Close the book once the exercise window opens. No new listings after this.
    /// @dev Permissionless on purpose. It only ever moves the vault from Listed to
    ///      Exercisable, and only after a timestamp the registry already fixed, so there is
    ///      nothing to gain by calling it and something to lose if nobody can.
    function lockBook() external nonReentrant {
        if (phase != Phase.Listed) revert WrongPhase(Phase.Listed, phase);
        if (block.timestamp < cycleExerciseTs) revert NotYetExercisable(cycleExerciseTs);

        if (listingHash != bytes32(0)) _invalidateAllListings();
        phase = Phase.Exercisable;

        emit BookLocked(cycleNumber);
    }

    /// @notice Redeem the claim, harvest the premium, settle the redeem queue, return to Idle.
    /// @dev Strike proceeds from the claim are credited to holders fee-free; see {_accrueHarvest}.
    /// @dev Callable by the keeper from expiry, and by anyone an hour later. The vault must
    ///      not depend on a hot key staying alive for depositors to get their money back.
    function rollClose() external nonReentrant {
        Phase p = phase;
        if (p != Phase.Listed && p != Phase.Exercisable) revert WrongPhase(Phase.Exercisable, p);
        if (block.timestamp < cycleExpiryTs) revert NotYetExpired(cycleExpiryTs);

        if (!hasRole(KEEPER_ROLE, msg.sender)) {
            uint40 openAt = cycleExpiryTs + 1 hours;
            if (block.timestamp < openAt) revert GuardianTooEarly(openAt);
        }

        phase = Phase.Settling;

        // Kill any listing that is somehow still live before the inventory becomes worthless.
        if (listingHash != bytes32(0)) _invalidateAllListings();

        // Read the assignment BEFORE redeeming: `_redeemClaim` zeroes `claimKey`, and the view
        // returns 0 from then on. An earlier draft emitted a hardcoded 0 here, which made every
        // assigned week look unassigned in the public cycle tape.
        uint256 assignedCount = contractsAssigned();
        (uint256 assetsReturned, uint256 usdgFromAssignment) = _redeemClaim(asset, usdg);
        emit RollClose(cycleNumber, assetsReturned, usdgFromAssignment, assignedCount);

        _harvest(usdgFromAssignment);
        _settleQueue();

        phase = Phase.Idle;
    }

    /// @notice Settle the redeem queue while the vault is flat. Anyone.
    /// @dev WHY THIS EXISTS. Queueing is allowed in every phase and there is no dequeue, but the
    ///      queue used to settle only inside `rollClose`, which needs a `rollOpen` first. Anything
    ///      that stops the next write (a halt nobody lifts, a registry lot other than one token,
    ///      a Valorem fee not accepted, a stale or paused oracle, or simply less than one lot
    ///      idle, e.g. the last holder with half a token) froze a queuer's shares indefinitely
    ///      while everyone who had not queued could still redeem instantly.
    ///
    ///      While Idle the vault is flat (`rollClose` clears `contractsWritten` on the way in), so
    ///      {idleAssets} is the whole NAV and settling now pays exactly what an instant redemption
    ///      of the same shares would, virtual share included (see {_settleQueue}). The harvest checkpoint first folds any USDG that arrived
    ///      since the last close into the index, so the escrow's accrual is paid to the queuers.
    ///      It moves no tokens, so it works under an issuer freeze and while halted; the payout
    ///      is `completeRedeem`, as always.
    function settleQueue() external nonReentrant {
        if (phase != Phase.Idle) revert WrongPhase(Phase.Idle, phase);
        if (queuedShares == 0) revert NothingQueued();
        _checkpointHarvest();
        _settleQueue();
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    /// @dev Sweep whatever USDG has arrived but not yet been accounted for into the per-share
    ///      index, taking the protocol fee on the way. Pure bookkeeping: no external calls, so
    ///      it is safe to run from inside a deposit.
    ///
    ///      Everything in the USDG balance that is not already owed to someone is this week's
    ///      take: premium that filled, plus strike proceeds from any assignment. All of it is
    ///      credited to holders, but the fee is charged on the premium only.
    ///
    ///      WHY `feeFree`: strike proceeds are not yield. They are the assigned depositors'
    ///      principal, sold at the strike, and they have already given up the upside above it.
    ///      An earlier draft fee'd the whole inflow, which on an assigned week took 10% of
    ///      returned principal (a fee over 100 times the premium it was meant to be a cut of).
    ///      `rollClose` passes the measured claim redemption here; the deposit checkpoint
    ///      passes 0, and can, because strike proceeds sit inside the Valorem claim until
    ///      `rollClose` redeems it.
    function _accrueHarvest(uint256 feeFree) private returns (uint256 gross, uint256 feeUsdg, uint256 netUsdg) {
        uint256 balance = usdg.balanceOf(address(this));
        uint256 accounted = usdgAccounted;
        gross = balance > accounted ? balance - accounted : 0;
        // Everything held is attributed from here, whether or not any of it was new.
        _markUsdgAccounted(balance);
        if (gross == 0) return (0, 0, 0);

        (feeUsdg,) = Policy.splitHarvest(gross > feeFree ? gross - feeFree : 0, policy);
        netUsdg = gross - feeUsdg;
        if (feeUsdg != 0) pendingFeeUsdg += feeUsdg;
        _distributeUsdg(netUsdg);
    }

    /// @dev Checkpoint before minting new shares.
    ///      WHY THIS EXISTS: a premium can land the moment a buyer fills, days before
    ///      `rollClose` runs the harvest. Without this, anyone could deposit just before the
    ///      close, mint shares, and take a cut of premium earned entirely before they arrived,
    ///      diluting the depositors whose collateral actually backed the call. Folding the
    ///      accrual into the index first fixes the index in place, and the new shares then start
    ///      from it.
    function _checkpointHarvest() private {
        (uint256 gross, uint256 feeUsdg, uint256 netUsdg) = _accrueHarvest(0);
        if (gross != 0) emit Harvest(cycleNumber, gross, feeUsdg, netUsdg);
    }

    /// @dev The end-of-cycle harvest. Always emits, including the honest zero of an unfilled
    ///      week, and this is where the accumulated protocol fee actually leaves the vault.
    ///      `usdgFromAssignment` is credited fee-free (see {_accrueHarvest}), so on an assigned
    ///      week `Harvest.grossUsdg` still includes the strike proceeds while `feeUsdg` is
    ///      charged on `grossUsdg - RollClose.usdgFromAssignment` alone.
    function _harvest(uint256 usdgFromAssignment) private {
        (uint256 gross, uint256 feeUsdg, uint256 netUsdg) = _accrueHarvest(usdgFromAssignment);

        // Try to pay the protocol fee, but NEVER let it revert this call.
        //
        // `rollClose` is the only function that redeems the claim, clears `contractsWritten` and
        // settles the redeem queue. If a USDG transfer could revert it, then a blocklisted fee
        // recipient, a paused USDG, or a recipient contract that reverts on receive would freeze
        // every unit of collateral in the vault, strand the queue, and block every future cycle —
        // a stablecoin-side problem taking the whole product offline over a fee that harms only
        // us. So the push is best-effort, and {sweepFee} is the permissionless recovery path.
        _tryPayFee();

        if (usdgUnallocated != 0) _distributeUsdg(0);

        emit Harvest(cycleNumber, gross, feeUsdg, netUsdg);
    }

    /*//////////////////////////////////////////////////////////////
                            QUEUE SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Burn the escrowed shares and set aside their pro-rata assets and USDG.
    ///      Runs after the harvest so queued redeemers receive their share of the week they
    ///      actually sat through.
    function _settleQueue() private {
        uint256 q = queuedShares;
        if (q == 0) return;

        // The escrow's own accrual over the cycle belongs to the people who queued, each entry
        // according to the index it entered at (`_entryUsdg`).
        uint256 escrowUsdg = _takeAccrued(address(this));
        _epochAccUsdgPerShare[epochId] = accUsdgPerShare;

        // Priced exactly like an instant redemption, virtual share included: `q <= supply`, so
        // this never exceeds `idleAssets()`. An earlier draft paid `idle * q / supply` with no
        // +1/+1. Once `settleQueue` made the queue an atomic, permissionless exit while flat,
        // that turned first-depositor inflation from a donation-bounded grief into a profit:
        // seed 3 wei, donate, let a victim round down to one share, then queue and settle out
        // with part of the victim's deposit. The virtual share now keeps its slice on both paths.
        uint256 payoutAssets = q.mulDiv(idleAssets() + 1, totalSupply() + 1);

        queuedShares = 0;
        _burn(address(this), q);

        epochs[epochId] = Epoch({sharesRemaining: q, assetsRemaining: payoutAssets, usdgRemaining: escrowUsdg});
        reservedAssets += payoutAssets;
        usdgReservedForQueue += escrowUsdg;

        emit QueueSettled(epochId, q, payoutAssets, escrowUsdg);
        epochId += 1;
    }

    /// @dev Everything the vault holds in USDG less what is already promised elsewhere: the
    ///      settled redeem queue and the accrued protocol fee. Share holders can only ever be
    ///      paid out of the remainder.
    function _usdgAvailableForHolders() internal view override returns (uint256) {
        uint256 bal = usdg.balanceOf(address(this));
        uint256 spokenFor = usdgReservedForQueue + pendingFeeUsdg;
        return bal > spokenFor ? bal - spokenFor : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Spot for one lot in USDG base units. Gate and display only. The implementation lives
    ///      in {ValoremLib.spotUsdg}, beside the write gate that is its main consumer.
    function _spotUsdg() internal view returns (uint256) {
        return ValoremLib.spotUsdg(priceFeed, maxPriceAge);
    }

    /// @notice Spot used by the policy gate, for the UI.
    function spotUsdg() external view returns (uint256) {
        return _spotUsdg();
    }

    /// @dev The Stock Token can halt its own oracle. When it does, the vault holds spot and
    ///      writes nothing. See {ValoremLib.oraclePaused}.
    function _oraclePaused() private view returns (bool) {
        return ValoremLib.oraclePaused(asset);
    }

    function _requireOracleLive() private view {
        if (_oraclePaused()) revert OraclePaused();
    }

    /// @dev The two live-spot floors a listing of `amount` contracts must clear: the band's lower
    ///      strike bound and the gross premium floor. ONE function so {approveListing} (refuses
    ///      below either) and {invalidateStaleListing} (kills below either) can never disagree
    ///      about what the policy would still authorise. A stale feed reverts inside {_spotUsdg}.
    function _listingFloors(uint256 amount) private view returns (uint256 minStrike, uint256 minGross) {
        uint256 spot = _spotUsdg();
        PolicyParams memory p = policy;
        (minStrike,) = Policy.strikeBand(spot, p);
        minGross = Policy.minPremium(spot, amount, p);
    }

    /// @notice ERC-8056 display multiplier, or 1e18 when the token does not expose one.
    /// @dev Display only. No internal maths reads this.
    function uiMultiplier() external view returns (uint256) {
        (bool ok, bytes memory data) =
            address(asset).staticcall(abi.encodeWithSelector(IStockToken.uiMultiplier.selector));
        if (ok && data.length == 32) return abi.decode(data, (uint256));
        return 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Send the accrued protocol fee to the fee recipient.
    /// @dev PULL, NOT PUSH, AND THAT IS THE POINT.
    ///      An earlier draft transferred the fee inside `rollClose`. That put a USDG token call
    ///      on the vault's liveness path: if the fee recipient were blocklisted, or USDG paused,
    ///      or the recipient a contract that reverts, `rollClose` would revert with it. And
    ///      `rollClose` is the only function that redeems the claim, clears `contractsWritten`
    ///      and settles the redeem queue — so a stablecoin-side problem that has nothing to do
    ///      with the Stock Token would freeze every last unit of collateral, strand the queue,
    ///      and block every future cycle. Nobody could even redeem, because
    ///      `canRedeemInstantly()` needs the phase `rollClose` never reached.
    ///
    ///      Making it a separate, pull-based call means the worst case is an unpaid fee sitting
    ///      in `pendingFeeUsdg` until the obstruction clears, which harms only the protocol.
    ///
    ///      Permissionless on purpose: the destination is the stored `feeRecipient`, never
    ///      `msg.sender`, so an arbitrary caller can only ever pay the fee Safe.
    function sweepFee() external nonReentrant returns (uint256 fee) {
        fee = _tryPayFee();
        if (fee == 0) revert NothingToClaim();
    }

    /// @dev Best-effort transfer of the accrued fee. Returns what actually moved, and zero if
    ///      nothing did. State is only touched on success, so a failed attempt leaves the fee
    ///      exactly where it was, claimable later.
    /// @return paid USDG base units actually transferred.
    function _tryPayFee() private returns (uint256 paid) {
        uint256 fee = pendingFeeUsdg;
        if (fee == 0) return 0;

        // Clamp to what is actually here, same discipline as {Distributor._claimUsdg}.
        uint256 bal = usdg.balanceOf(address(this));
        if (fee > bal) fee = bal;
        if (fee == 0) return 0;

        // Best-effort, so a reverting or blocklisting token cannot take the caller down with it.
        if (!_tryTransfer(usdg, feeRecipient, fee)) return 0;

        pendingFeeUsdg -= fee;
        _debitUsdgOut(fee);
        emit FeeSwept(feeRecipient, fee);
        return fee;
    }

    /*//////////////////////////////////////////////////////////////
                             HALT / ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Block `rollOpen`, `writeMore` and `approveListing`. Never blocks redemptions,
    ///         claims, `settleQueue`, `cancelListing`, `lockBook` or `rollClose`.
    function haltWrites() external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        writesHalted = true;
        emit WritesHalted(true);
    }

    /// @notice Resume writing. Admin only: the guardian can stop, not start.
    function unhaltWrites() external onlyRole(DEFAULT_ADMIN_ROLE) {
        writesHalted = false;
        emit WritesHalted(false);
    }

    function setPolicy(PolicyParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Policy.validate(p);
        policy = p;
        emit PolicyUpdated(p);
    }

    function setFeeRecipient(address r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (r == address(0)) revert ZeroAddr();
        feeRecipient = r;
        emit FeeRecipientUpdated(r);
    }

    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @notice Set how stale the spot price may be before a write is refused.
    /// @dev Bounded in bytecode to [1 hour, 7 days]. The ceiling exists so nobody can quietly
    ///      switch the staleness check off; the floor exists because anything tighter than an
    ///      hour would fail even during market hours.
    function setMaxPriceAge(uint32 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxPriceAge(seconds_);
    }

    function _setMaxPriceAge(uint32 seconds_) private {
        if (seconds_ < MIN_PRICE_AGE || seconds_ > MAX_PRICE_AGE_CEIL) {
            revert PriceAgeOutOfBounds(seconds_, MIN_PRICE_AGE, MAX_PRICE_AGE_CEIL);
        }
        maxPriceAge = seconds_;
        emit MaxPriceAgeUpdated(seconds_);
    }

    /// @notice Accept paying Valorem's engine fee on writes.
    /// @dev Deliberately a separate, explicit switch. If Valorem turns its 15 bps notional fee
    ///      on, the vault stops writing until a human decides the premium still covers it.
    function acceptValoremFee(bool accepted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        valoremFeeAccepted = accepted;
        emit ValoremFeeAccepted(accepted);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERFACE
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return interfaceId == 0x4e2312e0 // ERC1155Receiver
            || interfaceId == 0x1626ba7e // EIP-1271
            || super.supportsInterface(interfaceId);
    }
}
