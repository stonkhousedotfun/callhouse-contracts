// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Managed} from "../../access/Managed.sol";
import {IClearinghouse} from "../../interfaces/IClearinghouse.sol";
import {IExpiryCalendar} from "../../interfaces/IExpiryCalendar.sol";
import {IOrderBook} from "../../interfaces/IOrderBook.sol";
import {ISettlementOracle} from "../../interfaces/ISettlementOracle.sol";
import {V2Constants} from "../../interfaces/V2Constants.sol";
import {V2Errors} from "../../interfaces/V2Errors.sol";
import {V2Ids} from "../../interfaces/V2Ids.sol";
import {V2Types} from "../../interfaces/V2Types.sol";

/// @title HouseVault
/// @notice The user-funded market maker: one instance per market. Depositors hand it USDG and Stock Tokens and hold
///         ERC-20 shares of it; a bot key holding QUOTER on the manager quotes and trades the pool inside the same
///         on-chain guard rails as {MakerVault}. Owner decision V3-D30.
/// @dev THE ONE-LINE DIFFERENCE FROM MakerVault. MakerVault is treasury money, so TREASURY_ADMIN can pull any asset
///      out to {treasury}. THIS vault is depositor money, so NO ROLE CAN MOVE A NON-SHARE ASSET TO AN ADDRESS ANYONE
///      CHOOSES. There is no `withdraw(address,uint256)`, no `withdrawPosition`, no `setTreasury`. Exactly two paths
///      move a non-share asset out of this contract:
///        - {rollEpoch}, which pays the performance fee in USDG to the IMMUTABLE {splitter}, and
///        - {claim}, which pays a shareholder their own in-kind pro rata.
///      Both destinations are fixed by the contract, not by a caller. That is the property depositors rely on and it
///      is asserted directly against the compiled artifact by the interface suite.
///
///      UNITS (ADR-04), the same as everywhere in v2. Prices, spot, intrinsic value, notional, NAV and USDG amounts
///      are USDG base units (6 dp) per whole share or in total; option amounts are 0.01-share units (ERC-1155
///      amounts); the Stock Token is 18 dp; rates are bps of BPS = 10_000. Shares are 18 dp.
///
///      WHO CAN DO WHAT (INTERFACE_VERSION 8). The vault holds no role table: it is {Managed}, and one
///      `AccessManager` maps (this contract, selector) to a role id. Every new instance needs its own
///      `setTargetFunctionRole` batch -- see {HouseVaultFactory}.
///        - ANYONE: {requestDeposit}, {cancelDepositRequest}, {requestWithdraw}, {cancelWithdrawRequest},
///          {rollEpoch}, {claim}, and the ERC-20 surface.
///        - QUOTER (the mm-bot key): the quoting surface, byte-identical in shape to {MakerVault}'s.
///        - TREASURY_ADMIN: {setPerformanceFeeBps}. It CANNOT quote and it CANNOT reach the money.
///        - CONFIG_ADMIN: {setProtocolAccount}, which also ARMS the vault -- {take} reverts `NoSource()` until
///          at least one protocol account has been named. See {protocolAccountsConfirmed}. And {setOracle}, the
///          only way the boundary's price source can move after deployment (T-OP-058).
///        - GUARDIAN (zero delay): {setQuotingPaused} and, since T-OP-159, {setLimits}: the owner ordered NO
///          delay on the limits at all (2026-09-22), so the guard rails moved off TREASURY_ADMIN's 24 h lane.
///          The authority for every row above is `script/v2/roles.v8.json` `.targets.HouseVault`; this list
///          mirrors it and is re-pinned when it moves (T-OP-168).
///
///      EPOCHS. The vault runs in weekly epochs that end at {epochEnd}, a weekly expiry taken from
///      {IExpiryCalendar.nextExpiry}(afterTs, true). Quoting is confined to the epoch: {place}, {replace} and {take}
///      revert BadExpiry unless the series expires at or before {epochEnd}, and so does {sync} -- a series that
///      outlives the epoch can never enter {_tracked}, whatever was transferred in (T-OP-064, SEC-14). {close} is the
///      one exception and it is deliberate: it will close an out-of-epoch pair (the runbook's escape hatch) but
///      never tracks one. (BadExpiry, not PastCutoff: PastCutoff is
///      already the book's "your validUntil is past the series cutoff" and reusing it here would make two different
///      refusals indistinguishable in a trace. BadExpiry reads as "that series does not belong to this epoch", which
///      is what this is.)
///
///      THE BOUNDARY. {rollEpoch} is PERMISSIONLESS and refuses until the vault holds nothing but USDG and Stock
///      Tokens and the epoch's settlement price is final:
///        (a) every series the vault touched this epoch is settled, its ERC-1155 balance here is zero, and it has no
///            live orders, and
///        (b) `oracle.settlementPrice(underlying, epochEnd)` is Finalized.
///      NO OPTION IS EVER VALUED. If any option were still held, (a) failed and there is no boundary. That is the
///      whole reason the guard exists: it removes option pricing from the deposit/withdraw path entirely rather than
///      trying to do it correctly.
///
///      NAV, AND THE MISTAKE IT IS BUILT TO AVOID. Deposits and withdrawal requests QUEUE during the epoch and are
///      priced only at the boundary. A queued deposit's assets are already sitting in this contract's balance, so
///      measuring NAV as a bare `balanceOf` would let a depositor's own money inflate the NAV that prices their own
///      shares -- they would pay themselves. NAV therefore subtracts {pendingDepositUsdg} and {pendingDepositStock},
///      and also the assets already reserved for unclaimed withdrawals ({owedUsdg}, {owedStock}), which belong to
///      former shareholders and not to the pool.
///      THE CLEARINGHOUSE LEDGER IS INCLUDED IN THE MEASUREMENT, AND THE RESERVE IT CREATES IS PULLED BACK AFTER.
///      `clearinghouse.free(this, asset)` is added to NAV rather than withdrawn before measuring, because reading it
///      cannot fail; the locked part is necessarily zero at the boundary, since guard (a) proved no open position.
///      Then {_restoreReserve} moves the withdrawal reserve the batch just created back into the wallet (F-5): a
///      reserve left in the ledger is lockable by the next epoch's write and {claim} would fail closed. The pull is
///      clamped to what is free and `Clearinghouse.withdraw` has no pause flag, so it cannot stall the roll.
///
///      FIRST DEPOSITOR. On the first boundary with no supply the batch is priced at a flat ONE SHARE BASE UNIT PER
///      ONE USDG BASE UNIT of NAV -- shares are 18 dp and USDG is 6, so one WHOLE USDG buys 1e-12 of a WHOLE share,
///      and {MIN_SHARES} is worth 0.001 USDG at that batch. The rate, not the decimals, is what the inflation
///      defence rests on, so the mint is correct and is not changed; only this sentence was wrong (F9).
///      {MIN_SHARES} shares are credited to {DEAD_SHARES}. A direct token donation before that boundary cannot be
///      used to inflate anyone: the rate is FIXED at 1:1 rather than derived from NAV, so a donation only adds NAV
///      that the donor does not get shares for. The dead shares then stop the classic second-step attack, where a
///      1-wei first depositor donates a large balance and rounds every later depositor down to zero shares.
contract HouseVault is ERC20, IERC1155Receiver, Managed, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The admin-set guard rails. MIRRORED FIELD FOR FIELD from `MakerVault.Limits` so the two vaults can be
    ///         configured identically and compared directly; the equivalence test relies on that.
    struct Limits {
        uint64 maxSeriesUnits; // 0.01-share units: worst-case net position per series
        uint128 maxTotalNotional; // USDG base units: Σ over series of exposure x strike / 100
        uint16 askToleranceBps; // bps of spot subtracted from intrinsic value for the ask floor, <= BPS
        uint16 maxBidBpsOfSpot; // bid / buying-take price cap, bps of spot, <= BPS
        uint32 maxOrderLifetime; // seconds an order may stay live from placement; 0 = up to the series limit
        uint128 maxDailyOutflow; // USDG base units the quoter may pay out net at once; refills per OUTFLOW_WINDOW
    }

    /// @notice What the vault holds and has open on one series, in 0.01-share units.
    /// @dev MIRRORED from `MakerVault.Exposure`.
    struct Exposure {
        uint256 longs;
        uint256 shorts;
        uint256 bids;
        uint256 resale;
        uint256 writes;
        uint256 live;
    }

    /// @notice A depositor's queued assets and the epoch they were queued in.
    struct DepositRequest {
        uint64 epochId;
        uint128 usdg; // USDG base units queued
        uint128 stock; // Stock Token base units (18 dp) queued
    }

    /// @notice A withdrawer's escrowed shares and the epoch they were queued in.
    struct WithdrawRequest {
        uint64 epochId;
        uint256 shares;
    }

    /// @dev What one epoch's boundary decided. Written once by {rollEpoch} and read by {claim}, so neither queue
    ///      needs an unbounded loop over its participants at the boundary -- the boundary is permissionless and must
    ///      not have a gas cost that grows with the number of depositors, or it becomes un-rollable.
    struct EpochRates {
        uint128 price; // Finalized settlement price at this boundary, USDG 6 dp per whole share
        uint256 depositValue; // total USDG-denominated value of the deposit batch
        uint256 depositShares; // shares minted for that batch
        uint256 withdrawShares; // shares burned for the withdrawal batch
        uint256 withdrawUsdg; // USDG reserved for that batch
        uint256 withdrawStock; // Stock Tokens reserved for that batch
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Most live orders the vault keeps on one series. MIRRORED from `MakerVault.MAX_LIVE_ORDERS_PER_SERIES`.
    uint256 public constant MAX_LIVE_ORDERS_PER_SERIES = 16;

    /// @notice The window {Limits.maxDailyOutflow} refills over. MIRRORED from `MakerVault.OUTFLOW_WINDOW`.
    uint256 public constant OUTFLOW_WINDOW = 1 days;

    /// @notice Dead shares minted to address(0) on the first boundary, against first-depositor inflation.
    uint256 public constant MIN_SHARES = 1e3;

    /// @notice Where {MIN_SHARES} dead shares are credited on the first batch.
    /// @dev NOT `address(0)`. OZ `ERC20._mint` reverts `ERC20InvalidReceiver(address(0))` on a zero receiver
    ///      (`lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol:214-217`), so crediting the zero address
    ///      is not merely unconventional -- it is unreachable, and it made {rollEpoch} revert on the `supply == 0`
    ///      branch, i.e. the FIRST batch, so a freshly deployed vault could never be seeded. MIRRORED from
    ///      {EarnVault.DEAD_SHARES}, which hit the same wall and wrote the reason down at `EarnVault.sol:104-106`
    ///      while copying this contract's own MIN_SHARES idea.
    address public constant DEAD_SHARES = address(0xdead);

    /// @notice The most {performanceFeeBps} may ever be, compiled in and unreachable by any role.
    uint16 public constant PERFORMANCE_FEE_CEIL_BPS = 2000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The OrderBook the vault quotes on.
    IOrderBook public immutable orderBook;
    /// @notice The Clearinghouse the OrderBook trades (read from the book at deployment).
    IClearinghouse public immutable clearinghouse;
    /// @notice USDG (6 dp), the Clearinghouse's.
    IERC20 public immutable usdg;
    /// @notice The 18-dp Stock Token this vault makes a market in.
    IERC20 public immutable underlying;
    /// @notice The expiry calendar the weekly epoch boundary comes from.
    IExpiryCalendar public immutable calendar;
    /// @notice The settlement oracle the boundary price comes from. Seeded from `HouseVaultFactory` at
    ///         construction; moved by {setOracle} (CONFIG_ADMIN) and by nothing else.
    /// @dev F6, FIXED BY T-OP-058 -- this used to be `immutable`, and the paragraph that follows is why that was
    ///      a defect and not a simplification. `Clearinghouse.setMarketOracle` re-points a market for series
    ///      created afterwards, but a boundary prices on THIS oracle: after an oracle migration (a new
    ///      SettlementOracle deploy after an oracle defect, which is exactly the kind of fix the launch phase may
    ///      need) the boundary kept reading the retired instance, whose `settlementPrice` for future epochs is
    ///      never written -- every {rollEpoch} reverted NotSettled for ever and depositor money sat behind
    ///      {_requireFlat}. The immutability was compiled in, so the only post-deploy remedy would have been a new
    ///      vault per market and a depositor migration. Same family as T-310.
    ///
    ///      READING THE SERIES ORACLE AT THE BOUNDARY IS NOT THE ANSWER: {rollEpoch} runs only when the vault is
    ///      FLAT, so at the moment the price is needed there is no series to take an oracle from. A setter is.
    ///
    ///      THE FACTORY KEEPS ITS `immutable oracle` ON PURPOSE. It is a SEED for vaults created afterwards, and a
    ///      new vault takes whatever the factory holds at creation; a stale factory seed is a different and smaller
    ///      problem (the next vault starts on the old oracle and its CONFIG_ADMIN moves it with one call) than a
    ///      live vault that can never move. If a migration ever needs new vaults on the new oracle at birth, deploy
    ///      a new factory: it holds no state a vault depends on.
    ISettlementOracle public oracle;
    /// @notice The FeeSplitter: the ONLY address the performance fee can ever reach, fixed at deployment.
    address public immutable splitter;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    Limits private _limits;

    /// @dev The leaky bucket behind {Limits.maxDailyOutflow}. MIRRORED from `MakerVault._outflowScaled`/`_outflowAt`.
    uint216 private _outflowScaled;
    uint40 private _outflowAt;

    /// @notice Σ {seriesNotional}, USDG base units.
    uint256 public totalNotional;
    /// @notice Last measured notional of `longId`. MIRRORED from `MakerVault.seriesNotional`.
    mapping(uint256 longId => uint256) public seriesNotional;

    mapping(uint256 longId => uint256[]) private _orderIds;
    uint256[] private _tracked;
    mapping(uint256 longId => uint256) private _trackedPos;

    /// @notice The weekly expiry this epoch ends at, unix seconds.
    uint40 public epochEnd;
    /// @notice Monotonic epoch counter; 0 is the epoch before the first {rollEpoch}.
    uint64 public epochId;
    /// @notice High-water mark of NAV per share, USDG base units per 1e18 shares. The performance fee is charged
    ///         only above this, so a recovery after a losing epoch is not charged twice.
    uint256 public highWaterMark;
    /// @notice Performance fee on the gain of a positive epoch, bps, <= {PERFORMANCE_FEE_CEIL_BPS}.
    uint16 public performanceFeeBps;
    /// @notice The Finalized settlement price the LAST boundary used, USDG 6 dp per whole share; 0 before the first
    ///         {rollEpoch}. {nav} values the Stock leg at this between boundaries.
    uint128 public lastSettlementPrice;
    /// @notice GUARDIAN's quoting brake. Blocks {place}, {replace} and {take} and NOTHING else.
    bool public quotingPaused;

    /// @notice Accounts the vault may never trade against, set by CONFIG_ADMIN.
    /// @dev SEEDED IN THE CONSTRUCTOR with {splitter}, which is the only protocol address this contract can derive
    ///      for itself. Everything else -- the MakerVault, the EarnVault, the Hedger, the other House vaults, the
    ///      protocol Safes -- is an address no vault can know, so CONFIG_ADMIN names them and {take} refuses to run
    ///      until it has. See {protocolAccountsConfirmed}.
    mapping(address account => bool) public protocolAccount;

    /// @notice True once CONFIG_ADMIN has named at least one protocol account through {setProtocolAccount}.
    ///         {take} reverts `NoSource()` until it is.
    /// @dev WHY THIS EXISTS, and it is the whole point of the row that added it. D30 says the vault NEVER TRADES
    ///      AGAINST PROTOCOL ACCOUNTS, and {_requireNoSelfDeal} enforces exactly that -- against whatever is in
    ///      {protocolAccount}. Before this flag, that mapping was EMPTY at launch and nothing on chain filled it:
    ///      the constructor wrote nothing, {HouseVaultFactory.createVault} seeded nothing, and no deploy script
    ///      called {setProtocolAccount}. So the guard passed every take by being unable to see its own subject --
    ///      a check satisfied because it had nothing to check, which is the most expensive way for a safety
    ///      property to be false.
    ///
    ///      IT IS NOT SET BY THE CONSTRUCTOR ON PURPOSE. Seeding {splitter} there is derivable and therefore
    ///      trustworthy; the rest is an operational fact about a deployment, and a vault cannot tell "the operator
    ///      configured the empty set deliberately" from "the operator forgot". So arming is an AFFIRMATIVE act by
    ///      CONFIG_ADMIN and the unconfigured state fails closed.
    ///
    ///      IT COSTS NO NEW LIVE WINDOW. A vault is born with no selector mapped to any role (see
    ///      {HouseVaultFactory}), so it cannot be quoted until the Admin Safe sends its `setTargetFunctionRole`
    ///      batch anyway; `setProtocolAccount` rides that same batch. Depositor paths -- {requestDeposit},
    ///      {requestWithdraw}, {rollEpoch}, {claim} -- are untouched by this and never trap money behind it.
    bool public protocolAccountsConfirmed;

    /// @notice USDG queued by depositors and not yet priced. Excluded from NAV.
    uint256 public pendingDepositUsdg;
    /// @notice Stock Tokens queued by depositors and not yet priced. Excluded from NAV.
    uint256 public pendingDepositStock;
    /// @notice Shares escrowed here by withdrawers and not yet burned.
    uint256 public pendingWithdrawShares;
    /// @notice USDG already reserved for unclaimed withdrawals. Excluded from NAV.
    uint256 public owedUsdg;
    /// @notice Stock Tokens already reserved for unclaimed withdrawals. Excluded from NAV.
    uint256 public owedStock;

    mapping(address account => DepositRequest) public depositRequestOf;
    mapping(address account => WithdrawRequest) public withdrawRequestOf;
    mapping(uint64 epoch => EpochRates) private _rates;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DepositRequested(address indexed account, uint256 usdgAmount, uint256 stockAmount, uint64 indexed epochId);
    event DepositRequestCancelled(address indexed account, uint256 usdgAmount, uint256 stockAmount);
    event WithdrawRequested(address indexed account, uint256 shares, uint64 indexed epochId);
    event WithdrawRequestCancelled(address indexed account, uint256 shares);
    event EpochRolled(
        uint64 indexed epochId,
        uint40 indexed epochEnd,
        uint256 price,
        uint256 nav,
        uint256 supply,
        uint256 sharesMinted,
        uint256 sharesBurned,
        uint256 performanceFee
    );
    event Claimed(address indexed account, uint256 shares, uint256 usdgAmount, uint256 stockAmount);
    event LimitsSet(Limits limits);
    event PerformanceFeeBpsSet(uint16 bps);
    event ProtocolAccountSet(address indexed account, bool blocked);
    /// @notice CONFIG_ADMIN has named a protocol account for the first time and {take} is now armed.
    event ProtocolAccountsConfirmed();
    event QuotingPausedSet(bool paused);
    event ExposureSet(uint256 indexed longId, uint256 units, uint256 notional, uint256 totalNotional);
    /// @notice CONFIG_ADMIN moved the boundary's settlement oracle (T-OP-058).
    event OracleSet(address indexed previous, address indexed oracle);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param orderBook_ The OrderBook; its `clearinghouse()` and that Clearinghouse's `usdg()` become immutable.
    /// @param authority_ The `AccessManager` that gates every privileged selector.
    /// @param underlying_ The 18-dp Stock Token this vault makes a market in.
    /// @param calendar_ The expiry calendar the weekly boundary comes from.
    /// @param oracle_ The settlement oracle the boundary price comes from.
    /// @param splitter_ The FeeSplitter, the only address the performance fee can reach.
    /// @param limits_ Initial guard rails.
    /// @param name_ ERC-20 name, e.g. "Stonkhouse House NVDA".
    /// @param symbol_ ERC-20 symbol, e.g. "hNVDA".
    constructor(
        IOrderBook orderBook_,
        address authority_,
        IERC20 underlying_,
        IExpiryCalendar calendar_,
        ISettlementOracle oracle_,
        address splitter_,
        Limits memory limits_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Managed(authority_) {
        if (address(underlying_) == address(0) || splitter_ == address(0)) {
            revert V2Errors.NotAuthorized();
        }
        if (address(calendar_) == address(0) || address(oracle_) == address(0)) revert V2Errors.NoSource();
        IClearinghouse ch = IClearinghouse(orderBook_.clearinghouse());
        clearinghouse = ch;
        orderBook = orderBook_;
        usdg = IERC20(ch.usdg());
        underlying = underlying_;
        calendar = calendar_;
        oracle = oracle_;
        splitter = splitter_;
        // THE ONE PROTOCOL ADDRESS A VAULT CAN DERIVE. `splitter_` is checked non-zero five lines up and is the
        // only address the performance fee can ever reach, so it is a protocol account by construction and seeding
        // it needs no operator and cannot be got wrong. It deliberately does NOT arm the vault: see
        // {protocolAccountsConfirmed}.
        protocolAccount[splitter_] = true;
        emit ProtocolAccountSet(splitter_, true);
        _setLimits(limits_);
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        epochEnd = calendar_.nextExpiry(uint40(block.timestamp), true);
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                             DEPOSITOR QUEUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Queues `amount` base units of `asset` (USDG or the Stock Token) for the running epoch's boundary.
    ///         ANYONE, strictly before {epochEnd}.
    /// @dev The assets are pulled now and sit in this contract, but they are NOT part of NAV until the boundary
    ///      prices them -- see {nav}. Calling twice in one epoch adds to the same request; calling in a LATER epoch
    ///      than an unclaimed one reverts, because the earlier batch is already priced and must be claimed first.
    function requestDeposit(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert V2Errors.BadUnits();
        // At the boundary the settlement price may already be Finalized even if nobody has called permissionless
        // {rollEpoch} yet. Admitting a deposit in that interval would let it join the finished batch at a known rate.
        if (block.timestamp >= epochEnd) revert V2Errors.PastCutoff();
        bool isUsdg = asset == address(usdg);
        if (!isUsdg && asset != address(underlying)) revert V2Errors.UnsupportedAsset();

        DepositRequest memory r = depositRequestOf[msg.sender];
        if (r.epochId != epochId && (r.usdg != 0 || r.stock != 0)) revert V2Errors.TooEarly(epochEnd);

        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert V2Errors.BadUnits();

        r.epochId = epochId;
        if (isUsdg) {
            r.usdg = _u128(uint256(r.usdg) + received);
            pendingDepositUsdg += received;
        } else {
            r.stock = _u128(uint256(r.stock) + received);
            pendingDepositStock += received;
        }
        depositRequestOf[msg.sender] = r;
        emit DepositRequested(msg.sender, isUsdg ? received : 0, isUsdg ? 0 : received, epochId);
    }

    /// @notice Returns an UNPRICED queued deposit. ANYONE, for their own request only, strictly before {epochEnd}.
    /// @dev Same cutoff as {requestDeposit}: `epochId` moves only in {rollEpoch}, so in `[epochEnd, rollEpoch)` the
    ///      Finalized price is readable and a cancel there would let a depositor leave a batch that went against them.
    function cancelDepositRequest(address account) external nonReentrant {
        if (account != msg.sender) revert V2Errors.NotAuthorized();
        DepositRequest memory r = depositRequestOf[account];
        if (r.epochId != epochId) revert V2Errors.TooEarly(epochEnd);
        if (r.usdg == 0 && r.stock == 0) revert V2Errors.BadUnits();
        if (block.timestamp >= epochEnd) revert V2Errors.PastCutoff();
        delete depositRequestOf[account];
        if (r.usdg != 0) {
            pendingDepositUsdg -= r.usdg;
            _payReserved(usdg, account, r.usdg);
        }
        if (r.stock != 0) {
            pendingDepositStock -= r.stock;
            _payReserved(underlying, account, r.stock);
        }
        emit DepositRequestCancelled(account, r.usdg, r.stock);
    }

    /// @notice Escrows `shares` for redemption at the next boundary. ANYONE, for their own shares.
    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert V2Errors.BadUnits();
        WithdrawRequest memory r = withdrawRequestOf[msg.sender];
        if (r.shares != 0 && r.epochId != epochId) revert V2Errors.TooEarly(epochEnd);
        _transfer(msg.sender, address(this), shares);
        r.epochId = epochId;
        r.shares += shares;
        withdrawRequestOf[msg.sender] = r;
        pendingWithdrawShares += shares;
        emit WithdrawRequested(msg.sender, shares, epochId);
    }

    /// @notice Returns UNPROCESSED escrowed shares. ANYONE, for their own request only.
    function cancelWithdrawRequest() external nonReentrant {
        WithdrawRequest memory r = withdrawRequestOf[msg.sender];
        if (r.shares == 0) revert V2Errors.BadUnits();
        if (r.epochId != epochId) revert V2Errors.TooEarly(epochEnd);
        delete withdrawRequestOf[msg.sender];
        pendingWithdrawShares -= r.shares;
        _transfer(address(this), msg.sender, r.shares);
        emit WithdrawRequestCancelled(msg.sender, r.shares);
    }

    /// @notice Collects whatever a past boundary decided for the caller: shares from a priced deposit, the queued
    ///         assets back from a deposit batch the boundary refused (SEC-17), and USDG plus Stock Tokens from a
    ///         processed withdrawal. PERMISSIONLESS and idempotent.
    function claim() external nonReentrant {
        uint256 sharesOut;
        uint256 usdgOut;
        uint256 stockOut;
        // Whether a MATURED request was consumed, which is a different question from whether anything was
        // paid. See the refusal at the end of this function.
        bool retired;

        DepositRequest memory d = depositRequestOf[msg.sender];
        if ((d.usdg != 0 || d.stock != 0) && d.epochId < epochId) {
            EpochRates memory e = _rates[d.epochId];
            retired = true;
            delete depositRequestOf[msg.sender];
            if (e.depositValue != 0 && e.depositShares == 0) {
                // A REFUSED batch (SEC-17, see {rollEpoch}): the boundary minted nothing and moved the whole batch
                // into the owed reserve, so each request is returned exactly as it was queued, in kind.
                usdgOut = d.usdg;
                stockOut = d.stock;
            } else {
                uint256 value = uint256(d.usdg) + Math.mulDiv(d.stock, e.price, 1e18);
                // floor-divided against the batch, so rounding dust stays with the pool and never overdraws it
                sharesOut = e.depositValue == 0 ? 0 : Math.mulDiv(value, e.depositShares, e.depositValue);
                if (sharesOut != 0) _transfer(address(this), msg.sender, sharesOut);
            }
        }

        WithdrawRequest memory w = withdrawRequestOf[msg.sender];
        if (w.shares != 0 && w.epochId < epochId) {
            EpochRates memory e = _rates[w.epochId];
            if (e.withdrawShares != 0) {
                // Added to, not assigned: a refused deposit above may already have put an amount here.
                uint256 payUsdg = Math.mulDiv(e.withdrawUsdg, w.shares, e.withdrawShares);
                uint256 payStock = Math.mulDiv(e.withdrawStock, w.shares, e.withdrawShares);
                usdgOut += payUsdg;
                stockOut += payStock;
                // SEC-27. THE BATCH IS RUN DOWN IN STORAGE, NOT DIVIDED FROM A FIXED TOTAL.
                //
                // Each slice floors, so paying every holder out of the UNCHANGED batch totals left a
                // remainder of up to one wei per holder that no claim could ever reach: {owedUsdg} and
                // {owedStock} are only ever decremented by what {claim} pays, and {_nav} excludes both
                // reserves, so that remainder was neither payable nor poolable -- stranded, and excluded
                // from NAV for the life of the vault, once per epoch, forever.
                //
                // Subtracting each payment from the batch makes the LAST claimant of an epoch divide the
                // whole remaining reserve by the whole remaining share count, so `mulDiv` returns it
                // exactly and nothing is left behind. The dust therefore goes to the final claimant of
                // that batch rather than to the pool; at one wei per holder either destination is
                // defensible, and this one needs no "is the batch finished" test to find.
                //
                // The subtractions cannot underflow: the per-epoch requests sum to the `wShares` this
                // batch burned ({rollEpoch} zeroes {pendingWithdrawShares} at the same boundary), each
                // request is deleted below so it is claimed once, and every slice is floor-divided, so
                // the running totals reach zero together. If that invariant were ever broken the
                // subtraction reverts rather than overpaying, which is the right direction to fail.
                _rates[w.epochId].withdrawUsdg = e.withdrawUsdg - payUsdg;
                _rates[w.epochId].withdrawStock = e.withdrawStock - payStock;
                _rates[w.epochId].withdrawShares = e.withdrawShares - w.shares;
            }
            retired = true;
            delete withdrawRequestOf[msg.sender];
        }

        // Both legs pay out of the owed reserve, so they are paid together, once.
        if (usdgOut != 0) {
            owedUsdg -= usdgOut;
            _payReserved(usdg, msg.sender, usdgOut);
        }
        if (stockOut != 0) {
            owedStock -= stockOut;
            _payReserved(underlying, msg.sender, stockOut);
        }

        // NOTHING WAS OWED versus NOTHING TO PAY -- the distinction this refusal previously collapsed.
        //
        // Refusing a call with no matured request is right: it is the idempotency guard against a
        // pointless call, and it is kept. But a matured request that PRICES TO ZERO is ordinary -- floor
        // division at any boundary above 1:1 produces it (`sharesOut` above), and so does a withdrawal
        // batch whose per-holder slice floors away. Refusing THAT case reverted the two `delete`s above
        // along with everything else, so the request survived with an epoch id in the past, and
        // {deposit}, {requestWithdraw} and {cancel} then all refuse it as TooEarly. The account was
        // permanently unable to deposit, withdraw or claim over sub-one-share dust, and this function's
        // own NatSpec calls itself idempotent.
        //
        // So the test is whether a request was RETIRED, not whether anything was transferred.
        if (!retired) revert V2Errors.BadUnits();
        emit Claimed(msg.sender, sharesOut, usdgOut, stockOut);
    }

    /*//////////////////////////////////////////////////////////////
                               THE BOUNDARY
    //////////////////////////////////////////////////////////////*/

    /// @notice Closes the epoch: prices the queues, charges the performance fee, and opens the next epoch.
    ///         PERMISSIONLESS.
    /// @dev REFUSES, and each refusal is deliberate:
    ///        - TooEarly before {epochEnd}.
    ///        - NotSettled if any tracked series is unsettled, still held, or still has a live order. This is the
    ///          guard that makes option pricing unnecessary: if it passes, the vault holds only USDG and Stock.
    ///        - NotSettled if the boundary settlement price is not Finalized.
    ///      Deleting EITHER half lets the boundary price a vault that still holds options, which is what the
    ///      acceptance test proves by deleting each half in turn.
    function rollEpoch() external nonReentrant {
        uint40 end = epochEnd;
        if (block.timestamp < end) revert V2Errors.TooEarly(end);
        _redeemSettled();
        _requireFlat();

        (V2Types.SettlementStatus status, uint256 price) = oracle.settlementPrice(address(underlying), end);
        if (status != V2Types.SettlementStatus.Finalized || price == 0) revert V2Errors.NotSettled();

        // T-OP-073. Bring the BOOK-OWED slice home before anything is measured. The pool below counts
        // `orderBook.owed(vault)` for the same reason {_nav} does, and reserves `owedUsdg` from it; but only
        // {_restoreReserve} ran at the boundary and it reaches the LEDGER slice alone, so a reserve backed by USDG the
        // book still held was unreachable to {_payReserved} until a QUOTER {claimOwed}, and {claim} failed closed
        // (`InsufficientCollateral`) by exactly that amount. `claimOwed` pays msg.sender, which is this vault, and
        // is a no-op at zero. BEST-EFFORT ON PURPOSE: the book's transfer to this vault failing is the very way an
        // `owed` balance arises (a frozen or paused USDG), and a revert here would let that block the PERMISSIONLESS
        // boundary; when it fails the slice stays in the book, exactly as before this pull existed, and NAV and the
        // pool still count it. The measurement is value-neutral either way: `_nav` and `usdgPool` sum the same
        // three places; only which place holds the money moves.
        try orderBook.claimOwed() {} catch {}

        uint256 supply = totalSupply();
        uint256 navBefore = _nav(price);

        // PERFORMANCE FEE, before any share is minted or burned so the incoming batch is not charged for a gain it
        // was not present for, and the outgoing batch IS charged for one it was.
        uint256 fee;
        if (supply != 0) {
            uint256 perShare = Math.mulDiv(navBefore, 1e18, supply);
            if (perShare > highWaterMark) {
                uint256 gainPerShare = perShare - highWaterMark;
                uint256 gain = Math.mulDiv(gainPerShare, supply, 1e18);
                fee = gain * performanceFeeBps / V2Constants.BPS;
                // WALLET ONLY, AND SATURATING. This caps a real token transfer, so the Clearinghouse ledger
                // is deliberately NOT added: ledger collateral cannot be sent to the splitter. But the
                // reserves can legitimately exceed the wallet whenever the quoter has posted collateral via
                // {depositToClearinghouse}, and a raw `-` panics 0x11 in that state -- taking the
                // PERMISSIONLESS boundary down with it, which is the one thing roles.v8.json marks
                // `rollEpoch` unrestricted to prevent. Same saturating form as {_nav}.
                uint256 reservedUsdg = pendingDepositUsdg + owedUsdg;
                uint256 walletUsdg = usdg.balanceOf(address(this));
                uint256 payable_ = walletUsdg > reservedUsdg ? walletUsdg - reservedUsdg : 0;
                if (fee > payable_) fee = payable_;
                if (fee != 0) usdg.safeTransfer(splitter, fee);
            }
        }

        uint256 navNow = navBefore - fee;

        // WITHDRAWALS, in kind and pro rata against the pool as it stands after the fee.
        uint256 wShares = pendingWithdrawShares;
        uint256 wUsdg;
        uint256 wStock;
        if (wShares != 0 && supply != 0) {
            // MIRRORS {_nav}: the ledger is ADDED FIRST and the reserves are then taken out with a
            // saturating subtraction. Subtracting from the bare wallet balance before adding the ledger
            // panics 0x11 whenever the quoter has posted more into the Clearinghouse than the wallet still
            // holds -- ordinary behaviour needing no attacker -- and bricks the permissionless boundary.
            // The VALUE is unchanged wherever the old form did not revert: (w - r) + l == (w + l) - r.
            // Book-owed USDG is in the pool for the same reason it is in {_nav}; leaving it out here would pay
            // withdrawers less than the value NAV just charged them for.
            uint256 usdgPool = usdg.balanceOf(address(this)) + clearinghouse.free(address(this), address(usdg))
                + orderBook.owed(address(this));
            uint256 stockPool =
                underlying.balanceOf(address(this)) + clearinghouse.free(address(this), address(underlying));
            uint256 reservedUsdg = pendingDepositUsdg + owedUsdg;
            uint256 reservedStock = pendingDepositStock + owedStock;
            usdgPool = usdgPool > reservedUsdg ? usdgPool - reservedUsdg : 0;
            stockPool = stockPool > reservedStock ? stockPool - reservedStock : 0;
            wUsdg = Math.mulDiv(usdgPool, wShares, supply);
            wStock = Math.mulDiv(stockPool, wShares, supply);
            owedUsdg += wUsdg;
            owedStock += wStock;
            _burn(address(this), wShares);
            pendingWithdrawShares = 0;
            uint256 outValue = wUsdg + Math.mulDiv(wStock, price, 1e18);
            navNow = navNow > outValue ? navNow - outValue : 0;
            supply -= wShares;
        }

        // DEPOSITS, priced at the post-fee, post-withdrawal NAV per share.
        uint256 dUsdg = pendingDepositUsdg;
        uint256 dStock = pendingDepositStock;
        uint256 dValue = dUsdg + Math.mulDiv(dStock, price, 1e18);
        uint256 minted;
        if (dValue != 0) {
            if (supply == 0) {
                // FIRST BATCH: a FIXED ONE SHARE BASE UNIT PER ONE USDG BASE UNIT of value (F9: 18-dp shares against
                // 6-dp USDG, so one whole USDG buys 1e-12 of a whole share), never a NAV-derived rate. A donation made before
                // this boundary therefore buys the donor nothing -- it only raises NAV for everyone -- so the classic
                // inflation attack has no lever here. {MIN_SHARES} dead shares block the follow-up attack.
                minted = dValue;
                _mint(DEAD_SHARES, MIN_SHARES);
                _mint(address(this), minted);
                supply = minted + MIN_SHARES;
            } else {
                // SEC-17. `navNow == 0` with shares outstanding is TOTAL LOSS and leaves `minted` at zero: the
                // wiped-out holders keep their full share count, so the old fixed-rate reopening handed them
                // supply/(supply + minted) of this batch. A batch that prices to nothing -- total loss, or floor
                // division at a high share price -- is REFUSED rather than confiscated: it moves from the pending
                // reserve to the owed reserve and {claim} returns it in kind. Not a revert: this boundary is
                // permissionless, and a revert here would let a single 1-wei request stop every epoch from rolling.
                if (navNow != 0) minted = Math.mulDiv(dValue, supply, navNow);
                if (minted != 0) {
                    _mint(address(this), minted);
                    supply += minted;
                } else {
                    owedUsdg += dUsdg;
                    owedStock += dStock;
                }
            }
            pendingDepositUsdg = 0;
            pendingDepositStock = 0;
        }

        _rates[epochId] = EpochRates({
            price: _u128(price),
            depositValue: dValue,
            depositShares: minted,
            withdrawShares: wShares,
            withdrawUsdg: wUsdg,
            withdrawStock: wStock
        });

        // F-5. The batch above was measured over wallet + ledger, so `owedUsdg` / `owedStock` can now exceed the
        // wallet with the difference in `clearinghouse.free`. Bring that part home while nothing is locked.
        _restoreReserve(usdg, owedUsdg);
        _restoreReserve(underlying, owedStock);

        // The new high-water mark is measured on the epoch that is opening, so the next boundary compares like with
        // like. A losing epoch leaves the mark where it was, which is what makes a recovery free.
        uint256 navAfter = _nav(price);
        if (supply != 0) {
            uint256 perShareAfter = Math.mulDiv(navAfter, 1e18, supply);
            if (perShareAfter > highWaterMark) highWaterMark = perShareAfter;
        }

        lastSettlementPrice = _u128(price);

        uint64 closed = epochId;
        epochId = closed + 1;
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        epochEnd = calendar.nextExpiry(uint40(block.timestamp), true);

        emit EpochRolled(closed, end, price, navAfter, supply, minted, wShares, fee);
    }

    /// @dev F10. Redeems every SETTLED tracked series the vault still holds, immediately before {_requireFlat}.
    ///
    ///      THE DEFECT: the ERC-1155 hooks accept any Clearinghouse token from anyone (:890-903, the only check is
    ///      that the caller is the Clearinghouse, which every transfer satisfies), and {_requireFlat} reverts while
    ///      the vault holds any balance of a tracked series. So after the epoch's series settle, anyone holding one
    ///      unit of a tracked long -- worthless after settlement -- can transfer it here and re-block a boundary
    ///      that `roles.v8.json` marks `unrestricted` precisely so nothing can block it. A series does not leave
    ///      {_tracked} until a re-measure finds nothing held, and the donated unit is what a re-measure finds.
    ///
    ///      WHY REDEEM RATHER THAN IGNORE: ignoring settled balances in {_requireFlat} is the forbidden fix,
    ///      because it is T-309/F1 reopened -- the vault would walk past a position it REALLY holds and price a
    ///      boundary without it. Redeeming keeps the value: {Clearinghouse.redeem} is permissionless, burns a
    ///      zero-value balance outright, and credits the payout to the holder's wallet or free ledger, both of
    ///      which {_nav} counts. A donation is therefore absorbed at its real worth, which is usually nothing,
    ///      and the boundary proceeds. Refusing the transfer in the hook is the other forbidden fix: the hook
    ///      must not revert on the vault's own fills.
    ///
    ///      An UNSETTLED series is untouched, so a real open position still stops the boundary through
    ///      {_requireFlat} exactly as before, and so does a live order.
    function _redeemSettled() private {
        uint256[] memory ids = _tracked;
        for (uint256 i; i < ids.length; ++i) {
            uint256 longId = ids[i];
            V2Types.Series memory s = clearinghouse.series(longId);
            if (s.underlying == address(0) || !s.settled) continue;
            if (clearinghouse.balanceOf(address(this), longId) != 0) clearinghouse.redeem(longId, address(this));
            uint256 shortId = V2Ids.shortIdOf(longId);
            if (clearinghouse.balanceOf(address(this), shortId) != 0) clearinghouse.redeem(shortId, address(this));
        }
    }

    /// @dev Guard (a): the vault holds no option and no live order. Reverts NotSettled otherwise.
    function _requireFlat() private view {
        uint256[] memory ids = _tracked;
        for (uint256 i; i < ids.length; ++i) {
            uint256 longId = ids[i];
            V2Types.Series memory s = clearinghouse.series(longId);
            if (s.underlying != address(0) && !s.settled) revert V2Errors.NotSettled();
            (Exposure memory e,,) = _scan(longId);
            if (e.longs != 0 || e.shorts != 0 || e.live != 0) revert V2Errors.NotSettled();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                   NAV
    //////////////////////////////////////////////////////////////*/

    /// @notice NAV in USDG base units at `price` (USDG 6 dp per whole share of the underlying).
    /// @dev Queued deposits and reserved withdrawals are excluded: see the contract NatSpec. NO OPTION IS VALUED --
    ///      at a boundary there are none, and off a boundary this is a view with no authority over anything.
    ///      USDG the book OWES this vault is counted like Clearinghouse free collateral: it is ours, merely not in the
    ///      wallet. {OrderBook.prune} refunds an expired Bid's escrow with pay-or-owe, so when the transfer fails the
    ///      refund lands in `orderBook.owed` instead -- and the order is then cancelled, so {_requireFlat} passes.
    ///      Leaving it out would price the boundary without that escrow (T-309 defect A).
    function _nav(uint256 price) private view returns (uint256) {
        uint256 cashUsdg = usdg.balanceOf(address(this)) + clearinghouse.free(address(this), address(usdg))
            + orderBook.owed(address(this));
        uint256 heldStock = underlying.balanceOf(address(this)) + clearinghouse.free(address(this), address(underlying));
        uint256 excludedUsdg = pendingDepositUsdg + owedUsdg;
        uint256 excludedStock = pendingDepositStock + owedStock;
        cashUsdg = cashUsdg > excludedUsdg ? cashUsdg - excludedUsdg : 0;
        heldStock = heldStock > excludedStock ? heldStock - excludedStock : 0;
        return cashUsdg + Math.mulDiv(heldStock, price, 1e18);
    }

    /// @notice NAV in USDG base units, valuing the Stock leg at the price the LAST boundary settled on.
    /// @dev DELIBERATELY the last boundary's price, not the next one's. The next boundary is by definition not
    ///      Finalized while the epoch is running, so requiring it would make this view revert for the whole epoch --
    ///      which is exactly when a depositor wants to read it. Using the last settled price means this is a
    ///      MARK, not a live valuation: it does not move with spot during the epoch, and it is not what any deposit
    ///      or withdrawal is priced at. Those are priced at their own boundary, by {rollEpoch}, from a Finalized
    ///      price read there. Reverts NotSettled only before the first boundary, when there is no settled price at
    ///      all and any number would be invented.
    function nav() external view returns (uint256) {
        uint256 price = lastSettlementPrice;
        if (price == 0) revert V2Errors.NotSettled();
        return _nav(price);
    }

    /*//////////////////////////////////////////////////////////////
                                 QUOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Moves `amount` of `asset` from the vault's wallet into its Clearinghouse ledger. QUOTER only.
    /// @dev F3. CLAMPED TO THE UNRESERVED WALLET BALANCE, and the clamp is the fix rather than a convenience.
    ///      Queued deposits ({pendingDepositUsdg}, {pendingDepositStock}) and priced-but-unclaimed withdrawals
    ///      ({owedUsdg}, {owedStock}) are somebody else's money. Once they are in the ledger a write can LOCK
    ///      them under a series, and {_payReserved} tops up from `clearinghouse.free` only -- so {claim} and
    ///      {cancelDepositRequest} revert `InsufficientCollateral` until that series settles, which is SEC-15's
    ///      own statement (:1030-1047) violated by the QUOTER key in ordinary operation. The keeper deposits
    ///      every idle wallet token as write collateral when `depositTokens` is set, so this is the ordinary
    ///      path and not an edge case.
    ///
    ///      WHY HERE AND NOT IN {_enforce}: `_enforce` bounds units and notional; it has no model of which
    ///      collateral is spoken for, and teaching it one would duplicate the reserve accounting that already
    ///      lives on these four fields. The deposit is the only place reserved wallet balance crosses into
    ///      lockable collateral -- because {rollEpoch} pulls the reserve a boundary creates out of the ledger
    ///      through {_restoreReserve} (F-5) -- so it is the narrow place to hold the line.
    ///
    ///      CLAMPS RATHER THAN REVERTS, MIRRORING `EarnVault.sweepToVenue` (:736-749): an over-request from the
    ///      quoter is ordinary and a smaller deposit is a fine outcome, so it deposits what is free to deposit
    ///      and refuses `BadUnits` only when there is nothing unreserved at all. A reserve is never the caller's
    ///      to move, which is why this one is a clamp while {_payReserved} -- paying a holder their own money --
    ///      is all-or-revert.
    function depositToClearinghouse(address asset, uint256 amount) external nonReentrant restricted {
        uint256 unreserved = _unreservedWallet(asset);
        if (amount > unreserved) amount = unreserved;
        if (amount == 0) revert V2Errors.BadUnits();
        IERC20(asset).forceApprove(address(clearinghouse), amount);
        clearinghouse.deposit(asset, amount, address(this));
    }

    /// @dev The wallet balance of `asset` that is NOT reserved for a queued deposit or an unclaimed withdrawal.
    ///      Saturating, in the same form {_nav} and {rollEpoch} use, because the reserves can legitimately exceed
    ///      the wallet whenever the quoter has already posted collateral into the ledger, and a raw `-` would
    ///      panic 0x11 there. An asset that is neither leg carries no reserve, so its whole balance is free.
    function _unreservedWallet(address asset) private view returns (uint256) {
        uint256 wallet = IERC20(asset).balanceOf(address(this));
        uint256 reserved;
        if (asset == address(usdg)) reserved = pendingDepositUsdg + owedUsdg;
        else if (asset == address(underlying)) reserved = pendingDepositStock + owedStock;
        return wallet > reserved ? wallet - reserved : 0;
    }

    /// @notice Moves `amount` of `asset` from the Clearinghouse ledger back to the vault. QUOTER only.
    function withdrawFromClearinghouse(address asset, uint256 amount) external nonReentrant restricted {
        clearinghouse.withdraw(asset, amount, address(this));
    }

    /// @notice Places a vault order on the book. QUOTER only. MIRRORED from `MakerVault.place`, plus the epoch guard.
    function place(uint256 longId, V2Types.OrderKind kind, uint128 price, uint64 units, uint40 validUntil)
        external
        nonReentrant
        restricted
        returns (uint256 orderId)
    {
        _requireQuoting();
        V2Types.Series memory s = _seriesInEpoch(longId);
        bool bid = kind == V2Types.OrderKind.Bid;
        _checkPrice(s, bid, kind == V2Types.OrderKind.AskWrite, price);
        validUntil = _boundLifetime(s, kind, validUntil);
        Exposure memory before = _measure(longId);
        if (before.live >= MAX_LIVE_ORDERS_PER_SERIES) revert V2Errors.CeilingExceeded();
        uint256 cashBefore = bid ? _cash() : 0;
        orderId = orderBook.place(longId, kind, price, units, validUntil);
        _orderIds[longId].push(orderId);
        _enforce(longId, s.strike, _units(before), _measure(longId));
        if (bid) _bookOutflow(cashBefore, true);
    }

    /// @notice Replaces one of the vault's own live orders. QUOTER only. MIRRORED from `MakerVault.replace`.
    function replace(uint256 orderId, uint128 newPrice, uint64 newUnits)
        external
        nonReentrant
        restricted
        returns (uint256 newOrderId)
    {
        _requireQuoting();
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        V2Types.Order memory o = orderBook.getOrders(ids)[0];
        if (o.maker == address(0)) revert V2Errors.OrderNotLive(orderId);
        if (o.maker != address(this)) revert V2Errors.NotAuthorized();
        V2Types.Series memory s = _seriesInEpoch(o.longId);
        bool bid = o.kind == V2Types.OrderKind.Bid;
        _checkPrice(s, bid, o.kind == V2Types.OrderKind.AskWrite, newPrice);
        Exposure memory before = _measure(o.longId);
        uint256 cashBefore = bid ? _cash() : 0;
        newOrderId = orderBook.replace(orderId, newPrice, newUnits);
        _orderIds[o.longId].push(newOrderId);
        _enforce(o.longId, s.strike, _units(before), _measure(o.longId));
        if (bid) _bookOutflow(cashBefore, true);
    }

    /// @notice Cancels vault orders. QUOTER only. NOT blocked by {quotingPaused}: a brake must never trap inventory.
    /// @dev THIS LINE IS THE "a brake must never trap inventory" RULE, and it is cited from outside this file.
    ///      T-241-C8-VENUE-ENABLED-NAV-COLLAPSE took it as precedent for ungating EarnVault's WITHDRAW path --
    ///      reasoning that if withdraw stayed gated, `EarnVault.setAdapter` could never drain a disabled adapter,
    ///      so its stranding guard would revert forever and the adapter could never be replaced: a permanent
    ///      lockout traded for a blind guard. That entry cited the rule as living at `HouseVault.sol:654`. It does
    ///      not: at the base this note was written against, `:654` is high-water-mark arithmetic inside
    ///      {rollEpoch}. The rule is HERE, and the same principle is restated at {setQuotingPaused} -- "a brake
    ///      that traps depositor money is not a brake". Checked by T-559's sibling row T-558; the citation had
    ///      drifted 189 lines and a reader following it landed on unrelated code.
    ///
    ///      IF SOMEONE LATER DECIDES a disabled adapter must refuse withdrawals, that decision has to come with a
    ///      way for `setAdapter` to drain it, or the vault cannot migrate venues. That is the open question this
    ///      rule was borrowed to settle, and it belongs to EarnVault, not here.
    function cancel(uint256[] calldata orderIds) external nonReentrant restricted {
        V2Types.Order[] memory orders = orderBook.getOrders(orderIds);
        bool anyBid;
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].kind == V2Types.OrderKind.Bid) {
                anyBid = true;
                break;
            }
        }
        uint256 cashBefore = anyBid ? _cash() : 0;
        orderBook.cancel(orderIds);
        if (anyBid) _bookOutflow(cashBefore, false);
        for (uint256 i; i < orders.length; ++i) {
            uint256 longId = orders[i].longId;
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (orders[j].longId == longId) {
                    seen = true;
                    break;
                }
            }
            if (!seen) _refresh(longId);
        }
    }

    /// @notice Takes against the book. QUOTER only. MIRRORED from `MakerVault.take`, plus the epoch guard and the
    ///         self-dealing refusal.
    function take(V2Types.TakeParams calldata p)
        external
        nonReentrant
        restricted
        returns (uint64 unitsFilled, uint256 premium, uint256 takerFee)
    {
        _requireQuoting();
        _requireProtocolAccountsConfirmed();
        if (p.recipient != address(this)) revert V2Errors.NotAuthorized();
        V2Types.Series memory s = _seriesInEpoch(p.longId);
        _checkPrice(s, p.buying, p.writeToSell, p.limitPrice);
        _requireNoSelfDeal(p.orderIds);
        Exposure memory before = _measure(p.longId);
        uint256 cashBefore = _cash();
        (unitsFilled, premium, takerFee) = orderBook.take(p);
        _enforce(p.longId, s.strike, _units(before), _measure(p.longId));
        _bookOutflow(cashBefore, true);
    }

    /// @notice Closes long/short pairs back to collateral. QUOTER only. NOT blocked by {quotingPaused}.
    /// @dev DELIBERATELY NOT epoch-gated, unlike {sync} (T-OP-064, SEC-14 runbook step 5). A pair of a series that
    ///      outlives the epoch can only be in this vault because someone transferred it in; closing it is the operator's
    ///      way to release that collateral early, so the close itself is allowed. What it must never do is TRACK such a
    ///      series: {_refresh} runs only if the series is in the epoch or is already tracked. A re-measure of an
    ///      already-tracked series can keep it or untrack it (see {_record}), never add it, so this cannot widen
    ///      {_tracked}; a never-tracked out-of-epoch series is closed and left untracked, with nothing for
    ///      {_requireFlat} to wait on. Silent by design here, where the caller chose the id: {sync} is the
    ///      re-measure entry point and it refuses by name.
    function close(uint256 longId, uint64 units) external nonReentrant restricted {
        V2Types.Series memory s = _series(longId);
        clearinghouse.close(longId, units);
        if (s.expiry <= epochEnd || _trackedPos[longId] != 0) _refresh(longId);
    }

    /// @notice Pulls what the book owes the vault. QUOTER only. NOT blocked by {quotingPaused}.
    function claimOwed() external nonReentrant restricted {
        orderBook.claimOwed();
    }

    /// @notice Re-measures the given series. QUOTER only. NOT blocked by {quotingPaused}.
    /// @dev EPOCH-GATED like {place} (T-OP-064, SEC-14 residual). {_refresh} is the only way a series enters
    ///      {_tracked}, and {_requireFlat} then waits for everything tracked to settle. The receipt hooks accept any
    ///      Clearinghouse token from anyone, so without this check a QUOTER sync on a transferred-in series expiring
    ///      after {epochEnd} would hold the boundary until that expiry. Refused by name, not skipped: an operator
    ///      reading a trace must be able to tell "not in this epoch" from "nothing to re-measure". The whole batch
    ///      reverts, so a sync that names one such id re-measures nothing.
    function sync(uint256[] calldata longIds) external nonReentrant restricted {
        for (uint256 i; i < longIds.length; ++i) {
            _seriesInEpoch(longIds[i]);
            _refresh(longIds[i]);
        }
    }

    /// @notice Re-grants the book the operator right, the ERC-1155 approval and the USDG allowance. QUOTER only.
    function refreshApprovals() external nonReentrant restricted {
        _approveBook();
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the guard rails. GUARDIAN, zero delay (roles.v8.json `.targets.HouseVault`; T-OP-159 moved it
    ///         off TREASURY_ADMIN on the owner's order of 2026-09-22: no delay on the limits at all).
    function setLimits(Limits calldata limits_) external nonReentrant restricted {
        _setLimits(limits_);
    }

    /// @notice Sets the performance fee. TREASURY_ADMIN. CeilingExceeded above {PERFORMANCE_FEE_CEIL_BPS}.
    function setPerformanceFeeBps(uint16 bps) external nonReentrant restricted {
        if (bps > PERFORMANCE_FEE_CEIL_BPS) revert V2Errors.CeilingExceeded();
        performanceFeeBps = bps;
        emit PerformanceFeeBpsSet(bps);
    }

    /// @notice Marks an account the vault may never trade against. CONFIG_ADMIN. The first call that BLOCKS an
    ///         account also arms {take} -- see {protocolAccountsConfirmed}.
    /// @dev THE SELECTOR IS UNCHANGED, and that is a constraint rather than a convenience. `roles.v8.json`,
    ///      `script/v2/abi-manifest.txt` and `test/v2/unit/AccessMatrix.t.sol` are the manifest side of this
    ///      contract and none of them is in this row's scope; `AccessMatrix.t.sol` fails any `restricted` selector
    ///      that the manifest does not list. A separate `confirmProtocolAccounts(...)` would therefore have been a
    ///      correct-looking change that broke a guard in a file this row may not edit. Arming rides the existing
    ///      selector instead.
    ///
    ///      ONLY `blocked == true` ARMS IT. Unblocking an account is not evidence that the set was ever
    ///      considered, and a vault armed by `setProtocolAccount(addr, false)` would be armed with an EMPTY set --
    ///      exactly the state this is here to refuse. Clearing the set afterwards does NOT disarm the vault: that
    ///      is a deliberate operator act on a live vault, not the unconfigured state, and re-blocking {take}
    ///      mid-epoch would strand open positions the vault still has to unwind.
    function setProtocolAccount(address account, bool blocked) external nonReentrant restricted {
        // F7. The zero address can never be a maker, so blocking it blocks nothing -- and because
        // `blocked == true` is what ARMS {take}, accepting it would arm the self-deal check on a set that
        // proves nothing was considered. That is the same "a check satisfied because it had nothing to
        // check" state the arming flag exists to refuse. A ONE-ENTRY SET IS LEGITIMATE: a vault whose only
        // protocol counterparty is the splitter is a real configuration, so the guard is on the VALUE, not
        // on the size of the set.
        if (account == address(0)) revert V2Errors.UnsupportedAsset();
        protocolAccount[account] = blocked;
        if (blocked && !protocolAccountsConfirmed) {
            protocolAccountsConfirmed = true;
            emit ProtocolAccountsConfirmed();
        }
        emit ProtocolAccountSet(account, blocked);
    }

    /// @notice Moves the settlement oracle the boundary prices with. CONFIG_ADMIN: 24 h execution delay, and the
    ///         scheduled operation is GUARDIAN-cancellable, like every CONFIG_ADMIN action in `roles.v8.json`.
    /// @dev THE ONE WAY OFF A RETIRED ORACLE (F6 / T-OP-058; see {oracle}). Two refusals, both fail-closed:
    ///        1. `NoSource` for the zero address, a code-less address, or a contract that does not answer
    ///           {ISettlementOracle.SETTLEMENT_WINDOW} with a non-zero value -- the same probe
    ///           `Clearinghouse._requireSettlementOracle` applies to `setMarketOracle`, so a candidate this vault
    ///           accepts is one the Clearinghouse would accept. A staticcall that reverts or returns nothing is a
    ///           refusal, not a pass.
    ///        2. `NotSettled` while a boundary is PENDING: `block.timestamp >= epochEnd` means {rollEpoch} is
    ///           callable and its price read is imminent, and a roll must never straddle two oracles -- the epoch's
    ///           price was pinned and finalized on the oracle that was current when the epoch ran. Roll the
    ///           boundary first, then move. Inside the epoch the switch is safe because nothing reads {oracle}
    ///           until the next boundary: quoting reads the SERIES oracle (`_seriesInEpoch`, `_checkPrice`),
    ///           never this one.
    ///      Setting the oracle that is already current is a no-op that still emits, deliberately: a scheduled
    ///      operation that lands after an identical one should succeed, not strand the operator on a revert.
    ///      WHAT IT DOES NOT DO: it does not re-pin or re-finalize anything on the new oracle. The next boundary
    ///      reads `settlementPrice(underlying, epochEnd)` from the new instance exactly as it read the old one, so
    ///      the new oracle must have (or be able to produce) a Finalized price for the CURRENT `epochEnd` -- which
    ///      is what a migration that keeps the market's weekly expiries pinned provides.
    ///      NEW RESTRICTED SELECTOR: mapped to CONFIG_ADMIN in `script/v2/roles.v8.json` (the manifest side of
    ///      this contract), which `test/v2/unit/AccessMatrix.t.sol` walks; a selector added here and not there is
    ///      the T-170 shape and reads as ADMIN-only to `VerifyV8`.
    /// @param oracle_ The replacement settlement oracle.
    function setOracle(address oracle_) external nonReentrant restricted {
        if (block.timestamp >= epochEnd) revert V2Errors.NotSettled();
        _requireSettlementOracle(oracle_);
        address previous = address(oracle);
        oracle = ISettlementOracle(oracle_);
        emit OracleSet(previous, oracle_);
    }

    /// @dev MIRRORED from `Clearinghouse._requireSettlementOracle` (src/v2/Clearinghouse.sol:370-377), not
    ///      re-reasoned: code present, and `SETTLEMENT_WINDOW()` answers non-zero through a staticcall that is
    ///      allowed to fail. See that function's note on which doubles carry the constant and which deliberately
    ///      do not.
    function _requireSettlementOracle(address candidate) private view {
        if (candidate.code.length == 0) revert V2Errors.NoSource();
        try ISettlementOracle(candidate).SETTLEMENT_WINDOW() returns (uint32 window) {
            if (window == 0) revert V2Errors.NoSource();
        } catch {
            revert V2Errors.NoSource();
        }
    }

    /// @notice The quoting brake. GUARDIAN, zero delay. Blocks {place}, {replace} and {take} and NOTHING else --
    ///         unwinding, the boundary and every depositor path stay open under it, because a brake that traps
    ///         depositor money is not a brake.
    function setQuotingPaused(bool paused) external nonReentrant restricted {
        quotingPaused = paused;
        emit QuotingPausedSet(paused);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function limits() external view returns (Limits memory) {
        return _limits;
    }

    function exposure(uint256 longId) external view returns (uint256 units, uint256 notional, Exposure memory detail) {
        (detail,,) = _scan(longId);
        units = _units(detail);
        notional = seriesNotional[longId];
    }

    function orderIdsOf(uint256 longId) external view returns (uint256[] memory) {
        return _orderIds[longId];
    }

    function trackedSeries() external view returns (uint256[] memory) {
        return _tracked;
    }

    /// @notice The ask floor of `longId` for a fill of the given kind, USDG base units per share.
    function askFloorOf(uint256 longId, bool primary) external view returns (uint256) {
        V2Types.Series memory s = _series(longId);
        return _askFloor(s, _spot(s), _sellerFeeBps(primary));
    }

    /// @notice The bid cap of `longId`, USDG base units per share.
    function bidCap(uint256 longId) external view returns (uint256) {
        V2Types.Series memory s = _series(longId);
        return _spot(s) * _limits.maxBidBpsOfSpot / V2Constants.BPS;
    }

    /// @notice The outflow bucket: USDG used and still available in the current window.
    function outflow() external view returns (uint256 used, uint256 available) {
        uint256 cap = _limits.maxDailyOutflow;
        uint256 s = _refilled(cap);
        used = (s + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
        available = cap > used ? cap - used : 0;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(clearinghouse)) revert V2Errors.UnsupportedAsset();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(clearinghouse)) revert V2Errors.UnsupportedAsset();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev GUARDIAN's brake, applied to the three entry points that can open or grow a position.
    function _requireQuoting() private view {
        if (quotingPaused) revert V2Errors.TradingPaused();
    }

    /// @dev THE UNCONFIGURED SET FAILS CLOSED. {_requireNoSelfDeal} can only refuse makers it has been told about,
    ///      so a vault whose {protocolAccount} set was never populated would satisfy D30 by being blind rather than
    ///      by being safe. This refuses {take} until CONFIG_ADMIN has named at least one.
    ///
    ///      NoSource(), NOT TradingPaused() AND NOT NotAuthorized(), for the reason the contract NatSpec gives for
    ///      BadExpiry over PastCutoff: two different refusals must not be indistinguishable in a trace.
    ///      TradingPaused is GUARDIAN's brake and NotAuthorized is "that maker is a protocol account"; this is
    ///      neither. NoSource already means "a source this contract depends on was never configured" -- the
    ///      constructor raises it for a zero calendar or oracle -- which is exactly this. It reuses an existing
    ///      error rather than adding one because `src/v2/interfaces/V2Errors.sol` is the exported error ABI (see
    ///      its own header) and is not in this row's scope.
    ///
    ///      ONLY {take} IS GATED. {place} and {replace} rest orders, and a resting order hit BY a protocol account
    ///      is the case the contract already states it cannot see (see {_requireNoSelfDeal}) -- gating them would
    ///      buy no safety while freezing the quoting surface. {cancel}, {close}, {sync}, the unwinding path, the
    ///      boundary and every depositor path stay open, so an unarmed vault can always be emptied.
    function _requireProtocolAccountsConfirmed() private view {
        if (!protocolAccountsConfirmed) revert V2Errors.NoSource();
    }

    /// @dev NO SELF-DEALING, enforced on chain for every take the vault initiates: the named makers are read from the
    ///      book BEFORE the take and refused if any is a protocol account or this vault.
    ///      THIS CHECK IS ONLY AS WIDE AS {protocolAccount}, which is why {take} refuses to run at all until
    ///      CONFIG_ADMIN has populated it -- see {protocolAccountsConfirmed}. An empty set would make every maker
    ///      look ordinary here and the refusal below would never fire.
    ///      WHAT THIS DOES NOT COVER, stated plainly rather than implied: the vault's own RESTING orders can still be
    ///      hit by a protocol account, because the book never calls back into the maker on a fill. Refusing that is
    ///      the bot's job (K8-05) plus indexing; no contract-level check can see it.
    function _requireNoSelfDeal(uint256[] calldata orderIds) private view {
        if (orderIds.length == 0) return;
        V2Types.Order[] memory orders = orderBook.getOrders(orderIds);
        for (uint256 i; i < orders.length; ++i) {
            address maker = orders[i].maker;
            if (maker == address(this) || protocolAccount[maker]) revert V2Errors.NotAuthorized();
        }
    }

    /// @dev The series of `longId`, refusing one that outlives this epoch. BadExpiry, see the contract NatSpec.
    function _seriesInEpoch(uint256 longId) private view returns (V2Types.Series memory s) {
        s = _series(longId);
        if (s.expiry > epochEnd) revert V2Errors.BadExpiry();
    }

    /// @dev MIRRORED from `MakerVault._series`.
    function _series(uint256 longId) private view returns (V2Types.Series memory s) {
        s = clearinghouse.series(longId);
        if (s.underlying == address(0)) revert V2Errors.UnknownSeries();
    }

    /// @dev MIRRORED from `MakerVault._spot`.
    function _spot(V2Types.Series memory s) private view returns (uint256 spot) {
        (spot,) = ISettlementOracle(s.oracle).spot(s.underlying);
        if (spot == 0) revert V2Errors.NoSource();
    }

    /// @dev MIRRORED from `MakerVault._sellerFeeBps`. READ FROM THE BOOK, never a compiled copy: {IOrderBook.feeParams}
    ///      already resolves a scheduled change, so the floor moves with the fee instead of being crossed by it.
    function _sellerFeeBps(bool primary) private view returns (uint256) {
        V2Types.FeeParams memory f = orderBook.feeParams();
        return primary ? f.premiumFeeBps : f.resaleFeeBps;
    }

    /// @dev MIRRORED from `MakerVault._askFloor`: ceil(base x BPS / (BPS - sellerFeeBps)) with
    ///      base = max(0, intrinsic - spot x askToleranceBps / BPS). Rounded UP, so proceeds NET of the seller fee are
    ///      never below `base`. `BPS - sellerFeeBps` underflows and reverts at a fee of 100 % or more: fail-closed.
    function _askFloor(V2Types.Series memory s, uint256 spot, uint256 sellerFeeBps) private view returns (uint256) {
        uint256 strike = s.strike;
        uint256 intrinsic;
        if (s.isPut) {
            if (strike > spot) intrinsic = strike - spot;
        } else if (spot > strike) {
            intrinsic = spot - strike;
        }
        uint256 tolerance = spot * _limits.askToleranceBps / V2Constants.BPS;
        uint256 base = intrinsic > tolerance ? intrinsic - tolerance : 0;
        if (base == 0) return 0;
        return Math.ceilDiv(base * V2Constants.BPS, V2Constants.BPS - sellerFeeBps);
    }

    /// @dev MIRRORED from `MakerVault._checkPrice`.
    function _checkPrice(V2Types.Series memory s, bool buying, bool primary, uint256 price) private view {
        uint256 spot = _spot(s);
        if (buying) {
            if (price > spot * _limits.maxBidBpsOfSpot / V2Constants.BPS) revert V2Errors.BadPrice();
        } else if (price < _askFloor(s, spot, _sellerFeeBps(primary))) {
            revert V2Errors.BadPrice();
        }
    }

    /// @dev MIRRORED from `MakerVault._boundLifetime`, with the epoch as an extra ceiling: a quote may never outlive
    ///      the boundary that has to find the vault flat.
    function _boundLifetime(V2Types.Series memory s, V2Types.OrderKind kind, uint40 validUntil)
        private
        view
        returns (uint40)
    {
        uint256 life = _limits.maxOrderLifetime;
        if (life == 0) return validUntil;
        uint256 latest = block.timestamp + life;
        if (validUntil == 0) {
            uint256 limit = kind == V2Types.OrderKind.AskWrite ? s.expiry - V2Constants.SETTLEMENT_WINDOW : s.expiry;
            // casting to 'uint40' is safe because latest < limit, which is a uint40
            // forge-lint: disable-next-line(unsafe-typecast)
            return latest < limit ? uint40(latest) : 0;
        }
        if (validUntil > latest) revert V2Errors.PastCutoff();
        return validUntil;
    }

    /// @dev MIRRORED from `MakerVault._cash`.
    /// @dev PAYS A RESERVE, FROM WHEREVER THE RESERVE ACTUALLY IS. Tops the wallet up out of this vault's OWN
    ///      free Clearinghouse ledger when the wallet alone cannot cover `amount`, then transfers.
    ///
    ///      WHY THIS EXISTS (SEC-15). Every reserve in this contract is MEASURED as wallet plus ledger --
    ///      {_nav} at :614-615, and the withdrawal split at :525-527 which is where `owedUsdg` / `owedStock`
    ///      are set. Both payers were written against the WALLET ALONE. So one {depositToClearinghouse} by
    ///      the quoter, entirely ordinary and entirely within its role, made {claim} revert for EVERY
    ///      claimant of that epoch and {cancelDepositRequest} revert for every queued depositor -- with the
    ///      only unblock being {withdrawFromClearinghouse}, the same QUOTER key whose ordinary use caused it.
    ///      A user's own money became unreachable by a key they do not hold.
    ///
    ///      NOT THE SHAPE THE FEE PATH USES, deliberately, and this is the one design decision in the fix.
    ///      {rollEpoch}'s performance fee (:500-509) CAPS itself to the wallet with a saturating subtraction.
    ///      That is right for protocol revenue -- a smaller fee is a fine outcome and the permissionless
    ///      boundary must not revert. It is WRONG here: capping a claim would retire the request and pay the
    ///      claimant less than they are owed, turning a loud refusal into a silent loss. A reserve is the
    ///      holder's money, so this pays IN FULL or reverts.
    ///
    ///      PULLS THE SHORTFALL ONLY, never the whole amount, so collateral the quoter placed for quoting
    ///      stays where it was put beyond what this payment needs.
    ///
    ///      NO NEW LEVER FOR A CALLER. {claim} is permissionless, but this can only move collateral that is
    ///      already owed to the caller -- money {_nav} has already excluded from the pool. Nobody can reach
    ///      anyone else's reserve through it, and nobody can drain quoting collateral that is not spoken for.
    /// @dev F-5. Called by {rollEpoch} once the batch has set `owedUsdg` / `owedStock`. The withdrawal pool was
    ///      measured over wallet PLUS `clearinghouse.free`, so the reserve it produced can exceed the wallet with the
    ///      difference sitting in the ledger -- where the next epoch's AskWrite fill locks it through
    ///      `Clearinghouse.mint`, which debits `free` with no notion of reserves, and {claim} then fails closed in
    ///      {_payReserved}. The F3 clamp on {depositToClearinghouse} cannot see this: that balance was unreserved
    ///      when it was deposited and became reserved in place. So the boundary brings the ledger-held part home.
    ///
    ///      CANNOT STALL THE ROLL, which is the objection the header NatSpec raises against moving tokens here:
    ///      `_requireFlat` already proved nothing is locked, `Clearinghouse.withdraw` reads only `free` and has no
    ///      pause flag, and the pull is CLAMPED to what is free rather than reverting on a shortfall. The only
    ///      failure left is the token transfer itself, which would already block every payout this vault makes.
    ///
    ///      WHAT IT DOES NOT COVER: book-owed USDG (`orderBook.owed`), which is in the pool for the same reason it
    ///      is in {_nav}. {rollEpoch} pulls that slice home itself, best-effort, before it measures anything
    ///      (T-OP-073); when that pull fails the slice stays in the book and a reserve backed by it is unreachable to
    ///      {_payReserved} until the quoter's {claimOwed} succeeds -- the pre-existing gap, now confined to a USDG
    ///      that refuses to pay this vault at all.
    function _restoreReserve(IERC20 token, uint256 reserved) private {
        uint256 wallet = token.balanceOf(address(this));
        if (wallet >= reserved) return;
        uint256 shortfall = reserved - wallet;
        uint256 free = clearinghouse.free(address(this), address(token));
        uint256 pull = shortfall < free ? shortfall : free;
        if (pull != 0) clearinghouse.withdraw(address(token), pull, address(this));
    }

    function _payReserved(IERC20 token, address to, uint256 amount) private {
        uint256 wallet = token.balanceOf(address(this));
        if (wallet < amount) {
            uint256 shortfall = amount - wallet;
            uint256 free = clearinghouse.free(address(this), address(token));
            // FAIL CLOSED AND LOUD. Reaching here means the reserve is not covered by wallet + ledger at all,
            // which is an accounting hole rather than a placement problem; paying part of it would hide that.
            if (free < shortfall) revert V2Errors.InsufficientCollateral(wallet + free, amount);
            clearinghouse.withdraw(address(token), shortfall, address(this));
        }
        token.safeTransfer(to, amount);
    }

    function _cash() private view returns (uint256) {
        return usdg.balanceOf(address(this)) + orderBook.owed(address(this));
    }

    /// @dev MIRRORED from `MakerVault._refilled`.
    function _refilled(uint256 cap) private view returns (uint256 s) {
        s = _outflowScaled;
        uint256 refill = cap * (block.timestamp - _outflowAt);
        s = s > refill ? s - refill : 0;
    }

    /// @dev MIRRORED from `MakerVault._bookOutflow`. NO CALLER EXEMPTION: `msg.sender` is not consulted, so the bound
    ///      is a property of the contract rather than of who holds which key.
    function _bookOutflow(uint256 before, bool enforce) private {
        uint256 cashAfter = _cash();
        if (cashAfter == before) return;
        uint256 cap = _limits.maxDailyOutflow;
        uint256 s = _refilled(cap);
        if (cashAfter < before) {
            uint256 out = before - cashAfter;
            uint256 next = s + out * OUTFLOW_WINDOW;
            if (enforce && next > cap * OUTFLOW_WINDOW) {
                uint256 used = (s + OUTFLOW_WINDOW - 1) / OUTFLOW_WINDOW;
                revert V2Errors.OutflowCapExceeded(cap > used ? cap - used : 0, out);
            }
            s = next > type(uint216).max ? type(uint216).max : next;
        } else {
            uint256 back = (cashAfter - before) * OUTFLOW_WINDOW;
            s = s > back ? s - back : 0;
        }
        // casting is safe: `s` is clamped to uint216 above, and a credit only lowers it
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowScaled = uint216(s);
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowAt = uint40(block.timestamp);
    }

    /// @dev MIRRORED from `MakerVault._setLimits`.
    function _setLimits(Limits memory l) private {
        if (l.askToleranceBps > V2Constants.BPS || l.maxBidBpsOfSpot > V2Constants.BPS) {
            revert V2Errors.CeilingExceeded();
        }
        // casting is safe: {_refilled} only ever lowers the stored uint216
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowScaled = uint216(_refilled(_limits.maxDailyOutflow));
        // casting to 'uint40' is safe until the year 36812
        // forge-lint: disable-next-line(unsafe-typecast)
        _outflowAt = uint40(block.timestamp);
        _limits = l;
        emit LimitsSet(l);
    }

    /// @dev MIRRORED from `MakerVault._approveBook`.
    function _approveBook() private {
        address book = address(orderBook);
        clearinghouse.setOperator(book, true);
        clearinghouse.setApprovalForAll(book, true);
        usdg.forceApprove(book, type(uint256).max);
    }

    /// @dev MIRRORED from `MakerVault._scan`.
    function _scan(uint256 longId) private view returns (Exposure memory e, uint256[] memory ids, bool[] memory dead) {
        ids = _orderIds[longId];
        dead = new bool[](ids.length);
        if (ids.length != 0) {
            V2Types.Order[] memory orders = orderBook.getOrders(ids);
            for (uint256 i; i < ids.length; ++i) {
                V2Types.Order memory o = orders[i];
                uint256 left = o.units - o.filled;
                // Expiry alone releases no escrow. An expired Bid still has refundable USDG in the book, just as an
                // expired AskResale still has the vault's longs there, until permissionless {OrderBook.prune} marks
                // the order cancelled and returns (or records as owed) that value. Keeping both kinds live here
                // makes {rollEpoch} refuse regardless of whether a roller races the pruner. AskWrite is the only
                // kind with no asset escrowed before a fill, so it can become dead from time alone.
                bool expiredWrite = block.timestamp >= o.validUntil && o.kind == V2Types.OrderKind.AskWrite;
                if (o.cancelled || left == 0 || expiredWrite) {
                    dead[i] = true;
                    continue;
                }
                ++e.live;
                if (o.kind == V2Types.OrderKind.Bid) e.bids += left;
                else if (o.kind == V2Types.OrderKind.AskResale) e.resale += left;
                else e.writes += left;
            }
        }
        e.longs = clearinghouse.balanceOf(address(this), longId);
        e.shorts = clearinghouse.balanceOf(address(this), V2Ids.shortIdOf(longId));
    }

    /// @dev MIRRORED from `MakerVault._measure`.
    function _measure(uint256 longId) private returns (Exposure memory e) {
        uint256[] memory ids;
        bool[] memory dead;
        (e, ids, dead) = _scan(longId);
        uint256[] storage stored = _orderIds[longId];
        for (uint256 i = ids.length; i > 0;) {
            --i;
            if (!dead[i]) continue;
            uint256 last = stored.length - 1;
            if (i != last) stored[i] = stored[last];
            stored.pop();
        }
    }

    /// @dev MIRRORED from `MakerVault._units`.
    function _units(Exposure memory e) private pure returns (uint256) {
        uint256 longSide = e.longs + e.resale + e.bids;
        uint256 up = longSide > e.shorts ? longSide - e.shorts : 0;
        uint256 shortSide = e.shorts + e.writes;
        uint256 down = shortSide > e.longs ? shortSide - e.longs : 0;
        return up > down ? up : down;
    }

    /// @dev MIRRORED from `MakerVault._enforce`, except that it takes the measured exposure rather than its units:
    ///      {_record} needs to know whether anything is held, which net units cannot say.
    function _enforce(uint256 longId, uint256 strike, uint256 beforeUnits, Exposure memory after_) private {
        uint256 afterUnits = _units(after_);
        uint256 notional = afterUnits * strike / V2Constants.UNITS_PER_SHARE;
        uint256 total = totalNotional - seriesNotional[longId] + notional;
        if (afterUnits > beforeUnits) {
            Limits memory l = _limits;
            if (afterUnits > l.maxSeriesUnits || total > l.maxTotalNotional) revert V2Errors.CeilingExceeded();
        }
        _record(longId, afterUnits, notional, total, _holds(after_));
    }

    /// @dev MIRRORED from `MakerVault._refresh`, with the same exception as {_enforce}.
    function _refresh(uint256 longId) private {
        Exposure memory e = _measure(longId);
        uint256 units = _units(e);
        uint256 notional = units * clearinghouse.series(longId).strike / V2Constants.UNITS_PER_SHARE;
        _record(longId, units, notional, totalNotional - seriesNotional[longId] + notional, _holds(e));
    }

    /// @dev Whether the vault still has anything in `longId`: a long, a short or a live order.
    function _holds(Exposure memory e) private pure returns (bool) {
        return e.longs != 0 || e.shorts != 0 || e.live != 0;
    }

    /// @dev MIRRORED from `MakerVault._record` for the notional, but {_tracked} FOLLOWS WHAT THE VAULT HOLDS, not
    ///      the net notional (T-309, T-BUG-02 F1). A matched long+short pair with no live order nets to zero units
    ///      and zero notional, yet its tokens are options and its collateral is locked in the Clearinghouse, outside
    ///      {_nav}. Untracking it on zero notional -- MakerVault's rule, which has no boundary to protect -- let
    ///      {_requireFlat}, which walks only {_tracked}, pass a boundary the vault still held options at. A series
    ///      now leaves {_tracked} only when a re-measure finds nothing held: after {close} before settlement, or
    ///      after the pair is redeemed. Every path that re-measures (take, place, replace, cancel, close, sync) goes
    ///      through here, so none of them can untrack a held pair.
    function _record(uint256 longId, uint256 units, uint256 notional, uint256 total, bool held) private {
        if (seriesNotional[longId] != notional) {
            seriesNotional[longId] = notional;
            totalNotional = total;
            emit ExposureSet(longId, units, notional, total);
        }
        uint256 pos = _trackedPos[longId];
        if (held && pos == 0) {
            _tracked.push(longId);
            _trackedPos[longId] = _tracked.length;
        } else if (!held && pos != 0) {
            uint256 lastId = _tracked[_tracked.length - 1];
            _tracked[pos - 1] = lastId;
            _trackedPos[lastId] = pos;
            _tracked.pop();
            delete _trackedPos[longId];
        }
    }

    function _u128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert V2Errors.CeilingExceeded();
        // casting is safe: bounded immediately above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
