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

    /// @dev The longest cycle this vault will ever underwrite, measured from the moment of the
    ///      write. Overcall's cycles are seven days with a 24-hour exercise window.
    ///
    ///      WHY A COMPILED-IN CONSTANT, NOT A POLICY FIELD. The registry that sets the cycle is
    ///      owned by a single third-party EOA, and its `setCycle` bounds the expiry only from
    ///      below (`exerciseAt + MIN_EXERCISE_WINDOW`). Nothing stops it setting an expiry years
    ///      out, by malice or by fat finger. The vault snapshots that expiry and `rollClose`
    ///      then refuses to run until it passes, so collateral would be locked in Valorem for
    ///      the whole tenor with no redemption path for anyone. A skipped week is strictly
    ///      better than a decade-long lock on depositor principal, and making this
    ///      admin-settable would reintroduce the single-key dependency it exists to remove.
    uint40 internal constant MAX_CYCLE_TENOR = 21 days;

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

    /// @notice When true, `rollOpen` and `approveListing` are blocked. Nothing else is.
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
    error DepositsClosedForCycle(uint40 exerciseTs);

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
    /// @dev Idle balance, less what is already promised to settled redeemers, plus whatever
    ///      is still locked behind this cycle's Valorem claim. USDG is not included: it is
    ///      distributed through {Distributor}, not through the share price. Unsold option
    ///      inventory is valued at zero.
    function totalAssets() public view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        uint256 free = idle > reserved ? idle - reserved : 0;
        return free + lockedAssets();
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
        // Quote zero in any phase that would reject the deposit. A non-zero figure the caller
        // cannot act on is the same dishonesty as a preview quoting an instant redemption while
        // the queue is the only path.
        Phase p = phase;
        if (p != Phase.Idle && p != Phase.Listed) return 0;
        // Mirror the exercise-window close in {_requireDepositPhase}, so the quote goes to zero
        // at the same instant the deposit starts reverting.
        if (p == Phase.Listed && block.timestamp >= cycleExerciseTs) return 0;
        if (claimKey != 0 && claimedExerciseProceeds() != 0) return 0;

        uint256 held = totalAssets();
        if (held >= depositCap) return 0;
        return depositCap - held;
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
    /// @dev Allowed in Idle and Listed. New money lands in the idle balance and is not added
    ///      to a short that is already open, so a late depositor cannot be assigned against a
    ///      call they were never part of writing.
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
    function _requireDepositPhase() private view {
        Phase p = phase;
        if (p != Phase.Idle && p != Phase.Listed) revert WrongPhase(Phase.Idle, p);
        if (p == Phase.Listed && block.timestamp >= cycleExerciseTs) {
            revert DepositsClosedForCycle(cycleExerciseTs);
        }
        // Second line of defence, independent of the clock. If any contract has been assigned
        // and the claim has not been redeemed yet, the vault's NAV has already fallen by the
        // collateral that left while the offsetting strike USDG is still inside Valorem. Pricing
        // new shares against that gap is exactly the theft the timestamp check prevents, so
        // refuse regardless of what the timestamps say.
        if (claimKey != 0 && claimedExerciseProceeds() != 0) revert DepositsClosedForCycle(cycleExerciseTs);
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

        // Settle before escrowing so the depositor keeps every cent already earned.
        _settleAccount(msg.sender);
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

        (assets, usdgOut) = _payoutOwed(owner, receiver);

        if (shares == 0 && assets == 0 && usdgOut == 0) {
            if (queued != 0) revert EpochNotSettled(e, epochId);
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

        // Draw down the epoch's remaining balances proportionally. The final claimant has
        // `shares == ep.sharesRemaining`, so they receive exactly what is left and the
        // division leaves nothing stranded.
        uint256 assets = (ep.assetsRemaining * shares) / ep.sharesRemaining;
        uint256 usdgOut = (ep.usdgRemaining * shares) / ep.sharesRemaining;

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
    ///      is the only leg an issuer freeze can stop.
    function _payoutOwed(address owner, address receiver) private returns (uint256 assets, uint256 usdgOut) {
        assets = owedAssets[owner];
        usdgOut = owedQueueUsdg[owner];
        if (assets == 0 && usdgOut == 0) return (0, 0);

        owedAssets[owner] = 0;
        owedQueueUsdg[owner] = 0;
        reservedAssets -= assets;
        usdgReservedForQueue -= usdgOut;

        if (assets != 0) asset.safeTransfer(receiver, assets);
        if (usdgOut != 0) {
            _debitUsdgOut(usdgOut);
            usdg.safeTransfer(receiver, usdgOut);
        }
    }

    /// @notice What a queued position is worth once its epoch has settled.
    function previewCompleteRedeem(address owner) external view returns (uint256 assets, uint256 usdgOut) {
        // Anything already settled out of an epoch but not yet collected.
        assets = owedAssets[owner];
        usdgOut = owedQueueUsdg[owner];

        uint256 shares = queuedSharesOf[owner];
        uint256 e = queuedEpochOf[owner];
        if (shares == 0 || e >= epochId) return (assets, usdgOut);
        Epoch storage ep = epochs[e];
        if (ep.sharesRemaining == 0) return (assets, usdgOut);
        assets += (ep.assetsRemaining * shares) / ep.sharesRemaining;
        usdgOut += (ep.usdgRemaining * shares) / ep.sharesRemaining;
    }

    /*//////////////////////////////////////////////////////////////
                             PHASE MACHINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Write this cycle's calls and move to Listed.
    /// @param optionId_ The Overcall rung to write. Must be approved in the live cycle.
    /// @param contractsCount Whole lots to write.
    function rollOpen(uint256 optionId_, uint112 contractsCount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (phase != Phase.Idle) revert WrongPhase(Phase.Idle, phase);
        if (writesHalted) revert WritesAreHalted();

        // The registry's own gate. `isWritingOpen()` is false both before the first cycle is
        // set and after the write deadline passes.
        if (!registry.isWritingOpen()) revert WritingNotOpen();

        IOvercallRegistry.Cycle memory cyc = registry.cycle();
        if (cyc.number == 0) revert NoCycle();
        if (!registry.isApproved(optionId_)) revert OptionNotApproved(optionId_);

        uint32 optCycle = registry.cycleOf(optionId_);
        if (optCycle != cyc.number) revert OptionNotInCurrentCycle(optionId_, optCycle, cyc.number);

        // Refuse an absurd cycle before any collateral moves. The registry's owner is a single
        // third-party EOA and its `setCycle` bounds the expiry only from below, so a hostile or
        // mistaken cycle could otherwise lock the vault's collateral until that expiry passed.
        if (cyc.expiryTimestamp <= cyc.exerciseTimestamp) {
            revert BadCycleWindow(cyc.exerciseTimestamp, cyc.expiryTimestamp);
        }
        if (cyc.expiryTimestamp > uint40(block.timestamp) + MAX_CYCLE_TENOR) {
            revert BadCycleWindow(cyc.exerciseTimestamp, cyc.expiryTimestamp);
        }

        // Valorem's engine fee is 15 bps of notional, which on a weekly out-of-the-money call
        // is a large slice of the premium. Writing through it is a governance decision, not a
        // keeper decision.
        if (clear.feesEnabled() && !valoremFeeAccepted) revert ValoremFeeNotAccepted(clear.feeBps());

        _requireOracleLive();

        uint256 strikeUsdg = uint256(registry.strikePerContract(optionId_));
        uint256 spot = _spotUsdg();

        PolicyParams memory p = policy;
        Policy.checkStrike(strikeUsdg, spot, p);
        Policy.checkContracts(contractsCount, idleAssets(), p);

        _writeCalls(asset, address(usdg), optionId_, contractsCount, cyc, valoremFeeAccepted);

        cycleNumber = cyc.number;
        cycleExerciseTs = cyc.exerciseTimestamp;
        cycleExpiryTs = cyc.expiryTimestamp;
        cycleStrikeUsdg = strikeUsdg;
        _resetListingBudget();
        phase = Phase.Listed;

        emit RollOpen(cyc.number, optionId_, contractsCount, strikeUsdg);
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

        // The economic floor is checked here rather than in the adapter because it needs the
        // live spot, and the adapter is deliberately free of oracle knowledge.
        _requireOracleLive();
        Policy.checkPremium(grossUsdg, _spotUsdg(), amount, policy);
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

        // The escrow's own accrual over the cycle belongs to the people who queued.
        uint256 escrowUsdg = _takeAccrued(address(this));

        uint256 supply = totalSupply();
        uint256 payoutAssets = supply == 0 ? 0 : (idleAssets() * q) / supply;

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

    /// @dev Spot for one lot in USDG base units. Gate and display only.
    ///      This is the single seam where the price comes from; nothing downstream of a write
    ///      decision ever calls it.
    function _spotUsdg() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt, maxPriceAge);
        return Policy.normalizeSpot(answer, priceFeed.decimals());
    }

    /// @notice Spot used by the policy gate, for the UI.
    function spotUsdg() external view returns (uint256) {
        return _spotUsdg();
    }

    /// @dev The Stock Token can halt its own oracle. When it does, the vault holds spot and
    ///      writes nothing. Probed with a staticcall so a token without the function is not a
    ///      permanent brick.
    function _requireOracleLive() private view {
        (bool ok, bytes memory data) =
            address(asset).staticcall(abi.encodeWithSelector(IStockToken.oraclePaused.selector));
        if (ok && data.length == 32 && abi.decode(data, (bool))) revert OraclePaused();
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

        // Raw call rather than SafeERC20 so a reverting or blocklisting token cannot take the
        // caller down with it. A missing return value is treated as success, matching the
        // non-compliant-ERC20 convention SafeERC20 follows.
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (feeRecipient, fee)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) return 0;

        pendingFeeUsdg -= fee;
        _debitUsdgOut(fee);
        emit FeeSwept(feeRecipient, fee);
        return fee;
    }

    /*//////////////////////////////////////////////////////////////
                             HALT / ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Block `rollOpen` and `approveListing`. Never blocks redemptions, claims,
    ///         `cancelListing`, `lockBook` or `rollClose`.
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
