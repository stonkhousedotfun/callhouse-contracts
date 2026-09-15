// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Policy, PolicyParams} from "../Policy.sol";
import {ValoremLib} from "../lib/ValoremLib.sol";
import {IValoremClear} from "../interfaces/IValoremClear.sol";
import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {IERC1155Minimal} from "../interfaces/IERC1155Minimal.sol";
import {
    ISeaport,
    IZone,
    Order,
    OrderComponents,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType,
    ZoneParameters
} from "../interfaces/ISeaport.sol";

interface IAccountFactory {
    function KEEPER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function feeRecipient() external view returns (address);
    function depositCap() external view returns (uint256);
    function maxPriceAge() external view returns (uint32);
    function writesHalted() external view returns (bool);
    function valoremFeeAccepted() external view returns (bool);
    function policy()
        external
        view
        returns (
            uint16 minOtmBps,
            uint16 maxOtmBps,
            uint16 minPremiumBps,
            uint16 maxUtilizationBps,
            uint16 protocolFeeBps,
            uint64 maxContractsCap
        );

    function week()
        external
        view
        returns (uint32 id, uint256 strikeUsdg, uint40 exerciseTs, uint40 baseExpiryTs, uint256 askUsdg);
}

/// @title WriterAccount
/// @notice One user's isolated covered-call account. Cloneable; immutables live on the implementation.
/// @dev Deposit NVDA, request N lots, keeper lists N FULL 1-contract Seaport orders of this
///      account's own option type (expiry = week.baseExpiry + index). A fill writes this user's
///      NVDA and pays this user the premium. Unfilled lots unlock at settle. Assignment of this
///      option type cannot hit another account.
contract WriterAccount is ReentrancyGuardTransient, IZone {
    using SafeERC20 for IERC20;

    IAccountFactory public immutable factory;
    IERC20 public immutable asset;
    IERC20 public immutable usdg;
    IValoremClear public immutable clear;
    ISeaport public immutable seaport;
    IChainlinkFeed public immutable priceFeed;
    bytes32 public immutable conduitKey;

    address public owner;
    uint32 public index;
    bool public initialized;

    uint32 public listedWeekId;
    uint64 public requestedLots;
    uint64 public listedLots;
    uint256 public reserved;
    uint256 public optionId;
    uint256 public claimKey;
    uint112 public contractsWritten;

    mapping(bytes32 => bool) public liveListing;
    uint256 public liveListingCount;

    uint256 private transient _fillBaseline;
    bool private transient _fillArmed;

    event Deposited(address indexed owner, uint256 assets);
    event Withdrawn(address indexed owner, uint256 assets);
    event WriteRequested(uint64 lots);
    event LotsListed(uint32 indexed weekId, uint256 indexed optionId, uint64 lots, uint256 askUsdg);
    event LotFilled(bytes32 indexed orderHash, uint256 indexed optionId, uint256 premiumUsdg);
    event Settled(uint256 nvdaReturned, uint256 strikeUsdg);
    event UsdgClaimed(address indexed to, uint256 amount);

    error NotOwner();
    error NotKeeper();
    error NotSeaport();
    error AlreadyInitialized();
    error ImplementationLocked();
    error ZeroAmount();
    error DepositCapExceeded();
    error InsufficientIdle();
    error NoWeek();
    error WritesAreHalted();
    error AlreadyListed();
    error StillOpen();
    error NothingToList();
    error TooManyLots();
    error NotLiveListing(bytes32 orderHash);
    error BadLot();
    error InventoryLeftBehind(uint256 got, uint256 expected);
    error TooEarly();
    error NoOpenClaim();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IAccountFactory factory_,
        IERC20 asset_,
        IERC20 usdg_,
        IValoremClear clear_,
        ISeaport seaport_,
        IChainlinkFeed priceFeed_,
        bytes32 conduitKey_
    ) {
        factory = factory_;
        asset = asset_;
        usdg = usdg_;
        clear = clear_;
        seaport = seaport_;
        priceFeed = priceFeed_;
        conduitKey = conduitKey_;
    }

    /// @dev Called once on the implementation so it cannot be used as an account.
    function lockImplementation() external {
        if (msg.sender != address(factory)) revert NotKeeper();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
    }

    function initialize(address owner_, uint32 index_) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != address(factory)) revert NotKeeper();
        if (owner_ == address(0) || index_ == 0) revert ImplementationLocked();
        initialized = true;
        owner = owner_;
        index = index_;
        IERC1155Minimal(address(clear)).setApprovalForAll(address(seaport), true);
    }

    function deposit(uint256 assets) external onlyOwner nonReentrant {
        if (assets == 0) revert ZeroAmount();
        uint256 next = _heldAssets() + assets;
        if (next > factory.depositCap()) revert DepositCapExceeded();
        asset.safeTransferFrom(owner, address(this), assets);
        emit Deposited(owner, assets);
    }

    /// @notice NVDA not reserved for unfilled listings. Locked Valorem collateral is already gone
    ///         from the balance, so this is the amount the owner can take home right now.
    function idleAssets() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > reserved ? bal - reserved : 0;
    }

    function withdraw(uint256 assets) external onlyOwner nonReentrant {
        if (assets == 0) revert ZeroAmount();
        if (assets > idleAssets()) revert InsufficientIdle();
        asset.safeTransfer(owner, assets);
        emit Withdrawn(owner, assets);
    }

    /// @notice How many 1-NVDA lots to write this week. 0 means do not list.
    function requestWrite(uint64 lots) external onlyOwner {
        if (listedLots != 0) revert AlreadyListed();
        if (lots > asset.balanceOf(address(this)) / Policy.LOT) revert InsufficientIdle();
        requestedLots = lots;
        emit WriteRequested(lots);
    }

    /// @notice Keeper-only. Creates this account's option type and validates `requestedLots`
    ///         FULL 1-contract Seaport orders. Premium (minus fee) pays `owner` on fill.
    function list() external nonReentrant {
        if (msg.sender != address(factory) && !factory.hasRole(factory.KEEPER_ROLE(), msg.sender)) {
            revert NotKeeper();
        }
        if (factory.writesHalted()) revert WritesAreHalted();
        if (listedLots != 0) revert AlreadyListed();
        if (optionId != 0) revert StillOpen();

        (uint32 weekId, uint256 strikeUsdg, uint40 exerciseTs, uint40 baseExpiryTs, uint256 askUsdg) = factory.week();
        if (weekId == 0) revert NoWeek();

        uint64 lots = requestedLots;
        if (lots == 0) revert NothingToList();
        if (uint256(lots) * Policy.LOT > asset.balanceOf(address(this))) revert InsufficientIdle();

        (,,,,, uint64 cap) = factory.policy();
        if (lots > cap) revert TooManyLots();

        uint40 expiryTs = uint40(uint256(baseExpiryTs) + index);
        optionId = _ensureOptionType(strikeUsdg, exerciseTs, expiryTs);
        ValoremLib.open(
            clear,
            ValoremLib.Open({
                feed: priceFeed,
                asset: asset,
                exerciseAsset: address(usdg),
                optionId: optionId,
                maxPriceAge: factory.maxPriceAge(),
                feeAccepted: factory.valoremFeeAccepted()
            }),
            _policy()
        );

        reserved = uint256(lots) * Policy.LOT;
        listedLots = lots;
        listedWeekId = weekId;
        liveListingCount = lots;

        for (uint256 i; i < lots; i++) {
            OrderComponents memory c = lotOrder(i);
            bytes32 h = seaport.getOrderHash(c);
            liveListing[h] = true;
            Order[] memory orders = new Order[](1);
            orders[0] = Order({parameters: _toParameters(c), signature: ""});
            if (!seaport.validate(orders)) revert BadLot();
        }

        emit LotsListed(weekId, optionId, lots, askUsdg);
    }

    function authorizeOrder(ZoneParameters calldata zp) external nonReentrant returns (bytes4) {
        if (msg.sender != address(seaport)) revert NotSeaport();
        if (!liveListing[zp.orderHash] || zp.offerer != address(this)) revert NotLiveListing(zp.orderHash);
        if (factory.writesHalted()) revert WritesAreHalted();
        if (zp.offer.length != 1 || zp.offer[0].amount != 1) revert BadLot();

        uint256 id = optionId;
        if (!_fillArmed) {
            _fillArmed = true;
            _fillBaseline = IERC1155Minimal(address(clear)).balanceOf(address(this), id);
        }

        uint256 gross;
        for (uint256 i; i < zp.consideration.length; i++) {
            gross += zp.consideration[i].amount;
        }

        liveListing[zp.orderHash] = false;
        liveListingCount -= 1;
        reserved -= Policy.LOT;

        PolicyParams memory p = _policy();
        (uint256 key, uint256 collateral) = ValoremLib.writeOnFill(
            clear,
            ValoremLib.Fill({
                feed: priceFeed,
                asset: asset,
                optionId: id,
                claimId: claimKey,
                strikeUsdg: _strike(),
                sizingAssets: type(uint128).max,
                reserved: reserved,
                grossUsdg: gross,
                written: contractsWritten,
                n: 1,
                cycleExerciseTs: _exerciseTs(),
                maxPriceAge: factory.maxPriceAge(),
                feeAccepted: factory.valoremFeeAccepted()
            }),
            p
        );
        claimKey = key;
        contractsWritten += 1;
        collateral; // locked in Valorem; recorded via contractsWritten

        emit LotFilled(zp.orderHash, id, gross);
        return IZone.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata) external view returns (bytes4) {
        if (msg.sender != address(seaport)) revert NotSeaport();
        uint256 bal = IERC1155Minimal(address(clear)).balanceOf(address(this), optionId);
        uint256 baseline = _fillBaseline;
        if (bal != baseline) revert InventoryLeftBehind(bal, baseline);
        return IZone.validateOrder.selector;
    }

    /// @notice After expiry: kill leftover listings, redeem the claim if anything sold, release reserve.
    function settle() external nonReentrant {
        uint40 expiry = _expiryTs();
        if (expiry == 0 || block.timestamp < expiry) revert TooEarly();

        if (liveListingCount != 0) {
            seaport.incrementCounter();
            liveListingCount = 0;
        }
        reserved = 0;
        requestedLots = 0;
        listedLots = 0;

        uint256 nvdaBefore = asset.balanceOf(address(this));
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 nvdaIn;
        uint256 usdgIn;
        if (claimKey != 0) {
            (bool ok, uint256 underlyingReturned, uint256 exerciseReceived) =
                ValoremLib.tryRedeemClaim(clear, asset, usdg, claimKey);
            if (ok) {
                claimKey = 0;
                optionId = 0;
                contractsWritten = 0;
                nvdaIn = underlyingReturned;
                usdgIn = exerciseReceived;
            }
        } else {
            optionId = 0;
            contractsWritten = 0;
        }
        nvdaBefore;
        usdgBefore;
        emit Settled(nvdaIn, usdgIn);
    }

    function claimUsdg() external onlyOwner nonReentrant {
        uint256 amount = usdg.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        usdg.safeTransfer(owner, amount);
        emit UsdgClaimed(owner, amount);
    }

    /// @notice The 1-lot FULL_RESTRICTED order at `salt` (0 .. listedLots-1).
    function lotOrder(uint256 salt) public view returns (OrderComponents memory c) {
        (,,,, uint256 askUsdg) = factory.week();
        (,,,, uint16 feeBps,) = factory.policy();
        uint256 fee = (askUsdg * feeBps) / 10_000;
        uint256 seller = askUsdg - fee;

        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: address(clear),
            identifierOrCriteria: optionId,
            startAmount: 1,
            endAmount: 1
        });

        uint256 nConsid = fee == 0 ? 1 : 2;
        ConsiderationItem[] memory consid = new ConsiderationItem[](nConsid);
        consid[0] = ConsiderationItem({
            itemType: ItemType.ERC20,
            token: address(usdg),
            identifierOrCriteria: 0,
            startAmount: seller,
            endAmount: seller,
            recipient: payable(owner)
        });
        if (fee != 0) {
            consid[1] = ConsiderationItem({
                itemType: ItemType.ERC20,
                token: address(usdg),
                identifierOrCriteria: 0,
                startAmount: fee,
                endAmount: fee,
                recipient: payable(factory.feeRecipient())
            });
        }

        c = OrderComponents({
            offerer: address(this),
            zone: address(this),
            offer: offer,
            consideration: consid,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: 0,
            endTime: _exerciseTs(),
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: conduitKey,
            counter: seaport.getCounter(address(this))
        });
    }

    function onERC1155Received(address, address from, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(clear) || from != address(0)) return 0x00000000;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address from, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(clear) || from != address(0)) return 0x00000000;
        return this.onERC1155BatchReceived.selector;
    }

    function _heldAssets() internal view returns (uint256) {
        uint256 locked;
        if (claimKey != 0) locked = ValoremLib.lockedAssets(clear, claimKey);
        return asset.balanceOf(address(this)) + locked;
    }

    function _ensureOptionType(uint256 strikeUsdg, uint40 exerciseTs, uint40 expiryTs) internal returns (uint256 id) {
        id = uint256(
            uint160(
                bytes20(
                    keccak256(
                        abi.encode(
                            address(asset), uint96(Policy.LOT), address(usdg), uint96(strikeUsdg), exerciseTs, expiryTs
                        )
                    )
                )
            )
        ) << 96;
        if (clear.tokenType(id) == IValoremClear.TokenType.None) {
            uint256 got = clear.newOptionType(
                address(asset), uint96(Policy.LOT), address(usdg), uint96(strikeUsdg), exerciseTs, expiryTs
            );
            if (got != id) id = got;
        }
    }

    function _policy() internal view returns (PolicyParams memory p) {
        (p.minOtmBps, p.maxOtmBps, p.minPremiumBps, p.maxUtilizationBps, p.protocolFeeBps, p.maxContractsCap) =
            factory.policy();
    }

    function _strike() internal view returns (uint256 strikeUsdg) {
        (, strikeUsdg,,,) = factory.week();
    }

    function _exerciseTs() internal view returns (uint40 exerciseTs) {
        (,, exerciseTs,,) = factory.week();
    }

    function _expiryTs() internal view returns (uint40) {
        (,,, uint40 baseExpiryTs,) = factory.week();
        if (baseExpiryTs == 0 || index == 0) return 0;
        return uint40(uint256(baseExpiryTs) + index);
    }

    function _toParameters(OrderComponents memory c) internal pure returns (OrderParameters memory p) {
        p.offerer = c.offerer;
        p.zone = c.zone;
        p.offer = c.offer;
        p.consideration = c.consideration;
        p.orderType = c.orderType;
        p.startTime = c.startTime;
        p.endTime = c.endTime;
        p.zoneHash = c.zoneHash;
        p.salt = c.salt;
        p.conduitKey = c.conduitKey;
        p.totalOriginalConsiderationItems = c.consideration.length;
    }
}
