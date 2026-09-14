# Review scope

> **Status, 2026-09-13 (branch `redesign/a2-own-strikes-2026-09-13`).** There is no external audit
> and none is planned (owner decision D14). This document is the scope of the INTERNAL review that
> stands behind the contracts and the description of the code for anyone who reads it looking for
> bugs: what is in and out, what we believe is true of the code and where, what the tests prove and
> do not, and where we think the code is weakest. It was rewritten for the 2026-09-13 redesign
> (write on fill, no registry, the stranded-claim state machine, split payout legs, honest NAV);
> every line number, size and count in it was re-derived on this branch after the redesign landed
> (`git log` names the commits). Earlier revisions of this file, written for an external
> engagement that did not happen, are in the history.

The redesign in one paragraph (README "Write on fill", SECURITY.md §0): `rollOpen(optionId)` ARMS a
Valorem option type the keeper created and writes nothing; every listing is a `PARTIAL_RESTRICTED`
Seaport 1.6 order whose zone is the vault; Seaport calls the vault's `authorizeOrder` before any
transfer on every fulfilment path, and that hook writes exactly the filled contracts into Valorem;
`validateOrder`, after the transfers, reverts the fill unless the vault's option balance is back at
its pre-fill baseline. The vault never holds an unsold option token, so `written == sold` by
construction. The Overcall registry, the venue fee item, EIP-1271, `writeMore`,
`invalidateStaleListing` and the price-cut listing budget no longer exist. A `rollClose` whose
Valorem redeem reverts STRANDS the claim instead of bricking the vault.

> **Paths and commits.** This file lives in leekzor/callhouse-contracts and every path in it
> resolves from that repository's root (`src/`, `test/`, `script/`, `docs/`, `lib/`,
> `foundry.toml`). A path followed by (leekzor/callhouse) lives in the app repository (keeper,
> indexer, web, ops and the project-wide docs), which mounts this repository as a git submodule at
> `contracts/`. Commit hashes are this repository's. The contracts were moved here from a monorepo
> with `git subtree split`; nothing below cites a pre-split hash.

It does not repeat the architecture or the accounting. Read [ACCOUNTING.md](ACCOUNTING.md) (the
money maths, the stranded-claim state, the thirteen invariants) and [SECURITY.md](../SECURITY.md)
(the threat model, the properties enforced in bytecode, the 2026-09-12 review and the 2026-09-13
audit with fixes) first. `docs/ARCHITECTURE.md` (leekzor/callhouse) §2 has the trust boundaries and
`ops/addresses.json` (leekzor/callhouse) the address book; neither has been re-read for this
revision and both predate the redesign.

Nothing is deployed to mainnet. This is a pre-deployment review of one deployable bytecode plus its
two linked libraries.

---

## 1. Purpose

**What a reviewer is asked to do.**

1. Read the seven in-scope Solidity files in §3: one deployable contract (`Vault`), the three
   abstract bases it inherits (`Distributor`, `AdapterValorem`, `AdapterSeaport`), the two `public`
   libraries linked into it and reached by `DELEGATECALL` (`ValoremLib`, `SeaportOrderLib`), and
   the `internal` library that holds the compiled-in caps (`Policy`). 1,397 nSLOC. The properties
   to attack are in §5.
2. Read the deploy path for configuration mistakes: `script/Deploy.s.sol`, `script/DeployClear.s.sol`,
   `script/Configure.s.sol`, `script/HandoverAdmin.s.sol`, `script/Verify.s.sol`, the runbook
   `docs/DEPLOY.md`, and the role topology in `ops/safes.md` (leekzor/callhouse; not re-read for
   this revision).
3. Check each integration assumption we make about the third-party contracts we do not ask anyone
   to audit (§4) against their verified source or bytecode. The contracts are theirs; the
   assumptions are ours.

**Commit.** This document describes the tree at the "docs: redesign" commit on branch
`redesign/a2-own-strikes-2026-09-13`, whose code is identical to `13dbd4d` ("harden: invariants,
sizes, scripts, fork tests") except for NatSpec. `git status --porcelain` is empty there. Reproduce
every figure in §6 and §8 from the commit, not from this document.

**Access.** First command after checkout: `git submodule update --init --recursive`
(`lib/openzeppelin-contracts` and `lib/forge-std` are submodules; nothing builds without them).
The canonical ABI, including every event and custom error, is generated from `out/` (§8 "ABIs flow
one way"); the app repository's copies predate the redesign until its pin is bumped (SECURITY.md
§5 item 4).

**Not asked for.** A re-audit of Valorem Clear, Seaport 1.6, USDG or the Stock Token. Gas
optimisation. Review of the keeper, indexer or web code beyond the note in §4; they are not yet
ported to write on fill.

**Reporting.** `security@callhouse.finance` (SECURITY.md §6). The contracts are unaudited and a
report is a favour, not a claim.

---

## 2. System overview and trust model

Callhouse is one non-upgradeable vault on Robinhood Chain (chain id 4663) running a weekly
covered-call strategy on one Robinhood Chain Stock Token, NVDA
(`0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, 18 decimals, non-rebasing). Depositors put in the
Stock Token and receive 18-decimal ERC-20 shares (`cNVDA`). Once a week the keeper creates an
out-of-the-money option type on Valorem Clear (`newOptionType` is permissionless) and calls
`rollOpen(optionId)`; the vault reads the tuple back from the clearinghouse and ARMS it, writing
nothing, if it is an option type on our asset and USDG with a one-token lot, exercise at least an
hour out, a window of at least a day, a tenor of at most 21 days, the engine fee off or accepted,
the oracle live and the strike inside the OTM band with both bounds. The keeper then proposes a
`PARTIAL_RESTRICTED` Seaport 1.6 order with the vault as offerer AND zone, selling up to the vault's
capacity for USDG in one consideration item; the vault checks every field against its own state,
records the hash and calls `seaport.validate`, so an empty signature fills. On every fill Seaport
calls the vault's `authorizeOrder` before any transfer: the hook checks the order is the live
listing, the phase is Listed and writes are not halted, re-runs the clock, fee, oracle, band floor,
premium floor and size gates at live spot, and writes exactly the filled contracts into Valorem
(opening the cycle's claim on the first fill, topping it up afterwards); Seaport moves the freshly
minted tokens to the buyer and pays the premium to the vault; `validateOrder` reverts the fill
unless the vault's option balance is back at its pre-fill baseline. During the exercise window
buyers may exercise inside Valorem; the vault sees this only by reading its claim position. After
expiry `rollClose` (keeper first, anyone one hour later) redeems the claim, harvests every unit of
USDG that arrived (premium plus any strike proceeds), takes a protocol fee on the premium only (5%
at launch, capped at 20% in bytecode), credits the rest to holders through a per-share index, and
settles a batched redeem queue. A week with no fill has no claim: the close skips the redeem. A
close whose redeem reverts strands the claim and still reaches Idle. A queue made while the vault is
flat can be settled by anyone with `settleQueue`, and a stranded claim redeemed by anyone with
`retryStrandedClaim`.

Two ledgers, kept apart on purpose (ACCOUNTING.md §1): the share price tracks only the Stock Token
(`max(balance + locked − reserved, 0)`). It never marks the short call, never reads a price feed
in the settlement path, and never sees USDG. Yield is a separate USDG claim. Instant
`redeem`/`withdraw` work only while the vault is flat and not stranded; the rest of the week exits
go through `queueRedeem`/`completeRedeem`. Deposits close at the cycle's exercise timestamp.

The one-sentence model (SECURITY.md §1): **no off-chain component can transfer a token out of the
vault, but the keeper chooses the option type and the price the vault sells at.** A fully
compromised keeper key cannot move a token, but it can arm the lowest strike the band admits and
sell the week's calls at the policy floor to itself: about 1.1% of sold notional per week at
launch policy and 50% implied volatility, about 2.2% for a bootstrap admin that first loosens
policy (SECURITY.md §3). Under write on fill that is the whole bound: there is no unsold inventory
to write to the cap and leave unlisted.

| Key | Holder | Can | Cannot |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | At launch: the deployer key (bootstrap phase). After `HandoverAdmin.s.sol`: the admin Safe, 2-of-3 | `setPolicy` inside the `Policy.validate` caps; `setFeeRecipient` (non-zero); `setDepositCap` (unbounded, can close deposits); `setMaxPriceAge` in [1 hour, 7 days]; `acceptValoremFee`; `haltWrites` and `unhaltWrites`; grant/revoke `KEEPER_ROLE` and `GUARDIAN_ROLE`; grant admin to another address; renounce | Move any Stock Token or USDG (there is no admin-gated transfer in the vault); upgrade; rescue or sweep to an arbitrary address; take more than 20% of harvested premium, or any fee on strike proceeds (the exclusion is in bytecode); sell inside 1% OTM; widen staleness past 7 days; set utilisation above 99.85%. **No timelock on any admin action.** Worst case: never a token transfer, but value: `setPolicy` to the compiled floors, `grantRole(KEEPER_ROLE)` to itself, arm and sell to itself at the floor, about 2.2% of sold notional per week at 50% IV (SECURITY.md §3), plus 20% of whatever premium remains, routed to a recipient of its choosing |
| `KEEPER_ROLE` | Hot EOA run by `keeper/` (leekzor/callhouse) | `rollOpen(optionId)` (chooses which option type to arm, inside the arm gate); `approveListing` (proposes the whole Seaport order, at most three per cycle); `cancelListing`; `invalidateAllListings`; `rollClose` from `cycleExpiryTs` | Write anything itself (only a Seaport fill writes, and only through the vault's hook); hold option tokens or the claim; pay premium anywhere but the vault; list above strike, below the premium floor or with the strike below the band floor at live spot, past `cycleExerciseTs`, or beyond capacity; arm a type outside the band, with another asset, lot, or window; halt or unhalt; change any parameter; move a token. Worst case: a sale at the floor to a colluding buyer, about 1.1% of sold notional per week (SECURITY.md §3) |
| `GUARDIAN_ROLE` | 1-of-1 key on separate hardware | `haltWrites` (blocks `rollOpen`, `approveListing` and every fill: `authorizeOrder` refuses); `cancelListing`; `invalidateAllListings` (needs no order data) | `unhaltWrites` (stop, never start); change parameters; block deposits, instant redemption, the queue (`queueRedeem`, `settleQueue`, `completeRedeem`), USDG claims, `retryStrandedClaim`, `lockBook` or `rollClose`; move a token |
| Seaport 1.6 (the contract) | canonical address, no admin | call `authorizeOrder` and `validateOrder` on the vault (`NotSeaport` for anyone else); pull the option tokens the hook just minted under the one-time `setApprovalForAll` | make the vault write for any order but its own live listing (`NotLiveListing`: hash and offerer checked); leave a token behind (`InventoryLeftBehind`) |
| Fee recipient | Fee Safe | Receive the protocol fee through the best-effort push in `rollClose` or the permissionless `sweepFee()` (both via `_tryPayFee`, Vault L1610) | Holds no role; nothing else |
| Deployer | EOA running `Deploy.s.sol` | Fix every immutable at construction (asset, USDG, clearinghouse, Seaport, feed, conduit key); choose the one `admin` the constructor grants `DEFAULT_ADMIN_ROLE` to (Vault L421). **Launch plan: `admin` = the deployer's own address** | A wrong immutable is unfixable without a redeploy. The zone is not a parameter: it is the vault. Leaves the admin role only through `HandoverAdmin.s.sol` |
| Anyone | — | `deposit`, `mint`, `redeem`, `withdraw`, `queueRedeem`, `completeRedeem`, `claimUsdg`, `claimUsdgTo`, ERC-20 transfers; `lockBook` after `cycleExerciseTs`; `rollClose` after `cycleExpiryTs + 1 hour`; `sweepFee`; `settleQueue` while `Idle` with shares queued; `retryStrandedClaim` while stranded; buying through any Seaport fulfil function; writing the same option id on Valorem and exercising | Make the vault write outside a fill of its own listing; settle a queue outside `Idle`; be assigned more than the vault sold |

Third parties that hold no role but have power over the vault: the Stock Token issuer, the USDG
issuer, the clearinghouse `feeTo` and the chain operator. SECURITY.md §3 has a row for each with
the verified powers; §4 below states what we assume about each.

---

## 3. In scope

| File | nSLOC | Purpose | Externally callable surface |
|---|---:|---|---|
| `src/Vault.sol` | 740 | The deployed contract: shares, deposits and the deposit gate, the phase machine, the arm, the two Seaport zone hooks (where the vault writes), listings, the close with the stranded-claim path, the retry, harvest, the redeem queue and flat settlement, the reserve haircut, admin | 41 external or public functions declared here (23 state-changing incl. `authorizeOrder`, 18 view/pure incl. `validateOrder`) plus the constructor, plus the inherited ERC-20, AccessControl, Distributor and adapter surfaces |
| `src/Distributor.sol` | 110 | Abstract ERC-20 base: the 1e27-scaled USDG accrual index, settle-on-transfer, claims, the balance checkpoint and the payout clamp | `claimUsdg`, `claimUsdgTo`, `claimableUsdg`, `usdgOwed`, 7 auto-getters; internal hooks used by Vault |
| `src/AdapterValorem.sol` | 57 | Abstract base: the per-cycle short position on Valorem (option id, claim id, running contract count), position views, the mint-only ERC-1155 receiver | 3 public views, 2 ERC-1155 hooks, 4 getters; `_recordWrite` reachable only through `authorizeOrder`, `_tryRedeemClaim` only through `rollClose`/`retryStrandedClaim` |
| `src/AdapterSeaport.sol` | 92 | Abstract base: one authorised listing at a time, the three-per-cycle budget, cancel/counter bump, the one-time ERC-1155 operator approval, the zone view | `seaportZone`, 3 immutable getters, 4 storage getters; internal mutators reachable only through Vault |
| `src/lib/ValoremLib.sol` | 156 | **Linked public library, DELEGATECALL.** The arm gate (`open`), the fill gate and write (`writeOnFill`), the low-level redeem with the gas guard (`tryRedeemClaim`), the spot read, the oracle-pause probe, three never-reverting position views | `open` (view), `writeOnFill`, `tryRedeemClaim` (DELEGATECALL only), `spotUsdg`, `oraclePaused`, `lockedAssets`, `claimedExerciseProceeds`, `contractsAssigned` (views) |
| `src/lib/SeaportOrderLib.sol` | 125 | **Linked public library, DELEGATECALL.** Field-by-field validation of the keeper's `OrderComponents` (zone == vault, `PARTIAL_RESTRICTED`, one offer item, ONE consideration item), `getOrderHash`, `validate`, hash-checked `cancel` | `approve`, `cancel` (DELEGATECALL only), `toParameters` (pure) |
| `src/Policy.sol` | 117 | Internal pure library, inlined: the hard caps, OTM band, premium floor, utilisation and count caps, fee split, oracle normalisation | None external; 11 internal pure functions and 8 constants |
| **Total** | **1,397** | | |

nSLOC is what remains after stripping every `/* … */` block (all NatSpec), `//` comments and
blank lines; the same seven files are about 3,230 physical lines, so more than half the text is
comment. All seven files are `pragma solidity 0.8.28`. `Distributor`, `AdapterValorem` and
`AdapterSeaport` have no bytecode of their own.

**Why the two linked libraries matter.** `ValoremLib` and `SeaportOrderLib` are `public`
libraries: deployed as their own contracts and linked into the Vault runtime (8 link sites:
`SeaportOrderLib` at 2, `ValoremLib` at 6, in `out/Vault.sol/Vault.json` `linkReferences`).
Every call into them is a `DELEGATECALL`, so inside them `address(this)` is the vault and they
have full access to its storage and balances. That is required (Valorem mints the claim NFT to
`msg.sender` and `redeem` reverts for anyone else; Seaport accepts `validate` and `cancel` only from
the offerer), but it also means a mis-linked or substituted library is a total-compromise vector,
and `ValoremLib` holds BOTH gates: a substituted `ValoremLib` could skip every arm and fill check.
The extraction predates the discovery that chain 4663 allows 98,304 B of code (README item 1); it
is kept because it works and is verified. Treat adapter plus library as one trust unit each,
verify that the library holds no storage and writes none, confirm Solidity's library
call-protection makes direct `CALL`s to the non-view functions revert, and, at deploy, verify the
link targets embedded in the deployed Vault runtime (`Verify.s.sol` does, reading the count from
`linkReferences`) and that both libraries are verified on Sourcify separately.

**Interfaces.** `src/interfaces/` (`IValoremClear.sol`, `ISeaport.sol` with `IZone` and
`ZoneParameters`, `IStockToken.sol`, `IChainlinkFeed.sol`, `IERC1155Minimal.sol`) are
hand-transcribed subsets of third-party ABIs. They are in scope as statements of what we assume
about those contracts, not as code. `IValoremClear.sol`'s header states its provenance (a copy of
the interface Overcall transcribed from upstream `6436c82`, comments changed); diff it against
`valorem-labs-inc/clear` at `6436c823` yourself. `IOvercallRegistry.sol` is gone.

**Mocks and fixtures.** `src/mocks/` (`MockClear`, bucketed and upstream-faithful, with a
differential test against the real bytecode in `test/unit/MockClearDiff.t.sol`; `MockSeaport`,
1.6 hook order, checked against the real runtime in `test/unit/Fixtures.t.sol`; `MockStockToken`
with pause, blocklist, `adminBurn`, oracle pause and multiplier; `MockERC20` with pause, freeze on
sender/recipient/spender, wipe and burn-from; `MockFeed`) are out of scope as code but matter for
how much the unit suite proves. `test/fixtures/` holds the real Clear artifact
(`valorem-labs-inc/clear` @ `6436c823`, solc 0.8.16) and the 4663 Seaport 1.6 and
ConduitController runtimes; `test/helpers/RealClearBase.sol` and `RealSeaportBase.sol` deploy or
etch them, and every AF-01/AF-02 regression, `VaultRealSeaport.t.sol` and the invariant suite's
`MockClearDiff` run against them.

**Scripts, in scope for configuration review only.** `script/Deploy.s.sol` fixes every chain-4663
address as a constant (each overridable by env), installs `Policy.launchDefaults()` through the
constructor, sets `MAX_PRICE_AGE = 4 days` and `LAUNCH_DEPOSIT_CAP = 20e18`, passes `ADMIN` (if
set, else `SAFE_ADMIN`) as the constructor's `admin` and `SAFE_FEE` as fee recipient, prints a
warning when that admin has no code, and runs `_preflight` (asset 18 and USDG 6 decimals; Clear
`feeBps() == 15`, `feesEnabled() == false`, ERC-1155; `seaport.information()` version `1.6` and the
canonical ConduitController; feed `answer > 0`, `updatedAt > 0`, `decimals() == 8`). There is no
registry preflight and no zone parameter. `script/DeployClear.s.sol` (optional) deploys our own
`ValoremOptionsClearinghouse` from the vendored artifact under `script/artifacts/` (asserted
identical to the test fixture by `Fixtures.t.sol`), with `CLEAR_FEE_TO` as `feeTo` and Overcall's
URI generator by default, and asserts `feeBps() == 15`, `feesEnabled() == false`, the wiring and
ERC-1155 support. `Configure.s.sol` grants `KEEPER_ROLE` and `GUARDIAN_ROLE` from `ADMIN_PK`
(refusing a key without admin) or writes a Safe Transaction Builder batch. `HandoverAdmin.s.sol`
moves admin to the Safe in two runs (`grant`, then `renounce` refused until the Safe has executed a
transaction after the grant). `Verify.s.sol` is read-only and reverts if any check fails (63
checks bootstrap-unconfigured, 69 bootstrap-configured, 72 safe phase with the owner set pinned,
71 without; `docs/DEPLOY.md`): vault and both libraries byte for byte against `out/` with link
sites (count from `linkReferences`), immutables and a library's own address word masked and each
checked separately; every immutable including **`seaportZone() == address(vault)`**, `conduitKey ==
0`, `transferApprovalTarget == seaport` and the ERC-1155 approval on Clear; the Seaport 1.6 zone
interface advertised and EIP-1271 not; the dependencies: `seaport.information()` version 1.6 and
the canonical controller, the Seaport runtime `extcodehash` equal to the vendored 4663 runtime,
Clear `feeBps == 15` with the switch off or accepted, token decimals; policy field by field; roles
for the phase; the Safes; a fresh state. `script/rehearse-deploy.sh` runs both admin paths on an
anvil fork started with `--code-size-limit 98304` (it probes for the flag and refuses without it),
our own Clear on path A and Overcall's on path B, with negative checks (swapped libraries and a
flipped byte fail Verify; renounce before the Safe has acted is refused; a renounced key is refused;
the executor refuses a non-anvil node). `test/unit/Smoke.t.sol`
`test_verifyScript_acceptsAByteForByteDeployment` runs Verify's bytecode section in the test tree.

