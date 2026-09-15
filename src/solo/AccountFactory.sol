// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Policy, PolicyParams} from "../Policy.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";
import {ISeaport} from "../interfaces/ISeaport.sol";
import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {WriterAccount, IAccountFactory} from "./Account.sol";

/// @title AccountFactory
/// @notice Deploys isolated per-user covered-call accounts.
/// @dev Keeper and the book iterate `pending` / `live` only — never every account ever created.
contract AccountFactory is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    WriterAccount public immutable implementation;
    IERC20 public immutable asset;
    IERC20 public immutable usdg;
    IValoremClear public immutable clear;
    ISeaport public immutable seaport;
    IChainlinkFeed public immutable priceFeed;
    bytes32 public immutable conduitKey;

    PolicyParams public policy;
    address public feeRecipient;
    uint32 public maxPriceAge;
    uint256 public depositCap;
    bool public writesHalted;
    bool public valoremFeeAccepted;

    struct Week {
        uint32 id;
        uint256 strikeUsdg;
        uint40 exerciseTs;
        uint40 baseExpiryTs;
        uint256 askUsdg;
    }

    Week public week;

    mapping(address => WriterAccount) public accountOf;
    uint32 public nextIndex;

    /// @dev Clones waiting for `list()`. Swap-remove. Not every created account.
    address[] private _pending;
    mapping(address => uint256) private _pendingPos;

    /// @dev Clones with live listings this week. Swap-remove. What the book iterates.
    address[] private _live;
    mapping(address => uint256) private _livePos;

    event AccountCreated(address indexed owner, WriterAccount indexed account, uint32 index);
    event AccountRekeyed(address indexed from, address indexed to, WriterAccount indexed account);
    event WeekSet(uint32 indexed id, uint256 strikeUsdg, uint40 exerciseTs, uint40 baseExpiryTs, uint256 askUsdg);
    event WritesHalted(bool halted);
    event PolicySet();
    event FeeRecipientSet(address indexed recipient);
    event DepositCapSet(uint256 cap);

    error ZeroAddr();
    error AlreadyHasAccount();
    error NoAccount();
    error BadWeek();
    error AskAboveStrike(uint256 ask, uint256 strike);
    error NotAccount();
    error Occupied();

    constructor(
        IERC20 asset_,
        IERC20 usdg_,
        IValoremClear clear_,
        ISeaport seaport_,
        IChainlinkFeed priceFeed_,
        uint32 maxPriceAge_,
        bytes32 conduitKey_,
        address admin_,
        address feeRecipient_,
        uint256 depositCap_
    ) {
        if (
            address(asset_) == address(0) || address(clear_) == address(0) || address(seaport_) == address(0)
                || address(priceFeed_) == address(0) || admin_ == address(0) || feeRecipient_ == address(0)
        ) revert ZeroAddr();

        asset = asset_;
        usdg = usdg_;
        clear = clear_;
        seaport = seaport_;
        priceFeed = priceFeed_;
        conduitKey = conduitKey_;
        feeRecipient = feeRecipient_;
        depositCap = depositCap_;
        maxPriceAge = maxPriceAge_;

        PolicyParams memory p = Policy.launchDefaults();
        Policy.validate(p);
        policy = p;

        implementation =
            new WriterAccount(IAccountFactory(address(this)), asset_, usdg_, clear_, seaport_, priceFeed_, conduitKey_);
        implementation.lockImplementation();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function createAccount() external returns (WriterAccount account) {
        if (address(accountOf[msg.sender]) != address(0)) revert AlreadyHasAccount();
        uint32 index = ++nextIndex;
        account = WriterAccount(payable(Clones.clone(address(implementation))));
        account.initialize(msg.sender, index);
        accountOf[msg.sender] = account;
        emit AccountCreated(msg.sender, account, index);
    }

    function accountCount() external view returns (uint256) {
        return nextIndex;
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function pendingAt(uint256 i) external view returns (address) {
        return _pending[i];
    }

    function liveCount() external view returns (uint256) {
        return _live.length;
    }

    function liveAt(uint256 i) external view returns (address) {
        return _live[i];
    }

    function setWeek(uint256 strikeUsdg, uint40 exerciseTs, uint40 baseExpiryTs, uint256 askUsdg)
        external
        onlyRole(KEEPER_ROLE)
    {
        if (exerciseTs <= block.timestamp + 1 hours) revert BadWeek();
        if (baseExpiryTs < exerciseTs + 1 days) revert BadWeek();
        if (askUsdg == 0 || strikeUsdg == 0) revert BadWeek();
        if (askUsdg > strikeUsdg) revert AskAboveStrike(askUsdg, strikeUsdg);
        week = Week({
            id: week.id + 1,
            strikeUsdg: strikeUsdg,
            exerciseTs: exerciseTs,
            baseExpiryTs: baseExpiryTs,
            askUsdg: askUsdg
        });
        emit WeekSet(week.id, strikeUsdg, exerciseTs, baseExpiryTs, askUsdg);
    }

    function listFor(address owner) external onlyRole(KEEPER_ROLE) {
        WriterAccount account = accountOf[owner];
        if (address(account) == address(0)) revert NoAccount();
        account.list();
    }

    function notifyPending() external {
        _onlyClone();
        _enqueue(_pending, _pendingPos, msg.sender);
    }

    function notifyNotPending() external {
        _onlyClone();
        _dequeue(_pending, _pendingPos, msg.sender);
    }

    function notifyListed() external {
        _onlyClone();
        _dequeue(_pending, _pendingPos, msg.sender);
        _enqueue(_live, _livePos, msg.sender);
    }

    function notifySettled() external {
        _onlyClone();
        _dequeue(_pending, _pendingPos, msg.sender);
        _dequeue(_live, _livePos, msg.sender);
    }

    function rekey(address newOwner) external {
        if (newOwner == address(0)) revert ZeroAddr();
        address oldOwner = WriterAccount(payable(msg.sender)).owner();
        if (address(accountOf[oldOwner]) != msg.sender) revert NotAccount();
        if (address(accountOf[newOwner]) != address(0)) revert Occupied();
        delete accountOf[oldOwner];
        accountOf[newOwner] = WriterAccount(payable(msg.sender));
        emit AccountRekeyed(oldOwner, newOwner, WriterAccount(payable(msg.sender)));
    }

    function setWritesHalted(bool halted) external onlyRole(GUARDIAN_ROLE) {
        writesHalted = halted;
        emit WritesHalted(halted);
    }

    function setValoremFeeAccepted(bool accepted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        valoremFeeAccepted = accepted;
    }

    function setPolicy(PolicyParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Policy.validate(p);
        policy = p;
        emit PolicySet();
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddr();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    function setMaxPriceAge(uint32 age) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPriceAge = age;
    }

    function _onlyClone() internal view {
        address owner_ = WriterAccount(payable(msg.sender)).owner();
        if (address(accountOf[owner_]) != msg.sender) revert NotAccount();
    }

    function _enqueue(address[] storage arr, mapping(address => uint256) storage pos, address account) internal {
        if (pos[account] != 0) return;
        arr.push(account);
        pos[account] = arr.length;
    }

    function _dequeue(address[] storage arr, mapping(address => uint256) storage pos, address account) internal {
        uint256 i = pos[account];
        if (i == 0) return;
        uint256 last = arr.length;
        if (i != last) {
            address moved = arr[last - 1];
            arr[i - 1] = moved;
            pos[moved] = i;
        }
        arr.pop();
        pos[account] = 0;
    }
}
