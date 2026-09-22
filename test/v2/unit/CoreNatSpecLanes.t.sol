// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title CoreNatSpecLanes
/// @notice Freezes ONE fact: every AccessManager lane named in the five core files' comments is the lane
///         `script/v2/roles.v8.json` records for that function (T-186, F-CORE-02).
/// @dev WHY THIS EXISTS. The v7 role names drifted out of these comments' agreement with the manifest for a whole
///      interface version and nothing noticed, because nothing compares prose to the manifest. The realistic harm is
///      an ops error -- somebody schedules a DEFAULT_ADMIN operation for a function that needs CONFIG_ADMIN's 24 h
///      lane -- so the defence has to be a check, not a careful rewrite.
///
///      THE MANIFEST IS THE AUTHORITY, IN BOTH DIRECTIONS. Lanes and delays are read out of
///      `script/v2/roles.v8.json` at run time, never retyped here: a lane name is compared against `.targets`, and a
///      delay phrase against `.delaysS`. This test READS that file and writes nothing under `script/**`.
///
///      IT MUST BE ABLE TO FAIL, which is the whole point of the row. A parser that finds nothing would pass every
///      assertion vacuously -- the exact false-green shape this task documents -- so {test_everySiteIsFound} asserts
///      the EXPECTED COUNT of sites before any lane is compared, and every anchor below is deliberately free of a
///      lane name so that corrupting a comment's lane is caught as a MISMATCH and not merely as a missing anchor.
contract CoreNatSpecLanesTest is Test {
    string internal constant MANIFEST = "script/v2/roles.v8.json";

    string internal constant CLEARINGHOUSE = "src/v2/Clearinghouse.sol";
    string internal constant KEEPER_REWARDS = "src/v2/KeeperRewards.sol";
    string internal constant V2TYPES = "src/v2/interfaces/V2Types.sol";
    string internal constant IAUTOROLLER = "src/v2/interfaces/IAutoRoller.sol";
    string internal constant IPRICESOURCE = "src/v2/interfaces/IPriceSource.sol";

    /// @dev `file` and `anchor` locate ONE comment line; `signature` is the entry in `.targets` whose lane that line
    ///      must name. `anchor` never contains a lane name, so a corrupted lane still finds its line and fails as a
    ///      mismatch. `delayed` marks the lines that also print the lane's delay, checked against `.delaysS`.
    struct Site {
        string file;
        string anchor;
        string signature;
        bool delayed;
    }

    /// @dev T-OP-015. A comment line that names MORE than one lane, or names a lane for a group of functions
    ///      rather than one (the trust-model header, a section banner). `signatures` are the `.targets` entries
    ///      whose manifest lanes the line must name -- exactly that set, no more and no fewer -- so a banner that
    ///      names a lane none of its functions use fails here, and a lane added to the line without a function
    ///      behind it fails too. Anchors are lane-free for the same reason {Site} anchors are.
    struct Prose {
        string file;
        string anchor;
        string[] signatures;
    }

    /// @dev The eleven lanes `.roles` declares. Read from the manifest in {setUp}, never typed here.
    string[] internal lanes;
    string internal manifestJson;

    function setUp() public {
        manifestJson = vm.readFile(MANIFEST);
        lanes = vm.parseJsonKeys(manifestJson, ".roles");
        assertEq(lanes.length, 11, "roles.v8.json declares eleven lanes");
    }

    function _sites() internal pure returns (Site[] memory s) {
        s = new Site[](33);
        uint256 i;
        // ---- Clearinghouse: state, events, setters -------------------------------------------------
        s[i++] = Site(CLEARINGHOUSE, "{setCreatePaused}, no delay", "setCreatePaused(bool)", false);
        // T-OP-015: the three single-lane prose lines the whole-file walk ({test_everyLaneMentionIsASite})
        // found with no row. T-OP-060 reworded and rewrapped the rent framing (Clearinghouse.sol:38-39): the lane
        // moved off the "can still raise the rate on chain afterwards" line this row used to anchor on, so the
        // anchor is now the landed text of the line that NAMES the lane (:39, lane-free like every anchor here,
        // and unique in the file), and that line also prints the lane's 72 h delay: `delayed` true, where the old
        // layout had the delay on the next line (T-OP-097 (b)(2)).
        s[i++] = Site(
            CLEARINGHOUSE, "lane's 72 h delay. When it IS non-zero", "setMarketFees(address,uint16,uint32)", true
        );
        s[i++] = Site(
            CLEARINGHOUSE, "the caller may be the AccessManager itself", "registerMarket(address,uint64,bool)", false
        );
        s[i++] = Site(CLEARINGHOUSE, "AND LIES. A compromised", "setMarketOracle(address,address)", false);
        s[i++] = Site(CLEARINGHOUSE, "pointed NEW series at", "setCalendar(address)", false);
        s[i++] = Site(CLEARINGHOUSE, "set the bounty payer (address(0)", "setKeeperRewards(address)", false);
        s[i++] = Site(CLEARINGHOUSE, "bounty threshold, USDG base units", "setMinRedeemPayout(uint96)", false);
        s[i++] = Site(CLEARINGHOUSE, "set the ERC-1155 metadata base URI.", "setBaseUri(string)", false);
        s[i++] = Site(CLEARINGHOUSE, "Pauses or resumes {mint} for one market.", "setMintPaused(address,bool)", true);
        s[i++] = Site(
            CLEARINGHOUSE,
            "Pauses or resumes {createSeries} for new ids in every market.",
            "setCreatePaused(bool)",
            true
        );
        s[i++] = Site(CLEARINGHOUSE, "Points NEW series at another calendar.", "setCalendar(address)", true);
        s[i++] = Site(CLEARINGHOUSE, "Sets the receiver of swept exercise fees.", "setFeeRecipient(address)", true);
        s[i++] = Site(
            CLEARINGHOUSE,
            "Sets the PayoutAdapter and the conversion slippage bound.",
            "setPayoutAdapter(address,uint16)",
            true
        );
        s[i++] = Site(CLEARINGHOUSE, "Sets the bounty payer.", "setKeeperRewards(address)", true);
        s[i++] = Site(CLEARINGHOUSE, "Sets the REDEEM and SETTLE bounty threshold.", "setMinRedeemPayout(uint96)", true);
        s[i++] = Site(CLEARINGHOUSE, "Sets the ERC-1155 metadata base URI.", "setBaseUri(string)", true);
        // ---- KeeperRewards: events ------------------------------------------------------------------
        s[i++] = Site(KEEPER_REWARDS, "or unregistered `caller` for {reward}.", "setCaller(address,bool)", false);
        s[i++] = Site(KEEPER_REWARDS, "set the cap to `amount` USDG base units", "setDailyCap(uint256)", false);
        s[i++] = Site(KEEPER_REWARDS, "of the budget to `to`.", "defund(uint256)", false);
        // T-OP-015: the five setter NatSpec lines the whole-file walk found with no row. `setCaller`'s lane sits
        // on a continuation line whose ONLY text is the lane and its delay, so its anchor is lane-bearing by
        // necessity: the one anchor here where a corrupted lane reads as "anchor missing" rather than a mismatch.
        s[i++] = Site(KEEPER_REWARDS, "Pays {treasury} only", "defund(uint256)", true);
        s[i++] = Site(KEEPER_REWARDS, "Sets the only address {defund} can pay.", "setTreasury(address)", true);
        s[i++] = Site(KEEPER_REWARDS, "CONFIG_ADMIN (24 h).", "setCaller(address,bool)", true);
        s[i++] = Site(KEEPER_REWARDS, "Set the bounty of `action` to `amount`", "setBounty(bytes32,uint256)", true);
        s[i++] = Site(KEEPER_REWARDS, "Set the maximum spend per rolling 24 h", "setDailyCap(uint256)", true);
        // ---- V2Types: MarketConfig and Strategy -----------------------------------------------------
        s[i++] = Site(V2TYPES, "registers the row and moves listing", "registerMarket(address,uint64,bool)", true);
        s[i++] = Site(V2TYPES, "moves the fee fields (setMarketFees)", "setMarketFees(address,uint16,uint32)", true);
        s[i++] = Site(V2TYPES, "`mintPaused` is the", "setMintPaused(address,bool)", true);
        s[i++] = Site(V2TYPES, "reprice inside [minAskBps, maxAskBps]", "reprice(address,address,uint128)", false);
        // ---- IAutoRoller ----------------------------------------------------------------------------
        s[i++] =
            Site(IAUTOROLLER, "(NotAuthorized), and only when the strategy", "reprice(address,address,uint128)", true);
        s[i++] = Site(
            IAUTOROLLER,
            "function reprice(address writer, address underlying, uint128 newPrice) external;",
            "reprice(address,address,uint128)",
            false
        );
        s[i++] = Site(IAUTOROLLER, "replaced the writer's ask.", "reprice(address,address,uint128)", false);
        // ---- IPriceSource ---------------------------------------------------------------------------
        s[i++] = Site(IPRICESOURCE, "oracles may call {pin}) is", "setOracle(address,bool)", true);
        s[i++] = Site(IPRICESOURCE, "Only an oracle the", "setOracle(address,bool)", true);
        require(i == s.length, "site table length");
    }

    /// @dev The multi-lane and group-level lines. Every lane-bearing line in the five files is either a {Site} or
    ///      one of these; {test_everyLaneMentionIsASite} refuses a line that is neither. The two section banners
    ///      were the whole-file walk's only red lines when it landed (T-OP-015): `Clearinghouse.sol` said
    ///      "POINTERS (ADMIN)" over CONFIG_ADMIN, TREASURY_ADMIN and LISTING setters and `KeeperRewards.sol` said
    ///      "ADMIN" over CONFIG_ADMIN and FEE_MANAGER setters, while ADMIN is the 48 h manager-only lane nothing under
    ///      either banner uses. T-OP-037 renamed both to name exactly their setters' lanes and listed them here, one
    ///      signature per lane the banner names, so the walk is a plain assertion again and a banner that drifts
    ///      back to a lane none of its setters use fails {test_everyProseLineNamesExactlyItsLanes}.
    function _prose() internal pure returns (Prose[] memory p) {
        p = new Prose[](8);
        uint256 i;
        // ---- Clearinghouse: the trust-model header, one lane or two per line ------------------------
        string memory listing = "registerMarket(address,uint64,bool)";
        p[i++] = Prose(CLEARINGHOUSE, "Roles live on one AccessManager, not here.", _one(listing));
        p[i++] = Prose(
            CLEARINGHOUSE,
            "moves fee dials;",
            _two("setMarketFees(address,uint16,uint32)", "setMarketOracle(address,address)")
        );
        p[i++] = Prose(
            CLEARINGHOUSE, "moves the fee recipient;", _two("setFeeRecipient(address)", "setCreatePaused(bool)")
        );
        // ---- Clearinghouse: the registration trust paragraph and the pause banner --------------------
        p[i++] = Prose(CLEARINGHOUSE, "trust assumption, not an enforced one", _one(listing));
        p[i++] = Prose(CLEARINGHOUSE, "refuses a token that does not move exactly the amount", _one(listing));
        p[i++] = Prose(CLEARINGHOUSE, "PAUSES (", _one("setMintPaused(address,bool)"));
        // ---- the two section banners T-OP-037 renamed: one signature per lane the banner names -------------
        p[i++] = Prose(
            CLEARINGHOUSE,
            "POINTERS (",
            _three("setCalendar(address)", "setFeeRecipient(address)", "setMinRedeemPayout(uint96)")
        );
        p[i++] = Prose(KEEPER_REWARDS, "SETTERS (", _two("setCaller(address,bool)", "setBounty(bytes32,uint256)"));
        require(i == p.length, "prose table length");
    }

    function _one(string memory a) internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = a;
    }

    function _two(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }

    function _three(string memory a, string memory b, string memory c) internal pure returns (string[] memory out) {
        out = new string[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /*//////////////////////////////////////////////////////////////
                                 the check
    //////////////////////////////////////////////////////////////*/

    /// @notice Every site's anchor is present exactly once and names exactly one lane.
    /// @dev THE POSITIVE CONTROL FOR EVERY OTHER ASSERTION IN THIS FILE. A parser that located nothing would make
    ///      {test_everyNamedLaneMatchesTheManifest} pass over an empty set. This fails first if that ever happens.
    function test_everySiteIsFound() public view {
        Site[] memory sites = _sites();
        assertEq(sites.length, 33, "33 single-lane sites across the five core files");
        for (uint256 i; i < sites.length; ++i) {
            string memory line = _lineContaining(sites[i].file, sites[i].anchor);
            assertGt(bytes(line).length, 0, string.concat("anchor missing: ", sites[i].anchor));
            assertEq(_lanesOnLine(line).length, 1, string.concat("exactly one lane on the line for: ", sites[i].anchor));
        }
    }

    /// @notice Each site names the lane `roles.v8.json` records for that function, and prints that lane's real delay.
    function test_everyNamedLaneMatchesTheManifest() public view {
        Site[] memory sites = _sites();
        for (uint256 i; i < sites.length; ++i) {
            string memory line = _lineContaining(sites[i].file, sites[i].anchor);
            string[] memory found = _lanesOnLine(line);
            assertEq(found.length, 1, string.concat("one lane expected near: ", sites[i].anchor));
            string memory expected = _manifestLaneOf(sites[i].signature);
            assertEq(found[0], expected, string.concat("lane must match the manifest for ", sites[i].signature));
            if (sites[i].delayed) {
                assertTrue(
                    _contains(line, _delayPhrase(expected)),
                    string.concat("delay phrase must match .delaysS for ", expected)
                );
            }
        }
    }

    /// @notice No v7 AccessControl role name survives in any of the five files.
    /// @dev The drift this row fixes reappears as a `_ROLE` suffix, so the regression is worth its own assertion.
    function test_noV7RoleNamesRemain() public view {
        string[5] memory files = [CLEARINGHOUSE, KEEPER_REWARDS, V2TYPES, IAUTOROLLER, IPRICESOURCE];
        for (uint256 i; i < files.length; ++i) {
            assertFalse(_contains(vm.readFile(files[i]), "_ROLE"), string.concat("v7 role name left in ", files[i]));
        }
    }

    /// @notice Each prose line is present and names EXACTLY the manifest lanes of its signatures.
    /// @dev Both directions: a lane on the line with no signature behind it fails, and a signature whose lane the
    ///      line no longer names fails. `_lanesOnLine` blanks longer names first, so MARKET_FEE_MANAGER on a line
    ///      does not also count as FEE_MANAGER.
    function test_everyProseLineNamesExactlyItsLanes() public view {
        Prose[] memory prose = _prose();
        for (uint256 i; i < prose.length; ++i) {
            string memory line = _lineContaining(prose[i].file, prose[i].anchor);
            assertGt(bytes(line).length, 0, string.concat("prose anchor missing: ", prose[i].anchor));
            string[] memory found = _lanesOnLine(line);
            assertEq(found.length, prose[i].signatures.length, string.concat("lane count near: ", prose[i].anchor));
            for (uint256 j; j < prose[i].signatures.length; ++j) {
                string memory expected = _manifestLaneOf(prose[i].signatures[j]);
                assertTrue(
                    _has(found, expected),
                    string.concat("prose line must name ", expected, " for ", prose[i].signatures[j])
                );
            }
        }
    }

    /// @notice Every line in the five files that names a lane is a {Site} or a {Prose} entry, and names only the
    ///         lanes those entries vouch for. Closes T-186 suspicion 1: the site table could prove every listed
    ///         anchor exists, but not that an UNLISTED lane mention did not exist -- a comment naming the wrong lane
    ///         on a line with no row passed everything. This walk reads the whole file, so it cannot.
    /// @dev THE COUNT IS THE POSITIVE CONTROL. A walk that split the file wrongly and saw no lines would pass the
    ///      per-line checks over nothing, so the total number of lane-bearing lines must equal the number of table
    ///      entries. Walked per file through an external self-call for a fresh memory frame (the AccessMatrix
    ///      pattern): Clearinghouse.sol is 1,300 lines and every line is sliced and scanned for eleven lanes.
    function test_everyLaneMentionIsASite() public {
        string[5] memory files = [CLEARINGHOUSE, KEEPER_REWARDS, V2TYPES, IAUTOROLLER, IPRICESOURCE];
        uint256 total;
        for (uint256 i; i < files.length; ++i) {
            total += this.assertLaneMentionsAreSites(files[i]);
        }
        assertEq(total, _sites().length + _prose().length, "every lane-bearing line is exactly one table entry");
    }

    /// @dev External so {test_everyLaneMentionIsASite} can give each file its own memory frame. Returns the number
    ///      of lane-bearing lines in `file`. Not meant to be called from outside the test.
    function assertLaneMentionsAreSites(string memory file) external view returns (uint256 mentions) {
        Site[] memory sites = _sites();
        Prose[] memory prose = _prose();
        bytes memory src = bytes(vm.readFile(file));
        uint256 start;
        for (uint256 end; end <= src.length; ++end) {
            if (end != src.length && src[end] != 0x0a) continue;
            string memory line = _slice(src, start, end);
            start = end + 1;
            string[] memory found = _lanesOnLine(line);
            if (found.length == 0) continue;
            ++mentions;
            // Which table entries anchor on THIS line, and which lanes they vouch for. Bounded by every entry
            // anchoring here at once with three lanes each, which cannot happen, so the array is never short.
            string[] memory vouched = new string[](sites.length + 3 * prose.length);
            uint256 n;
            for (uint256 i; i < sites.length; ++i) {
                if (!_sameString(sites[i].file, file) || !_contains(line, sites[i].anchor)) continue;
                vouched[n++] = _manifestLaneOf(sites[i].signature);
            }
            for (uint256 i; i < prose.length; ++i) {
                if (!_sameString(prose[i].file, file) || !_contains(line, prose[i].anchor)) continue;
                for (uint256 j; j < prose[i].signatures.length; ++j) {
                    vouched[n++] = _manifestLaneOf(prose[i].signatures[j]);
                }
            }
            require(n != 0, string.concat("lane mention with no table entry in ", file, ": ", line));
            for (uint256 i; i < found.length; ++i) {
                bool ok;
                for (uint256 j; j < n; ++j) {
                    if (_sameString(found[i], vouched[j])) {
                        ok = true;
                        break;
                    }
                }
                require(
                    ok, string.concat("line names ", found[i], " that no entry vouches for, in ", file, ": ", line)
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev The manifest lane recorded for `signature`, read out of `.targets` by scanning the raw JSON. Scanned
    ///      rather than addressed by JSON path because the keys are Solidity signatures: parentheses and commas are
    ///      not addressable path segments. The first match wins; the signatures used here that appear under more than
    ///      one contract (`setOracle`, `setKeeperRewards`) carry the same lane in every one, which
    ///      {test_manifestIsUnambiguousForTheSignaturesUsed} asserts rather than assumes.
    function _manifestLaneOf(string memory signature) internal view returns (string memory) {
        bytes memory json = bytes(manifestJson);
        bytes memory needle = bytes(string.concat('"', signature, '"'));
        uint256 at = _indexOf(json, needle, 0);
        require(at != type(uint256).max, string.concat("signature not in roles.v8.json: ", signature));
        uint256 colon = _indexOf(json, bytes(":"), at + needle.length);
        uint256 open = _indexOf(json, bytes('"'), colon + 1);
        uint256 close = _indexOf(json, bytes('"'), open + 1);
        return _slice(json, open + 1, close);
    }

    /// @notice Every signature this file maps is recorded with ONE lane wherever the manifest mentions it.
    /// @dev Without this, `_manifestLaneOf`'s first-match scan would be an assumption instead of a fact.
    function test_manifestIsUnambiguousForTheSignaturesUsed() public view {
        Site[] memory sites = _sites();
        for (uint256 i; i < sites.length; ++i) {
            bytes memory json = bytes(manifestJson);
            bytes memory needle = bytes(string.concat('"', sites[i].signature, '"'));
            string memory first = _manifestLaneOf(sites[i].signature);
            uint256 at = _indexOf(json, needle, 0);
            while (at != type(uint256).max) {
                uint256 colon = _indexOf(json, bytes(":"), at + needle.length);
                uint256 open = _indexOf(json, bytes('"'), colon + 1);
                uint256 close = _indexOf(json, bytes('"'), open + 1);
                assertEq(
                    _slice(json, open + 1, close),
                    first,
                    string.concat("manifest gives two lanes for ", sites[i].signature)
                );
                at = _indexOf(json, needle, at + needle.length);
            }
        }
    }

    /// @dev The human phrase a lane's `.delaysS` entry must print as: "no delay" for 0, otherwise "<n> h".
    function _delayPhrase(string memory lane) internal view returns (string memory) {
        uint256 seconds_ = vm.parseJsonUint(manifestJson, string.concat(".delaysS.", lane));
        if (seconds_ == 0) return "no delay";
        return string.concat(vm.toString(seconds_ / 1 hours), " h");
    }

    /// @dev The whole line of `file` that contains `anchor`, or "" when the anchor is absent.
    function _lineContaining(string memory file, string memory anchor) internal view returns (string memory) {
        bytes memory src = bytes(vm.readFile(file));
        uint256 at = _indexOf(src, bytes(anchor), 0);
        if (at == type(uint256).max) return "";
        uint256 start = at;
        while (start > 0 && src[start - 1] != 0x0a) --start;
        uint256 end = at;
        while (end < src.length && src[end] != 0x0a) ++end;
        return _slice(src, start, end);
    }

    /// @dev Which of the manifest's lanes appear on `line`. Longer names are matched first so that a line naming
    ///      MARKET_FEE_MANAGER does not also report FEE_MANAGER, which is a substring of it.
    ///      `rest` is a COPY: `bytes(line)` aliases the caller's memory and {_blank} writes into it, so without the
    ///      copy every lane on the caller's line came back as spaces -- harmless to the delay check, fatal to the
    ///      one lane-bearing anchor and to any failure message that prints the line (T-OP-015).
    function _lanesOnLine(string memory line) internal view returns (string[] memory) {
        string[] memory hits = new string[](lanes.length);
        uint256 n;
        bytes memory rest = bytes(string.concat(line, ""));
        string[] memory ordered = _byDescendingLength(lanes);
        for (uint256 i; i < ordered.length; ++i) {
            if (_indexOf(rest, bytes(ordered[i]), 0) != type(uint256).max) {
                hits[n++] = ordered[i];
                rest = bytes(_blank(string(rest), ordered[i]));
            }
        }
        string[] memory out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = hits[i];
        }
        return out;
    }

    function _byDescendingLength(string[] memory xs) internal pure returns (string[] memory out) {
        out = new string[](xs.length);
        for (uint256 i; i < xs.length; ++i) {
            out[i] = xs[i];
        }
        for (uint256 i; i < out.length; ++i) {
            for (uint256 j = i + 1; j < out.length; ++j) {
                if (bytes(out[j]).length > bytes(out[i]).length) {
                    string memory t = out[i];
                    out[i] = out[j];
                    out[j] = t;
                }
            }
        }
    }

    /// @dev `haystack` with every occurrence of `needle` overwritten by spaces, so a second lane can be searched for
    ///      without re-finding the first (or a substring of it).
    function _blank(string memory haystack, string memory needle) internal pure returns (string memory) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        uint256 at = _indexOf(h, n, 0);
        while (at != type(uint256).max) {
            for (uint256 k; k < n.length; ++k) {
                h[at + k] = 0x20;
            }
            at = _indexOf(h, n, at + n.length);
        }
        return string(h);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return _indexOf(bytes(haystack), bytes(needle), 0) != type(uint256).max;
    }

    function _has(string[] memory xs, string memory x) internal pure returns (bool) {
        for (uint256 i; i < xs.length; ++i) {
            if (_sameString(xs[i], x)) return true;
        }
        return false;
    }

    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _indexOf(bytes memory haystack, bytes memory needle, uint256 from) internal pure returns (uint256) {
        if (needle.length == 0 || haystack.length < needle.length) return type(uint256).max;
        for (uint256 i = from; i + needle.length <= haystack.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return type(uint256).max;
    }

    function _slice(bytes memory src, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = src[start + i];
        }
        return string(out);
    }
}
