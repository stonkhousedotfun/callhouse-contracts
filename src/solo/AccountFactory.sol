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
/// @notice Deploys isolated per-user covered-call accounts. No pooled vault, no shares.
/// @dev Each account holds that user's NVDA, writes only that user's lots, and has its own
///      Valorem option type (unique expiry offset) so assignment cannot hit anyone else.
///      The keeper publishes one week's terms; `listFor` posts 1-lot FULL_RESTRICTED Seaport
///      orders from that account. The live pooled {Vault} is a different product.
contract AccountFactory is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Shared implementation. Clones delegatecall into it; immutables live here.
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
    WriterAccount[] public accounts;
    uint32 public nextIndex;

    event AccountCreated(address indexed owner, WriterAccount indexed account, uint32 index);
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
        accounts.push(account);
        emit AccountCreated(msg.sender, account, index);
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    /// @notice Publish this week's terms. Every listed account uses this strike and window;
    ///         each account's option type uniquifies `baseExpiryTs` by its index.
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

    /// @notice Post this owner's requested 1-lot orders for the live week.
    function listFor(address owner) external onlyRole(KEEPER_ROLE) {
        WriterAccount account = accountOf[owner];
        if (address(account) == address(0)) revert NoAccount();
        account.list();
    }

    function listMany(address[] calldata owners) external onlyRole(KEEPER_ROLE) {
        for (uint256 i; i < owners.length; i++) {
            WriterAccount account = accountOf[owners[i]];
            if (address(account) == address(0)) revert NoAccount();
            account.list();
        }
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
}
