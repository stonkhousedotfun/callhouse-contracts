// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title V2Types
/// @notice Shared structs and enums of the Stonkhouse v2 contracts; changes require a versioned interface update.
/// @dev A library only as a namespace. Every interface and contract spells these `V2Types.Series` etc., so the
///      `internalType` strings in every exported ABI agree and the off-chain generators see one set of tuple names.
///
///      UNITS, stated once and relied on everywhere in src/v2 (ADR-04):
///        - Every price (spot, strike, order price, settlement price) is USDG base units (6 dp) per WHOLE share.
///          $215.00 => 215_000_000. Order prices and strikes are multiples of PRICE_TICK (100), so the cost of one
///          unit, price / 100, is exact.
///        - `units` are 0.01-share units. 1 unit = V2Constants.UNIT = 1e16 base units of an 18-dp underlying.
///          ERC-1155 balances of long and short ids are units.
///        - `*PerUnit` settlement amounts are base units of the series' collateral asset per unit: USDG (6 dp) for
///          puts, the 18-dp underlying for calls.
///        - Times are unix seconds.
library V2Types {
    /// @notice One market row of the Clearinghouse, keyed by underlying (ADR-02: one Clearinghouse, markets are rows).
    /// @dev Set by DEFAULT_ADMIN_ROLE at registration; `mintPaused` is the GUARDIAN_ROLE switch.
    ///      INTERFACE_VERSION 7 APPENDED `mintFeePpm`. Appended, never inserted: a decoder built on the v6 tuple keeps
    ///      reading the first five fields correctly. The tuple is part of registerMarket / setMarketConfig and of the
    ///      MarketRegistered / MarketConfigSet topics, so all four changed.
    struct MarketConfig {
        bool enabled; // series may be created and minted
        bool mintPaused; // guardian switch
        uint64 strikeTick; // USDG 6 dp per share. strike % strikeTick == 0; strikeTick % 100 == 0
        uint16 exerciseFeeBps; // pinned into each series at creation; <= EXERCISE_FEE_CEIL_BPS
        address oracle; // ISettlementOracle for NEW series -- slot 0 ends here (32 B)
        // v7: millionths of the locked collateral per V2Constants.MINT_FEE_PERIOD of REMAINING life, pinned into
        // each series at creation; <= MINT_FEE_CEIL_PPM. Slot 1.
        uint32 mintFeePpm;
    }

    /// @notice An option series `(underlying, isPut, strike, expiry)`, shared by every writer and buyer.
    /// @dev `oracle`, `exerciseFeeBps` and `mintFeePpm` are copied from the market at creation and never change
    ///      afterwards, so an admin re-pointing the market cannot touch existing positions. The five settlement fields
    ///      are written once, by the settle call that finds a final price; the identity
    ///      long + fee + short == collateralPerUnit holds.
    ///      INTERFACE_VERSION 7 APPENDED `mintFeePpm` and `mintFeesHeld` as a new slot 5. Appended, never inserted (v7
    ///      design §3.5): `ops/v2/monitor.mjs` decodes `series()` from a hand-written positional ABI, and a decoder
    ///      built on the v6 tuple keeps reading the first eleven fields correctly, while an inserted field would
    ///      silently return `mintFeePpm` as the strike. `series(uint256)` keeps its selector.
    struct Series {
        address underlying; // 18-dp Stock Token
        bool isPut;
        uint40 expiry; // unix seconds, 16:00 New York on a session day -- slot 0
        uint128 strike; // USDG 6 dp per whole share -- slot 1
        address oracle; // pinned at creation
        uint16 exerciseFeeBps; // pinned at creation
        bool settled; // slot 2 ends here
        uint128 settlementPrice; // USDG 6 dp per whole share; 0 until settled
        uint128 longPayoutPerUnit; // collateral-asset base units, net of fee -- slot 3
        uint128 feePerUnit; // collateral-asset base units taken from the long payout
        uint128 shortPayoutPerUnit; // collateral-asset base units returned to the short -- slot 4
        uint32 mintFeePpm; // v7: pinned from the market at creation, never changes
        // v7: rent collected and not yet refunded by close or accrued by settle, collateral-asset base units
        uint128 mintFeesHeld; // slot 5 (20 B used)
    }

    /// @notice Order kinds of the OrderBook.
    /// @dev Bid: escrows USDG = price * units / 100. AskResale: escrows the maker's long tokens. AskWrite: escrows
    ///      nothing; the longs are minted from the maker's free Clearinghouse collateral at fill time.
    enum OrderKind {
        Bid,
        AskResale,
        AskWrite
    }

    /// @notice A resting limit order. `units - filled` is what is left.
    struct Order {
        address maker;
        uint256 longId;
        OrderKind kind;
        uint128 price; // USDG 6 dp per whole share, % 100 == 0
        uint64 units; // original size, 0.01-share units
        uint64 filled; // 0.01-share units
        uint40 validUntil; // unix seconds
        bool cancelled;
    }

    /// @notice Arguments of OrderBook.take. The taker names the order ids; there is no on-chain sorting (ADR-03).
    struct TakeParams {
        uint256 longId;
        bool buying; // true: hit asks. false: hit bids
        uint256[] orderIds; // tried in this order
        uint64 units; // wanted, 0.01-share units
        uint64 minUnits; // revert below this
        uint128 limitPrice; // USDG 6 dp per share. buying: max price. selling: min price
        bool writeToSell; // selling only: mint the longs from taker's free collateral
        address recipient; // receives longs (buying) or USDG (selling)
        uint40 deadline; // unix seconds
    }

    /// @notice OrderBook fee parameters (ADR-08). Admin-set under the V2Constants ceilings.
    struct FeeParams {
        uint16 premiumFeeBps; // seller, primary sales only; <= PREMIUM_FEE_CEIL_BPS
        uint16 resaleFeeBps; // seller on resale; <= PREMIUM_FEE_CEIL_BPS
        uint32 takerFeeFlat; // USDG base units; <= TAKER_FEE_FLAT_CEIL
        uint16 takerFeeCapBps; // taker fee never above premium * cap / 1e4; <= TAKER_FEE_CAP_CEIL_BPS
        uint16 makerRebateBps; // default share of the taker fee paid to makers
    }

    /// @notice Settlement state of one (underlying, expiry) in the SettlementOracle (ADR-05).
    /// @dev None: nothing decided yet. Pending: an uncorroborated candidate is waiting out the market's delay.
    ///      Finalized: the price is final. Held: the guardian vetoed the uncorroborated path.
    enum SettlementStatus {
        None,
        Pending,
        Finalized,
        Held
    }

    /// @notice AutoRoller strategy of one (writer, underlying) (architecture §3.8).
    struct Strategy {
        bool active;
        bool weekly; // false = daily
        bool smartPricing; // lets PRICER_ROLE reprice inside [minAskBps, maxAskBps]
        uint16 otmBps; // strike distance above spot, bps (100-2500)
        uint16 askBps; // ask price as bps of spot (5-1000)
        uint16 minAskBps; // smart-pricing floor, bps of spot
        uint16 maxAskBps; // smart-pricing ceiling, bps of spot
        uint64 maxUnits; // 0.01-share units; 0 = all free collateral
    }
}