Please check: that no constant is wrong for chain 4663 (Appendix); that the preflight cannot pass
against a clearinghouse whose `write` or `redeem` semantics differ from upstream `6436c823` (it
checks only `feeBps`, the switch and ERC-1155; the fork suite and `Verify`'s Seaport hash do the
rest); that the Safe batch calldata grants exactly the two roles; that `HandoverAdmin.s.sol` cannot
leave the vault without an admin or with the key still admin after a successful renounce; that the
bootstrap phase's risk is stated correctly in §2 and `docs/DEPLOY.md`; and whether `Verify.s.sol`'s
bytecode comparison is sound (masking exactly the link and immutable references, and nothing else).

### 3.1 `Vault.sol`

**Purpose.** The only deployed contract. `Vault is ERC20, AccessControl, ReentrancyGuard,
Distributor, AdapterValorem, AdapterSeaport`. ERC-4626-like, deliberately not compliant. A
four-state phase machine `Idle → Listed → Exercisable → Settling → Idle` (`Settling` is transient
inside `rollClose`; `rollClose` also accepts `Listed`) gates deposits, instant redemption and the
queue, with one extra Idle sub-state, **stranded** (`isStranded()`, L497: `phase == Idle &&
claimKey != 0`), that only a failed redeem can produce.

**External surface (line numbers at the commit in §1).**

- Views: `decimals()` L435 (always 18); `totalAssets()` L477 = `max(balance + _lockedForNav() −
  reservedAssets, 0)`, USDG excluded, where `_lockedForNav` L486 is `lockedAssets()` or
  `lockedAssets() × strandedRemainingWad / 1e18` while stranded; `isStranded()` L497;
  `idleAssets()` L502; `convertToShares`/`convertToAssets` L508–L522 (virtual offset +1/+1);
  `previewDeposit` (floor) L524, `previewMint` (ceil) L528; `previewRedeem`/`previewWithdraw`
  L535/L540 return 0 unless `canRedeemInstantly()` L550 (`phase == Idle && contractsWritten ==
  0`; a stranded vault keeps `contractsWritten`, so instant redemption is off while stranded);
  `maxDeposit` L560 and `maxMint` L600 (0 whenever `_depositRefused()` L591–L597, else
  `depositCap − totalAssets()` saturating); `previewCompleteRedeem` L993 (owed balances, the
  pending entry's pro-rata assets after the reserve haircut, its per-entry USDG through
  `_entryUsdg` L1037, and any redeemed stranded-claim share folded in the same order as the
  payout); `spotUsdg()` L1547; `uiMultiplier()` L1574 (display only, 1e18 fallback);
  `supportsInterface` L1696 (ERC1155Receiver, the Seaport 1.6 `IZone` interface, AccessControl;
  NOT EIP-1271); public storage getters for phase, policy, the cycle snapshot, reserves, queue
  state, strand state (`strandGen`, `lastResolvedGen`, `strandedRemainingWad`, `strands`,
  `epochStrandWad`, `epochStrandGen`, `owedStrandWad`, `owedStrandGen`), listing state and
  immutables. `_queueAccDebt`, `_epochAccUsdgPerShare`, `_fillBaseline` and `_fillArmed` are
  private.
- Depositor paths, all `nonReentrant`: `deposit` L628 and `mint` L649 (`_requireDepositPhase`
  L690, which is `_depositRefused()`: phase Idle or Listed; in Listed `block.timestamp <
  cycleExerciseTs`; no claim with unclaimed exercise proceeds; not stranded; `balance >=
  reservedAssets`; one selector `DepositsClosed` for all five; cap checked on `totalAssets() +
  assets`; `_checkpointHarvest()` before `_mint`); `redeem` L701 and `withdraw` L716 (`UseQueue`
  unless flat; burn before transfer); `queueRedeem` L746 (every phase; moves no tokens; settles a
  prior epoch into owed balances, settles the owner's USDG accrual, records the reward debt,
  escrows the shares); `completeRedeem` L780 → `_completeRedeem` L784 (settles the owner's entry
  out of a closed epoch, `_settleEpochEntry` L821, staging any stranded-claim share
  `_stageStrandShare` L870 and materialising a redeemed one `_materializeStrand` L882 /
  `_strandSlice` L906, then `_payoutOwed` L940–L964: the asset leg after `_haircut` L971 by
  `safeTransfer`, the USDG leg by `_tryTransfer` L980 with `UsdgLegDeferred` on failure; a call
  with nothing but a blocked USDG leg reverts `UsdgLegBlocked`).
- Roll paths: `rollOpen(optionId)` L1063–L1092 (`KEEPER_ROLE`, `nonReentrant`; Idle; not halted;
  `claimKey == 0` else `StillStranded`; `ValoremLib.open` (§3.3); then `cycleNumber++`, snapshot
  `optionId`/`cycleExerciseTs`/`cycleExpiryTs`/`cycleStrikeUsdg`, `_resetListingBudget`, phase
  Listed, `RollOpen(number, optionId, 0, strike)`; NOTHING WRITTEN); **`authorizeOrder(ZoneParameters)`**
  L1139–L1185 (`nonReentrant`; `msg.sender == seaport` else `NotSeaport`; `zp.orderHash ==
  listingHash != 0 && zp.offerer == vault` else `NotLiveListing`; Listed; not halted; the
  transient baseline `_fillBaseline`/`_fillArmed` L1110–L1111 snapshotted once per transaction;
  `gross = listingGrossUsdg / listingAmount × zp.offer[0].amount`, exact because divisibility was
  enforced at approval; `ValoremLib.writeOnFill` with `sizingAssets = totalAssets()`, `reserved =
  reservedAssets`, `written = contractsWritten`, `claimId = claimKey`; `_recordWrite`; returns the
  selector); **`validateOrder(ZoneParameters)`** L1197–L1203 (view; `NotSeaport`; `clear.balanceOf(vault,
  optionId) == _fillBaseline` else `InventoryLeftBehind`); `approveListing` L1218–L1240
  (`KEEPER_ROLE`, Listed, not halted; capacity `= Policy.maxContracts(totalAssets()) −
  contractsWritten`; `_approveListing` (§3.4); then `_requireOracleLive` and, through
  `_listingFloors` L1565, `cycleStrikeUsdg >= strikeBand(spot).min` and `gross >= minPremium(spot,
  amount)` as an early refusal; the fill gate is the line of defence); `cancelListing` L1243 and
  `invalidateAllListings` L1253 (`KEEPER_ROLE` or `GUARDIAN_ROLE`, no phase or halt gate);
  `lockBook` L1265 (permissionless from `cycleExerciseTs`, invalidates any live listing);
  `rollClose` L1292–L1336 (keeper from `cycleExpiryTs`, anyone from +1 hour; phase → Settling;
  invalidate a live listing; read `contractsAssigned()`; if `claimKey == 0` forget `optionId`,
  else `_tryRedeemClaim` and on failure `strandGen++`, `strandedRemainingWad = 1e18`,
  `ClaimStranded`; `RollClose`; `_harvest(usdgFromAssignment)`; `_settleQueue()`; phase → Idle);
  `retryStrandedClaim` L1352–L1380 (anyone; `NotStranded` unless stranded; `_tryRedeemClaim`, on
  failure `StillStranded`; records `strands[gen]`, moves the queue's `1e18 − strandedRemainingWad`
  share of both legs into `reservedAssets` and `usdgReservedForQueue`, marks that USDG accounted,
  `StrandedClaimRecovered`, then `_harvest` on the live shares' USDG); `settleQueue` L1400–L1405
  (anyone; Idle; `queuedShares != 0`; `_checkpointHarvest` then `_settleQueue`).
- Harvest and settlement: `_accrueHarvest(feeFree)` L1426–L1438 (`gross = balance −
  usdgAccounted`, `fee = splitHarvest(gross − feeFree)`, net to the index); `_checkpointHarvest`
  L1447 (passes 0); `_harvest` L1457–L1473 (passes `usdgFromAssignment`, then `_tryPayFee`, then
  emits); `_settleQueue` L1482–L1525 (`_takeAccrued(vault)`, `_epochAccUsdgPerShare[epochId] =
  accUsdgPerShare`, `payoutAssets = q × (idleAssets() + 1) / (totalSupply() + 1)`, and while
  `claimKey != 0` the epoch's `strandedRemainingWad × q / totalSupply()` share with
  `EpochStrandShare`; burn the escrow; record the epoch; reserve).
- Fee and admin: `sweepFee` L1601 and `_tryPayFee` L1610–L1626 (permissionless, always the stored
  `feeRecipient`, raw-call best effort, clamped to balance, state touched on success only);
  `haltWrites` L1635 (guardian or admin); `unhaltWrites` L1644, `setPolicy` L1649,
  `setFeeRecipient` L1655, `setDepositCap` L1661, `setMaxPriceAge` L1670 / `_setMaxPriceAge` L1674,
  `acceptValoremFee` L1685 (all admin). `writesHalted` is checked in `rollOpen`, `authorizeOrder`
  and `approveListing` and nowhere else.
- Constants: `MIN_PRICE_AGE = 1 hours`, `MAX_PRICE_AGE_CEIL = 7 days` (L92–L93); the window bounds
  live in `ValoremLib` (§3.3). Constructor L400–L428 takes one `Config` struct (L385), grants
  `DEFAULT_ADMIN_ROLE` to `c.admin` and nobody else, installs `launchDefaults()`, and calls
  `_approveOptionTransfers` once.

**ERC-4626 deviations, all deliberate.** (1) Does not inherit `IERC4626`; no `maxWithdraw` or
`maxRedeem`. (2) `previewRedeem`/`previewWithdraw` return 0 whenever the queue is the only path.
(3) `maxDeposit`/`maxMint` return 0 in any state where a deposit would revert and are measured on
`totalAssets()` including collateral locked in Valorem. (4) `redeem`/`withdraw` revert `UseQueue`
unless flat and not stranded; there is no ERC-7540 request interface. (5) A queued exit can pay a
mix of Stock Token and USDG, plus a later share of a stranded claim. (6) Yield is not in the share
price, so `convertToAssets` understates economic value. (7) `decimals()` is hard-coded 18; the
virtual offset is +1/+1. (8) Deposits are also blocked by a timestamp, a live-assignment probe, the
stranded state and the reserve. (9) `Withdraw` is emitted only on the instant path; queue exits
emit `CompleteRedeem`/`QueueEntrySettled`/`QueueSettled`/`StrandShareSettled`/`ReserveHaircut`/
`UsdgLegDeferred`.

**External dependencies and what we assume.** Valorem Clear (§3.3 and §4), Seaport 1.6 (§3.4 and
§4), USDG as a plain 6-decimal ERC-20 whose `balanceOf` delta is the harvest signal (any USDG
donated to the vault is harvested and fee'd; a pause, freeze, wipe or burn-from is tolerated by the
best-effort fee push, the split payout legs, the stranded-claim path and the clamped claims), the
Stock Token as non-rebasing with raw `balanceOf` and no transfer hooks (`uiMultiplier()` and
`oraclePaused()` probed by `staticcall` with graceful fallback; a blocklist or pause stops only the
token-moving legs; an `adminBurn` is absorbed by the NAV formula, the deposit gate and the
haircut), the Chainlink feed as a gate only (`answer > 0`, `updatedAt` within `maxPriceAge`; no
`roundId`/`answeredInRound` check; no sequencer feed exists on 4663; `block.timestamp −
updatedAt` panics on a future `updatedAt`), and OpenZeppelin 5.7.0 `ERC20`, `AccessControl`,
`ReentrancyGuard`, `SafeERC20`, `Math.mulDiv`. `DEFAULT_ADMIN_ROLE` is assumed honest;
`KEEPER_ROLE` is assumed compromisable. The protocol fee is charged on premium only: `rollClose`
passes the USDG measured across the claim redeem into `_accrueHarvest(feeFree)` and the fee is
`floor((gross − feeFree) × protocolFeeBps / 10000)`, saturating at 0 (P-26).

**Focus:** §5 A.1–A.7, B.8–B.12, C.13–C.16, E.20–E.24.

### 3.2 `Distributor.sol`

**Purpose.** Abstract ERC-20 base holding the USDG index (MasterChef pattern, 1e27 scale), with
the settle hooked into `ERC20._update` so accrual survives transfers, mints and burns;
`claimUsdg()`/`claimUsdgTo(address)`; `usdgDust` and `usdgUnallocated` carried forward;
`usdgAccounted` as the balance checkpoint; every payout clamped to `_usdgAvailableForHolders()`,
which Vault overrides (L1530) to `balance − usdgReservedForQueue − pendingFeeUsdg`, saturating.

**External surface.** `claimUsdg()` L161 and `claimUsdgTo(address)` L166 (permissionless, **not**
`nonReentrant`, CEI only through `_claimUsdg` L171); `claimableUsdg` L110 (not clamped, can
overstate by the rounding drift); `usdgOwed()` L247 (saturating, informational). Internal hooks:
`_distributeUsdg` L131, `_settle` L199, `_update` L208 (settles both parties, then `super`),
`_settleAccount` L216, `_usdgAvailableForHolders` L222 (virtual), `_takeAccrued` L230 (escrow
accrual swept into an epoch, clamped), `_debitUsdgOut` L255 (saturating), `_markUsdgAccounted`
L261. Vault's `_update` L447 is `override(ERC20, Distributor)` and only calls `super`.

**Dependencies and assumptions.** USDG has no transfer hook into sender or recipient (a
before-transfer hook re-entering `deposit`/`rollClose` between `_debitUsdgOut` and the balance
update would double-count the outgoing claim as harvest). USDG is a facet proxy whose upgrade is
behind a 24 h timelock and whose pause/freeze/wipe/burn-from are instant (§4). OpenZeppelin 5
`_update` semantics: every mint/burn/transfer routes through it.

**Invariants to hold.** `accUsdgPerShare` never decreases; per distribution `credited + new
usdgDust == pot`; settle-before-move on both sides at pre-change balances; zero-supply
distributions park the pot in `usdgUnallocated`; every outflow is `min(accrual, available)`;
`usdgAccounted <= usdg.balanceOf(vault)` with zero tolerance (`invariant_usdgBooksBalance`);
`_accrued` is never reset on burn; `claimUsdg` reverts `NothingToClaim` on a zero accrual or a zero
clamp; `totalUsdgClaimed` moves in lockstep with actual outflow. A USDG wipe of the vault breaks
`usdgAccounted <= balance` until the next harvest re-anchors it (accepted, §7).

**Focus:** §5 A.3, A.4, B.8.

### 3.3 `AdapterValorem.sol` and `lib/ValoremLib.sol`

**Purpose.** The adapter holds the per-cycle short position (`optionId`, `claimKey`,
`contractsWritten` as a raw `uint112` running count, which under write on fill is also the count
SOLD; never the 1e18-scaled Valorem scalar), the position views and the mint-only ERC-1155
receiver; the library holds every Valorem call and both gates.

*The arm gate*, `ValoremLib.open` (L132–L161, `view`; from `rollOpen`), in order:
`clear.tokenType(id) == Option` (`NotAnOptionType`; a claim id or unknown id is refused here,
since `option()` ignores the claim key and a claim id would otherwise pass every tuple check and
`write` would mint into somebody else's claim); `o = clear.option(id)`: `underlyingAsset == asset`
(`OptionAssetMismatch`), `exerciseAsset == usdg` (`OptionExerciseAssetMismatch`),
`underlyingAmount == Policy.LOT` (`UnexpectedLotSize`); `exerciseTimestamp >= now + MIN_LEAD`
(1 hour, L34; `ExerciseTooSoon`); `expiryTimestamp >= exerciseTimestamp + MIN_EXERCISE_WINDOW`
(1 day, L38) and `<= now + MAX_CYCLE_TENOR` (21 days, L49) (`BadCycleWindow`); `feesEnabled() &&
!feeAccepted` (`ValoremFeeNotAccepted`); `oraclePaused(asset)` (`OraclePaused`);
`Policy.checkStrike(o.exerciseAmount, spotUsdg(feed, maxPriceAge))` with BOTH bounds
(`StalePrice`/`SpotZero`/`StrikeBelowBand`/`StrikeAboveBand`). Returns the strike and window the
vault snapshots. Nothing moves.

*The fill gate and the write*, `ValoremLib.writeOnFill` (L201–L256; from `authorizeOrder`), in
order: `block.timestamp < cycleExerciseTs` (`WriteWindowClosed`, L205); `n != 0`
(`ContractsZero`, L207); `feesEnabled() && !feeAccepted` (L209–L210); `oraclePaused` (L213);
`spot = spotUsdg(...)` (L214); `strike >= strikeBand(spot).min`, floor ONLY (`StrikeBelowBand`,
L216–L217; the ceiling is checked at arm alone, decision D9); `collateral = n × LOT` (L219); `fee =
collateral × feeBps / 10_000` with a floor of 1 when the switch is on (L224–L227); `gross >=
minPremium(spot, n) + fee × spot / LOT` (`PremiumBelowFloorAtFill`, L230–L231; AF-04);
`Policy.checkContracts(written + n, sizingAssets)` (L235; `sizingAssets` is `totalAssets()`, idle
plus locked less reserved); `forceApprove(clear, collateral + fee)` (L241); `claimId =
clear.write(claimId == 0 ? optionId : claimId, n)` (L247), `WriteReturnedNoClaim` on 0,
`WriteReturnedWrongClaim` when a top-up returns any other id (L248–L249); `forceApprove(clear, 0)`
(L250); `asset.balanceOf(vault) >= reserved` (`ReserveBreached`, L254–L255; AF-04). The tuple, lot
and window are NOT re-read: they are immutable in Valorem once armed.

*The redeem*, `ValoremLib.tryRedeemClaim` (L319–L335; from `_tryRedeemClaim`): snapshots both
balances, makes `clear.redeem(claimKey)` as a raw `call`, and on failure reverts `RedeemOutOfGas`
when `gasleft() <= gasBefore / 63` (L329: EIP-150 leaves a starved callee's caller at most 1/64,
so a caught revert with that little left is starvation, not a refusal) and otherwise returns
`ok == false` with nothing changed; on success returns the measured deltas (checked subtraction).
`oraclePaused` (L264–L268) and `spotUsdg` (L273–L277) are the probe and the feed read. Three views
(`lockedAssets` L346, `claimedExerciseProceeds` L358, `contractsAssigned` L372) return 0 when
`claimKey == 0`, clamp negative `int256` to 0, return 0 on any revert of `position()`/`claim()`,
and `contractsAssigned` divides `amountExercised` by 1e18.

**Adapter surface.** `lockedAssets()` L85 (feeds `totalAssets()`), `claimedExerciseProceeds()`
L94 (the clock-independent deposit gate), `contractsAssigned()` L99 (event only),
`onERC1155Received`/`onERC1155BatchReceived` L173/L178 (return the magic selector only when
`msg.sender == clear && from == address(0)`, i.e. a MINT; otherwise `0x00000000` without
reverting, which makes the donor's own transfer revert), getters `clear`, `optionId`, `claimKey`,
`contractsWritten`. `_recordWrite` L116 is reached only from `authorizeOrder` and **adds** `n` to
`contractsWritten`, setting `claimKey` to what the library returned (unchanged on a top-up, by the
library's check); `_tryRedeemClaim` L138 only from `rollClose` and `retryStrandedClaim`, reverts
`NoOpenClaim` when `claimKey == 0`, and clears `claimKey`/`optionId`/`contractsWritten` ONLY on
success. Both write storage after the external call and rely on Vault's `nonReentrant` (and, for
the mint callback, on the receiver hook being a view).

**Dependencies and assumptions about Valorem Clear** (`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`
by default, or our own instance; bytecode-identical to `valorem-labs-inc/clear` @ `6436c823`, §4):
`newOptionType` is permissionless and the tuple it records is immutable; `tokenType(id)` is
`Option` for an option id, `Claim` for a claim id, `None` otherwise; `option(id)` returns the tuple
for an option id and the SAME tuple for a claim id of that type (hence the `tokenType` check);
`write(optionId, n)` pulls exactly `n × underlyingAmount` (+ fee on top when `feesEnabled`) via
`transferFrom` and mints `n` option ERC-1155 plus one claim NFT to `msg.sender` in one batch,
invoking `onERC1155BatchReceived`; `write(claimId, n)` requires the caller to hold that claim,
pulls the same, mints only option tokens (single hook), returns the claim id it was given, and
records the tranche as a claim index in the option type's CURRENT bucket; every write before the
first exercise lands in bucket 0 and a write after an exercise opens a new bucket; assignment
within a bucket is pro rata by amount written and the bucket draw uses `settlementSeed ==
optionKey`, fixed forever; `redeem(claimId)` reverts for non-owners and before expiry, burns the
claim, and pushes assigned strike USDG then unassigned underlying to `msg.sender`, each leg only if
non-zero, with no writer-side fee; `position(claimId)`/`claim(claimId)` sum over every claim index
and reflect partial assignment live; `claim().amountExercised` is `count × 1e18`; exercise has no
callback into the writer; `feesEnabled()`/`feeBps()`/`feeTo()` are the only admin surface
(`onlyFeeTo`; `feeBps` is the constant 15). All of this is exercised against the real bytecode by
`test/unit/MockClearDiff.t.sol`, the AF-01/AF-02 regressions and the fork suite.

**Invariants to hold.** P-03, P-04, P-05, P-06, P-21, P-22, P-23, P-27, P-33, P-34 in §5, plus:
all three claim-backed views are 0 when flat and 0 on a Valorem revert, so `totalAssets()`,
`maxDeposit()` and `deposit` never revert because of Valorem; `collateral` is an exact integer;
`contractsWritten` cannot overflow because `checkContracts` bounds the sum by the uint64 cap
first; `|lockedAssets() − (contractsWritten × 1e18 − claim.amountExercised)| <= 1 wei` while a
claim is open (per-index flooring in upstream), and 0 when flat (`invariant_reservesAreReal`,
`invariant_phaseSanity`).

**Focus:** §5 A.1, A.2, B.9, B.10, C.17, D.19, E.20, E.21, E.22.

### 3.4 `AdapterSeaport.sol` and `lib/SeaportOrderLib.sol`

**Purpose.** The vault is the Seaport 1.6 offerer AND the zone of every listing. The adapter
records one authorised order hash at a time (`listingHash`, `listingGrossUsdg`, `listingAmount`,
`listingsThisCycle`), caps authorisations at `Policy.MAX_LISTINGS_PER_CYCLE = 3` per cycle (every
`approveListing` spends one, cancelled or not; a listing is sized to capacity and Seaport tracks
the fraction filled, so a relist is a reprice), cancels or counter-bumps, exposes
`seaportZone() == address(this)` (L119), and grants a one-time
`clear.setApprovalForAll(transferApprovalTarget, true)` from the constructor (`_approveOptionTransfers`
L221; Vault L425). The constructor (L97–L111) resolves the approval target: Seaport itself for a
zero conduit key (launch), else the conduit from `ConduitController.getConduit`, falling back to
Seaport if it does not exist. The library validates the keeper's `OrderComponents` against a
`Checks` struct (L41) populated entirely from vault state, obtains the hash from
`seaport.getOrderHash`, calls `seaport.validate` so the order fills with an empty signature
(`approve` L97–L110), and cancels only an order whose recomputed hash equals `listingHash`
(`cancel` L113–L121). The economic floors are deliberately not in the library; Vault checks both
through `_listingFloors` after `approve` returns, and the fill gate re-derives them at its own
spot. There is no `isValidSignature`.

**Adapter surface.** Immutables `seaport`, `conduitKey`, `transferApprovalTarget`.
`_approveListing` L139–L173 (`PreviousListingLive` L148; `TooManyListings` when
`listingsThisCycle >= 3` L150–L151; library shape checks; then records state, i.e. writes after
`seaport.validate`; `ListingApproved.seq` is `listingsThisCycle` after the approval, unique per
cycle); `_cancelListing` L182–L188; `_invalidateAllListings` L194–L200 (`seaport.incrementCounter()`,
from `invalidateAllListings`, `lockBook` and `rollClose` whenever a listing is live);
`_clearListing` L202; `_resetListingBudget` L209 (only `rollOpen`).

**The shape every authorised order must have** (`_checkOffer` L144–L177, `_checkConsideration`
L182–L213, `_checkTiming` L216–L227): `offerer == address(this)` (`BadOfferer`); **`zone ==
address(this)`** (`BadZone`); `conduitKey == conduitKey` (`BadConduitKey`); `zoneHash == 0`
(`BadZoneHash`); **`orderType == PARTIAL_RESTRICTED`** and only that (`BadOrderType`: restricted so
the hooks run, partial so a buyer takes what they want; `CONTRACT` orders are a different
mechanism); exactly one offer item (`BadOfferLength`), `ERC1155` on the clearinghouse with
`identifier == optionId` (`BadOfferItemType`/`BadOfferToken`/`BadOfferIdentifier`), `startAmount
== endAmount` (`DutchAuctionNotAllowed`), `0 < amount <= capacity` (`OfferAmountZero`/
`OfferExceedsCapacity`); **exactly one consideration item** (`BadConsiderationLength`), `ERC20`
USDG with identifier 0 and no ramp, recipient the vault (`BadVaultRecipient`); `gross % amount ==
0` (`PremiumNotDivisibleByOrderSize`); `unitPrice <= strike` when `strike != 0`
(`UnitPriceExceedsStrike`); `startTime <= now` (`ListingStartsInFuture`), `endTime > now`
(`ListingAlreadyEnded`), `endTime <= cycleExerciseTs` (`ListingOutlivesExercise`; Seaport's
`endTime` is exclusive, and the fill gate enforces the same edge); `counter ==
seaport.getCounter(vault)` (`BadCounter`). Salt is unchecked. The keeper retains only salt, timing
within the window, price within [floor, strike], size within [1, capacity], and when to cancel or
relist. There is no minimum unit price beyond the premium floor: the old 20-base-unit floor
existed only so the venue's 5% leg was non-zero.

**Dependencies and assumptions about Seaport 1.6** (`0x0000000000000068F116a894984e2DB1123eB395`,
§4): `getOrderHash` is the canonical EIP-712 struct hash including the counter and the zone;
`validate` accepts an offerer-submitted order with an empty signature, reverts on a cancelled hash
and makes no callback into the offerer; every later fill of a validated order skips signature
verification, so EIP-1271 is never consulted for the vault's listings; `cancel` permanently marks
the hash when called by the offerer; `incrementCounter` jumps by a quasi-random amount, orphaning
every prior hash; **on every fulfilment path (`fulfillOrder`, `fulfillAdvancedOrder`,
`fulfillAvailableOrders`, `fulfillAvailableAdvancedOrders`, `matchOrders`, `matchAdvancedOrders`,
`fulfillBasicOrder`) a restricted order's `authorizeOrder` runs before any transfer and before the
order status is updated, with `ZoneParameters.offer[0].amount` already scaled to the fraction being
filled, and `validateOrder` runs after all transfers of the call; a revert in `authorizeOrder`
skips the order inside `fulfillAvailable*` and reverts the fill everywhere else; a status update
that fails after a successful `authorizeOrder` (e.g. the same order occurring twice and overfilling
its remainder) reverts the whole transaction; the zone itself is the one caller exempt from the
hooks** (integrations/seaport.md; the vault never calls a fulfil function). Seaport's own transient
reentrancy guard is set for the whole fill, so a buyer's `onERC1155Received` cannot reach Seaport,
and hooks are sequential, never nested. `TSTORE`/`TLOAD` execute on 4663 (fork
`test_fork_transientStorageIsLiveOnChain4663`). `InexactFraction` requires each amount to be
divisible by the order size. All of this is exercised against the real 4663 runtime by
`test/unit/VaultRealSeaport.t.sol` and `test/unit/Fixtures.t.sol`, and live by the fork suite.

**Invariants to hold.** P-16, P-31, P-32, P-33 in §5, plus: every clearing path zeroes
`listingHash`; `listingsThisCycle` increments exactly once per authorisation, never exceeds 3, and
is reset only by `rollOpen`; cancel targets only the recorded hash; after
`_invalidateAllListings` the counter is strictly greater; `listingHash` is always cleared before
the vault enters Exercisable or Settling; all Seaport parameters are immutable.

**Focus:** §5 B.10, B.11, C.13, C.18, E.20.

### 3.5 `Policy.sol`

**Purpose.** Pure, storage-free `internal` library, inlined; no separate deployment. It is the
only thing between the admin and a policy that sells at-the-money calls, takes a 100% fee or
writes the reserve.

**Surface (internal, with the entry point that reaches each).** `validate` L112 (constructor,
`setPolicy`): `minOtmBps >= 100`, `maxOtmBps <= 2500`, `minOtm <= maxOtm`, `minPremiumBps >= 10`,
`maxUtilizationBps <= 9985`, `protocolFeeBps <= 2000`, `maxContractsCap != 0`. `launchDefaults`
L129: `{300, 1200, 40, 9500, 500, 50}`. `strikeBand`/`checkStrike` L146/L157 (`checkStrike` from
`ValoremLib.open`, both bounds; `strikeBand`'s lower bound from `ValoremLib.writeOnFill` and from
Vault `_listingFloors`): inclusive `[spot × (1 + minOtm), spot × (1 + maxOtm)]`, floor-rounded,
`SpotZero` on 0. `minPremium`/`checkPremium` L171/L181 (`minPremium` from `writeOnFill` and
`_listingFloors`; `checkPremium` is tests-only): gross `>= spot × contracts × minPremiumBps /
10000`, floor-rounded, on the gross of the one consideration item. `maxContracts` L195
(`approveListing`'s capacity) and `checkContracts` L202 (`writeOnFill` with `N = written + n` and
`idle = totalAssets()`): `1 <= N <= maxContractsCap` and `N <= floor(idle × maxUtil / 10000 /
1e18)`. `splitHarvest` L217 (`_accrueHarvest`): fee floored, `(0, 0)` on a zero input; the vault
passes the fee-bearing amount and computes `net = gross − fee` itself. `normalizeSpot` L236
(`ValoremLib.spotUsdg`): `SpotZero` on `answer <= 0` or a result that rounds to 0; rescales
`feedDecimals → 6`. Constants L45–L82: `BPS 10_000`, `MIN_OTM_FLOOR_BPS 100`, `MAX_OTM_CEIL_BPS
2_500`, `MIN_PREMIUM_FLOOR_BPS 10`, **`MAX_UTILIZATION_CEIL_BPS 9_985`** (AF-04: leaves Valorem's
15 bps fee inside the free balance), `PROTOCOL_FEE_CEIL_BPS 2_000`, `MAX_LISTINGS_PER_CYCLE 3`
(enforced in AdapterSeaport), `LOT 1e18`. `splitPremium`, `minListableUnitPrice` and
`OVERCALL_FEE_BPS` are gone with the venue fee item.

**Dependencies and assumptions.** None directly (every function is `pure`). The numbers that flow
in: the Chainlink answer and `decimals()` (re-read live on every call; a proxy phase change to a
different-decimals aggregator rescales spot silently), Valorem's `exerciseAmount` for one 1e18 lot
in USDG 6-dp (now read from Clear directly and pinned at arm), Seaport's fraction rule, USDG at 6
decimals and the asset at 18 (checked by the deploy preflight, not in code), one lot = 1e18
(refused otherwise, P-27), and USD treated as 1:1 with USDG (no depeg consideration).

**Invariants to hold.** P-01 in §5, plus: an armed call is strictly OTM at arm time for any `spot
>= 1`; the band is inclusive and at most 1 base unit lenient on the lower edge; `N × 1e18 <= idle ×
0.9985` whenever `maxUtil <= 9985`; `fee + net == input` and `fee <= 20%` of the input in
`splitHarvest`, zero fee on a zero input; `normalizeSpot` never returns 0 and never accepts a
non-positive answer; no storage, no external calls.

**Focus:** §5 A.3, A.6, A.7, C.13, C.14, C.16.

---

## 4. Out of scope, with reasons and links

Do not re-audit the dependencies. Do check our integration assumptions about each, listed in §3
and summarised here.

**Valorem Clear** (`ValoremOptionsClearinghouse`; Overcall's instance at
`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`, or one of our own from `script/DeployClear.s.sol`).
The 4663 instance was deployed by Overcall's key (deploy tx `0xacc4c4f9…1034`, block 59,378,584,
constructor `feeTo = 0xdAe7…0782`), is verified `exact_match` on Sourcify to
`valorem-labs-inc/clear` @ `6436c823f560af493af119d6148fb3237037aca4` (solc 0.8.16, 200 runs,
`london`, no via-IR), and is the artifact vendored under `test/fixtures/valorem/` and
`script/artifacts/`. The contract is immutable: no owner, no pause, no blocklist, no proxy; `feeTo`
holds the fee switch, `setFeeTo` (no event), the URI generator and fee sweeping. **Upstream is
dormant** (last commit 2023-11-13): no patch path, bounty or incident response. Audits, from the
upstream [`audits/`](https://github.com/valorem-labs-inc/clear/tree/master/audits) folder:

| Report | Auditor | Date | Audited commit | Scope |
|---|---|---|---|---|
| [Valorem December 2022 – Zellic Audit Report](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_December_2022_%20-%20Zellic%20Audit%20Report.pdf) | Zellic | 2022-12-27 | `6c118f20` | `OptionSettlementEngine.sol`; 2 high, 1 medium, 2 low |
| [Valorem April 2023 – Zellic Audit Report](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_April_2023_-_Zellic_Audit_Report.pdf) | Zellic | 2023-04-10 (engagement Jan 2023) | `ed53af23` | `OptionSettlementEngine.sol`; 2 medium, 1 informational. Findings 3.2/3.3 (the public, fixed-seed bucket walk) were never fixed; the redesign is built on exactly that behaviour |
| [Valorem Options Smart Contract Patch Review](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_Options_Smart_Contract_Patch_Review.pdf) | Zellic | 2023-08-29 | `fe39eb73` | "changes to the expiry window and protocol fee" only |

`src/` is unchanged between `fe39eb73` and the deployed `6436c823`. The last full-scope audit was
on `ed53af23`; `ed53af23 → 6436c823` touches `ValoremOptionsClearinghouse.sol` (+64/−55) and its
interface, and whether the patch review covers all of that delta is unconfirmed. Assumptions to
confirm: §3.3, in particular `tokenType`/`option` on a claim id, `write`'s pull amount and fee
formula on a fresh claim and a top-up, `redeem`'s two-leg push order and the each-leg-only-if-
non-zero rule, bucket formation and the fixed seed, and no callback on exercise.

**Seaport 1.6** (`0x0000000000000068F116a894984e2DB1123eB395`; `information()` returns version
`1.6`, ConduitController `0x00000000F9490004C11Cef243f5400493c00Ad63`; runtime 23,981 B, codehash
pinned by `Verify.s.sol` and vendored as `test/fixtures/seaport/Seaport16.runtime.hex`). The
Etherscan-verified source is byte-identical to seaport-core v1.6.6 (`523097f`) except the 34
immutable bytes of chain id and domain separator. No admin, no proxy, no pause. **There is no
public audit specific to Seaport 1.4, 1.5 or 1.6, and none of the 1.6 `authorizeOrder` hook code.**
Published reviews: Trail of Bits (1.0/1.1, 2022), Code4rena (1.0, May 2022; 1.2, Jan 2023),
Spearbit (1.2, Feb 2023). Our reliance is on the hook order and status-update semantics stated in
§3.4, on `validate`/`cancel`/`incrementCounter`, on the fulfilment paths for a single ERC-1155
offer with one ERC-20 consideration, and on the transient reentrancy guard. All are exercised
against the vendored 4663 runtime in the test tree and against the live contract by the fork
suite; none rests on an external audit.

**USDG** (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals). Paxos's native issuance on
4663: a UUPS facet proxy with five facets. **One EOA, `0x3Af3e85f…024B`, holds effectively every
power** (integrations/usdg.md, verified by simulation at block 62,374,563): instant `pause()`
(reverts transfer, transferFrom, approve, permit and EIP-3009; not views, mint, burn, freeze or
wipe); instant `freeze`/`wipeFrozenAddress` (enforced on sender, recipient and the `transferFrom`
spender; a zero-value transfer with a frozen party reverts; 27 freezes on 4663, 0 unfreezes ever);
SupplyControl manager, able to grant itself `allowAnyMintAndBurnAddress` and burn from any
non-frozen address with no allowance; owner of the OFT wrapper; and proposer, executor and
canceller of the 24 h `TimelockController` that gates the upgrade and per-selector facet
replacement. **Earlier revisions of this document put freeze and wipe behind that timelock; they
are instant.** Source: [paxosglobal/usdg-contract](https://github.com/paxosglobal/usdg-contract)
on [paxosglobal/paxos-token-contracts](https://github.com/paxosglobal/paxos-token-contracts)
(audits: Zellic 2024-11 and 2026-02, Halborn 2025-11); the live implementation has not been
source-matched to a specific audited commit. Assumptions in scope: plain `balanceOf` semantics, no
transfer hooks, no fee-on-transfer, no rebasing; pause, freeze (of the vault, Clear or Seaport),
wipe and burn-from tolerated by the best-effort fee push, the split payout legs, the
stranded-claim path and the clamped claims (§5 E.21).

**Robinhood Chain Stock Token** (NVDA, `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`; ERC-20 debt
security issued by Robinhood Assets (Jersey) Ltd; beacon proxy whose beacon is the chain-wide
`AccessControlledRegistry` shared by all 204 Stock Tokens; ERC-7201 storage; source verified
full-match on robinscan, solc 0.8.33). **No published third-party audit was found.** Verified
powers, each held by exactly one EOA with no multisig and no timelock (integrations/robinhood-
chain.md): registry-wide and per-token `pause()`; a per-address blocklist enforced on sender and
recipient; `adminBurn(from, amount)`, a bare `_burn` with **no pause and no blocklist modifier**;
`pauseOracle()`, which flips `oraclePaused()` and does not block transfers; `updateMultiplier`,
where the multiplier **can decrease and can apply immediately** and a scheduled step switches at
`effectiveAt` with no transaction and no event; `registry.upgradeTo`, re-pointing the logic of all
204 tokens at once. The prospectus adds seizure and an Issuer Redemption Option terminating the
Series on 30 calendar days' notice. Assumptions in scope: non-rebasing raw `balanceOf`, no transfer
hooks, 18 decimals, `uiMultiplier()` display-only, `oraclePaused()` a gate probed by `staticcall`
with lenient fallback, a freeze or pause stopping only token-moving legs, and a burn absorbed by
the NAV formula, the deposit gate and the haircut (AF-05). `MockStockToken` models the pause, the
blocklist, `adminBurn`, the oracle pause and the multiplier.

**Chainlink RHNVDA/USD** (`0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`, the Standard
`AggregatorProxy`, 8 decimals, heartbeat 86400 s, 0.5% deviation, `us_equities_24/5`, category
Custom; integrations/chainlink.md). Gate and display only, never in settlement. Chainlink's docs
state the feed publishes **no updates, heartbeat included, while markets are closed**, and honours
the Stock Token's `oraclePaused()` by freezing at the last good value. Observed: intra-week gaps
up to 21.04 h, weekends ~52 h, a Friday holiday 76.09 h, Labor Day 78.24 h; the frozen weekend
value is the last print BEFORE the close, up to a few hours early; the feed does NOT re-print at a
multiplier `effectiveAt` (≈11.8 h lag at NVDA's 2026-09-10 step); pre-launch rounds 1–24 were
mis-scaled by 1e8 and nothing on chain would precede a recurrence. No L2 sequencer uptime feed
exists on 4663. The proxy's owner is a 4-of-9 Safe that can rotate the aggregator or install a read
ACL (writes then fail closed). Assumptions in scope: `answer > 0`, `updatedAt` within
`maxPriceAge` (4 days at launch, [1 hour, 7 days] in bytecode), `decimals()` re-read live.

**Robinhood Chain (4663).** Arbitrum Nitro, ArbOS 61, a single sequencer run by RHDA, LLC with
**compliance filtering** (a transaction touching a restricted address can be dropped; burns to
`0x0` exempt; whether force-included transactions are also filtered depends on optional components
whose status on 4663 is unknown); force inclusion through the L1 Delayed Inbox after **4 days**;
L1 governance by a 7-of-8 Security Council with no delay and a 6-of-8 proposer Safe behind a 7-day
timelock with permissionless execution. **The contract code limit is 98,304 B**, verified by
create probes (98,304 B deploys, 98,305 B fails `max code size exceeded`); `foundry.toml` sets
`code_size_limit = 98304` and the Vault runtime is 25,470 B. `TSTORE`/`TLOAD`/`MCOPY` execute;
`BLOBBASEFEE` does not (the build emits no blob opcodes). `block.number` is the L1 number; the
contracts use timestamps only. Nothing in the vault can defend against the chain; SECURITY.md §3
discloses it.

**OpenZeppelin Contracts v5.7.0** (`lib/openzeppelin-contracts`): `ERC20`, `AccessControl`,
`ReentrancyGuard`, `SafeERC20`, `Math`, `IERC20`. **forge-std v1.16.2**: tests only.

**Keeper, indexer, web** (`keeper/`, `indexer/`, `web/` (leekzor/callhouse); the site
(leekzor/callhouse-site)). No money authority: no key they hold can move a token, and the vault
re-validates every field the keeper proposes. Out of scope, and **not yet ported to write on
fill** (SECURITY.md §5 item 4): they still build `PARTIAL_OPEN` orders with two consideration
items, POST to Overcall, and read `writeMore`/`contractsRemaining`. Until they land the vault can
be operated only by hand. If a reviewer finds an order the vault accepts that an honest keeper
would never build, that is a finding against the vault.

---

## 5. Properties a reviewer should try to break

Each is a falsifiable statement with its code location at the commit in §1. SECURITY.md §2 is the
prose version. Removed properties keep their numbers as "retired" so cross-references in the
history still resolve.

| # | Property | Where |
|---|---|---|
| P-01 | No `policy` value outside the hard caps (`minOtmBps >= 100`, `maxOtmBps <= 2500`, `minOtm <= maxOtm`, `minPremiumBps >= 10`, `maxUtilizationBps <= 9985`, `protocolFeeBps <= 2000`, `maxContractsCap != 0`) can ever be stored | `Policy.sol` L112; `Vault.sol` L417–L419, L1650 |
| P-02 | `deposit`/`mint` revert `DepositsClosed` and `maxDeposit`/`maxMint` return 0 on exactly the same five conditions: phase not Idle or Listed; Listed with `block.timestamp >= cycleExerciseTs` (whether or not anyone called `lockBook`); a claim with unclaimed exercise proceeds; a stranded claim; `asset.balanceOf(vault) < reservedAssets` | `Vault.sol` L560, L591–L597, L690 |
| P-03 | While `claimKey != 0 && claimedExerciseProceeds() != 0`, or while stranded, no share can be minted by any path | `Vault.sol` L594; `ValoremLib.sol` L358 |
| P-04 | Nothing is armed whose `exerciseTimestamp < now + 1 hour`, whose window is under 1 day, or whose expiry is over `now + 21 days`; and nothing moves at arm regardless | `ValoremLib.sol` L34, L38, L49, L147–L151; `Vault.sol` L1063–L1092 |
| P-05 | The option type armed always has `tokenType == Option`, `underlyingAsset == asset`, `exerciseAsset == USDG`, `underlyingAmount == 1e18`; a claim id, a foreign id or a type on another asset is refused by `rollOpen`; every later fill writes THAT id or tops up THAT claim and nothing else | `ValoremLib.sol` L138–L143, L246–L249; `Vault.sol` L1148, L1168–L1169 |
| P-06 | No arm and no fill happens while `clear.feesEnabled()` is true unless `valoremFeeAccepted`; when the fee is on and accepted, the fill's premium floor is raised by `fee × spot / 1e18`, the approval is `collateral + fee`, and the allowance is zero afterwards | `ValoremLib.sol` L156, L209–L210, L224–L231, L241, L250 |
| P-07 | No state of `feeRecipient` or of USDG can make `rollClose` revert through the fee leg; `sweepFee()` always pays the stored recipient, never the caller | `Vault.sol` L1467, L1601–L1626 |
| P-08 | No holder claim or queue take ever exceeds `_usdgAvailableForHolders() = balance − usdgReservedForQueue − pendingFeeUsdg` | `Distributor.sol` L171, L230; `Vault.sol` L1530 |
| P-09 | `usdgAccounted <= usdg.balanceOf(vault)` always (absent an issuer wipe, §7), and every USDG outflow debits it | `Distributor.sol` L255, L261; `Vault.sol` L958, L1375, L1431, L1623 |
| P-10 | Rounding favours the vault: `deposit` floors shares, `mint` ceils assets, `redeem` floors assets, `withdraw` ceils shares; +1/+1 virtual offset on all four and on the queue's epoch pot; redeeming the whole supply, instantly or through the queue, pays at most `totalAssets()` | `Vault.sol` L508–L544, L1497 |
| P-11 | The share price never marks the short call to market and no price feed is read in the settlement path: `totalAssets() = max(balance + navLocked − reservedAssets, 0)`, USDG excluded; the feed is read only by the arm gate, the fill gate, `_listingFloors` (from `approveListing`) and the `spotUsdg()` view | `Vault.sol` L477–L494, L1542–L1571; `ValoremLib.sol` L160, L214, L273 |
| P-12 | The phase machine moves only `Idle → Listed` (`rollOpen`), `Listed → Exercisable` (`lockBook`), `Listed/Exercisable → Settling → Idle` (`rollClose`); a fill never changes the phase; `Idle && !stranded ⇒ contractsWritten == 0 && claimKey == 0 && lockedAssets() == 0`; `Idle && stranded ⇒ claimKey != 0 && contractsWritten > 0`; no cycle opens over a stranded claim | `Vault.sol` L1064, L1087, L1267–L1270, L1302, L1335; `invariant_phaseSanity` |
| P-13 | Instant `redeem`/`withdraw` succeed only when `phase == Idle && contractsWritten == 0` (so never while stranded); previews return 0 otherwise | `Vault.sol` L535–L554, L702, L717 |
| P-14 | The deposit cap is measured on `totalAssets()` (locked collateral included, reserved excluded), never on raw balance | `Vault.sol` L567–L569, L632–L633, L658–L659 |
| P-15 | A share minted after USDG arrived can never claim any of it: `_checkpointHarvest()` runs before every `_mint` (and before `settleQueue` settles) and makes no external call other than `usdg.balanceOf` | `Vault.sol` L637, L653, L1403, L1426–L1438, L1447 |
| P-16 | The vault authorises at most one Seaport order at a time, at most three per cycle, only in the shape listed in §3.4 (zone == vault, `PARTIAL_RESTRICTED`, one offer item on the armed id, ONE consideration item of USDG to the vault, size within capacity, ending by `cycleExerciseTs`), and only with the strike not below the band floor and the gross not below the premium floor at live spot | `SeaportOrderLib.sol` L97–L110, L144–L227; `AdapterSeaport.sol` L139–L173; `Vault.sol` L1218–L1240 |
| P-17 | retired (registry gate); replaced by P-05 and P-33 | — |
| P-18 | `maxPriceAge` can only ever be in [1 hour, 7 days] | `Vault.sol` L92–L93, L1674–L1680 |
| P-19 | The guardian can stop but never start: `haltWrites` is guardian-or-admin, `unhaltWrites` admin-only, and a halt blocks only `rollOpen`, `approveListing` and `authorizeOrder` (every fill) | `Vault.sol` L1065, L1146, L1220, L1635–L1647 |
| P-20 | Liveness never depends on the keeper: `lockBook` is permissionless from `cycleExerciseTs`, `rollClose` from `cycleExpiryTs + 1 hour`, `sweepFee` always, `settleQueue` whenever `Idle` with shares queued, `retryStrandedClaim` whenever stranded; `queueRedeem` works in every phase and under an issuer freeze; `rollClose` reaches Idle whatever Valorem's `redeem` does | `Vault.sol` L1265–L1273, L1292–L1300, L1352–L1356, L1400–L1405, L1601, L746 |
| P-21 | The ERC-1155 receiver hooks accept only `msg.sender == clear && from == address(0)` (mints), so no third party can put an option token or a claim NFT into the vault | `AdapterValorem.sol` L173–L185 |
| P-22 | No allowance to the clearinghouse survives a fill; the approval equals exactly what upstream `write` pulls | `ValoremLib.sol` L241–L250 |
| P-23 | `optionId`, `claimKey`, `contractsWritten` are non-zero together after the first fill and, unless stranded, zero together after a successful redeem; a top-up leaves `optionId` and `claimKey` unchanged and adds exactly `n` to `contractsWritten`; `_tryRedeemClaim` reverts `NoOpenClaim` when flat and clears nothing on failure | `AdapterValorem.sol` L116–L121, L138–L154; `ValoremLib.sol` L246–L249 |
| P-24 | Checks-effects-interactions in every money path: burn before transfer in `redeem`/`withdraw`, owed and reserves zeroed before transfer in `_payoutOwed`, `phase = Settling` before any external call in `rollClose`; every state-changing user entry point is `nonReentrant` except ERC-20 transfers, `claimUsdg`/`claimUsdgTo` and the view `validateOrder` | `Vault.sol` L709, L724, L947–L960, L1302 |
| P-25 | Governance cannot **transfer** principal by any path, including `setFeeRecipient` plus the 20% fee ceiling (the fee base excludes strike proceeds), `setDepositCap`, `setPolicy`, role grants, or renouncing. A statement about token movement only: `setPolicy` to the compiled floors plus a `KEEPER_ROLE` grant lets it sell calls below fair value to itself, which C.16 and SECURITY.md §3 quantify | `Vault.sol` L1635–L1690, L1426–L1438 |
| P-26 | The protocol fee is charged only on premium. On `rollClose`, `Harvest.feeUsdg == floor((Harvest.grossUsdg − RollClose.usdgFromAssignment) × protocolFeeBps / 10000)` (saturating at 0); on a checkpoint `Harvest`, `feeUsdg == floor(grossUsdg × protocolFeeBps / 10000)`; on a stranded claim's retry the queue's USDG share is marked accounted before the harvest and the live shares' USDG is harvested fee-free | `Vault.sol` L1332, L1375–L1379, L1426–L1438; `ValoremLib.sol` L319–L335; `Policy.sol` L217 |
| P-27 | No option type with `underlyingAmount != 1e18` is ever armed, so the per-token OTM band, utilisation, band floor and premium floor always measure the contract actually sold | `ValoremLib.sol` L143; `Policy.sol` L82; `test/unit/VaultLotSize.t.sol` |
| P-28 | Each queue entry's USDG payout equals the index growth over its own time in escrow, and the epoch pays out exactly its pot (ACCOUNTING.md §5): `usdgOut == min(floor((shares × epochIndex − debt) / 1e27), usdgRemaining)` for every entry settled while others remain, the last claimant takes `usdgRemaining`; `previewCompleteRedeem` returns exactly what `completeRedeem` would pay in the same state, haircut and stranded shares included | `Vault.sol` L746–L778, L821–L868, L993–L1061; `test/unit/VaultQueueFairness.t.sol` |
| P-29 | `settleQueue` runs only in `Idle` with `queuedShares != 0`, moves no token, prices the epoch at `q × (idleAssets() + 1) / (totalSupply() + 1)` (which, flat and not stranded, equals `previewRedeem(q)`), and while stranded also records the epoch's `strandedRemainingWad × q / totalSupply()` share of the claim. No sequence of donations, deposits and `settleQueue` pays a queuer more than instant redemption would have | `Vault.sol` L1400–L1405, L1482–L1525; `test/unit/VaultQueue.t.sol` `test_settleQueue_*` |
| P-30 | retired (`writeMore`); replaced by P-33 | — |
| P-31 | `listingsThisCycle` increments by exactly one per `approveListing`, never exceeds 3, and is zeroed only by `rollOpen`; a cancel neither spends nor refunds a slot | `AdapterSeaport.sol` L150–L151, L167, L209–L211 |
| P-32 | retired (`invalidateStaleListing`); a listing the policy no longer admits is unfillable through the fill gate (P-33) rather than killable | — |
| P-33 | **The vault writes into Valorem only inside `authorizeOrder`, called by Seaport for the vault's own live listing, for exactly the amount Seaport is moving to a buyer in that call.** `authorizeOrder` refuses any caller but Seaport, any order whose hash is not `listingHash` or whose offerer is not the vault, any phase but Listed, a halt, a fill at or after `cycleExerciseTs`, `n == 0`, the engine fee on and unaccepted, a paused or stale oracle, `cycleStrikeUsdg` below the live band floor, a gross below the live premium floor (plus fee × spot), `contractsWritten + n` past the cap or `maxUtilizationBps` of `totalAssets()`, and a post-write balance below `reservedAssets`; `validateOrder` reverts unless `clear.balanceOf(vault, optionId)` equals the transaction's pre-fill baseline. Consequently `clear.balanceOf(vault, optionId) == 0` outside a fill, `contractsWritten` equals the contracts sold, and the vault's lifetime assignment never exceeds what it sold | `Vault.sol` L1110–L1111, L1139–L1203; `ValoremLib.sol` L201–L256; `invariant_vaultHoldsNoOptionTokens`, `invariant_assignedNeverExceedsSold`, `invariant_longSupplyIsUnexercisedCollateral`; `test/regression/AF01_UnsoldInventory.t.sol`; `test/unit/VaultRealSeaport.t.sol` |
| P-34 | **A failed claim redeem strands, never bricks, and strands fairly.** `rollClose` reaches Idle whether `clear.redeem` succeeds, reverts, or is skipped (`claimKey == 0`); a caught failure with `gasleft() <= gasBefore / 63` reverts `RedeemOutOfGas` instead of stranding; while stranded, deposits are refused, instant redemption is off, `rollOpen` reverts `StillStranded`, `lockedAssets()` still reads the claim and NAV counts only `strandedRemainingWad / 1e18` of it, every epoch that settles takes its pro-rata WAD share, and for every generation `g`: unresolved ⇒ `strandedRemainingWad + Σ epochStrandWad(g) + Σ owedStrandWad(g) == 1e18`, resolved ⇒ `Σ epochStrandWad(g) + Σ owedStrandWad(g) == strands[g].wadLeft`; `retryStrandedClaim` is permissionless, reverts `StillStranded` until Valorem lets the redeem through, and moves exactly the queue's share of both legs into the reserves; `reservedAssets == Σ epoch.assetsRemaining + Σ owedAssets + Σ strands.assetsLeft` and the USDG analogue hold with no allowance; generations resolve strictly in order; at most 1 wei of dust per owner per generation | `Vault.sol` L1292–L1380, L1482–L1525, L870–L938; `ValoremLib.sol` L319–L335; `invariant_strandSharesAreConserved`, `invariant_reservesAreReal`, `invariant_depositGateTracksTheReserve`, `invariant_phaseSanity`; `test/regression/AF02_UsdgFreezeRollClose.t.sol` |
| P-35 | **A settled redeemer's Stock Token leg is paid whatever USDG is doing, and the reserve is haircut pro rata when unbacked.** `_payoutOwed` pays the asset leg by `safeTransfer` after `_haircut` (`booked × balance / reservedAssets` when `balance < reservedAssets`, else `booked`; the fraction is invariant under collection) and the USDG leg by a raw call that on failure leaves `owedQueueUsdg`, `usdgReservedForQueue` and `usdgAccounted` untouched and emits `UsdgLegDeferred`; `previewCompleteRedeem` quotes the haircut figure; a call with nothing left but a blocked USDG leg reverts `UsdgLegBlocked`; a Stock Token pause reverts the whole call | `Vault.sol` L940–L991; `test/regression/AF03_CompleteRedeemLegs.t.sol`, `AF05_BurnShortfall.t.sol` |

The money invariants of ACCOUNTING.md §7, asserted by the stateful suite's **thirteen**
`invariant_*` functions (`test/invariant/VaultInvariant.t.sol`, `forge-config` L1600–L1603: 64
runs × depth 600, `fail-on-revert = true`):

| # | Invariant | Function |
|---|---|---|
| I-1 | `asset.balanceOf(vault) + lockedAssets() == deposited − withdrawn − assignedOut − burned` (ghosts from what callers asked and what the vault returned) | `invariant_assetConservation` L1679 |
| I-2 | USDG books balance: `usdgOwed() + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg <= balance + maxIndexRoundingDrift`; `usdgAccounted <= balance` (no allowance); `usdgReservedForQueue == Σ epoch.usdgRemaining + Σ owedQueueUsdg + Σ strands.usdgLeft` (no allowance) | `invariant_usdgBooksBalance` L1713 |
| I-3 | Per-holder USDG solvency: `Σ claimableUsdg + usdgReservedForQueue + usdgDust + usdgUnallocated + pendingFeeUsdg <= balance + maxIndexRoundingDrift` | `invariant_usdgHolderSolvency` L1766 |
| I-4 | `totalSupply() == Σ holder balances` (escrow at the vault included); `balanceOf(optionBuyer) == 0`; `queuedShares == balanceOf(vault)` (the handler never sends shares to the vault address; the contract does not forbid it, §7) | `invariant_shareAccounting` L1784 |
| I-5 | No free shares: `convertToAssets(totalSupply()) <= totalAssets()`; `Σ convertToAssets(holder) + min(reservedAssets, balance) <= balance + lockedAssets()`; `totalAssets() == max(balance + navLocked − reservedAssets, 0)` | `invariant_noFreeShares` L1802 |
| I-6 | The deposit gate tracks the reserve and the strand: `balance < reservedAssets ⇒ maxDeposit() == maxMint() == 0`; `isStranded() ⇒ maxDeposit() == 0`; `maxDeposit() != 0 ⇒ balance >= reserved, phase ∈ {Idle, Listed}, !stranded, maxDeposit() == depositCap − totalAssets()` | `invariant_depositGateTracksTheReserve` L1852 |
| I-7 | Reserves are real: `reservedAssets <= balance + burnReserveShortfall` (a shortfall originates only in a burn); `usdgReservedForQueue + pendingFeeUsdg <= usdg balance`; `reservedAssets == Σ epoch.assetsRemaining + Σ owedAssets + Σ strands.assetsLeft` (no allowance); `claimKey != 0 ⇒ claim.amountWritten == contractsWritten × 1e18`, `amountExercised <= amountWritten`, `|lockedAssets() − (amountWritten − amountExercised)| <= 1 wei`; `claimKey == 0 ⇒ lockedAssets() == 0`; `contractsAssigned() <= contractsWritten` | `invariant_reservesAreReal` L1875 |
| I-8 | **The vault holds no option tokens**: `optionId != 0 ⇒ clear.balanceOf(vault, optionId) == 0`; `claimKey != 0 ⇒ clear.balanceOf(vault, claimKey) == 1` | `invariant_vaultHoldsNoOptionTokens` L1963 |
| I-9 | **Assignment never exceeds what was sold**: `assignedOut <= totalSold × 1e18` over the whole run; `contractsAssigned() <= contractsWritten`; `claimKey != 0 ⇒ claim.amountExercised <= contractsWritten × 1e18`, with the third-party writer steering the bucket and exercising far more than the vault sold (the pre-redesign handler, writing at arm, fails this in the first in-the-money week) | `invariant_assignedNeverExceedsSold` L1984 |
| I-10 | For every id ever armed: `clear.optionSupply(id) == clear.unexercisedContracts(id) == balanceOf(buyer, id) + balanceOf(thirdPartyWriter, id) + balanceOf(vault, id)` and `balanceOf(vault, id) == 0`, past cycles included | `invariant_longSupplyIsUnexercisedCollateral` L2011 |
| I-11 | Phase sanity: `contractsWritten > 0 ⇒ phase != Idle || isStranded()`; `Idle && !stranded ⇒ claimKey == 0, lockedAssets() == 0, canRedeemInstantly(), strandGen == lastResolvedGen`; `Idle && stranded ⇒ claimKey != 0, contractsWritten > 0, !canRedeemInstantly(), maxDeposit() == 0, strandGen == lastResolvedGen + 1, strandedRemainingWad <= 1e18`; `phase != Idle ⇒ strandGen == lastResolvedGen`; never Settling between calls | `invariant_phaseSanity` L2037 |
| I-12 | Stranded-claim shares are conserved per generation (the two equalities in P-34) | `invariant_strandSharesAreConserved` L2073 |
| I-13 | The fee never touches strike proceeds: `protocolFeeBps` stays at `launchDefaults()`; `(usdg.balanceOf(feeRecipient) + pendingFeeUsdg) × 10000 <= premiumToVault × protocolFeeBps`, `premiumToVault` being a ghost of the vault's USDG balance change on every successful fill | `invariant_feeNeverTouchesStrikeProceeds` L2121 |

The index rounding drift is the one tolerance in the suite: `afterInvariant` (L2152) records it,
refuses a run where it reaches 1 USDG, and refuses any run that was shrunk or did not reach full
depth. Inline assertions on every successful handler call are listed in ACCOUNTING.md §7.

### Areas of concern, ranked

Deduplicated across the per-contract records. Money paths first.

**A. Loss or freeze of principal.**

1. **Live NAV read from Valorem and the deposit gate.** `totalAssets()` reads
   `clear.position(claimKey)` live (Vault L477–L494 via ValoremLib L346). A buyer's `exercise`
   collapses `lockedAssets()` in the same transaction with no callback, while the strike USDG
   stays inside the claim until `rollClose`. The defences are the `cycleExerciseTs` close, the
   `claimedExerciseProceeds() != 0` probe, the stranded refusal and the reserve check, all in
   `_depositRefused` (L591–L597). Try: any minting or price-quoting path that bypasses it; a
   partial assignment below one lot where `exerciseAmount` reads 0 while `underlyingAmount`
   already fell; a `position()` revert or an out-of-gas inside the try/catch that makes both reads
   0 (confirm EIP-150 leaves too little gas to finish the outer transaction once the inner
   staticcall has starved, and that `position()` gas cannot grow without bound: every fill before
   the first exercise lands in one bucket, so one claim index per bucket the vault wrote into,
   at most one per exercise); negative `int256` clamps; the fill-time `sizingAssets` reading a
   NAV that a same-block exercise then collapses (the deposit gate closes at `cycleExerciseTs`,
   the fill gate at the same instant, so no fill can coexist with an exercise; confirm the edge).
   This was the 2026-09-12 review's critical finding; attack it again.
2. **`rollClose`, the stranded path and the retry.** Vault L1292–L1380; ValoremLib L319–L335.
   `phase = Settling`, then `seaport.incrementCounter` (if a listing is live), the low-level
   redeem, harvest, queue settle, Idle. A revert in Seaport's `incrementCounter` would still brick
   the close (Seaport has no pause and no admin; say whether that is acceptable). For the redeem:
   enumerate every way `clear.redeem` can revert (USDG pause; the vault, Clear or the buyer's
   address frozen on USDG; Clear's USDG burnt; the vault blocklisted on NVDA; a registry-wide NVDA
   pause; a Clear-side revert we have not thought of) and confirm each strands rather than bricks,
   that the gas guard cannot be gamed in either direction (a legitimate refusal misread as
   starvation only costs a retry; a starvation misread as a refusal would strand a redeemable claim
   and cost nothing more than a `retryStrandedClaim`, but confirm no state is lost), and that
   `retryStrandedClaim`'s `_harvest(usdgReturned − queueUsdg)` after `_markUsdgAccounted(+
   queueUsdg)` cannot double-count or under-count when USDG also arrived from elsewhere between
   the strand and the retry (a fill cannot: the vault is Idle; a donation can). For each token
   action separately enumerate which vault functions survive: we expect `queueRedeem`, `claimUsdg`
   (unless USDG is paused), share transfers, `lockBook`, `cancelListing`/`invalidateAllListings`,
   `haltWrites`, the admin setters, `settleQueue`, `rollClose` and `retryStrandedClaim` (reverting
   `StillStranded`) to keep working, and `deposit`/`mint`, `redeem`/`withdraw`, `completeRedeem`'s
   asset leg, fills and the redeem's legs to revert or defer as documented.
3. **Queue settlement, reserves and the haircut.** Vault L746–L1061, L1482–L1525; Distributor
   L230. `payoutAssets = q × (idleAssets() + 1) / (totalSupply + 1)` before the burn with the
   escrow in the supply; USDG for the epoch from `_takeAccrued(vault)` clamped. Try: two
   uncollected epochs double-reserving; instant redemptions of the remaining supply reaching into
   `reservedAssets`; any state where the queue pays more than `previewRedeem`; the escrow accrual
   residual migrating between cohorts; re-queueing after a settled but uncollected epoch, with and
   without a staged stranded share (`_stageStrandShare` folds an older generation first; confirm
   the preview and the payout agree in every order of events); the haircut: `reservedAssets = r −
   booked` before `_haircut(booked, r)` reads the balance, the fraction's invariance under
   collection, rounding dust, and what happens when collateral returns from Valorem between two
   collections (the later claimant is paid in full and live shares bear the burn through NAV;
   confirm no path pays more than the balance); the per-entry USDG payout (P-28); shares sent
   straight to the vault address (accepted by `_update`, never burned; their accrual joins the
   escrow pot with no debt entry, so the last claimant collects it; §7).
4. **The USDG index and the clamps.** Distributor L110–L263; Vault L1530. The index over-promises
   by up to one base unit per account per distribution; the clamp is the only thing between that
   drift and an underflow. Try: a claim that pays out of `usdgReservedForQueue` or
   `pendingFeeUsdg`; carried `usdgDust`/`usdgUnallocated` consumed by a holder claim so the next
   epoch is under-backed; the saturating `_debitUsdgOut`/`usdgOwed()` hiding a real leak; an
   outflow that forgets the debit (the four outflow sites: claims Distributor L171, queue payout
   Vault L946, fee Vault L1623, and the deferred USDG leg which must NOT debit); a USDG wipe of the
   vault (balance drops below `usdgAccounted`; the next `_accrueHarvest` re-anchors; who loses).
5. **Fee sweep raw call.** Vault L1601–L1626. `pendingFeeUsdg` is clamped to the total balance,
   not to `_usdgAvailableForHolders`; "empty return equals success"; a USDG address without code
   would read as success; the `usdgAccounted` debit follows the external call. Try: paying the fee
   out of money reserved for the queue or a stranded generation's `usdgLeft`.
6. **Harvest is any USDG balance increase.** Vault L1426–L1473. Donated USDG, strike proceeds and
   premium are all distributed; premium and donations are fee'd, strike proceeds are not because
   `rollClose` and `retryStrandedClaim` pass the measured redeem into `feeFree`. Try: a donation
   that distorts the index or the fee; a deposit-then-queue sequence that captures premium landing
   between the last checkpoint and exercise; any USDG that is not strike proceeds but lands inside
   the `tryRedeemClaim` balance window and so escapes the fee; any path where `usdgFromAssignment`
   exceeds `gross` other than by saturation; the retry's `Harvest` under the stranded cycle's
   number; an off-chain reader that treats `feeUsdg / grossUsdg` as the fee rate on an assigned
   week. Confirm the late-depositor economics are intended (ACCOUNTING.md §4).
7. **Inflation and donation griefing.** Vault L508–L544, L1496. Offset +1 wei on an 18-decimal
   asset; first-depositor inflation is bounded by the donation cost
   (`test_inflationGriefIsBoundedByTheDonation`); `_settleQueue` prices with the same +1/+1 so the
   flat `settleQueue` exit cannot turn the grief into a profit; the cap counts donations; a direct
   Stock Token transfer inflates `totalAssets()` and therefore the capacity `approveListing`
   admits and the utilisation each fill passes. Weigh cost/benefit against `depositCap` and
   `ZeroShares`.

**B. Authorisation and external-call ordering.**

8. **Entry points without `nonReentrant`.** ERC-20 `transfer`/`transferFrom` (`Distributor._update`
   settles both sides), `claimUsdg`/`claimUsdgTo` (CEI only), and the view `validateOrder`. USDG
   and the Stock Token are assumed hook-free; both are proxies. Confirm on the live bytecode.
9. **CEI inverted inside the adapters and libraries, covered only by Vault's guard.**
   `_recordWrite` stores after `clear.write` has run (the mint callback into the view
   `onERC1155BatchReceived`/`onERC1155Received` fires first); `_tryRedeemClaim` clears after
   `clear.redeem`; `_approveListing` writes `listingHash` after `seaport.validate`. Confirm no path
   reaches them without `nonReentrant` and that no view can observe stale
   `claimKey`/`contractsWritten`/`phase` mid-transaction in a way that matters: in particular a
   buyer's `onERC1155Received`, which runs between `authorizeOrder` and `validateOrder` with the
   write recorded and the tokens already in the buyer's hands, can call any vault view or any
   function not guarded by Seaport's reentrancy lock (`test_buyerReenteringTheVaultMidFillIsBlocked`,
   `test_hostileContractBuyer_cannotReenterSeaportOrTheVault` cover `deposit`, `queueRedeem`,
   `settleQueue`, `claimUsdg` and Seaport; enumerate the rest).
10. **The zone hooks and Seaport's fulfilment paths.** Vault L1139–L1203; SeaportOrderLib
    L144–L227. Try: an order that passes the shape check but whose `ZoneParameters` at fill time
    differ from what the vault expects (`offer[0].amount` after fraction scaling with a
    numerator/denominator Seaport accepts; `orderHash` for an order with the same components and a
    different counter; `offerer` spoofing); the same listing occurring twice in one
    `fulfillAvailableAdvancedOrders` within and beyond the remainder (tested on the real runtime:
    within works with one baseline, beyond reverts the whole transaction); a `matchAdvancedOrders`
    whose mirror order delivers the option tokens somewhere other than the fulfiller
    (`test_matchAdvancedOrders_writesAndDeliversToTheMirrorOrdersOfferer`); `fulfillBasicOrder`
    after a partial fill; a foreign restricted order naming the vault as zone
    (`NotLiveListing`); a fill that Seaport routes through a conduit (launch has `conduitKey == 0`;
    the constructor's non-zero branch is untested in production); the transient baseline across two
    Seaport calls in one transaction (never zeroed by design: after a successful call the balance
    equals the baseline again; confirm a FAILED first call, whose state Seaport rolled back but
    whose transient writes persist, cannot leave a wrong baseline for a second call in the same
    transaction — the hook's `_fillBaseline` is written before the write and read against the
    post-transfer balance, so a rolled-back write leaves balance == baseline; check it); a fill at
    `endTime − 1` versus `cycleExerciseTs` (both enforce the same edge); the `nonReentrant` on
    `authorizeOrder` interacting with a Seaport call made from inside a vault function (the vault
    never calls Seaport's fulfil functions; `approveListing` calls `validate` and `cancelListing`
    `cancel`, neither of which runs hooks).
11. **Blanket, irrevocable operator approval on Clear.** AdapterSeaport L221; Vault L425. Covers
    the claim NFT and every future id; safety rests on Seaport requiring offerer authorisation and
    on the shape check pinning the offer to the current `optionId`, and on the vault holding no
    option tokens between fills. A non-zero conduit key would put a third-party-mutable conduit in
    that role.
12. **Linked libraries.** DELEGATECALL with full storage access; verify the eight link sites in
    the deployed runtime, library call-protection, no storage, separate verification. `ValoremLib`
    holds both gates and the redeem, so a substituted `ValoremLib` skips every check and can strand
    or steal; `SeaportOrderLib` holds the shape check, so a substituted one lets a keeper list to
    itself.

**C. Economic and governance.**

13. **Keeper discretion inside policy.** A compromised keeper can arm the lowest strike the band
    admits, list the whole capacity at exactly the floor (0.40% of spot notional at launch) to a
    colluding buyer whose fill writes immediately, or never roll. Our estimate (SECURITY.md §3):
    about 1.1% of sold notional per week at 50% IV, about 2.7% at 80%; it repeats every week nobody
    notices. Three listings per cycle bound how far the quote can be walked. Check our arithmetic,
    and say whether `haltWrites` (which now stops fills instantly) and `invalidateAllListings` are
    sufficient given that `SeaportOrderLib` refuses a future `startTime`, so a listing is fillable
    in the block it is authorised. None of the mitigations in SECURITY.md §3 is implemented.
14. **Oracle gate.** Vault L1542–L1571, ValoremLib L264–L277, Policy L236. No
    `roundId`/`answeredInRound`; staleness in days by design (4 days; the feed is dark all
    weekend and the frozen value predates the close by up to a few hours); `block.timestamp −
    updatedAt` panics on a future `updatedAt`; `decimals()` re-read live; `oraclePaused()` probed
    by `staticcall` where a non-32-byte return reads as not paused; no sequencer feed; no
    deviation check between reads; `10 ** (feedDecimals − 6)` panics for `feedDecimals >= 84`. The
    fill gate re-prices EVERY fill at live spot, so a stale listing after a rally is unfillable
    (good) and a listing after a sell-off fills at a premium that is now generous to the buyer
    relative to the band (accepted: the call is safer). Confirm the answer only ever changes which
    types and prices are armable and fillable, never settlement; assess the multiplier-step lag
    (§4 Chainlink) as a mispricing window bounded by the band.
15. **Own option types, and what the arm gate does not check.** ValoremLib L132–L161. Defended:
    a claim id or unknown id, another asset or exercise asset, a lot other than one token, an
    exercise under an hour out, a window under a day, a tenor over 21 days, the fee, the oracle,
    the band with both bounds. Not defended, by design: a type whose exercise is far out but inside
    21 days (a 20-day call sold at the 7-day premium floor is a keeper pricing error the floor does
    not scale for; say whether the floor should scale with tenor); option ids re-used across
    cycles (Valorem forbids re-creating a type, so an id can be armed twice only if it is still
    unexpired and inside the tenor); a type another party created and already wrote into (the
    vault's fills then share bucket 0 with them; under write on fill that is the priced exposure,
    P-33); `settlementSeed` steering by a third party (bounded to what the vault sold). Try any
    quantity the vault prices per token that the type can scale.
16. **Admin without a timelock, and immutability.** No upgrade, no rescue, no timelock;
    `setDepositCap` and `setPolicy` are immediate and not cycle-aware (a `setPolicy` mid-cycle
    changes the floors the NEXT fill must clear); the admin can renounce and freeze governance; a
    wrong immutable is unfixable. Say whether the `Policy` caps are "cannot rug" bounds: 1% OTM, a
    0.10% weekly premium floor, 99.85% utilisation, a fee of 20% of premium. They do not bound
    value leakage (about 2.2% of sold notional per week at the floors, SECURITY.md §3). The launch
    plan puts that power in one deployer key until the Safe handover.
17. **Valorem engine fee.** ValoremLib L224–L231, L241. Mirrors `collateral × feeBps / 10_000`
    with a floor of 1, on top of collateral, verified against the real bytecode
    (`test_fill_acceptedFeeRaisesTheFloorPullsTheFeeAndScrubsTheApproval`, `AF04_FeeSizing`);
    a mismatch would make every fill revert on allowance once the switch flips, with no upgrade.
    The fee is a NAV loss borne by depositors and priced into the buyer's floor; the only guard is
    `acceptValoremFee`. Upstream charges it on every top-up, so a week filled in `k` pieces pays it
    `k` times on `k` smaller notionals.
18. **Clearinghouse choice.** The vault is agnostic; the default is Overcall's instance, whose
    `feeTo` is an unfunded EOA that is also that venue's fee recipient. Our own instance moves the
    switch to our admin. Say whether anything in the vault depends on which instance it is, and
    whether the `DeployClear.s.sol` defaults (Overcall's URI generator) matter.

**D. Observability and test fidelity.**

19. `contractsAssigned()` integer-divides a fixed-point figure (event accuracy only). `CallsWritten`
    fires once per FILL with that fill's count and collateral; `RollOpen.contractsCount` is always
    0; `RollClose` on a stranded close reports zero legs and is preceded by `ClaimStranded`; the
    retry's `Harvest` carries the stranded cycle's number; `Harvest.grossUsdg` includes strike
    proceeds on an assigned week. An off-chain reader that misreads any of these is wrong
    (ACCOUNTING.md §2, §5, §6). Untested error paths: `WriteReturnedNoClaim` (the real Clear never
    returns 0), the catch branches of the three position views against the real Clear (they are
    reached against the mock). `MockClear` fidelity is checked by `MockClearDiff.t.sol` for bucket
    formation, pro-rata assignment and the steered draw; `MockSeaport`'s hook order by
    `Fixtures.t.sol`.

**E. Redesign surfaces (2026-09-13).**

20. **Write on fill through the zone hooks** (P-33; B.10). The premise: Seaport 1.6 calls
    `authorizeOrder` before any transfer on every path and reverts the transaction when a status
    update fails after a successful authorise. It is exercised on the vendored 4663 runtime
    (`VaultRealSeaport.t.sol`, 13 tests) and live (`test_fork_writeOnFillAgainstLiveSeaportAndClear`).
    Try to find a Seaport 1.6 path, parameter or error branch where a write happens and its sale
    does not (a token stays in the vault past `validateOrder`; `validateOrder` is skipped; an
    `authorizeOrder` succeeds and Seaport then skips the order instead of reverting), or a sale
    happens and its write does not (Seaport moves a token the vault did not mint in this call:
    impossible while the vault's balance is zero between fills, which is what I-8 and the receiver
    hook protect). Also the gas: a first fill is ~470k, a top-up ~245k (spike figures; re-measure).
21. **The stranded state machine** (P-34; A.2). Generations, WAD bookkeeping, `_stageStrandShare`
    ordering across generations, `previewCompleteRedeem` parity, the retry's harvest, the dust
    bound, the deposit and instant-redeem gates while stranded, and every redeem-failure cause in
    the AF-02 regression (USDG paused; vault frozen; Clear frozen; Clear's USDG burnt; NVDA
    blocklist of the vault in an unassigned week; control; gas ladder; re-strand with an
    uncollected earlier-generation owner; re-queue while stranded). Try: a strand followed by a
    donation, a queue and a retry in every order; a partial recovery (Valorem's `redeem` is atomic,
    so none exists; confirm); a retry while a later cycle is... impossible (`rollOpen` refuses);
    two owners in one epoch of a redeemed generation where floors leave the last one short (the
    last takes `*Left`, so never; confirm the sum of the others' floors never exceeds `*Left`).
22. **Option-type validation without a registry** (C.15). The arm gate replaces every fact the
    Overcall registry used to supply. Try a type that passes `open` and should not: `option()` on
    an id whose `tokenType` is `Option` but whose tuple was created by someone else with a strike
    exactly at the band edge; an `exerciseAmount` that is not what the keeper intended (the vault
    snapshots what Clear says, never what the keeper says); a type whose `exerciseTimestamp` is
    inside `MIN_LEAD` at arm but whose listing `endTime` is earlier still (fine: the listing must
    end by `cycleExerciseTs`); timestamp arithmetic at `uint40` bounds.
23. **No registry, no venue** (D16). Nothing in `src/` reads Overcall. Confirm no residual
    dependency (the default clearinghouse address is the only Overcall-adjacent constant, and it
    is a deploy-time choice), and that the removal of the fee item did not leave a rounding or
    minimum-price assumption behind in `SeaportOrderLib` or `Policy`.
24. **The receiver hook** (P-21). `from == address(0)` distinguishes a mint from a transfer in
    solmate's ERC-1155. Confirm upstream Clear never mints with a non-zero `from` and never
    transfers with a zero `from`, and that refusing the hook makes the sender's `safeTransferFrom`
    revert (it does in solmate: `UNSAFE_RECIPIENT`) rather than silently succeed.

---

## 6. Prior review and test evidence

**Internal adversarial review, 2026-09-12** (SECURITY.md §4): 13 surfaces, 72 raw findings, 51
surviving refutation; five rows fixed with regressions in `test/unit/VaultSecurity.t.sol`; two
more found 2026-09-13 during documentation (the one-token lot, the per-entry queue accrual) and
ten in a second pass the same day (the flat `settleQueue`, tranche writes, the pricing leak, the
stale-listing kill and five adversarial-round findings against those fixes). Everything from that
pass is in the checkpoint `25f4328`; the mechanisms the redesign removed are marked as such in
SECURITY.md §4.

**Internal audit, 2026-09-13** (SECURITY.md §4 "The 2026-09-13 audit"; `AUDIT-FINDINGS-2026-09-13.md`
in the project handoff folder): 38 agents, 20 raw findings, 5 confirmed with proofs of concept on
the checkpoint: F-01 High (unsold inventory assigned by a third party's write and self-exercise),
F-02 Medium (a USDG action bricks `rollClose`), F-03 Medium (all-or-nothing payout legs), F-04 Low
(the engine fee out of the reserve), F-05 Low (saturating NAV hides a burn). All five are fixed and
every proof of concept is a regression asserting the fixed behaviour, under `test/regression/`,
one file per finding, on the real Clear bytecode where the loss lived in Valorem. Two
plausible-unproven items are accepted (§7).

**Unit, regression and invariant tests**, all offline (`rm -rf cache/invariant && forge test
--no-match-path 'test/fork/*'`, measured 2026-09-13 on this branch: `Ran 23 test suites … 399 tests
passed, 0 failed, 0 skipped`):

| Suite | Tests | Covers |
|---|---:|---|
| `test/unit/Policy.t.sol` | 42 | Every `validate` branch incl. the 9,985 ceiling, band edges, premium floor, utilisation, harvest split, `normalizeSpot` |
| `test/unit/VaultDeposit.t.sol` | 42 | Rounding, cap semantics, the one deposit gate, previews returning 0, allowances, inflation griefing, fuzzed round-trips |
| `test/unit/VaultListing.t.sol` | 53 | One negative test per `SeaportOrderLib` revert (zone, type, one consideration item, capacity, divisibility, strike ceiling, timing, counter), the three-per-cycle budget, cancel/invalidate permissions, halt and oracle gates, the band floor and premium floor at `approveListing` |
| `test/unit/VaultRoll.t.sol` | 36 | Every arm-gate refusal (`NotAnOptionType`, asset, exercise asset, lot, `ExerciseTooSoon`, `BadCycleWindow` both ways, fee, oracle, both band bounds, `StillStranded`), `lockBook`, `rollClose` timing and permissions incl. the `claimKey == 0` close, a full OTM cycle |
| `test/unit/VaultWriteOnFill.t.sol` | 20 | The fill gate through the mock hooks: first fill opens the claim, later fills top it up, wrong claim returned, the `cycleExerciseTs` edge, band floor after a rally, ceiling not re-checked, premium floor at live spot, sizing on the total (utilisation and cap), zero, fee on and unaccepted, accepted fee raises the floor and scrubs the approval, halt, phase, `NotSeaport`, `InventoryLeftBehind`, a foreign order naming the vault as zone, hooks never call Seaport, a buyer re-entering mid-fill, the receiver refusing donations |
| `test/unit/VaultRealSeaport.t.sol` | 13 | Every real Seaport 1.6 fulfilment path against the vault on the vendored 4663 runtime: `fulfillOrder`, `fulfillAdvancedOrder` (first fill then top-ups), the `cycleExerciseTs` edge on real Seaport, a hook revert bubbling with nothing written, the same order twice in `fulfillAvailableAdvancedOrders` within and beyond the remainder (whole-tx revert), a hook revert skipping the vault's order, `matchAdvancedOrders`, `fulfillBasicOrder`, a hostile contract buyer, a foreign zone order, cancel and counter bump, a full cycle on real Seaport and real Clear |
| `test/unit/VaultQueue.t.sol` | 41 | Escrow, epoch settlement, zero dust, reserves vs NAV/cap/collateral, issuer freeze, multi-epoch, fuzzed reservation bounds, `settleQueue` (both trap PoCs, escrow accrual, instant-redeem parity, donation inflation, phase and empty-queue reverts, issuer freeze) |
| `test/unit/VaultQueueFairness.t.sol` | 4 | Per-entry escrow USDG, deposit-then-queue, a tranche indexed between entries, a fuzz over three entries around two tranches |
| `test/unit/VaultAssignment.t.sol` | 19 | Full/partial/zero assignment, the fee base on assigned weeks, the late depositor (shares the assignment; can be written against by a later fill), queued redeemers through assigned weeks, fuzzed collateral/strike exactness |
| `test/unit/VaultAdmin.t.sol` | 21 | Role wiring, halt/unhalt, hard caps, `maxPriceAge` bounds, fee recipient, Valorem fee switch, `uiMultiplier` never in share maths, freeze, `supportsInterface` (zone yes, 1271 no), ERC-1155 hooks |
| `test/unit/VaultDistributor.t.sol` | 19 | Pro-rata index, claims, transfers, late-depositor isolation, fee routing, dust and unallocated carry, fuzzed claim bounds |
| `test/unit/VaultSecurity.t.sol` | 8 | The 2026-09-12 review regressions (the critical deposit-gate finding, the tenor cap, the window check, the best-effort fee, the fee-on approval) |
| `test/unit/VaultLotSize.t.sol` | 5 | Types with lots 2e18, 1.08e18 and 0.5e18 refused at arm with nothing moved, a settled redeemer's reserve untouched, arming again at 1e18 |
| `test/unit/Smoke.t.sol` | 6 | Fixture wiring, one clean cycle, `Verify.s.sol`'s bytecode section against the fixture deployment (and swapped libraries failing it) |
| `test/unit/Fixtures.t.sol` | 8 | The vendored Seaport runtime matches the chain, fills a signed order, runs `authorizeOrder` before transfers and `validateOrder` after, moves nothing on a refused authorise; `MockSeaport` matches on both; the real Clear artifact deploys with the verified defaults and refuses zero addresses; the script artifact equals the fixture |
| `test/unit/MockClearDiff.t.sol` | 3 | `MockClear` against the real bytecode: single-bucket pro rata by written, a write after an exercise opens a new bucket, the steered draw with swap-and-pop |
| `test/regression/AF01_UnsoldInventory.t.sol` | 3 | Real Clear: the unsteered attack (depositor loss zero), the steered attack with the buyer asleep (full assignment is still only what was sold), the no-attacker control |
| `test/regression/AF02_UsdgFreezeRollClose.t.sol` | 18 | 9 on the mock and the same 9 on the real Clear: every redeem-failure cause, the unassigned-week control, the gas ladder, a re-strand with an uncollected earlier-generation owner, re-queueing while stranded |
| `test/regression/AF03_CompleteRedeemLegs.t.sol` | 5 | USDG pause and vault freeze pay the NVDA leg and defer the USDG leg; a frozen receiver collects USDG elsewhere; healthy tokens pay both legs; a Stock Token pause blocks both |
| `test/regression/AF04_FeeSizing.t.sol` | 4 | Governance cannot set 100% utilisation; the fee stays inside the free balance at the ceiling; `ReserveBreached` after the write; a fuzz that the ceiling leaves room for the fee |
| `test/regression/AF05_BurnShortfall.t.sol` | 4 | An Idle burn shortfall is shared by the reserve and closes deposits; a Listed shortfall is priced honestly and closes deposits; returning collateral refills the reserve and reopens; a fuzz that the haircut fraction is the same for every claimant |
| `test/invariant/VaultInvariant.t.sol` | 25 | The 13 `invariant_*` functions above (64 runs × depth 600, 26 handler actions incl. the third-party writer and exerciser, `adminBurn`, the three issuer toggles and `retryStrandedClaim`; `afterInvariant` refusing vacuous or shrunk runs) plus 12 deterministic tests incl. `test_handlerReachesEveryState`, `test_handlerReachesAStrandAndRecovers`, `test_handlerReachesANvdaBlocklistStrand`, `test_handlerReachesABurnShortfallAndTheHaircut`, `test_handlerReachesTheThirdPartyBucketAndFlatSettlement` |
| **Total** | **399** | |

**What the stateful suite can and cannot do.** The handler registers 26 selectors
(`VaultInvariant.t.sol` L1636–L1663): `deposit`, `mintShares`, `instantRedeem`, `instantWithdraw`,
`transferShares`, `queueRedeem`, `completeRedeem`, `claimUsdg`, `rollOpen`, `approveListing`,
`cancelListing`, `fill` (twice, to weight it), `exercise`, `rollClose`, `lockBook`, `warpAhead`,
`toggleHalt`, `settleQueue`, `adminBurn`, `thirdPartyWrite`, `thirdPartyExercise`,
`retryStrandedClaim`, `toggleUsdgPause`, `toggleUsdgFreeze` (the vault or Clear),
`toggleNvdaBlock`. Its actors, the buyer and the third-party writer are a closed set. It never
calls `setPolicy`, `setDepositCap`, `setFeeRecipient`, `setMaxPriceAge`, `acceptValoremFee`,
`sweepFee`, `claimUsdgTo` or `invalidateAllListings`; never donates USDG or Stock Token to the
vault; never transfers shares to the vault address; never turns the Valorem fee on; and fills
through `MockSeaport`'s hook order, not the real runtime (that is `VaultRealSeaport.t.sol`).
Consequently the following §5 items are covered only by deterministic tests: A.5, A.6 and A.7
(donations, the fee sweep), B.10's real-runtime paths, C.16 and P-25 (no setter is ever called),
C.17 and P-06's fee-on branch, P-28 (the per-entry figures; the code runs in every run but no
`invariant_*` checks them), and the `queuedShares == balanceOf(vault)` equality in I-4. The
handler's `approveListing` keeps spot at or below the highest price whose band floor still admits
the armed strike, so the band-floor refusal at fill is exercised by `VaultWriteOnFill.t.sol`, not
by the run.

**Fork tests against live chain 4663** (`FOUNDRY_PROFILE=fork forge test --fork-url $RH_RPC`,
`test/fork/ForkLive.t.sol`, 20 tests, all passing 2026-09-13 against the public RPC on this
branch): code presence at every address; the Seaport runtime hash equals the vendored one; token
decimals; the Valorem fee switch off; Clear is ERC-1155; anyone can create an option type and its
seed is its key; feed liveness, age and normalisation; the vault deploys and reads spot; Seaport
hashes our order shape; the guardian bumps the real counter; a real Stock Token deposit;
`uiMultiplier` display-only; the oracle not paused; **a first fill and a top-up fill through the
live Seaport and Clear** (`test_fork_writeOnFillAgainstLiveSeaportAndClear`); the arm gate
refusing an out-of-band strike and a claim id on the live Clear; `TSTORE`/`TLOAD` live on 4663;
**an assigned week exercised by the buyer and closed by a stranger on the live Clear** with
assignment equal to what was sold and the strike credited fee-free
(`test_fork_assignedWeekSettlesOnLiveClear`); **an unfilled week closing flat**; and **a stranded
close under the real USDG `ASSET_PROTECTION` freeze of the vault, with `retryStrandedClaim`
recovering it after the unfreeze** (`test_fork_usdgFreezeStrandsTheCloseAndRetryRecoversIt`).
Not covered on the fork: distribution and claims beyond the close's harvest, the NVDA-side strand
(the blocklist role is not impersonated), a multi-writer bucket on the live Clear (that is the real
bytecode in the regression suite).

**Deploy rehearsal** (`docs/DEPLOY.md` "Rehearsal record"): `script/rehearse-deploy.sh` on an
anvil fork of 4663 at block 62533535 with `--code-size-limit 98304`, both admin paths, our own
Clear on path A and Overcall's on path B, Verify 63/69/72/71 with the negative checks. It does not
prove the Safe{Wallet} UI, hardware signing, Sourcify verification, or anything after
configuration.

**What none of this proves.** No external review has been done and none is planned; these
contracts are unaudited (D14). Every real-Clear and real-Seaport result is against the bytecode
vendored from chain 4663 at one point in time, and the fork suite against the live chain at one
block. The keeper has never driven the redesigned vault: the keeper dry run in
`keeper/DRYRUN.md` (leekzor/callhouse) predates write on fill. Every figure in this document is
from a local run: every GitHub Actions run on the repository's account dies `startup_failure` at
the account level, so CI has not independently confirmed anything (README "CI").

---

## 7. Known accepted risks and open questions

Open questions being closed before launch (SECURITY.md §5):

1. The self-hosted fill page is the only venue; Overcall's book cannot list a restricted order
   with the vault as zone. Closed by decision D1.
2. **Keeper prices at exactly the policy floor.** An upward oracle tick between the keeper's read
   and `approveListing` reverts `PremiumBelowMinimum` or `StrikeBelowBand`; a rally between
   approval and a fill makes the listing unfillable (`PremiumBelowFloorAtFill`,
   `StrikeBelowBand`) until repriced. Self-heals; a margin is under consideration. Pricing at the
   floor is also the leakage in C.13.
3. **Deposit-time harvest checkpoint gas**, and the fill gas (~470k first fill, ~245k top-up,
   spike figures): to be measured on the first live week.
4. **The keeper, indexer and web are not ported to write on fill** (§4). Until they land the
   vault can be operated only by hand.
5. **Open decisions on pricing leakage** (SECURITY.md §3): an admin timelock, higher compiled
   floors, a listing start delay, vol-model keeper pricing, no deposits before the Safe handover.
   None is implemented.

Accepted by design (SECURITY.md §4 "Known and accepted"; confirm each is bounded as we claim
rather than re-open it):

- **No upgradeability, no rescue function, no timelock on the admin.** A real bug means Vault v2
  and a migration. The admin's value lever is 20% of future premium plus `feeRecipient`; strike
  proceeds are outside the fee base in bytecode.
- **The protocol fee is 5% of premium only.** `Harvest.feeUsdg / grossUsdg` is not the rate on an
  assigned week (ACCOUNTING.md §6).
- **Any USDG that lands in the vault is harvest**, fee'd and distributed.
- **The fee push is best-effort** and `sweepFee` is permissionless.
- **`rollClose`, `lockBook`, `settleQueue` and `retryStrandedClaim` are public** at their gates;
  anyone can bump the vault's Seaport counter at a phase gate. Liveness insurance, not a hazard.
- **Guardian griefing** (cancel, counter bump, halt) costs a week's premium, never principal. A
  halt stops fills instantly; it never stops an exit.
- **Keeper economic discretion inside policy** (type, size, price down to the floor, three
  listings, or skipping) is bounded by the caps and by write on fill, not eliminated (C.13, C.16).
- **The Stock Token issuer can burn, pause, blocklist, pause the oracle, move the multiplier and
  upgrade**, each from one key, and terminate the Series on 30 days' notice. Settlement stops or NAV
  falls; nobody is trapped (AF-05, the split legs, the stranded path).
- **USDG's operational powers sit with one EOA and act instantly**: pause, freeze (of the vault,
  Clear, Seaport or a receiver), wipe, burn-from. **A wipe of the vault's USDG re-anchors
  `usdgAccounted`** to the lower balance, so later premium backs older claims first come, first
  served (the audit's plausible-unproven Low; reachable only through the issuer). Premium and
  strike USDG frozen or wiped are gone for the holders they were owed to.
- **The price feed can lag the token** at a multiplier `effectiveAt` (≈11.8 h observed), and the
  frozen weekend value predates the close by up to a few hours. For those hours the band and floor
  are priced on a stale basis, bounded by the band; the keeper is expected to skip such windows.
  The audit's plausible-unproven "split-multiplier discontinuity" reduces to this under D16.
- **The 4663 sequencer is a single operator with compliance filtering**; force inclusion takes 4
  days and may itself be filtered; there is no uptime feed and `maxPriceAge` does not notice an
  outage shorter than 4 days. No on-chain remedy.
- **Upstream Valorem is dormant**, the fixed-seed bucket walk is public, and the vault is designed
  on exactly that behaviour: a third-party writer and exerciser can assign the vault fully on what
  it sold, which is the priced covered-call exposure, and on nothing more.
- **The Clear `feeTo`** of whichever instance is used holds the fee switch, which the vault treats
  as opt-in. Overcall's key on the default instance; ours on our own.
- **`maxPriceAge` is days, not hours** (4 at launch, ceiling 7). No `roundId`/`answeredInRound`.
- **The Valorem engine fee is opt-in** and, once accepted, a NAV cost of 15 bps of notional per
  fill, priced into the buyer's floor.
- **`claimUsdg`/`claimUsdgTo`, ERC-20 transfers and `validateOrder` are not `nonReentrant`**; CEI
  plus hook-free tokens plus Seaport's own guard is the argument.
- **Deposits are refused whenever unredeemed assignment proceeds exist, while stranded, and while
  the reserve is unbacked**, which can close deposits until `rollClose`, until the retry, or until
  collateral returns. Intended.
- **Fills are visible to the vault only as writes**; the keeper detects them from `OrderFulfilled`
  and `CallsWritten`, and a batch that skips the vault's order still succeeds.
- **Late depositors in `Listed` buy into the open short** and can be written against by a later
  fill (decision D9, A-6); premium already indexed is isolated by the checkpoint (ACCOUNTING.md §4).
- **Anyone may settle a flat queue, including another holder's entry, and anyone may retry a
  stranded claim.** Neither moves value by our analysis (P-29, P-34).
- **Shares transferred directly to the vault address are not rejected.** Never burned or queued,
  the sender's loss only; the stateful suite never generates such a transfer.

---

## 8. Build and test instructions

Toolchain the numbers in this document were produced with: `forge 1.3.5` (foundry-zksync build
`14afc70e`), `anvil 1.6.0`, solc `0.8.28+commit.7893614a`. State the build you reproduce with.

`foundry.toml`: `solc_version = "0.8.28"`, `evm_version = "cancun"`, `optimizer = true`,
`optimizer_runs = 200`, **`via_ir = true`** (needed for the Seaport/Valorem encoders),
**`code_size_limit = 98304`** (chain 4663's limit; forge's 24,576 B warnings are noise here),
`bytecode_hash = "none"`, `ffi = false`, read permissions on `out/`, `test/fixtures/` and
`script/artifacts/`. Dependencies: OpenZeppelin Contracts v5.7.0 and forge-std v1.16.2 as git
submodules under `lib/`.

```bash
set -o pipefail
forge fmt --check                                   # format gate
forge build --sizes                                 # Vault runtime 25,470 B; forge prints a negative EIP-170 "margin" and exits 1: ignore both
rm -rf cache/invariant                              # after any behaviour change
forge test --no-match-path 'test/fork/*'            # unit + regression + invariant, offline: 399 tests, 23 suites
FOUNDRY_PROFILE=fork forge test --fork-url "$RH_RPC"   # 20 tests against live 4663; back off on 429; never broadcast
```

`RH_RPC` can be the public endpoint, `https://rpc.mainnet.chain.robinhood.com`, which keeps
historical state only for a trailing window, so a long-running anvil fork needs an archive
endpoint. Sizes from `forge build --sizes` on this branch: `Vault` runtime **25,470 B** (initcode
28,684 B), `ValoremLib` 5,993 B, `SeaportOrderLib` 5,170 B, `Policy` 16 B (internal). The Vault is
above EIP-170's 24,576 B and that is fine on chain 4663 (README item 1); it is NOT portable to a
chain with the EIP-170 limit without a library extraction. `forge build` prints forge-lint warnings
that are expected and not a gate (`unsafe-typecast` and `divide-before-multiply` at annotated
sites in `Vault.authorizeOrder` and `ValoremLib`'s clamps; test files).

Deploy and verify (`docs/DEPLOY.md`): `Deploy.s.sol` with `ADMIN` = the deployer and
`--non-interactive` (forge otherwise stops at an EIP-170 prompt for the 25,470 B Vault),
`--verify --verifier sourcify --chain 4663`; `Verify.s.sol` with `ADMIN_PHASE=bootstrap
EXPECT_KEEPER_CONFIGURED=false`; `Configure.s.sol` with `ADMIN_PK`; `Verify.s.sol` again; later
`HandoverAdmin.s.sol` grant, a Safe transaction, renounce, `Verify.s.sol` with `ADMIN_PHASE=safe`.
Optionally `DeployClear.s.sol` first. Every `forge script` against a fork or mainnet passes
`--no-storage-caching`; anvil rehearsals need `--code-size-limit 98304`.

Traps (README "Four things that will bite you"):

- **Bytes.** The chain limit is 98,304 B. Ignore forge's EIP-170 warnings; report sizes anyway.
- **Tag space.** Each unit suite deploys the whole fixture; with via-IR on, another fixture-heavy
  suite can produce `Internal compiler error … Tag too large for reserved space`. Put shared
  sequences in helpers on `BaseTest` (`test/Base.t.sol`) rather than adding suites.
- **`vm.expectRevert` arms the NEXT external call.** Hoist any state-reading argument into a
  local first; `vm.expectEmit` has the same rule.
- **`cache/invariant`.** Foundry replays persisted counterexamples; clear the directory after
  changing behaviour.
- **Invariant depth.** Configured inline (`forge-config` L1600–L1603) and `afterInvariant` refuses
  a run that did not reach it; do not lower it to go faster.
- **ABIs flow one way**: `out/` → `ops/abis/Vault.json` (leekzor/callhouse) → generated copies in
  `indexer/` and `web/`; the keeper's `keeper/src/abi.ts` is hand-transcribed.

---

## 9. Reporting a finding

Send it to `security@callhouse.finance` (SECURITY.md §6), with: title, severity, location
(`file:line` at the commit in §1), description, impact in money terms, a proof of concept (a forge
test on the `BaseTest` fixture in `test/Base.t.sol`, or on `RealClearBase`/`RealSeaportBase` where
the mock would not show it), and a recommendation.

**Severity, in money terms.**

| Severity | Definition |
|---|---|
| Critical | Loss or permanent freeze of depositor principal (Stock Token, or USDG owed to holders or the queue) by any actor other than an honest `DEFAULT_ADMIN_ROLE` acting inside the caps; any path by which the keeper, guardian, admin, a third party or a token holder moves a token they do not own; any way to make the vault write outside a fill of its own listing, or to be assigned on more than it sold; any way to brick `rollClose` from outside the trust assumptions in §7 |
| High | Theft or loss of a week's premium or strike proceeds beyond dust; extraction from other depositors through share mispricing; any bypass of a bytecode-enforced property in §5; any role reaching a power outside the table in §2; a liveness failure that requires a redeploy and is reachable by an external actor without a trust-assumption violation |
| Medium | Bounded loss (rounding beyond the documented dust, or capped by policy at the keeper's discretion); griefing whose cost to the attacker is comparable to the damage; a liveness failure that a trusted actor can trigger or that requires an accepted-risk actor (issuer, Paxos, Clear `feeTo`, the sequencer) to act beyond what §7 already accepts; mis-accounting in views or events that would lead an off-chain system to a wrong money decision |
| Low | Deviations from stated invariants or best practice with no money impact; defence-in-depth gaps; dead code with a plausible future hazard |
| Informational | Code quality, gas, documentation mismatches, test gaps |

**How a fix is handled.** On a branch, one commit per finding where practical, each with a
regression test in the style of `test/regression/` asserting the FIXED behaviour, on the real
bytecode where the mock would not show the bug. Every fix passes the full local gate (§8) and the
fork suite, and a contract change re-opens `Verify.s.sol` (new bytecode) and the rehearsal.
Findings we decline to fix are recorded in SECURITY.md §4 "Known and accepted" with the rationale.

---

## Appendix. Addresses on chain 4663

| What | Address |
|---|---|
| Valorem Clear (`ValoremOptionsClearinghouse`), Overcall's instance, the default `CLEARINGHOUSE` | `0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0` |
| Clear `feeTo` on that instance (EOA, unfunded) | `0xdAe7e82A2E7D566C67E87C164B05a1C560190782` |
| Clear `tokenURIGenerator` on that instance (default for `DeployClear.s.sol`) | `0xE53cCB924d27f421a91b59087587fD866C5d64c7` |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |
| Seaport ConduitController (checked by the preflight and Verify; unused, `conduitKey == 0`) | `0x00000000F9490004C11Cef243f5400493c00Ad63` |
| USDG (Paxos, 6 dp, UUPS facet proxy) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| USDG operational EOA (pause, freeze, wipe, supply control, timelock roles) | `0x3Af3e85f4f97De7AD0f000B724Fb77fE5ffc024B` |
| NVDA Stock Token (18 dp, beacon proxy) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| Chainlink RHNVDA/USD `AggregatorProxy` (Standard, 8 dp) | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| Chainlink sequencer uptime feed | none |
| CREATE2 deterministic deployer (libraries) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Overcall NVDA registry `0x8E973cE1…f4EA` and registries owner `0x408adc…1CC0` | **not used** since decision D16; listed so nobody wires them back in |
| Vault, SeaportOrderLib, ValoremLib, Admin Safe, Fee Safe, keeper, guardian | not deployed |

Launch parameters (`Deploy.s.sol`, `Policy.launchDefaults()`): `minOtmBps 300`, `maxOtmBps 1200`,
`minPremiumBps 40`, `maxUtilizationBps 9500` (ceiling 9985), `protocolFeeBps 500` (5% of premium),
`maxContractsCap 50`, `maxPriceAge 4 days`, `depositCap 20e18`, `conduitKey bytes32(0)`, zone = the
vault, name/symbol "Callhouse NVDA"/"cNVDA". Compiled window bounds: `MIN_LEAD 1 hours`,
`MIN_EXERCISE_WINDOW 1 days`, `MAX_CYCLE_TENOR 21 days`. Role ids: `KEEPER_ROLE =
0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab`, `GUARDIAN_ROLE =
0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041`.
