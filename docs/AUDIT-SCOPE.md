# Audit scope

The document we hand to the external auditor (`tasks.md` (leekzor/callhouse) E-05; the engagement itself is E-06).
It says what we want reviewed, what we do not, what we already believe is true of the code, and
where we think it is weakest. Written 2026-09-12 against commit
`27d502a83d72aabf28838c6926cc0b2f5043deb5`; line numbers, sizes and test counts refreshed
2026-09-13 against this repository's commit `a4c38b0` (§1 "Commit").

> **Paths and commits.** This file lives in leekzor/callhouse-contracts, the audit target, and
> every path in it resolves from that repository's root (`src/`, `test/`, `script/`, `docs/`,
> `lib/`, `foundry.toml`). A path followed by (leekzor/callhouse) lives in the app repository
> (keeper, indexer, web, ops and the project-wide docs), which mounts this repository as a git
> submodule at `contracts/`; a path followed by (leekzor/callhouse-site) lives in the marketing
> site repository. Both resolve from that repository's root, and a marker after a list of paths
> applies to every path in the list. The contracts were written in a single monorepo whose
> history continues in leekzor/callhouse, and were moved here with `git subtree split`, which
> rewrote the commit hashes: a commit hash in this document is a leekzor/callhouse commit unless
> it is called this repository's. The contracts tree at `27d502a` is this repository's `adc2fbc`,
> at `cb82bf3` it is `0bc700e`, and at `b31dfb0` it is `edbf1a5`; file contents are identical.
> Commits after the split (`1187277`, `6023a96`, `a4c38b0`) exist only here.

It does not repeat the architecture or the accounting. Read `docs/ARCHITECTURE.md` (leekzor/callhouse)
(§2 for the trust boundaries, §3 for the contracts), [ACCOUNTING.md](ACCOUNTING.md) (the money
maths and the invariants) and [SECURITY.md](../SECURITY.md) (the threat model, the properties
enforced in bytecode, and the 2026-09-12 internal review) first. `ops/safes.md` (leekzor/callhouse) is the role
topology with a grep-level proof of the guardian claim (§4 there, re-run against `27d502a` on
2026-09-12; see the note under the table in §2 below); `ops/addresses.json` (leekzor/callhouse) is the address book.

Nothing is deployed to mainnet. Every `chains.4663.ours.*` entry in `ops/addresses.json` (leekzor/callhouse) is
`null`. This is a pre-deployment audit of one deployed bytecode plus its two linked libraries.

---

## 1. Purpose and engagement summary

**What we are asking for.**

1. A full manual review of the seven in-scope Solidity files in §3: one deployable contract
   (`Vault`), the three abstract bases it inherits (`Distributor`, `AdapterValorem`,
   `AdapterSeaport`), the two `public` libraries linked into it and reached by `DELEGATECALL`
   (`ValoremLib`, `SeaportOrderLib`), and the `internal` library that holds the compiled-in caps
   (`Policy`). 1,190 nSLOC. The properties we want attacked are in §5.
2. A configuration review of `script/Deploy.s.sol`, `script/Configure.s.sol`,
   `script/HandoverAdmin.s.sol` and `script/Verify.s.sol`, of the runbook `docs/DEPLOY.md`, and of
   the role topology in `ops/safes.md` (leekzor/callhouse): the constants, the preflight, the
   bootstrap admin phase (the deployer key is `DEFAULT_ADMIN_ROLE` at launch and hands over to the
   Safe later, §3 "Scripts"), the handover's safety conditions, and whether any key can reach a
   token.
3. A written verdict on each integration assumption we make about the third-party contracts we
   do not ask you to audit (§4). The contracts are theirs; the assumptions are ours.

**Timeline.** To be confirmed.

**Commit.** `<to be pinned at engagement>`. For reference, this document was written against
HEAD `27d502a83d72aabf28838c6926cc0b2f5043deb5` (2026-09-12 21:32 -0700); nothing in the
contracts tree (this repository's root) differed from HEAD while it was written. The rule that matters: the pinned commit
will be tagged `audit-<date>`; `git status --porcelain` is empty at that tag (the scratch files
that were at the monorepo root, `l2b.html`, `page.html`, `rh_sitemap.txt`, are not part of
this repository); the auditor should reproduce every figure in §6 and §8 from that tag,
not from this document. **Line numbers in this document are at this repository's commit
`a4c38b0`** (and will be re-checked at the audit tag); line citations into files marked
(leekzor/callhouse) or (leekzor/callhouse-site) are outside that statement and were not
re-derived. Since `27d502a` the contracts tree has changed in these commits of this
repository: `edbf1a5`, the protocol fee changed to 5% of premium only (strike proceeds from
assignment are never fee'd; see §3.1, P-26, §7), touching `Vault.sol` (`rollClose`,
`_accrueHarvest`, `_harvest`), `Policy.sol` (`launchDefaults`, NatSpec), `Configure.s.sol` and
the tests; `1187277`, the standalone-repository migration (comment-only path markers in
`script/Deploy.s.sol` and `test/unit/Policy.t.sol`); `6023a96`, comment and dead-constant
housekeeping in `Vault.sol`, `Policy.sol`, `IValoremClear.sol` and `Deploy.s.sol` with identical
runtime sizes (Appendix A items 6 and 8–11); `a4c38b0`, the deploy scripts and runbook
(§3 "Scripts"; `docs/DEPLOY.md`); and the bootstrap-admin revision of the scripts (script-only:
`Deploy.s.sol` accepts `ADMIN`, new `HandoverAdmin.s.sol` and
`script/rehearsal/ExecuteSafeBatch.s.sol`, `Configure.s.sol` loses its key-signing Safe mode,
`Verify.s.sol` rewritten). Line numbers into `script/` are at that revision; `src/` and `test/` are
unchanged by it.

**Contact.** To be confirmed at kickoff. The site is not yet deployed at `callhouse.finance`: as of
2026-09-13 the domain serves a registrar parking redirect (`/.well-known/security.txt` answers
HTTP 200 with an HTML `window.location.href="/lander"` stub, and `/lander` is a GoDaddy
"for sale" page), so nothing there is the Next route and there is no RFC 9116 endpoint at all
until deployment. Once hosted, the route handler `app/.well-known/security.txt/route.ts` (leekzor/callhouse-site)
(L36–41) returns 404 on purpose until `NEXT_PUBLIC_SECURITY_CONTACT_EMAIL` is set and the site
rebuilt (`tasks.md` (leekzor/callhouse) L-05; SECURITY.md §6 describes the same gap). The engagement uses a direct
channel agreed at kickoff, not that route.

**Access.** The repository is `callhouse-contracts` (this tree), delivered as read access to the GitHub
repository or a tarball of the tagged commit, to be confirmed. First command after checkout:
`git submodule update --init --recursive` (`lib/openzeppelin-contracts` and
`lib/forge-std` are submodules; nothing builds without them). The canonical ABI,
including every event and custom error, is `ops/abis/Vault.json` (leekzor/callhouse), generated from `out`
(§8 "ABIs flow one way"); the keeper's `keeper/src/abi.ts` (leekzor/callhouse) is a hand transcription and is not
authoritative.

**Not asked for.** A re-audit of Valorem Clear, Seaport 1.6, USDG or the Stock Token. Gas
optimisation. Review of the keeper, indexer or web code beyond the note in §4.

---

## 2. System overview and trust model

Callhouse is one non-upgradeable vault on Robinhood Chain (chain id 4663) running a weekly
covered-call strategy on one Robinhood Chain Stock Token, NVDA
(`0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, 18 decimals, non-rebasing). Depositors put in the
Stock Token and receive 18-decimal ERC-20 shares (`cNVDA`). Once a week the keeper calls
`rollOpen`; the vault writes out-of-the-money calls on Valorem Clear against up to 95% of idle
collateral and receives ERC-1155 option tokens plus a claim NFT. The keeper then proposes a
Seaport 1.6 order selling those option tokens for USDG; the vault checks every field of the
order against its own state, records the order hash, calls `seaport.validate`, and answers
EIP-1271 for exactly that hash. Buyers on Overcall's order book fill through Seaport: 95% of
the premium lands in the vault, 5% goes to Overcall's fee address in the same fill. During the
cycle's exercise window buyers may exercise inside Valorem; the vault sees this only by reading
its claim position. After expiry `rollClose` (keeper first, anyone one hour later) redeems the
claim, harvests every unit of USDG that arrived (premium plus any strike proceeds), takes a
protocol fee on the premium only (5% at launch, capped at 20% in bytecode; strike proceeds are
excluded from the fee base), credits the rest to holders through a per-share index, and settles
a batched redeem queue.

Two ledgers, kept apart on purpose (ACCOUNTING.md §1): the share price tracks only the raw
Stock Token balance (idle minus reserved, plus collateral locked in Valorem). It never marks the
short call, never reads a price feed in the settlement path, and never sees USDG. Yield is a
separate USDG claim. Instant `redeem`/`withdraw` work only while the vault is flat; the rest of
the week exits go through `queueRedeem`/`completeRedeem`. Deposits close at the cycle's exercise
timestamp.

The one-sentence model (SECURITY.md §1): **no off-chain component can move money.** The keeper
proposes, the vault validates. A fully compromised keeper key can waste a week; it cannot take
a token. `docs/ARCHITECTURE.md` (leekzor/callhouse) §2 has the who-holds-what table; SECURITY.md §2 lists the bytecode
properties this rests on.

| Key | Holder | Can | Cannot |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | At launch: the deployer key (bootstrap phase). After `HandoverAdmin.s.sol`: the admin Safe, Gnosis Safe 2-of-3 (`ops/safes.md` (leekzor/callhouse) §1) | `setPolicy` inside the `Policy.validate` caps; `setFeeRecipient` (non-zero); `setDepositCap` (unbounded, can close deposits); `setMaxPriceAge` in [1 hour, 7 days]; `acceptValoremFee`; `haltWrites` and `unhaltWrites`; grant/revoke `KEEPER_ROLE` and `GUARDIAN_ROLE`; grant admin to a fourth address; renounce | Move any Stock Token or USDG (there is no admin-gated transfer in the vault); upgrade; rescue or sweep to an arbitrary address; take more than 20% of harvested premium, or any fee on strike proceeds (the exclusion is in bytecode, not in `policy`); sell inside 1% OTM; widen staleness past 7 days. **No timelock on any admin action.** Worst case: 20% of harvested premium on filled weeks, routed to a recipient of its choosing, never principal |
| `KEEPER_ROLE` | Hot EOA run by `keeper/` (leekzor/callhouse) (`ops/safes.md` (leekzor/callhouse) §2) | `rollOpen` (chooses the rung and size within policy); `approveListing` (proposes the whole Seaport order, at most 3 authorisations per cycle); `cancelListing`; `invalidateAllListings`; `rollClose` from `cycleExpiryTs` | Hold the option tokens or the claim; pay premium anywhere but the vault and Overcall's fee address; list above strike, below the policy floor, past `cycleExerciseTs`, or more than inventory; halt or unhalt; change any parameter; move a token. Worst case: a wasted week |
| `GUARDIAN_ROLE` | 1-of-1 key on separate hardware, different continent (`ops/safes.md` (leekzor/callhouse) §3) | `haltWrites` (blocks `rollOpen` and `approveListing` only); `cancelListing`; `invalidateAllListings` (needs no order data) | `unhaltWrites` (the guardian can stop, never start); change parameters; block deposits, instant redemption, the queue, USDG claims, `lockBook` or `rollClose`; move a token. `ops/safes.md` (leekzor/callhouse) §4 is the checkable proof |
| Fee recipient | Fee Safe (`ops/safes.md` (leekzor/callhouse) §6) | Receive the protocol fee through the best-effort push in `rollClose` or the permissionless `sweepFee()` (both via `_tryPayFee`, Vault L980–999) | Holds no role; nothing else |
| Deployer | EOA running `Deploy.s.sol` | Fix every immutable at construction (asset, USDG, clearinghouse, registry, feed, Seaport, conduit key, zone, Overcall fee recipient); choose the one `admin` the constructor grants `DEFAULT_ADMIN_ROLE` to (Vault L299). **Launch plan: `admin` = the deployer's own address**, so until the handover the deployer key has every `DEFAULT_ADMIN_ROLE` power above | A wrong immutable is unfixable without a redeploy. Leaves the admin role only through `HandoverAdmin.s.sol` (grant to the Safe; renounce refused until the Safe has executed a transaction after the grant). `Verify.s.sol` checks the deployer holds admin in the bootstrap phase and nothing in the safe phase |
| Anyone | — | `deposit`, `mint`, `redeem`, `withdraw`, `queueRedeem`, `completeRedeem`, `claimUsdg`, `claimUsdgTo`, ERC-20 transfers; `lockBook` after `cycleExerciseTs`; `rollClose` after `cycleExpiryTs + 1 hour`; `sweepFee` | — |

On the proof in `ops/safes.md` (leekzor/callhouse) §4: it was re-derived against HEAD `27d502a` on 2026-09-12 (the
step 1 and step 2 tables there carry the line numbers at that commit). The one thing to know
when you re-run it: since defect 12 (§6) the fee leg is no longer a `safeTransfer` but a raw
`address(usdg).call(abi.encodeCall(IERC20.transfer, (feeRecipient, fee)))` at Vault L992 inside
`_tryPayFee`, reached from `_harvest` (only from `rollClose`) and from the permissionless
`sweepFee`; the grep in step 2 has been extended to catch it, and the `forceApprove` sites are
now in `ValoremLib.sol` L85/L88 (DELEGATECALL), not in `AdapterValorem.sol`. The guardian
conclusion is unchanged. Re-derive the tables from the pinned tag rather than trusting the
numbers.

Third parties that hold no role but have power over the vault: the Overcall registry owner (a
single EOA, `0x408adcFFebDF48EC23F1E3811A91AeD3cC951CC0`) sets the weekly cycle; the Stock Token
issuer can pause every Stock Token at once, blocklist the vault address, burn vault-held tokens
(`adminBurn`), pause its oracle and upgrade the token (§4, "Freeze and blocklist surface"); the
Valorem Clear owner can flip a 15 bps engine fee; Paxos can upgrade USDG behind a 24 h timelock.
What each can do to us is in `docs/ARCHITECTURE.md` (leekzor/callhouse) §7 and SECURITY.md §3–§4; what we assume about
each is in §3 and §4 below.

---

## 3. In scope

| File | nSLOC | Purpose | Externally callable surface |
|---|---:|---|---|
| `src/Vault.sol` | 534 | The deployed contract: shares, deposits, phase machine, roll, harvest, redeem queue, admin | 36 functions declared here (20 state-changing, 16 view) plus the constructor, plus the inherited ERC-20, AccessControl, Distributor and adapter surfaces |
| `src/Distributor.sol` | 110 | Abstract ERC-20 base: the 1e27-scaled USDG accrual index, settle-on-transfer, claims, the balance checkpoint and the payout clamp | `claimUsdg`, `claimUsdgTo`, `claimableUsdg`, `usdgOwed`, 7 auto-getters; 6 internal hooks used by Vault |
| `src/AdapterValorem.sol` | 77 | Abstract base: the per-cycle short position on Valorem (option id, claim id, count), position views, ERC-1155 receiver | 5 public views, 2 ERC-1155 hooks, 4 getters; `_writeCalls`/`_redeemClaim` reachable only through `rollOpen`/`rollClose` |
| `src/AdapterSeaport.sol` | 111 | Abstract base: one authorised listing at a time, EIP-1271, cancel/counter bump, 3-per-cycle budget, the one-time ERC-1155 operator approval | `isValidSignature`, 5 immutable getters, 4 storage getters; internal mutators reachable only through Vault |
| `src/lib/ValoremLib.sol` | 79 | **Linked public library, DELEGATECALL.** Option-vs-cycle validation, approval sizing incl. the Valorem engine fee, `write`, `redeem`, three never-reverting position views | `writeCalls`, `redeemClaim` (DELEGATECALL only), `lockedAssets`, `claimedExerciseProceeds`, `contractsAssigned` (views) |
| `src/lib/SeaportOrderLib.sol` | 147 | **Linked public library, DELEGATECALL.** Field-by-field validation of the keeper's `OrderComponents`, `getOrderHash`, `validate`, hash-checked `cancel` | `approve`, `cancel` (DELEGATECALL only), `toParameters` (pure) |
| `src/Policy.sol` | 132 | Internal pure library, inlined: the hard caps, OTM band, premium floor, the 95/5 per-contract split, utilisation and count caps, fee split, oracle normalisation | None external; 12 internal pure functions and 9 constants |
| **Total** | **1,190** | | |

nSLOC is what remains after stripping every `/* … */` block (all NatSpec), `//` comments and
blank lines; the same seven files are 2,406 physical lines, so roughly half the text is
comment. A cruder count that only drops lines beginning with a comment marker (and so keeps
the text inside the `/*////` section banners) gives 1,251. All seven files are `pragma solidity
0.8.28`. `Distributor`, `AdapterValorem` and `AdapterSeaport`
have no bytecode of their own.

**Why the two linked libraries matter.** `ValoremLib` and `SeaportOrderLib` are `public`
libraries: deployed as their own contracts and linked into the Vault runtime (5 link sites:
`SeaportOrderLib` at 2, `ValoremLib` at 3, both in `out/Vault.sol/Vault.json`
`linkReferences`). Every call into them is a `DELEGATECALL`, so inside them `address(this)` is
the vault and they have full access to its storage and balances. That is required (Valorem
mints the claim NFT to `msg.sender` and `redeem` reverts for anyone else; Seaport accepts
`validate` and `cancel` only from the offerer), but it also means a mis-linked or substituted
library is a total-compromise vector. They were extracted for EIP-170 headroom, not for reuse.
Please treat adapter plus library as one trust unit each, verify that the library holds no
storage and writes none, confirm Solidity's library call-protection makes direct `CALL`s to
the non-view functions revert, and, at deploy, verify the link targets embedded in the deployed
Vault runtime and that both libraries are verified on Blockscout separately. One documentation
gap to know about: `ops/addresses.json` (leekzor/callhouse) has a `seaportOrderLib` slot but no
`valoremLib` slot. (`Deploy.s.sol`'s NatSpec, lines 19–23, names both libraries for manual
`--libraries` linking since this repository's `6023a96`; before that it named `SeaportOrderLib`
only.) The keeper dry run (`keeper/DRYRUN.md` (leekzor/callhouse), "Two failures first") hit a stale
`Vault.json` compiled with `SeaportOrderLib` pinned to the placeholder
`0x1111111111111111111111111111111111111111`; a clean `forge build` produces both link
references and `metadata.settings.libraries == {}`.

**Interfaces.** `src/interfaces/` (`IValoremClear.sol` 121 nSLOC, `ISeaport.sol` 79,
`IOvercallRegistry.sol` 53, `IStockToken.sol` 12, `IChainlinkFeed.sol` 9, `IERC1155Minimal.sol`
8) are hand-transcribed subsets of third-party ABIs. They are in scope as statements of what we
assume about those contracts, not as code. `IValoremClear.sol`'s header used to say the Valorem
tree is vendored under `lib/clear`, deployed byte-for-byte by `script/lib/ValoremDeployer.sol`,
with 0.8.16 artefacts produced by `src/vendor/ValoremArtifacts.sol`; none of those exists in this
checkout (`lib` holds only `forge-std` and `openzeppelin-contracts`; there is no `script/lib`).
Since this repository's `6023a96` the header states its provenance instead: a verbatim copy of
the interface in the Blockscout-verified source of Overcall's NVDA registry, which Overcall
hand-transcribed from Valorem's clearinghouse at upstream `6436c82`, with only comments changed
(Appendix A item 9). It does not record a date the transcription was last diffed. Diff the
transcription against upstream `valorem-labs-inc/clear` at `6436c823` yourself.

**Mocks.** `src/mocks/` (557 nSLOC: `MockClear`, `MockSeaport`, `MockRegistry`,
`MockFeed`, `MockStockToken`, `MockERC20`) are out of scope as code but matter for how much
the unit suite proves; §6 lists their known infidelities.

**Scripts, in scope for configuration review only.** `script/Deploy.s.sol` fixes
every chain-4663 address as a constant (each overridable by env for a fork rehearsal), installs
`Policy.launchDefaults()` through the constructor, sets `MAX_PRICE_AGE = 4 days` and
`LAUNCH_DEPOSIT_CAP = 20e18`, passes `ADMIN` (if set, else `SAFE_ADMIN`) as the constructor's
`admin` and `SAFE_FEE` as fee recipient, prints a warning when that admin has no code, and runs
`_preflight` (registry `collateralToken`/`exerciseToken`/`clearinghouse` equal the asset, USDG and
clearinghouse; `lotSize() == 1e18`; feed `answer > 0`, `updatedAt > 0`, `decimals() == 8`). The
constructor grants `DEFAULT_ADMIN_ROLE` to that `admin` and to nobody else (Vault L299). Forge
deploys both libraries through the CREATE2 factory `0x4e59b448…956C`, so their addresses depend only
on bytecode (`docs/DEPLOY.md`).

**The launch plan is a bootstrap admin**: `ADMIN` = the deployer's address. `Configure.s.sol` then
broadcasts `grantRole(KEEPER_ROLE, KEEPER)` and `grantRole(GUARDIAN_ROLE, GUARDIAN)` (both non-zero
and different; plus `setPolicy` only when `SET_POLICY=true`) from `ADMIN_PK`, refusing a key that does
not hold `DEFAULT_ADMIN_ROLE`. Without `ADMIN_PK` it broadcasts nothing. In both modes it writes the
same calls as a Safe{Wallet} Transaction Builder batch (`broadcast/configure-safe-batch.json`, no
checksum field; `foundry.toml` grants read-write on `./broadcast`). It still casts `vm.envOr(uint256)`
to `uint16`/`uint64` with silent truncation before `Policy.validate` sees the value (an operational
footgun, not a contract bug).

`HandoverAdmin.s.sol` moves the admin role to the Safe in two runs. `STEP=grant`: requires `ADMIN_PK`
to hold admin and `SAFE_ADMIN` to have code, threshold ≥ 2, owners ≥ threshold and no enabled module;
grants `DEFAULT_ADMIN_ROLE` to the Safe; prints the Safe's nonce as `GRANT_NONCE`; writes a one-call
smoke batch (`setMaxPriceAge` to its current value). `STEP=renounce`: same preconditions, plus the
Safe holds admin and its nonce is above `GRANT_NONCE`, then `renounceRole` from the key. The nonce
condition is a liveness proof of the Safe, not of the smoke call specifically: any Safe transaction
after the grant satisfies it. `script/rehearsal/ExecuteSafeBatch.s.sol` (rehearsal only) executes a
batch file through a Safe with owner keys (threshold-many, sorted by address) and refuses unless the
node's `web3_clientVersion` starts with `anvil/`.

`Verify.s.sol` is read-only and reverts if any check failed (55–64 checks depending on phase in the
rehearsal). It compares the runtime bytecode of the vault and both libraries byte for byte with this
checkout's `out/` artifacts, masking only link sites (each separately required to hold the expected
library; all five), immutable slots (each checked by value) and a library's own deploy-address word
(required to equal the library's address); it checks every immutable including
`overcallFeeRecipient`, `conduitKey == 0`, `seaportZone == 0`, `transferApprovalTarget == seaport` and
the clearinghouse `isApprovedForAll(vault, seaport)`; policy field by field against
`launchDefaults()`, `depositCap`, `maxPriceAge`, `feeRecipient`, name, symbol, decimals; roles for
`ADMIN_PHASE` (`bootstrap`: deployer holds admin; `safe`: `SAFE_ADMIN` holds admin and has code, deployer
holds nothing) with keeper and guardian holding exactly their role, all three keys distinct and every
role administered by `DEFAULT_ADMIN_ROLE`; for each Safe, a canonical 1.3.0/1.4.1 singleton, threshold,
owners (optionally the exact set), no modules, no guard, canonical fallback handler; and a fresh state
(Idle, not halted, no cycle, option, claim, listing, shares, reserves, pending fee, USDG books, asset or
USDG balance). `script/rehearse-deploy.sh` runs both admin paths on an anvil fork with every forge call
under `--no-storage-caching`, including negative checks (swapped library addresses and a single
flipped byte of vault code must fail Verify; renounce before the Safe has executed must be refused; a
renounced key must be refused; the executor must refuse a non-anvil node). `docs/DEPLOY.md` is the
runbook and holds the rehearsal record (fork block 62201116). `ops/safes.md` (leekzor/callhouse) §7 is
the older cast-based deploy-day checklist (Appendix A item 12).

Please check: that no constant is wrong for chain 4663 (Appendix C); that the preflight cannot
pass with the JUGGERNAUT registry `0x65dD407955912Be814f723724cE60f91ebd72616` instead of the
NVDA one (fork test `test_fork_constructorRejectsWrongRegistry`); that the Safe batch calldata
grants exactly `KEEPER_ROLE` and `GUARDIAN_ROLE` and nothing else (with a third call, `setPolicy`,
only when `SET_POLICY=true`); that `HandoverAdmin.s.sol` cannot leave the vault without an admin or
with the key still admin after a successful renounce, and whether its liveness condition is
sufficient; that the bootstrap phase's risk (one key with every admin power) is stated correctly in
§2 and `docs/DEPLOY.md`; and whether `Verify.s.sol`'s bytecode comparison is sound (masking exactly
the link and immutable references in the artifact, and nothing else).

### 3.1 `Vault.sol`

**Purpose.** The only deployed contract. `Vault is ERC20, AccessControl, ReentrancyGuard,
Distributor, AdapterValorem, AdapterSeaport`. ERC-4626-like, deliberately not compliant (see
the deviations below). A four-state phase machine `Idle → Listed → Exercisable → Settling → Idle`
(`Settling` is transient inside `rollClose`; `rollClose` also accepts `Listed`) gates deposits,
instant redemption and the queue.

**External surface (line numbers at `a4c38b0`).**

- Views: `decimals()` (always 18); `totalAssets()` L337 = max(idle − `reservedAssets`, 0) +
  `lockedAssets()`, USDG excluded, unsold option inventory at zero; `idleAssets()` L345;
  `convertToShares`/`convertToAssets` (virtual offset +1/+1, floor); `previewDeposit` (floor),
  `previewMint` (ceil); `previewRedeem`/`previewWithdraw` return 0 unless
  `canRedeemInstantly()`; `canRedeemInstantly()` L389 = `phase == Idle && contractsWritten == 0`;
  `maxDeposit` L399 (0 unless a deposit would succeed; else `depositCap − totalAssets()`
  saturating); `maxMint` L416; `previewCompleteRedeem` L654; `spotUsdg()` L929 (Chainlink,
  normalised to USDG 6-dp per 1e18 lot, reverts `StalePrice`/`SpotZero`); `uiMultiplier()` L944
  (display only, 1e18 fallback); `supportsInterface` L1066 (ERC1155Receiver, EIP-1271,
  AccessControl); public storage getters for phase, policy, cycle snapshot, reserves, queue
  state, immutables.
- Depositor paths, all `nonReentrant`: `deposit` L429 and `mint` L450 (require Idle, or Listed
  before `cycleExerciseTs`, and no unredeemed assignment, via `_requireDepositPhase` L486; cap
  checked on `totalAssets() + assets`; `_checkpointHarvest()` runs before `_mint`); `redeem`
  L507 and `withdraw` L522 (revert `UseQueue` unless flat; burn before transfer); `queueRedeem`
  L548 (every phase, works under an issuer freeze because it moves no tokens; settles a prior
  epoch into owed balances, settles the owner's USDG accrual, escrows the shares in the vault);
  `completeRedeem` L580 (pays `owedAssets` + `owedQueueUsdg`, decrements reserves, debits
  `usdgAccounted`).
- Roll paths: `rollOpen` L675 (`KEEPER_ROLE`, `nonReentrant`; requires Idle, not halted,
  `registry.isWritingOpen()`, approved rung of the current cycle, `expiry > exercise`,
  `expiry <= now + 21 days` at L696, Valorem fee off or accepted, `oraclePaused() == false`,
  fresh price, strike inside the OTM band, count within utilisation and cap; then
  `ValoremLib.writeCalls`, snapshots `cycleNumber`/`cycleExerciseTs`/`cycleExpiryTs`/
  `cycleStrikeUsdg`, resets the listing budget); `approveListing` L730 (`KEEPER_ROLE`, Listed,
  not halted; inventory from `clear.balanceOf(vault, optionId)`; `_approveListing`; then
  re-checks oracle liveness and `Policy.checkPremium` against live spot); `cancelListing` L747
  and `invalidateAllListings` L757 (`KEEPER_ROLE` or `GUARDIAN_ROLE`, no phase or halt gate);
  `lockBook` L768 (permissionless from `cycleExerciseTs`, invalidates any live listing);
  `rollClose` L782 (keeper from `cycleExpiryTs`, anyone from +1 hour; phase → Settling,
  invalidate live listing, read `contractsAssigned()`, `ValoremLib.redeemClaim`, `_harvest`,
  `_settleQueue`, phase → Idle).
- Fee and admin: `sweepFee` L971 (permissionless, always pays the stored `feeRecipient`,
  raw-call best effort, clamped to balance); `haltWrites` L1007 (guardian or admin);
  `unhaltWrites` L1016, `setPolicy` L1021, `setFeeRecipient` L1027, `setDepositCap` L1033,
  `setMaxPriceAge` L1042, `acceptValoremFee` L1057 (all admin). `writesHalted` is checked at
  L677 (`rollOpen`) and L732 (`approveListing`) and nowhere else.
- Constants: `MIN_PRICE_AGE = 1 hours`, `MAX_PRICE_AGE_CEIL = 7 days` (L84–85);
  `MAX_CYCLE_TENOR = 21 days` (L98).

**ERC-4626 deviations, all deliberate.** (1) Does not inherit `IERC4626`; no `maxWithdraw` or
`maxRedeem`. (2) `previewRedeem`/`previewWithdraw` return 0 whenever the queue is the only path
(ACCOUNTING.md §3). (3) `maxDeposit`/`maxMint` return 0 in any phase where a deposit would
revert and are measured on `totalAssets()` including collateral locked in Valorem, not on
balance. (4) `redeem`/`withdraw` revert `UseQueue` unless flat; there is no ERC-7540 request
interface. (5) A queued exit can pay a mix of Stock Token and USDG. (6) Yield is not in the
share price at all, so `convertToAssets` understates economic value. (7) `decimals()` is
hard-coded 18; the virtual offset is +1/+1 (decimals offset 0). (8) Deposits are also blocked by
a timestamp and by a live-assignment probe. (9) `Withdraw` is emitted only on the instant path;
queue exits emit `CompleteRedeem`/`QueueEntrySettled`/`QueueSettled`.

**External dependencies and what we assume.** Valorem Clear (see 3.3 and §4), Seaport 1.6 (3.4
and §4), USDG as a plain 6-decimal ERC-20 whose `balanceOf` delta is the harvest signal (any
USDG donated to the vault is harvested and fee'd; a blocklist or pause is tolerated by the
best-effort fee push and the clamped claims), the Stock Token as non-rebasing with raw
`balanceOf` and no transfer hooks (`uiMultiplier()` and `oraclePaused()` are probed by
`staticcall` with graceful fallback, L936–949; an issuer freeze stops only the token-moving
legs), the Chainlink feed as a write gate only (`answer > 0`, `updatedAt` within `maxPriceAge`,
`updatedAt <= block.timestamp`; no `roundId`/`answeredInRound` check; no sequencer feed exists
on 4663), the Overcall registry as honest-but-fallible (we independently bound tenor, require
an approved rung of the current cycle, and cross-check the option's assets, lot and window),
and OpenZeppelin 5.7.0 `ERC20`, `AccessControl`, `ReentrancyGuard`, `SafeERC20`, `Math.mulDiv`.
`DEFAULT_ADMIN_ROLE` is assumed honest; `KEEPER_ROLE` is assumed compromisable. The protocol fee
is charged on premium only. The harvest still measures all new USDG
(`gross = balance − usdgAccounted`) and credits all of it, less the fee, to the index; but
`rollClose` passes the USDG measured across `clear.redeem` (`usdgFromAssignment`, the balance
delta in `ValoremLib.redeemClaim` L99–110) into `_accrueHarvest(feeFree)` (L829–841; the call at
L804, `_harvest` L860–876), and the fee is `floor((gross − feeFree) × protocolFeeBps / 10000)`,
saturating at 0. The deposit checkpoint passes `feeFree = 0` (L851). This is a product decision
taken 2026-09-13, replacing an earlier fee of 1000 bps on the whole inflow (which, on an assigned
week, took 10% of returned principal); please confirm the implementation matches it (P-26).

**Invariants to hold.** P-02, P-03, P-04, P-07, P-10 through P-15, P-17 through P-20 in §5,
plus: `usdgAccounted` is set to the measured balance on every harvest and debited on every
outflow (claims, queue payouts, fee), so each inflow is counted once; reserves are increased
only at settlement (L899–900) and decreased only on payout (L643–644); each epoch claimant takes
`floor(remaining × shares / sharesRemaining)` and the last takes the remainder (L619–624);
`Policy.checkContracts` runs on `idleAssets()` so reserved assets are never writable collateral.

**Focus:** §5 A.1, A.2, A.3, A.5, A.6, B.8, C.14, C.15, C.16.

### 3.2 `Distributor.sol`

**Purpose.** Abstract ERC-20 base holding the USDG index (MasterChef pattern, 1e27 scale),
with the settle hooked into `ERC20._update` so accrual survives transfers, mints and burns;
`claimUsdg()`/`claimUsdgTo(address)`; `usdgDust` (remainder too small to index) and
`usdgUnallocated` (USDG that arrived at zero supply) carried forward; `usdgAccounted` as the
balance checkpoint; every payout clamped to `_usdgAvailableForHolders()`, which Vault overrides
(L909) to `balance − usdgReservedForQueue − pendingFeeUsdg`, saturating.

**External surface.** `claimUsdg()` L161 and `claimUsdgTo(address)` L166 (permissionless,
**not** `nonReentrant`, CEI only: state debited before the `safeTransfer`); `claimableUsdg`
(not clamped, can overstate by the rounding drift); `usdgOwed()` L247 (saturating,
informational, read by nothing in the money path); getters `accUsdgPerShare`, `usdgDust`,
`usdgUnallocated`, `usdgAccounted`, `totalUsdgDistributed`, `totalUsdgClaimed`, `usdg`.
Internal hooks: `_distributeUsdg` L131, `_settleAccount`, `_takeAccrued` L230 (escrow accrual
swept into an epoch, clamped), `_usdgAvailableForHolders` (virtual), `_debitUsdgOut` L255
(saturating), `_markUsdgAccounted`. `_update` L208 settles both parties, then `super._update`;
Vault's `_update` L324 is `override(ERC20, Distributor)` and only calls `super`.

**Dependencies and assumptions.** USDG has no transfer hook into sender or recipient (a
before-transfer hook re-entering `deposit`/`rollClose` between `_debitUsdgOut` and the balance
update would double-count the outgoing claim as harvest). USDG is an upgradeable facet proxy
under a Paxos timelock, so record this as an explicit assumption. OpenZeppelin 5 `_update`
semantics: every mint/burn/transfer routes through it. The caller has already split off the
fee and holds the USDG.

**Invariants to hold.** `accUsdgPerShare` never decreases; per distribution
`credited + new usdgDust == pot`; per-account pending floors; settle-before-move on both sides
at pre-change balances; zero-supply distributions park the whole pot in `usdgUnallocated`
without a second fee; every outflow is `min(accrual, available)`; `usdgAccounted <=
usdg.balanceOf(vault)` with zero tolerance (`invariant_usdgBooksBalance`); `_accrued` is never
reset on burn (a full exit keeps its claimable balance); `claimUsdg` reverts `NothingToClaim`
on a zero accrual or a zero clamp; `totalUsdgClaimed` moves in lockstep with actual outflow.

**Focus:** §5 A.3, A.4, B.8. Defect 9 in §6 is the history here.

### 3.3 `AdapterValorem.sol` and `lib/ValoremLib.sol`

**Purpose.** The adapter holds the per-cycle short position (`optionId`, `claimKey`,
`contractsWritten` as a raw `uint112` count, never the 1e18-scaled Valorem scalar) and the
ERC-1155 receiver; the library holds every Valorem call. `writeCalls` (ValoremLib L38): reverts
`ValoremFeesEnabled` if `clear.feesEnabled() && !feeAccepted`; reverts `OptionAssetMismatch` /
`OptionExerciseAssetMismatch` / `UnexpectedLotSize` / `OptionWindowMismatch` unless
`clear.option(optionId)` matches (asset, USDG, `cyc.lotSize`, `cyc.exerciseTimestamp`,
`cyc.expiryTimestamp`); `collateral = n × underlyingAmount`; `forceApprove(collateral [+
collateral × feeBps / 10_000, floor 1, when fees are on])`; `clear.write(optionId, n)`; reverts
`WriteReturnedNoClaim` on 0; `forceApprove(0)`. `redeemClaim` (L99): snapshots both balances,
`clear.redeem(claimKey)`, returns the measured deltas (checked subtraction). Three views
(L121, L133, L146) return 0 when `claimKey == 0`, clamp negative `int256` to 0, and return 0 on
any revert of `position()`/`claim()`; `contractsAssigned` divides `amountExercised` by 1e18.

**External surface.** Adapter: `lockedAssets()` L72 (feeds `totalAssets()`),
`claimedExerciseProceeds()` L81 (the clock-independent deposit gate), `contractsAssigned()`
L86 (event only), `contractsRemaining()` L95 (live `clear.balanceOf(vault, optionId)`, never a
stored counter), `contractsSold()` L105 (clamped), `onERC1155Received`/`onERC1155BatchReceived`
L162/L167 (return the magic selector only when `msg.sender == clear`, otherwise `0x00000000`
without reverting), getters `clear`, `optionId`, `claimKey`, `contractsWritten`. `_writeCalls`
L117 and `_redeemClaim` L136 are reached only from `rollOpen`/`rollClose`; both write storage
after the external call and rely on Vault's `nonReentrant`. `_writeCalls` overwrites the triple
unconditionally, with no `claimKey == 0` guard; `_redeemClaim` reverts `NoOpenClaim` when
`claimKey == 0`.

**Dependencies and assumptions about Valorem Clear** (`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`,
bytecode-identical to `valorem-labs-inc/clear` @ `6436c823`, §4): `write(optionId, n)` pulls
exactly `n × underlyingAmount` (+ fee on top when `feesEnabled`) via `transferFrom` and mints
`n` option ERC-1155 plus one non-zero claim NFT to `msg.sender`, invoking `onERC1155Received`;
`redeem(claimId)` reverts for non-owners and before expiry, burns the claim, and transfers
unassigned underlying plus assigned strike USDG to `msg.sender` with no writer-side fee;
`position(claimId)` reflects partial, bucketed assignment live; `claim(claimId).amountExercised`
is `count × 1e18`; `balanceOf(vault, optionId)` is the true unsold inventory; exercise has no
callback into the writer; `feesEnabled()`/`feeBps()` are the only owner switches (live:
`feesEnabled = false`, `feeBps = 15`, owner-only with no timelock). `write` also accepts a claim
id as `tokenId` to top up an existing claim; we rely on the registry never approving a
claim-shaped id. The strike (`o.exerciseAmount`) is not checked in the library; Vault takes it
from `registry.strikePerContract(optionId)` (L707), which the deployed registry forwards to
`clear.option()` but `MockRegistry` stores independently.

**Invariants to hold.** P-05, P-06, P-21, P-22, P-23 in §5, plus: all three claim-backed views
are 0 when flat and 0 on a Valorem revert, so `totalAssets()`, `maxDeposit()` and `deposit`
never revert because of Valorem; `contractsSold()` never underflows; `collateral` is an exact
integer (uint112 × uint96); `lockedAssets() == (contractsWritten − contractsAssigned()) × 1e18`
while a claim is open and 0 when Idle (`invariant_phaseSanity`).

**Focus:** §5 A.1, A.2, B.9, B.10, C.17, D.19. `MockClear`'s infidelities are in §6.

### 3.4 `AdapterSeaport.sol` and `lib/SeaportOrderLib.sol`

**Purpose.** The vault is the Seaport 1.6 offerer. The adapter records one authorised order
hash at a time (`listingHash`, `listingGrossUsdg`, `listingAmount`, `listingsThisCycle`),
answers EIP-1271, cancels or counter-bumps, caps authorisations at
`Policy.MAX_LISTINGS_PER_CYCLE = 3` per cycle, and grants a one-time
`clear.setApprovalForAll(transferApprovalTarget, true)` in the constructor (Vault L302). The
library validates the keeper's `OrderComponents` against a `Checks` struct populated entirely
from vault state (never from calldata), obtains the hash from `seaport.getOrderHash`, calls
`seaport.validate` so the order fills with an empty signature, and cancels only an order whose
recomputed hash equals `listingHash`. The economic premium floor (`Policy.checkPremium` against
live spot) is deliberately not in the library; Vault runs it after `approve` returns (L742–743)
and the whole transaction reverts if it fails.

**External surface.** `isValidSignature(bytes32 digest, bytes)` L123: returns `0x1626ba7e` iff
`listingHash != 0` and `digest == listingHash` or `digest == keccak256(0x1901 ‖
seaport.information().domainSeparator ‖ listingHash)` (domain separator read live per call);
signature bytes are never read. Immutables `seaport`, `overcallFeeRecipient`, `conduitKey`,
`transferApprovalTarget`, `seaportZone`. `_approveListing` L154 (reverts `PreviousListingLive`,
`TooManyListings`; library shape checks; then records state, i.e. writes after
`seaport.validate`); `_cancelListing` L201 (does not refund a budget slot);
`_invalidateAllListings` L213 (`seaport.incrementCounter()`, also called by `lockBook` and
`rollClose` whenever a listing is live); `_resetListingBudget` L228 (only `rollOpen`);
`_approveOptionTransfers` L239 (once, never revoked). Constructor resolves the conduit via
`ConduitController.getConduit(conduitKey)` when the key is non-zero and silently falls back to
Seaport itself if the conduit does not exist (L109–111); launch uses `conduitKey = 0` and
`zone = 0`, so the branch is not exercised in production. Library: `approve` L85, `cancel`
L101, `toParameters` L113 (sets `totalOriginalConsiderationItems = consideration.length`).

**The shape every authorised order must have** (SeaportOrderLib L132–223): `offerer ==
address(this)`; `zone == seaportZone`; `conduitKey == conduitKey`; `zoneHash == 0`;
`orderType ∈ {FULL_OPEN, PARTIAL_OPEN}`; exactly one offer item, `ERC1155` on the
clearinghouse with `identifier == optionId`, `startAmount == endAmount`, `0 < amount <=
clear.balanceOf(vault, optionId)`; exactly two consideration items, both `ERC20` USDG with
identifier 0 and no Dutch ramp, recipient[0] the vault, recipient[1] `overcallFeeRecipient`;
`gross % amount == 0`; `unitPrice >= Policy.minListableUnitPrice()` (20 USDG base units, the
smallest price whose 5% leg is non-zero); `unitPrice <= strike` when `strike != 0`;
amounts byte-exact to `Policy.splitPremium` (fee floored per contract then multiplied);
`startTime <= now < endTime <= cycleExerciseTs`; `counter == seaport.getCounter(vault)`. Salt
is unchecked. The keeper retains only salt, timing within the window, price within
[floor, strike], size within [1, inventory], and when to cancel or relist.

**Dependencies and assumptions about Seaport 1.6** (`0x0000000000000068F116a894984e2DB1123eB395`,
§4): `getOrderHash` is the canonical EIP-712 struct hash including the counter; `validate`
accepts an offerer-submitted order with an empty signature, reverts on a cancelled hash and
makes no callback into the offerer; `cancel` permanently marks the hash when called by the
offerer; `incrementCounter` jumps by a quasi-random amount (observed on fork: 0 →
`645105783290196256915466989660461880`), orphaning every prior hash; on fill Seaport presents
exactly the 0x1901 digest to `isValidSignature`, pulls only the offered ERC-1155 under the
operator approval, and pays the two consideration items atomically; `InexactFraction` requires
each consideration amount to be divisible by the order size. About Overcall: `zone = 0`,
`zoneHash = 0`, `conduitKey = 0`, `PARTIAL_OPEN`, 500 bps fee rounded per contract, fee
recipient `0xdAe7e82A2E7D566C67E87C164B05a1C560190782` (also Valorem's `feeTo`), all copied from
a live order (`ops/recon/R2-R9-seaport-order-shape.md`, `ops/recon/R3-overcall-api.md`,
`ops/recon/sample-overcall-order.json` (leekzor/callhouse)). A change on Overcall's side makes every new listing
unsurfaceable until a redeploy; no on-chain loss.

**Invariants to hold.** P-16 in §5, plus: every clearing path zeroes `listingHash`;
`listingsThisCycle` is incremented on every successful authorisation, checked before each, and
reset only by `rollOpen`; cancel targets only the recorded hash; after
`_invalidateAllListings` the counter is strictly greater; `listingHash` is always cleared
before the vault enters Exercisable or Settling; all Seaport parameters are immutable.

**Focus:** §5 B.10, B.11, C.13, C.18. `MockSeaport`'s infidelities are in §6.

### 3.5 `Policy.sol`

**Purpose.** Pure, storage-free `internal` library, inlined; no separate deployment. It is
the only thing between the Admin Safe and a policy that sells ATM calls or takes a 100% fee.

**Surface (internal, with the entry point that reaches each).** `validate` L101 (constructor
L296, `setPolicy` L1021–1025): `minOtmBps >= 100`, `maxOtmBps <= 2500`, `minOtm <= maxOtm`,
`minPremiumBps >= 10`, `maxUtilizationBps <= 10000`, `protocolFeeBps <= 2000`, `maxContractsCap
!= 0`. `launchDefaults` L118: `{300, 1200, 40, 9500, 500, 50}`. `strikeBand`/`checkStrike`
L135/L146 (`rollOpen`): inclusive `[spot × (1 + minOtm), spot × (1 + maxOtm)]`, floor-rounded,
`SpotZero` on 0. `minPremium`/`checkPremium` L159/L169 (`approveListing`): gross `>= spot ×
contracts × minPremiumBps / 10000`, floor-rounded, on gross before Overcall's cut (so the
vault's net floor at launch is 0.38%, not 0.40%). `splitPremium` L198 and
`minListableUnitPrice` L213 (SeaportOrderLib). `maxContracts` L223 (unused in `src`; tests only)
and `checkContracts` L230 (`rollOpen`, re-derives the same formula inline): `1 <= N <=
maxContractsCap` and `N <= floor(idle × maxUtil / 10000 / 1e18)`. `splitHarvest` L245
(`_accrueHarvest`, every deposit checkpoint and `rollClose`): fee floored, `(0, 0)` on a zero
input. The vault passes it the fee-bearing amount, `gross − usdgFromAssignment` at the close and
`gross` at a checkpoint, and discards its `net` output: `Vault` computes `net = gross − fee`
itself (Vault L837–838), so strike proceeds reach the index without passing through the split.
`normalizeSpot` L264 (`_spotUsdg`): `SpotZero` on `answer <= 0` or a result that rounds
to 0; rescales `feedDecimals → 6`. Constants L44–71: `BPS 10_000`, `MIN_OTM_FLOOR_BPS 100`,
`MAX_OTM_CEIL_BPS 2_500`, `MIN_PREMIUM_FLOOR_BPS 10`, `MAX_UTILIZATION_CEIL_BPS 10_000`,
`PROTOCOL_FEE_CEIL_BPS 2_000`, `MAX_LISTINGS_PER_CYCLE 3` (enforced in AdapterSeaport),
`OVERCALL_FEE_BPS 500`, `LOT 1e18` (`USDG_ONE 1e6`, declared and never used, was removed in
this repository's `6023a96`).

**Dependencies and assumptions.** None directly (every function is `pure`). The numbers that
flow in: the Chainlink answer and `decimals()` (re-read live on every call; a proxy phase
change to a different-decimals aggregator rescales spot silently), the registry's
`strikePerContract` (assumed to be Valorem's `exerciseAmount` for one 1e18 lot in USDG 6-dp),
Overcall's 5% per-contract rounding (mirrored from `ops/recon/R3-overcall-api.md` (leekzor/callhouse), not from any
on-chain source), Seaport's fraction rule, USDG at 6 decimals (assumed, not verified in code),
the Stock Token at 18 decimals with one lot = 1e18, and USD treated as 1:1 with USDG (no
depeg consideration in the band or floor).

**Invariants to hold.** P-01 in §5, plus: a written call is strictly OTM at write time for
any `spot >= 1`; the band is inclusive and at most 1 base unit lenient on the lower edge;
`toVault + toOvercall == unit × N` exactly, both divisible by `N`, rounding to the vault;
`unit >= 20` ⇒ per-contract fee ≥ 1; `N × 1e18 <= idle` whenever `maxUtil <= 10000`;
`fee + net == input` and `fee <= 20%` of the input in `splitHarvest`, zero fee on a zero input,
and in the vault `fee + net == gross` with `fee <= 20%` of `gross − usdgFromAssignment`; `normalizeSpot` never returns 0
and never accepts a non-positive answer; no storage, no external calls.

**Focus:** §5 A.3, A.6, A.7, C.13, C.14, C.16, C.18.

---

## 4. Out of scope, with reasons and links

Do not re-audit Valorem Clear. Do review our integration assumptions about it, which are
listed in 3.3 and summarised here; the same holds for every dependency below.

**Valorem Clear** (`ValoremOptionsClearinghouse` at
`0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0`). Verified `exact_match` (creation and runtime) on
Sourcify to `valorem-labs-inc/clear` @ `6436c823f560af493af119d6148fb3237037aca4`, the HEAD of
`master` (`ops/recon/R10-address-audit.md` (leekzor/callhouse)). Compiler recorded: solc 0.8.16, optimizer 200
runs, `evmVersion london`, no via-IR. Audits, from the upstream
[`audits/`](https://github.com/valorem-labs-inc/clear/tree/master/audits) folder:

| Report | Auditor | Date | Audited commit | Scope |
|---|---|---|---|---|
| [Valorem December 2022 – Zellic Audit Report](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_December_2022_%20-%20Zellic%20Audit%20Report.pdf) | Zellic | 2022-12-27 (engagement Nov 30 – Dec 9, 2022) | `6c118f2090ba4f9ddac878a4afb1e5facb49b7ca` | `OptionSettlementEngine.sol`; five findings (four by Zellic plus one found by Valorem and verified by Zellic): 2 high, 1 medium, 2 low, 0 critical |
| [Valorem April 2023 – Zellic Audit Report](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_April_2023_-_Zellic_Audit_Report.pdf) | Zellic | 2023-04-10 (engagement Jan 11 – 13, 2023) | `ed53af23ff17d2c04aaa25f1b038d0a4081288b7` | `OptionSettlementEngine.sol`; three findings: 2 medium, 1 informational, 0 critical/high (the first finding's header says "Severity: High" with "Impact: Medium"; the executive summary counts it as medium) |
| [Valorem Options Smart Contract Patch Review](https://github.com/valorem-labs-inc/clear/blob/master/audits/Valorem_Options_Smart_Contract_Patch_Review.pdf) | Zellic | 2023-08-29 | `fe39eb73c5354bdebcc5cc61031a9585c2fe0c25` | `ValoremOptionsClearinghouse.sol`, "changes to the expiry window and protocol fee" only |
| [2022.04.14.md](https://github.com/valorem-labs-inc/clear/blob/master/audits/2022.04.14.md) | Carter Carlson (individual) | 2022-03-14 | none stated | informal, two findings; historical only |

What that establishes and what it does not: `src/` is unchanged between `fe39eb73` and the
deployed `6436c823` ([compare](https://github.com/valorem-labs-inc/clear/compare/fe39eb73c5354bdebcc5cc61031a9585c2fe0c25...6436c823f560af493af119d6148fb3237037aca4)),
so the deployed source is exactly what Zellic patch-reviewed in August 2023. The last
full-scope audit was on `ed53af23` (January 2023), and `ed53af23 → 6436c823` (66 commits)
touches, under `src/`, `ValoremOptionsClearinghouse.sol` (+64/−55), its interface
`IValoremOptionsClearinghouse.sol` (+80/−29), `TokenURIGenerator.sol` (+9/−5) and
`ITokenURIGenerator.sol` (+3/−3); the rename is `OptionSettlementEngine →
ValoremOptionsClearinghouse` for both the contract and its interface. Everything else in the
range is scripts, tests, mocks, CI and the audit PDFs themselves
([compare](https://github.com/valorem-labs-inc/clear/compare/ed53af23ff17d2c04aaa25f1b038d0a4081288b7...6436c823f560af493af119d6148fb3237037aca4)).
We have not diffed `ed53af23 → fe39eb73` line by line, and whether the patch review's stated
scope covers all of that delta is to be confirmed. Our own recon flags the same gap
(`ops/recon/R4-valorem-abi.md` (leekzor/callhouse), caveat 5 at line 519 and "Still UNRESOLVED after this pass"
item 3; `ops/recon/R10-address-audit.md` (leekzor/callhouse) §UNRESOLVED, bullet "Byte-level equivalence of the deployed
Valorem Clear to the Zellic-audited source"). The
Zellic portal (`reports.zellic.io`) refuses non-browser clients; the Valorem-hosted PDFs above
are the verifiable copies. Assumptions to confirm: 3.3, in particular `write`'s pull amount and
fee formula, `redeem`'s payout and lack of writer-side fee, `position()`/`claim()` semantics
under bucketed partial assignment, no callback on exercise, and the claim-id top-up path of
`write`.

**Seaport 1.6** (`0x0000000000000068F116a894984e2DB1123eB395`, canonical address; `information()`
returns version `1.6` and conduit controller `0x00000000F9490004C11Cef243f5400493c00Ad63`).
Repository tag `1.6` = `e9c5a9f17cb5ee658ccc9cb1a8eeab02c1f5a4cd`
([release](https://github.com/ProjectOpenSea/seaport/releases/tag/1.6)); at that tag the core
lives in [seaport-core @ `2f546b9a`](https://github.com/ProjectOpenSea/seaport-core/tree/2f546b9a0d61a70e1632445cbcb108149a9369ae)
and [seaport-types @ `fa8b592f`](https://github.com/ProjectOpenSea/seaport-types/tree/fa8b592f991b30ddf10a3b71737c9c1d5e315d10).
**There is no public audit specific to Seaport 1.4, 1.5 or 1.6.** Published reviews:

| Report | Auditor | Date | Version |
|---|---|---|---|
| [Seaport Protocol security review](https://github.com/trailofbits/publications/blob/master/reviews/SeaportProtocol.pdf) | Trail of Bits | Apr 18 – May 12, 2022 | 1.0/1.1; the only audit OpenSea's README links |
| [OpenSea Seaport contest report](https://code4rena.com/reports/2022-05-opensea-seaport) | Code4rena | May 2022 | 1.0 |
| [Seaport Spearbit Security Review](https://cdn.cantina.xyz/reports/Seaport-Spearbit-Security-Review.pdf) ([Cantina listing](https://cantina.xyz/portfolio/seaport)) | Spearbit | engagement Dec 13, 2022 – Jan 4, 2023; report Feb 23, 2023 | 1.2 (tag `spearbit-audit-2022-12`), 92 issues |
| [OpenSea Seaport 1.2 contest report](https://code4rena.com/reports/2023-01-opensea) | Code4rena | Jan 2023 | 1.2 |

Our reliance is limited to order validation, EIP-1271 contract-offerer authorisation, the
counter, `cancel`, and the fulfilment path for a single ERC-1155 offer with two ERC-20
considerations, all present since 1.2. Our fork test checks only the version string, not the
bytecode. OpenSea's 1.6 launch post mentions an early OpenZeppelin review; no report could be
found, so we do not cite one. Assumptions to confirm: 3.4.

**Overcall registry** (`OvercallRegistry` for NVDA at
`0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA`; deploy block 59378796). Third-party contract owned
and deployed by a single EOA (`0x408adcFFebDF48EC23F1E3811A91AeD3cC951CC0`) that sets the
weekly cycle (option ids, exercise and expiry timestamps, lot size). All eleven Overcall
registries are one compilation unit (`ops/recon/R12-overcall-discovery.md` (leekzor/callhouse)). No audit of it is
known to us; do not audit it. In scope: what we assume of it and how we bound it (`isWritingOpen`,
`isApproved`, `cycleOf`, `strikePerContract`, `cycle()`, the constructor binding of
`collateralToken`/`exerciseToken`/`clearinghouse`, the 21-day tenor cap, the window-equality
check, and what we do not defend against, listed in §5). The JUGGERNAUT registry
`0x65dD407955912Be814f723724cE60f91ebd72616` is the trap: it is Overcall's frontend top-level
`registry` key and must never be wired in (`Deploy.s.sol`, `ops/addresses.json` (leekzor/callhouse)
`_TRAP_JUGGERNAUT_REGISTRY`).

**USDG** (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals). Paxos's native issuance on
chain 4663 per [Paxos docs](https://docs.paxos.com/guides/stablecoin/usdg/mainnet), not a
bridged wrapper. ERC-1967/UUPS proxy to implementation `0x68184c449e1a8f34fa18d289737129fd27b66f8f`
with a `getFacet(bytes4)` dispatcher; `defaultAdmin` is an OpenZeppelin `TimelockController`
(`0xcfa0388f5ddf905fdc08c45c716c15dc10a14c6f`) whose `getMinDelay()` is 86400 s (24 h, read live
2026-09-12 at block 61712871); USDG's separate `defaultAdminDelay()` for transferring the admin
role itself is 10800 s (3 h) (`ops/abis/USDG.json` (leekzor/callhouse) L45–46, `ops/recon/R6-stock-token.md` (leekzor/callhouse) §7.3).
The two delays are different things: the 24 h is the execution delay on any admin action routed
through the timelock, the 3 h is the AccessControlDefaultAdminRules hand-over delay. Whether that
timelock can actually upgrade the UUPS implementation is unconfirmed without the implementation's
source (`ops/recon/R10-address-audit.md` (leekzor/callhouse) §UNRESOLVED, "USDG upgrade authority mechanics"; Appendix B).
Source: [paxosglobal/usdg-contract](https://github.com/paxosglobal/usdg-contract)
on top of [paxosglobal/paxos-token-contracts](https://github.com/paxosglobal/paxos-token-contracts)
([audits folder](https://github.com/paxosglobal/paxos-token-contracts/tree/master/audits)).
Relevant reports: [Paxos Stablecoin – Zellic](https://github.com/paxosglobal/paxos-token-contracts/blob/master/audits/Paxos%20Stablecoin%20-%20Zellic%20Audit%20Report.pdf)
(2024-11-07, commit `44992a908a222a8c453d86741fccba8f8b085e71`, `PaxosBaseAbstract`/`PaxosTokenV2`),
[Paxos Token Contracts – Halborn](https://github.com/paxosglobal/paxos-token-contracts/blob/master/audits/Paxos%20Token%20Contracts%20Halborn%20Audit%20Report.pdf)
(Oct 17 – Nov 3, 2025, the facet architecture that matches what our recon found live),
[Paxos USDG Rewards – Zellic](https://github.com/paxosglobal/paxos-token-contracts/blob/master/audits/Paxos%20USDG%20Rewards%20-%20Zellic%20Audit%20Report.pdf)
(2026-02-24; rewards/multiplier facets can change balances, which matters to our
balance-checkpoint accounting), and
[Enhance Signature Validation – Zellic](https://github.com/paxosglobal/paxos-token-contracts/blob/master/audits/Enhance%20Signature%20Validation%20-%20Zellic%20Audit%20Report.pdf)
(2025-12-15; permit/EIP-3009 paths we do not use). Gap: the live implementation has not been
source-matched to a specific audited commit (the Robinhood Blockscout verification API sits
behind a Cloudflare challenge); to be confirmed. Assumptions in scope: plain `balanceOf`
semantics, no transfer hooks, no fee-on-transfer, no rebasing, blocklist/pause tolerated.

**Robinhood Chain Stock Token** (NVDA, `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`; ERC-20 debt
security issued by Robinhood Assets (Jersey) Ltd; beacon proxy, implementation
`0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2`; ERC-7201 storage; oracle-pausable; role-gated;
ERC-8056 `uiMultiplier()`). **No published third-party audit was found** (Robinhood Chain docs,
L2BEAT, the usual auditors' publication lists). The only public write-up is an independent
Beosin code walkthrough of the TSLA token ([link](https://beosin.com/resources/robinhood-chain-stock-token-practice-code-analysis-on-token-contract-and-blockchain-protocol));
cite it as background only. Our ABI (`ops/abis/StockToken.json` (leekzor/callhouse)) was recovered from the
implementation bytecode. Treated as a trusted, upgradeable issuer dependency (SECURITY.md §4).
Assumptions in scope: non-rebasing raw `balanceOf` (the critical accounting assumption,
`IStockToken.sol` header), no transfer hooks, 18 decimals, `uiMultiplier()` display-only and
never in share maths, `oraclePaused()` as a write gate probed by `staticcall` with lenient
fallback, and that an issuer freeze stops only token-moving legs.

*Freeze and blocklist surface* (`ops/recon/R6-stock-token.md` (leekzor/callhouse), all read live 2026-09-12 with
state-override proofs; the only recon file that documents it). The token is a beacon proxy
whose beacon is also the chain-wide `AccessControlledRegistry`
(`0xe10b6f6b275de231345c20d14ab812db62151b00`), shared by all 204 Stock Tokens the factory has
deployed. Powers, each held by a single plain EOA (13 role holders, no multisig, no timelock):
(1) a registry-level `pause()` (`PAUSER_ROLE`) that halts every Stock Token at once, after which
`NVDA.transfer`/`transferFrom` revert `IsPaused()` (`0x1309a563`) while `balanceOf` keeps
answering; (2) a per-address blocklist (`BLOCKER_ROLE`, `blockAccounts(address[])`) enforced on
both sender and recipient, reverting `Blocked(address)` (`0x75e91ce7`), with 246 addresses
already blocked, so "freeze the vault" is a real per-address action and not only a global one;
(3) per-token `pause()` (`TOKEN_PAUSER_ROLE`), `mint`, `burn` and `adminBurn(address,uint256)`
(`ADMIN_BURNER_ROLE`, can destroy vault-held NVDA); (4) `registry.upgradeTo(address)`
(`BEACON_UPGRADER_ROLE`), which re-points the logic of all 204 tokens in one transaction;
(5) `pauseOracle()` (`ORACLE_PAUSER_ROLE`), which flips `oraclePaused()` and, proven by state
override, does *not* block transfers, which is why the vault treats it as a write gate only.
`IStockToken.sol` deliberately exposes no freeze or blocklist view; the vault learns of a freeze
only by a token-moving leg reverting. `MockStockToken.frozen` (`IssuerFreeze` revert,
`src/mocks/MockStockToken.sol` L13–47, used by `VaultQueue.t.sol`
`test_issuerFreezeDoesNotBlockQueueingForAStaleSlotHolder`) models a transfer revert only, not
the selector, the blocklist asymmetry, `adminBurn` or an upgrade. The registry pause and per-token
pause share one `IsPaused()` revert; R6 proved the registry pause by override and infers the
per-token one. USDG has the analogous `freeze`/`wipeFrozenAddress` pair behind its 24 h timelock.

**Chainlink NVDA/USD feed** (`0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`, `AggregatorProxy`,
"RHNVDA / USD", 8 decimals, heartbeat 86400 s, 0.5% deviation, `us_equities_24/5`, observed
weekend gaps up to 78 h; `ops/recon/R5-price-feed.md` (leekzor/callhouse)). Used only as a write gate and a UI
value, never in settlement. No sequencer uptime feed exists on 4663 (`ops/addresses.json` (leekzor/callhouse)
`sequencerUptimeFeed: null`). A USDG/USD feed exists at
`0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` and is not used.

**Multicall3** (`0xcA11bde05977b3631167028862bE2a173976CA11`): read batching by the keeper and
web only; never called by the contracts.

**OpenZeppelin Contracts v5.7.0** (`lib/openzeppelin-contracts`, submodule
`cab19933`): `ERC20`, `AccessControl`, `ReentrancyGuard`, `SafeERC20`, `Math`, `IERC20`. Standard.
**forge-std v1.16.2** (`bf647bd`): tests only.

**Keeper, indexer, web** (`keeper/`, `indexer/`, `web/` (leekzor/callhouse); the site (leekzor/callhouse-site)). No money authority: no key
they hold can move a token, and the vault re-validates every field the keeper proposes
(SECURITY.md §1, `docs/ARCHITECTURE.md` (leekzor/callhouse) §2). Out of scope. One exception worth a glance, not an
audit: the keeper's listing-construction path is the concrete example of what the vault must
reject. `keeper/src/seaport.ts` (leekzor/callhouse) (`buildOrderComponents`, `splitPremium`, `localOrderHash`,
`localOrderDigest`, `PLACEHOLDER_SIGNATURE`), `keeper/src/policy.ts` (leekzor/callhouse) (`pickWrite`,
`strikeBand`, `maxContracts`, `minUnitPrice6`) and `keeper/src/roll.ts` (leekzor/callhouse) (`tick`, `reconcile`,
`maybeRelist`, `repriceFromPolicy`) show the intended order shape and pricing; if the auditor
finds an order the vault accepts that this code would never build, that is a finding against
the vault, not the keeper. `test/unit/SplitDiff.t.sol` is the differential test that
keeps `Policy.splitPremium` and the keeper's split in agreement.

---

## 5. Properties the auditor should try to break

Each is a falsifiable statement with its code location. SECURITY.md §2 is the prose version.
Line numbers are at this repository's commit `a4c38b0` (§1 "Commit").

| # | Property | Where |
|---|---|---|
| P-01 | No `policy` value outside the hard caps (`minOtmBps >= 100`, `maxOtmBps <= 2500`, `minOtm <= maxOtm`, `minPremiumBps >= 10`, `maxUtilizationBps <= 10000`, `protocolFeeBps <= 2000`, `maxContractsCap != 0`) can ever be stored | `Policy.sol` L101–115; `Vault.sol` L296, L1021–1025 |
| P-02 | Once `block.timestamp >= cycleExerciseTs` in `Listed`, `deposit` and `mint` revert `DepositsClosedForCycle` and `maxDeposit`/`maxMint` return 0, whether or not anyone called `lockBook` | `Vault.sol` L486–498, L399–413 |
| P-03 | While `claimKey != 0 && claimedExerciseProceeds() != 0`, no share can be minted by any path | `Vault.sol` L497; `ValoremLib.sol` L133–140 |
| P-04 | `rollOpen` reverts `BadCycleWindow` if `expiry <= exercise` or `expiry > now + 21 days`, before any collateral moves | `Vault.sol` L98, L693–698 |
| P-05 | The option written always has `underlyingAsset == asset`, `exerciseAsset == USDG`, `underlyingAmount == cyc.lotSize`, and exercise/expiry timestamps equal to the cycle's; otherwise nothing moves | `ValoremLib.sol` L50–64 |
| P-06 | No write happens while `clear.feesEnabled()` is true unless `valoremFeeAccepted` | `Vault.sol` L702–703; `ValoremLib.sol` L50 |
| P-07 | No state of `feeRecipient` or of USDG can make `rollClose` revert through the fee leg; `sweepFee()` always pays the stored recipient, never the caller | `Vault.sol` L871, L971–999 |
| P-08 | No holder claim or queue take ever exceeds `_usdgAvailableForHolders() = balance − usdgReservedForQueue − pendingFeeUsdg` | `Distributor.sol` L183–185, L236–237; `Vault.sol` L909–913 |
| P-09 | `usdgAccounted <= usdg.balanceOf(vault)` always, and every USDG outflow debits it | `Distributor.sol` L255–263; `Vault.sol` L830, L648–649, L995–996 |
| P-10 | Rounding favours the vault: `deposit` floors shares, `mint` ceils assets, `redeem` floors assets, `withdraw` ceils shares; +1/+1 virtual offset; redeeming the whole supply pays at most `totalAssets()` | `Vault.sol` L351–365, L440, L456, L512, L526 |
| P-11 | The share price never marks the short call to market and no price feed is read in the settlement path: `totalAssets() = (idle − reservedAssets) + lockedAssets()`, USDG excluded; `_spotUsdg` is called only from `rollOpen`, `approveListing` and the `spotUsdg()` view | `Vault.sol` L337–349, L708, L743, L929 |
| P-12 | The phase machine moves only as drawn in `docs/ARCHITECTURE.md` (leekzor/callhouse) §3; `Idle ⇒ contractsWritten == 0 && claimKey == 0` | `Vault.sol` L676, L731, L769–770, L784–785, L792, L807; `invariant_phaseSanity` |
| P-13 | Instant `redeem`/`withdraw` succeed only when `phase == Idle && contractsWritten == 0`; previews return 0 otherwise | `Vault.sol` L389–391, L508, L523, L379, L384 |
| P-14 | The deposit cap is measured on `totalAssets()` (locked collateral included, reserved excluded), never on raw balance | `Vault.sol` L410–412, L433–434, L459–460 |
| P-15 | A share minted after USDG arrived can never claim any of it: `_checkpointHarvest()` runs before every `_mint` and makes no external call other than `usdg.balanceOf` | `Vault.sol` L438, L454, L829–841, L850 |
| P-16 | The vault authorises at most one Seaport order at a time, at most 3 per cycle, only in the shape listed in 3.4; `isValidSignature` returns the magic value only for the recorded `listingHash` or its EIP-712 digest and never when `listingHash == 0` | `SeaportOrderLib.sol` L132–223; `AdapterSeaport.sol` L123–128, L154–191 |
| P-17 | A rung is written only if `registry.isWritingOpen()`, `registry.isApproved(optionId)` and `registry.cycleOf(optionId) == cycle.number` | `Vault.sol` L681–688 |
| P-18 | `maxPriceAge` can only ever be in [1 hour, 7 days] | `Vault.sol` L84–85, L1047–1049 |
| P-19 | The guardian can stop but never start: `haltWrites` is guardian-or-admin, `unhaltWrites` admin-only, and a halt blocks only `rollOpen` and `approveListing` | `Vault.sol` L677, L732, L1007–1019 |
| P-20 | Liveness never depends on the keeper: `lockBook` is permissionless from `cycleExerciseTs`, `rollClose` from `cycleExpiryTs + 1 hour`, `sweepFee` always; `queueRedeem` works in every phase and under an issuer freeze | `Vault.sol` L768–776, L782–790, L971, L548–577 |
| P-21 | The ERC-1155 receiver hooks accept only `msg.sender == clear` | `AdapterValorem.sol` L162–174 |
| P-22 | No allowance to the clearinghouse survives a write; the approval equals exactly what upstream `write` pulls | `ValoremLib.sol` L74–88 |
| P-23 | `optionId`, `claimKey`, `contractsWritten` are non-zero together after a write and zero together after a redeem; `_redeemClaim` reverts `NoOpenClaim` when flat | `AdapterValorem.sol` L128–130, L140–150 |
| P-24 | Checks-effects-interactions in every money path: burn before transfer in `redeem`/`withdraw`, owed and reserves zeroed before transfer in `completeRedeem`, `phase = Settling` before any external call in `rollClose`; every state-changing user entry point is `nonReentrant` except ERC-20 transfers and `claimUsdg`/`claimUsdgTo` | `Vault.sol` L515–516, L530–531, L641–649, L792 |
| P-25 | Governance cannot reach principal by any path, including `setFeeRecipient` plus the 20% fee ceiling on a future assigned week (the fee base excludes strike proceeds, so the lever is 20% of that week's premium), `setDepositCap`, `setPolicy`, role grants, or renouncing | `Vault.sol` L1007–1060, L829–841 |
| P-26 | The protocol fee is charged only on premium. On `rollClose`, `Harvest.feeUsdg == floor((Harvest.grossUsdg − RollClose.usdgFromAssignment) × protocolFeeBps / 10000)` (saturating at 0) and `Harvest.netUsdg == Harvest.grossUsdg − Harvest.feeUsdg`, both events from the same transaction; on a checkpoint `Harvest`, `feeUsdg == floor(grossUsdg × protocolFeeBps / 10000)`. Strike proceeds never reach `pendingFeeUsdg`: for any assignment count and strike, `pendingFeeUsdg` after the close equals what the identical unassigned week would have accrued | `Vault.sol` L801–804, L829–841, L850–853, L860–876; `ValoremLib.sol` L99–110; `Policy.sol` L245–253 |

The money invariants of ACCOUNTING.md §7, asserted by the stateful suite's eight `invariant_*`
functions (`test/invariant/VaultInvariant.t.sol`, 64 runs × depth 600):

| # | Invariant | Function |
|---|---|---|
| I-1 | `asset.balanceOf(vault) + lockedAssets() == deposited − withdrawn − assignedOut` | `invariant_assetConservation` L1068 |
| I-2 | `usdg.balanceOf(vault) >= sum(claimableUsdg) + usdgReservedForQueue + pendingFeeUsdg + usdgDust + usdgUnallocated` | `invariant_usdgBooksBalance` L1100 (books; `usdgAccounted <= balance` with zero tolerance; queue reserve equals epochs plus staged exactly) and `invariant_usdgHolderSolvency` L1149 (per holder) |
| I-3 | `reservedAssets <= asset.balanceOf(vault)` and `usdgReservedForQueue <= usdg.balanceOf(vault)` | `invariant_reservesAreReal` L1212 |
| I-4 | `totalSupply() == sum over holders + balanceOf(vault)`; `queuedShares == sum(queuedSharesOf)`; `queuedShares <= balanceOf(vault)`, with equality whenever no share has been sent to the vault address directly. The suite asserts the equality (L1180) because its handler never transfers shares to the vault: `transferShares` draws `to` from a closed `actors` array (L358–364) that does not contain it. On the contract itself neither `Vault._update` (L324) nor `Distributor._update` (L208) rejects `to == address(this)`, so any holder can break `queuedShares == balanceOf(vault)` with one `transfer`; the stray shares are never burned and are the sender's loss only (§7) | `invariant_shareAccounting` L1167 |
| I-5 | `totalSupply() > 0 ⇒ convertToAssets(totalSupply()) <= totalAssets()` | `invariant_noFreeShares` L1185 |
| I-6 | `contractsWritten > 0 ⇒ phase != Idle`; `phase == Idle ⇒ claimKey == 0`; `lockedAssets() == (contractsWritten − contractsAssigned()) × 1e18` while open | `invariant_phaseSanity` L1270 |
| I-7 | The protocol fee never touches strike proceeds: `protocolFeeBps` stays at `launchDefaults()` for the run, and `(usdg.balanceOf(feeRecipient) + pendingFeeUsdg) × 10000 <= premiumToVault × protocolFeeBps`, where `premiumToVault` is a handler ghost of the vault's USDG balance change on every successful fill (P-26) | `invariant_feeNeverTouchesStrikeProceeds` L1308 (body in `_assertFeeBoundedByPremium` L1315) |

The index rounding drift is the one tolerance in the suite: `afterInvariant` (L1339) records
it, refuses a run where it reaches 1 USDG, and refuses any run that was shrunk or did not reach
full depth.

### Areas of concern, ranked

Deduplicated across the per-contract records. Money paths first.

**A. Loss or freeze of principal.**

1. **Live NAV read from Valorem and the deposit gate.** `totalAssets()` reads
   `clear.position(claimKey)` live (Vault L337–342 via ValoremLib L121–129). A buyer's
   `exercise` collapses `lockedAssets()` in the same transaction with no callback, while the
   strike USDG stays inside the claim until `rollClose`. The only defences are the
   `cycleExerciseTs` close and the `claimedExerciseProceeds() != 0` probe. Try: any minting or
   price-quoting path that bypasses `_requireDepositPhase`; a partial assignment below one lot
   or a bucket-accounting delay where `exerciseAmount` reads 0 while `underlyingAmount` already
   fell; a `position()` revert or an out-of-gas inside the try/catch (ValoremLib L123–128,
   L135–140) that makes both reads 0; negative `int256` clamps; a cycle whose
   `exerciseTimestamp` is already in the past at `rollOpen`. On the out-of-gas branch: confirm
   for every consumer of the three views that EIP-150's 63/64 rule leaves too little gas to
   finish the outer transaction once the inner staticcall has starved, and whether `position()`
   gas can grow with the claim (upstream iterates claim buckets). This was the review's critical
   finding (§6, defect 10); we want it attacked again.
2. **`rollClose` as the single exit.** Vault L782–808: `phase = Settling`, then
   `seaport.incrementCounter` (if a listing is live), `clear.redeem`, harvest, queue settle. A
   revert in Seaport or in `clear.redeem` (USDG blocklist of the vault; the vault address
   blocklisted on the Stock Token registry, or the registry-level pause, or Valorem's address
   blocklisted, §4 "Freeze and blocklist surface"; checked subtraction on the redeem deltas at
   ValoremLib L103–109) strands collateral, the queue and every future cycle; there is no
   alternative unwind, no rescue and no upgrade. Assess the blast radius and whether a
   documented recovery is required, given the care taken for the fee leg. For each of the two
   Stock Token actions separately (vault blocklisted; registry pause) enumerate which vault
   functions survive: we expect `queueRedeem`, `claimUsdg`/`claimUsdgTo`, ERC-20 share transfers,
   `lockBook`, `cancelListing`/`invalidateAllListings`, `haltWrites` and the admin setters to keep
   working, and `deposit`/`mint`, `redeem`/`withdraw`, `completeRedeem` whenever `owedAssets`
   is non-zero (a USDG-only payout still goes through), `rollOpen` (`clear.write` pulls
   collateral) and `rollClose` (`clear.redeem` pushes it back) to revert, with `approveListing`,
   Seaport fills and the fee push unaffected because they move option tokens or USDG, not the
   Stock Token. Confirm the revert is
   on `transfer`/`transferFrom` only and never on `balanceOf`, since `totalAssets()` and every
   preview read `balanceOf`.
3. **Queue settlement and reserves.** Vault L548–651, L885–904; Distributor L230–241.
   `payoutAssets = idleAssets() × queued / totalSupply` computed before the burn with the
   escrow in the supply; USDG for the epoch comes from `_takeAccrued(vault)` clamped. Try: two
   uncollected epochs double-reserving; later instant redemptions of the remaining supply
   reaching into `reservedAssets`; the +1 offset; the escrow accrual residual migrating from one
   cohort to the next (`_takeAccrued`, Distributor L230–241); re-queueing after a settled but
   uncollected epoch; utilisation is measured on `idleAssets()` at `rollOpen` only, so a queue
   that grows after the write is settled from whatever is idle at `rollClose`. Also: shares
   sent straight to the vault address are accepted by `_update` and never burned (§7, I-4);
   say whether a `to == address(this)` revert in `Vault._update` (L324) is worth its bytes
   under the 1,150 B EIP-170 headroom, or whether the loss-to-sender-only argument suffices.
4. **The USDG index and the clamps.** Distributor L118–152, L171–192; Vault L909–913. The index
   over-promises by up to one base unit per account per distribution (sum of `claimableUsdg`
   can exceed `totalUsdgDistributed` by that much); the clamp is the only thing between that
   drift and an underflow. Try: a claim that pays out of `usdgReservedForQueue` or
   `pendingFeeUsdg`; carried `usdgDust`/`usdgUnallocated` consumed by a holder claim so the
   next epoch is under-backed; the saturating `_debitUsdgOut`/`usdgOwed()` hiding a real leak;
   an outflow that forgets the debit (the three outflow sites are claims Distributor L190,
   queue payout Vault L648–649, fee Vault L992–996; at the fee site the debit follows the
   external call); the `bal × delta` bound at 1e30+ shares or at 1 wei of shares.
5. **Fee sweep raw call.** Vault L971–999. `pendingFeeUsdg` is clamped to the total balance,
   not to `_usdgAvailableForHolders`; "empty return equals success"; a USDG address without code
   would read as success; the `usdgAccounted` debit follows the external call. Try: paying the
   fee out of money reserved for the queue.
6. **Harvest is any USDG balance increase.** Vault L829–841. Donated USDG, strike proceeds and
   premium are all distributed. Premium and donations are fee'd at `protocolFeeBps`; strike
   proceeds are not, because `rollClose` excludes the USDG measured across `clear.redeem`
   (L801–804; P-26). Try: a donation that distorts the index, the fee, or a deposit-then-queue
   sequence that captures premium landing between the last checkpoint and exercise; any USDG
   that is not strike proceeds but lands inside the `redeemClaim` balance window (ValoremLib
   L103–109) and so escapes the fee (a fee dodge harms only the protocol, but say if it is
   reachable); any path where `usdgFromAssignment` exceeds `gross` other than by saturation; an
   off-chain reader that treats `Harvest.feeUsdg / Harvest.grossUsdg` as the fee rate, which on
   an assigned week it is not; confirm a late depositor in `Listed` who shares assignment
   losses and strike proceeds is the intended economics
   (`test_lateDepositorDuringListed_isNotWrittenAgainstButSharesTheAssignment`).
7. **Inflation and donation griefing.** Vault L351–365, L441. Offset +1 wei on an 18-decimal
   asset; first-depositor inflation is bounded only by the donation cost
   (`test_inflationGriefIsBoundedByTheDonation`); the cap counts donations; a direct Stock
   Token transfer also inflates `idleAssets()` and therefore the utilisation
   `Policy.checkContracts` allows at the next `rollOpen`. Weigh cost/benefit against
   `depositCap` and the `ZeroShares` revert.

**B. Authorisation and external-call ordering.**

8. **Entry points without `nonReentrant`.** ERC-20 `transfer`/`transferFrom`
   (`Distributor._update` settles both sides, L208–212) and `claimUsdg`/`claimUsdgTo` (CEI
   only). USDG and the Stock Token are assumed hook-free; both are upgradeable proxies. Confirm
   on the live bytecode and record the assumption.
9. **CEI inverted inside the adapters and libraries, covered only by Vault's guard.**
   `_writeCalls` stores the triple after `clear.write` (AdapterValorem L126–130; the mint
   callback into `onERC1155Received` fires first), `_redeemClaim` zeroes after `clear.redeem`
   (L143–150), `_approveListing` writes `listingHash` after `seaport.validate` (AdapterSeaport
   L168–189). Confirm no path reaches them without `nonReentrant` and that no view can observe
   stale `claimKey`/`phase` mid-transaction in a way that matters. `_writeCalls` overwrites the
   `optionId`/`claimKey`/`contractsWritten` triple unconditionally with no `claimKey == 0`
   guard; confirm nothing can reach it outside `Phase.Idle`, now or after a plausible fix.
10. **Seaport authorisation and fills.** AdapterSeaport L123–128; SeaportOrderLib L132–223.
    Fills are invisible to the vault; a third party can inflate `clear.balanceOf(vault,
    optionId)` by pushing option tokens of the same id (the receiver checks only `msg.sender`),
    which is the bound on relist size; partial fill → cancel → re-approve semantics on real
    Seaport; a filled-then-cancelled order after `rollOpen` resets `listingsThisCycle`; raw
    order hash accepted alongside the digest (dead code for Seaport, but wider than needed);
    `endTime == cycleExerciseTs` and a same-block fill-then-exercise; the counter window;
    bulk-signature digests; `isValidSignature` staticcalling back into `seaport.information()`
    for the domain separator during Seaport's own fill; and, irrelevant at launch with
    `zone = 0`, that a non-zero zone could cancel open orders on Seaport without the vault
    knowing.
11. **Blanket, irrevocable operator approval on Clear.** AdapterSeaport L239–241 (Vault L302).
    Covers the claim NFT and every future id; safety rests on Seaport requiring offerer
    authorisation and on the shape check pinning the offer to the current `optionId`. A
    non-zero conduit key would put a third-party-mutable conduit in that role; the constructor
    silently falls back to Seaport when the conduit does not resolve.
12. **Linked libraries.** DELEGATECALL with full storage access; verify the five link sites in
    the deployed runtime, library call-protection, no storage, separate verification. Vault
    runtime is 23,426 B with 1,150 B of EIP-170 headroom; any fix that does not fit moves code
    into a library.

**C. Economic and governance.**

13. **Keeper discretion inside policy.** A compromised keeper can pick the lowest approved rung
    in the band, write to 95% utilisation, list at exactly the floor (0.40% of spot notional
    gross at launch, 0.38% net) to a colluding buyer, use all three listing slots, or never
    roll. A guardian can burn slots or kill every listing. Quantify the weekly leakage bound and
    say whether `haltWrites`/`invalidateAllListings` are sufficient and fast enough; confirm the
    3-per-cycle cap counts authorisations (not live listings) and that a cancel never refunds a
    slot (AdapterSeaport L201, L228).
14. **Oracle gate.** Vault L922–940, Policy L264–275. No `roundId`/`answeredInRound`; staleness
    window in days by design (4 days at launch; `us_equities_24/5`); `block.timestamp −
    updatedAt` panics on a future `updatedAt`; `decimals()` re-read live; `oraclePaused()`
    probed by `staticcall` where a non-32-byte return reads as not paused; no sequencer feed;
    no deviation check between reads; `10 ** (feedDecimals − 6)` in `Policy.normalizeSpot`
    panics for `feedDecimals >= 84` (a revert, not a graceful path). The premium floor is
    checked at `approveListing` against live spot after the keeper priced: an upward tick
    reverts `PremiumBelowMinimum`, a downward tick lets a listing that was below the floor at
    keeper time pass. Checked-arithmetic products in `Policy` (`spot × (BPS + otm)`,
    `spot × contracts × minPremiumBps`, `idle × maxUtil`, `gross × fee`): confirm no input is
    attacker-unbounded. Assess whether a lagging or manipulated weekend price lets the keeper
    write inside a band that is far in the money at Monday open, and confirm the answer only
    ever changes which rungs and prices are writable, never settlement.
15. **The registry EOA.** Vault L683–698, ValoremLib L50–64. Defended: tenor > 21 days,
    inverted window, unapproved rung, rung from another cycle, option metadata disagreeing with
    the cycle. Not defended: a bad-but-legal strike ladder beyond the OTM band, `lotSize`
    changes mid-cycle (`setLotSize`), option ids re-used across cycles, a cycle whose
    `exerciseTimestamp` is already past, the strike not cross-checked against
    `clear.option().exerciseAmount` in the library, and `setCycle`'s `canReplaceCycle()` race
    (`ops/addresses.json` (leekzor/callhouse) `_race`).
16. **Admin without a timelock, and immutability.** No upgrade, no rescue, no timelock;
    `setDepositCap` and `setPolicy` are immediate and not cycle-aware; the admin can renounce
    and freeze governance; a wrong immutable is unfixable. Say whether the `Policy` caps are
    "cannot rug" bounds rather than merely "unlikely": 1% OTM, a 0.10%-of-notional weekly
    premium floor, 100% utilisation leaving nothing idle for the queue, a fee of 20% of premium.
    Confirm P-25.
17. **Valorem engine fee.** ValoremLib L74–88 mirrors `collateral × feeBps / 10_000` with a
    floor of 1, on top of collateral, verified only against `MockClear`; check rounding and
    fee-on-top versus fee-deducted against upstream `write`. A mismatch with
    upstream `write` at `6436c823` makes every write revert on allowance once the switch flips,
    with no upgrade. The fee is a pure NAV loss borne by depositors; the only guard is
    `acceptValoremFee`.
18. **Configuration drift on the Overcall side.** `overcallFeeRecipient`, zone, conduit key and
    the 500 bps per-contract rounding are immutable mirrors of a third party's off-chain order
    builder. Any change is a permanent liveness failure (`BadFeeSplit`), not a loss. The
    EIP-1271/validated path has never been exercised against Overcall's production validator
    (§7).

**D. Observability and test fidelity.**

19. `contractsAssigned()` integer-divides a fixed-point figure (event accuracy only; confirm it
    is never used for accounting). Untested error paths in ValoremLib: `OptionAssetMismatch`,
    `OptionExerciseAssetMismatch`, `UnexpectedLotSize`, `WriteReturnedNoClaim`,
    `ValoremFeesEnabled` (shadowed by Vault's earlier `ValoremFeeNotAccepted` check), and the
    catch branches of the three position views. `MockClear` and `MockSeaport` infidelities
    (§6). The duplicate `HALT / ADMIN` banner in Vault.sol was removed in this repository's
    `6023a96` (Appendix A item 11).

---

## 6. Prior review and test evidence

**Internal adversarial review, 2026-09-12** (SECURITY.md §4): 13 surfaces, 72 raw findings, 51
surviving refutation. Internal, not external. The thirteen defects fixed during the build and
the review (`tasks.md` (leekzor/callhouse) "Defects found and fixed during the build"; the review-era ones are
SECURITY.md §4 "Fixed" rows 1–5, where `tasks.md` (leekzor/callhouse) #11 merges SECURITY.md #2 and #3):

| # | Defect | Fix |
|---|---|---|
| 1 | Queued shares both escrowed and subtracted from the owner's balance; a full-position queue reverted | Escrow alone governs a queued share |
| 2 | A deposit during `Listed` shared premium earned before it arrived | `_checkpointHarvest()` before minting |
| 3 | Deposit cap measured on the raw token balance; writing to Valorem re-opened it | Measured on `totalAssets()` |
| 4 | `maxDeposit` ignored the phase gate | Returns 0 outside the deposit phases; `maxMint` added |
| 5 | `RollClose` emitted a hard-coded `0` assigned count | Read before `_redeemClaim` zeroes the claim key |
| 6 | `contractsSold` never updated | Both counts derived from the live ERC-1155 balance |
| 7 | The Valorem fee acceptance switch was decorative | Flag passed into the write path |
| 8 | `queueRedeem`'s auto-complete moved tokens, so a stale-slot holder could not queue under an issuer freeze | Settling parks into `owedAssets`/`owedQueueUsdg`; only `completeRedeem` touches tokens |
| 9 | The accrual index could promise one base unit more than held; `usdgOwed()` underflowed and bricked deposits and rolls, and a settled redeemer's principal was stranded | Accounting anchored on measured `usdgAccounted`; every payout clamped to `_usdgAvailableForHolders()` |
| 10 | **Critical.** Deposits open through the exercise window while assignment crashed NAV mid-transaction; riskless mint-against-crash extraction of strike proceeds | Deposit window closes on `cycleExerciseTs`; clock-independent refusal while unclaimed assignment proceeds exist |
| 11 | **High** (two findings). Registry `setCycle` bounded expiry only from below (years-long lock of up to 95% of collateral); the vault trusted the registry that the option's window matched the cycle's | `MAX_CYCLE_TENOR = 21 days`; `rollOpen` reverts `BadCycleWindow` and `OptionWindowMismatch` |
| 12 | **Medium.** Hard fee transfer inside `rollClose`; a blocklisted recipient, paused USDG or reverting receiver froze everything | Best-effort push, `pendingFeeUsdg`, permissionless `sweepFee()` |
| 13 | **Medium.** Accepted Valorem fee still could not write: the 15 bps is pulled on top of collateral and only collateral was approved | Approve collateral + fee, scrub the allowance after |

Regression tests for 10–13 are the eight tests in `test/unit/VaultSecurity.t.sol`
(`test_critical_cannotDepositAfterAssignmentCrashesNav`,
`test_critical_windowClosesEvenIfNobodyEverCallsLockBook`,
`test_critical_closedWindowStillLetsEveryoneOut`,
`test_high_refusesAnAbsurdlyLongCycleBeforeAnyCollateralMoves`,
`test_high_normalWeeklyCycleStillWrites`,
`test_high_refusesAnOptionWhoseWindowDiffersFromTheCycle`,
`test_medium_blockedFeeRecipientDoesNotFreezeTheVault`,
`test_medium_acceptedValoremFeeActuallyLetsTheVaultWrite`). Defect 9's regressions are
`test_accrualIndexCanPromiseMoreUsdgThanItCredited`, `test_accrualDriftCostsDustAndNothingElse`
and `test_settledRedeemerIsAlwaysPayable` in the invariant file. A keeper-focused sweep the
same day fixed 18 off-chain defects; out of contract scope.

**Unit and invariant tests**, all against mocks (`forge test --no-match-path 'test/fork/*'`,
measured 2026-09-13 at `a4c38b0` after `rm -rf cache/invariant`: `Ran 12 test suites in 12.34s
(60.29s CPU time): 310 tests passed, 0 failed, 0 skipped (310 total tests)`):

| Suite | Tests | Covers |
|---|---:|---|
| `test/unit/Policy.t.sol` | 48 | Every `validate` branch, band edges, premium floor, per-contract split (fuzzed), utilisation, harvest split, `normalizeSpot` |
| `test/unit/VaultDeposit.t.sol` | 42 | Rounding, cap semantics, phase gates, previews returning 0, allowances, inflation griefing, fuzzed round-trips |
| `test/unit/VaultListing.t.sol` | 63 | One negative test per SeaportOrderLib revert, fee split and partial-fill rounding (fuzzed), listing budget, cancel/invalidate permissions, EIP-1271 incl. fuzzed unrelated hashes, halt and oracle gates |
| `test/unit/VaultRoll.t.sol` | 35 | Every `rollOpen` gate, `lockBook`, `rollClose` timing and permissions, a full OTM cycle |
| `test/unit/VaultQueue.t.sol` | 34 | Escrow, epoch settlement, zero dust, reserves vs NAV/cap/collateral, issuer freeze, multi-epoch, fuzzed reservation bounds |
| `test/unit/VaultAdmin.t.sol` | 21 | Role wiring, halt/unhalt, hard caps, `maxPriceAge` bounds, fee recipient, Valorem fee switch, `uiMultiplier` never in share maths, freeze, `supportsInterface`, ERC-1155 hooks |
| `test/unit/VaultDistributor.t.sol` | 19 | Pro-rata index, claims, transfers, late-depositor isolation, fee routing, dust and unallocated carry, fuzzed claim bounds |
| `test/unit/VaultAssignment.t.sol` | 18 | Full/partial/zero assignment, the protocol fee base on assigned weeks, late depositor, queued redeemers through assigned weeks, fuzzed collateral/strike exactness |
| `test/unit/VaultSecurity.t.sol` | 8 | The review regressions above |
| `test/unit/Smoke.t.sol` | 4 | Fixture wiring, strike ladder, one clean cycle |
| `test/unit/SplitDiff.t.sol` | 2 | Contract split vs keeper vectors; fuzzed fillability |
| `test/invariant/VaultInvariant.t.sol` | 16 | The 8 `invariant_*` functions above (64 runs × depth 600, handler-driven with time as part of the fuzz, `afterInvariant` refusing vacuous or shrunk runs) plus 8 deterministic tests incl. `test_handlerReachesEveryState` |
| **Total** | **310** | |

`README.md` (L84) and `tasks.md` (leekzor/callhouse) both give 310 across 12 suites (Appendix A item 2).
`forge coverage` runs non-blocking in CI and has not gated anything.

**What the stateful suite can and cannot do.** The handler registers exactly 17 selectors
(`VaultInvariant.t.sol` L1036–1052): `deposit`, `mintShares`, `instantRedeem`,
`instantWithdraw`, `transferShares`, `queueRedeem`, `completeRedeem`, `claimUsdg`, `rollOpen`,
`approveListing`, `cancelListing`, `fill`, `exercise`, `rollClose`, `lockBook`, `warpAhead`,
`toggleHalt` (the last is `haltWrites` as guardian / `unhaltWrites` as admin, L789–812). Its
three actors and the buyer are a closed set; `transferShares` picks both ends from that set
(L358–364). It never calls `setPolicy`, `setDepositCap`, `setFeeRecipient`, `setMaxPriceAge`,
`acceptValoremFee`, `sweepFee`, `claimUsdgTo` or `invalidateAllListings`; never donates USDG or
Stock Token to the vault (its only mints are to the buyer for fills and exercises, L655/L713,
and to actors for deposits, L883); never pushes third-party ERC-1155 option tokens into the
vault; and never transfers shares to the vault address. Consequently the following §5 items are
covered, if at all, only by deterministic unit tests and not by the invariant run: A.5 (fee
sweep; `sweepFee` is never called, the fee leaves only through `rollClose`), A.6 and A.7
(donation as harvest; inflation and donation griefing: no donation of either token ever
happens), B.10 (ERC-1155 push inflating relist size), C.16 and P-25 (`setPolicy`, `setDepositCap`,
`setFeeRecipient` mid-cycle: no setter is ever called, the policy stays at `launchDefaults`),
C.13's `invalidateAllListings` leg, and the `queuedShares == balanceOf(vault)` equality in I-4.
Plan your own fuzzing there first.

**Fork tests against live chain 4663** (`FOUNDRY_PROFILE=fork`, `test/fork/ForkLive.t.sol`,
21 tests): code presence at every address, Seaport version string, token decimals, registry
pair binding and rejection of the JUGGERNAUT registry, cycle shape, unknown-rung refusal,
Valorem fee switch off, ERC-1155 support, feed liveness/age/normalisation, vault deploys and
reads spot, Seaport hashes our order shape, EIP-1271 rejects with nothing listed, guardian
bumps the real counter, a real Stock Token deposit, `uiMultiplier` display-only, oracle not
paused, a real Valorem write plus a real `seaport.validate` with the real EIP-712 digest
accepted by `isValidSignature` (`test_fork_writeAndListForReal`), and an out-of-band rung
refused. Not covered on the fork: any fill, any exercise, redeeming a real claim, `rollClose`,
distribution or claims.

**Keeper dry run** (`keeper/DRYRUN.md` (leekzor/callhouse), recorded 2026-09-13T05:49:32Z, anvil fork of chain
4663 at block 61720714): the keeper's production modules drove three full cycles against the real
Valorem Clear, Seaport 1.6, NVDA, USDG and Multicall3, with the real NVDA registry read for the
live series. Cycle 1: 25 NVDA deposited, 23 calls written at the 226 rung through the real
clearinghouse, listed through real `seaport.validate`, filled by a harness buyer through real
`seaport.fulfillOrder` with the 65-byte placeholder signature accepted via the vault's EIP-1271,
`lockBook`, then `rollClose` redeemed the real claim (gross 19.079259, fee 1.907925, net
17.171334, 0 assigned) and `claimUsdg` paid exactly `claimableUsdg`. Cycle 2: rolled while the
keeper was asleep, adopted by `reconcile()`, listed, unfilled, closed at 0. Cycle 3: the keeper
itself wrote 23 at the 225 rung and listed; the listing filled; the depositor queued 10 of 25
shares; spot was moved above the strike; after `lockBook` the buyer exercised 9 of 23 **on the real
clearinghouse** (debit exactly 2025 USDG, Clear fees off on the live chain); `rollClose` emitted
`RollClose(3, 14e18, 2025000000, 9)`, harvest gross 2044.079259 (19.079259 premium plus 2025
strike proceeds), fee 204.407925, net 1839.671334; the queue settled 6.4 NVDA and 735.868533
USDG to the queued shares, which `completeRedeem` paid exactly, and `claimUsdg` paid 1103.802800
for the remaining 15 shares, leaving 1 base unit of USDG owed. Stubbed or not proven: the registry
and feed were mocks (seeded with the real cycle and the real Chainlink answer), Overcall's API was
a stub implementing the recon shapes, token balances were written into storage, assignment was a
single exerciser in one transaction against a single writer (so Valorem's bucketed fair assignment
was trivial and the exercise-fee branch was not reached), and no cancel, partial fill, guardian
action or guardian `rollClose` ran. The USDG figures above are from that 05:49 run, under the
previous fee rule (1000 bps on all new USDG, strike proceeds included). It was re-run after the
2026-09-13 fee change (`keeper/DRYRUN.md` (leekzor/callhouse) "Re-run after the fee change", 2026-09-13T17:42:14Z,
fork block 62142174, on the uncommitted tree over `cb82bf3`) and passed: cycle 1 gross 19.079259,
fee 0.953962 (`floor(19_079_259 × 500 / 10000)`), net 18.125297; cycle 3 gross 2044.079259, fee
0.953962 on the premium leg alone with `RollClose.usdgFromAssignment` 2025 fee-free, net
2043.125297, queue 817.250118 USDG, `claimUsdg` 1225.875178. The harness now asserts every
`Harvest` fee against `floor((gross − feeFree) × bps / 10000)`.

**What none of this proves.** No external review has been done; these contracts are unaudited.
The EIP-1271/validated listing path has never been exercised against Overcall's production
validator (§7; `tasks.md` (leekzor/callhouse) L-04). Apart from the single exercise in the keeper dry run above, no exercise
has been run against the real clearinghouse: every assignment unit test is against `MockClear`, which does not fire `onERC1155Received` on mint,
does not model Valorem's bucketed fair assignment, and models `redeem`/`position` with simple
integer maths; `MockRegistry` stores strikes independently of the option's `exerciseAmount`.
`MockSeaport` hashes with a plain `keccak(abi.encode)`, does not model `OrderIsCancelled` on
re-validate or `OrderAlreadyFilled`, so "partial fill → cancel → re-approve" is reasoned about,
not executed against real Seaport. Distribution and claims have never run against the live
chain outside the dry run. Every figure in this document is from a local run: every GitHub
Actions run currently dies `startup_failure` at the account level (`tasks.md` (leekzor/callhouse) L-01), so CI has
not independently confirmed anything.

---

## 7. Known accepted risks and open questions

Open questions being closed before launch (`tasks.md` (leekzor/callhouse) "Open questions to settle before launch";
SECURITY.md §5):

1. **EIP-1271 vs Overcall's live validator.** The vault authorises by hash and ignores the
   signature bytes. Overcall's documented validation calls `isValidSignature` on a contract
   offerer, but this has never been exercised against their production server. One real
   1-contract listing is posted before launch (L-04); the self-hosted fill page on
   `/vault/nvda/cycle` is the fallback.
2. **Keeper prices at exactly the policy floor.** The vault re-reads spot at `approveListing`;
   an upward oracle tick between the two reads reverts `PremiumBelowMinimum`. Self-heals on
   the next tick; whether to add a margin is undecided. (Relists already price at
   `max(previous, live policy floor)`, `tasks.md` (leekzor/callhouse) K-17.)
3. **Deposit-time harvest checkpoint gas.** Correct but adds gas to every `deposit`/`mint`; to
   be measured on the first live week.

Accepted by design (SECURITY.md §4 "Known and accepted", plus decisions the per-contract
records flag; the auditor should confirm each is bounded as we claim rather than re-open it):

- **No upgradeability, no rescue function, no timelock on the Admin Safe.** A real bug means
  Vault v2 and a migration. The admin's entire value-extraction lever is `protocolFeeBps <=
  2000` (20%) of future harvested premium plus choosing `feeRecipient`. Strike proceeds are
  outside the fee base in bytecode, so a compromised admin cannot take a cut of principal on an
  assigned week; before 2026-09-13 it could (20% of strike proceeds at the ceiling).
- **The protocol fee is 5% of premium only (decided 2026-09-13).** Strike proceeds are credited
  to holders fee-free (P-26). On a fully assigned 10-contract week at a $231 strike with $2.00
  premium, the vault receives 19.00 USDG of premium after Overcall's cut and 2,310.00 USDG of
  strike proceeds; `Harvest` reports gross 2,329.000000, fee 0.950000
  (`floor(19_000_000 × 500 / 10000)`), net 2,328.050000 — the same fee as the unassigned week.
  Stacked with Overcall's 5% of gross, the total take is 9.75% of gross premium. The `Harvest`
  event ABI is unchanged, so on an assigned week `feeUsdg / grossUsdg` is not the rate; say
  whether that is adequately documented (ACCOUNTING.md §6, `ops/runbooks/close-week.md` (leekzor/callhouse)).
- **Any USDG that lands in the vault is harvest.** Donations are fee'd as premium and
  distributed to holders.
- **The fee push is best-effort** and `sweepFee` is permissionless; the fee can be delayed or,
  if the recipient is permanently blocklisted, stranded, never the vault.
- **`rollClose` is public after `cycleExpiryTs + 1 hour`**, and `lockBook` is public from
  `cycleExerciseTs`; anyone can bump the vault's Seaport counter at those phase gates. This is
  liveness insurance, not a hazard.
- **Guardian griefing** (cancel, counter bump, burn the three listing slots) costs a week's
  premium, never principal. A halt blocks only `rollOpen` and `approveListing`.
- **Keeper economic discretion inside policy** (rung, size, price down to the floor, three
  listings, or skipping) is bounded by the caps, not eliminated.
- **The registry owner is a single EOA.** Worst case is a skipped week; the tenor cap, the
  window check and the band refuse anything worse.
- **The Stock Token issuer can pause every Stock Token at once, blocklist the vault address,
  burn vault-held tokens (`adminBurn`), pause the oracle and upgrade the token**, each from a
  single EOA with no timelock (§4 "Freeze and blocklist surface"). Settlement then stops;
  queueing, share transfers and USDG claims keep working. Disclosed, not coded around.
- **USDG and the Stock Token are upgradeable proxies** under keys outside our control.
- **The 4663 sequencer is centralised with no uptime feed.** An outage surfaces as a stale
  price, which blocks writes.
- **`maxPriceAge` is days, not hours** (4 days at launch, ceiling 7) because the feed stops all
  weekend; Friday's close is treated as spot. No `roundId`/`answeredInRound` check.
- **The Valorem engine fee is opt-in** and, once accepted, a pure NAV cost to depositors of
  15 bps of notional per write. Live today: off.
- **`claimUsdg`/`claimUsdgTo` and ERC-20 transfers are not `nonReentrant`**; CEI plus
  hook-free tokens is the argument.
- **EIP-1271 answers for the raw order hash as well as the EIP-712 digest.** Seaport only ever
  presents the digest.
- **Deposits are refused whenever unredeemed assignment proceeds exist**, which can close
  deposits until `rollClose` even in `Listed`. Intended.
- **Fills are invisible to the vault**; the keeper detects them off-chain and must cancel or
  invalidate before relisting.
- **Late depositors in `Listed` share assignment**: a depositor who joins after the write but
  before `cycleExerciseTs` is priced on locked collateral and then bears assignment and
  receives strike proceeds pro rata, while premium already received is isolated by the
  checkpoint.
- **Shares transferred directly to the vault address are not rejected.** `_update` has no
  `to == address(this)` guard. Such shares are never burned or queued, so they are permanently
  unredeemable and the sender's loss only; the assets backing them stay in the vault and every
  other holder's `convertToAssets` is unaffected (I-4 is stated accordingly). The stateful suite
  never generates such a transfer. Whether a one-line revert is worth its bytes is asked in §5
  A.3.

---

## 8. Build and test instructions

Toolchain the numbers in this document were produced with: `forge 1.3.5-foundry-zksync-v0.1.9`
(commit `14afc70e251c89b7e2af6e6ac02e9ac6f095b5cc`), `anvil 1.6.0` (`f83bad91`), solc
`0.8.28+commit.7893614a`. CI uses `foundry-rs/foundry-toolchain@v1` with `version: stable`
(unpinned) and `FOUNDRY_PROFILE=ci`. Please state the forge build you reproduce with.

`foundry.toml`: `solc_version = "0.8.28"`, `evm_version = "cancun"`, `optimizer =
true`, `optimizer_runs = 200`, **`via_ir = true`** (needed for the Seaport/Valorem encoders),
`bytecode_hash = "none"`, `ffi = false`. Dependencies: OpenZeppelin Contracts v5.7.0 and
forge-std v1.16.2 as git submodules under `lib/` (`foundry.lock`).

```bash
forge fmt --check                                   # CI gate
forge build --sizes                                 # Vault runtime 23,426 B; margin 1,150 B
forge test -vvv --no-match-path 'test/fork/*'       # unit + invariant, mocks only: 310 tests
FOUNDRY_PROFILE=fork forge test --fork-url "$RH_RPC" -vvv   # 21 tests against live 4663
forge coverage --no-match-path 'test/fork/*' --report summary   # non-blocking in CI
```

`RH_RPC` defaults in CI to `https://rpc.mainnet.chain.robinhood.com`. That public endpoint
keeps historical state only for a trailing window of roughly 4,000–8,000 blocks
(`keeper/DRYRUN.md` (leekzor/callhouse)), so an anvil fork that runs for more than a few minutes needs an archive
endpoint. Sizes from `forge build --sizes` at `a4c38b0`: `Vault` runtime 23,426 B (margin
1,150 B), initcode 27,055 B;
`SeaportOrderLib` 5,694 B; `ValoremLib` 3,557 B; `Policy` 16 B (internal). `PolicyHarness`
(2,353 B) also appears in that table: it is a test-only wrapper around the internal library
and is not deployed. `forge build` prints forge-lint warnings that are expected and are not a
CI gate (the workflow runs `forge fmt --check`, `forge build --sizes` and `forge test`; no lint
step, no `deny` in `foundry.toml`): `unsafe-typecast` at `src/lib/ValoremLib.sol` L125 and L137
(both carry a `forge-lint: disable-next-line` comment that the current lint ignores),
`script/Deploy.s.sol` L131, `src/mocks/MockClear.sol` L131 and several `test/` files;
`erc20-unchecked-transfer` at four sites in three `test/unit/` files; `divide-before-multiply` at
`test/unit/SplitDiff.t.sol` L33. None is in the deployed path except the two `ValoremLib`
casts, which are the `int256 → uint256` clamps discussed in 3.3. Optimiser runs from 1 to 200
move the Vault figure by under 200 bytes.

Deploy and verify (`docs/DEPLOY.md`, the contract runbook; `README.md` "Deploying"; `ops/deploy.md`
(leekzor/callhouse) covers hosting only; `ops/safes.md` (leekzor/callhouse) §7):
`forge script script/Deploy.s.sol` with `ADMIN` = the deployer (the launch plan), `--broadcast
--verify` through `ops/bsproxy.js`; `Verify.s.sol` with `ADMIN_PHASE=bootstrap
EXPECT_KEEPER_CONFIGURED=false`; `Configure.s.sol` with `ADMIN_PK`; `Verify.s.sol` again; and later
`HandoverAdmin.s.sol` grant, a Safe transaction, renounce, and `Verify.s.sol` with `ADMIN_PHASE=safe`
(§3 "Scripts"). Every `forge script` against a fork or mainnet should pass `--no-storage-caching`
(`docs/DEPLOY.md`). The rehearsal is `script/rehearse-deploy.sh` against a local anvil fork of 4663.
`forge script` deploys and links both libraries automatically; manual linking is
`--libraries src/lib/SeaportOrderLib.sol:SeaportOrderLib:<addr>` and the equivalent for
`src/lib/ValoremLib.sol:ValoremLib`. Blockscout sits behind a Cloudflare challenge keyed on a
missing `Referer`; `ops/bsproxy.js` (leekzor/callhouse) injects one.

Traps (`tasks.md` (leekzor/callhouse) "Build constraints"):

- **EIP-170.** 1,150 B of headroom under via-IR at 200 runs. Any remediation that adds more than
  a small amount of code to `Vault` needs a third library extraction, not an optimiser setting.
  Re-run `forge build --sizes` on every fix.
- **Tag space.** Each unit suite deploys the whole fixture; with via-IR on, another
  fixture-heavy suite can produce `Internal compiler error (CompilerStack.cpp:1417): Assembly
  exception for bytecode: Tag too large for reserved space`. Put shared sequences in helpers on
  `BaseTest` (`test/Base.t.sol`) rather than repeating them.
- **`cache/invariant`.** Foundry replays persisted counterexamples; clear the directory after
  changing contract behaviour or a stale one reports as a mystery failure elsewhere.
- **Invariant depth.** The suite is configured inline (`/// forge-config:
  default.invariant.runs = 64`, `depth = 600`, VaultInvariant.t.sol L1004–1005) and
  `afterInvariant` refuses a run that did not reach exactly that depth; do not lower it to go
  faster.
- **Stale artefacts.** A `Vault.json` compiled with a library pinned to a placeholder address
  will link only the other library and DELEGATECALL `0x1111…1111` at runtime
  (`keeper/DRYRUN.md` (leekzor/callhouse)). A clean `forge build` against the committed `foundry.toml` has both
  libraries in `linkReferences` and `metadata.settings.libraries == {}`.
- **ABIs flow one way**: `out` → `ops/abis/Vault.json` (leekzor/callhouse) → generated copies in
  `indexer/` and `web/` (leekzor/callhouse); the keeper's `keeper/src/abi.ts` (leekzor/callhouse) is hand-transcribed.

---

## 9. Deliverables and severity

**Report.** Markdown (a PDF as well is fine), against the pinned commit, containing:

1. Per finding: title, severity, location (`file:line` at the pinned commit), description,
   impact in money terms, a proof of concept (a forge test on the `BaseTest` fixture in
   `test/Base.t.sol` where feasible; the mocks in `src/mocks/` are the
   fixture's dependencies), recommendation, and status after our fix.
2. A verdict per property in §5 (P-01 … P-26, I-1 … I-7): held, broken (with the finding), or
   not assessed.
3. A verdict per integration assumption in §3 and §4 (Valorem, Seaport, USDG, Stock Token,
   Chainlink, registry): confirmed, refuted, or not assessed, with the upstream source line
   where confirmed.
4. What was not reviewed, and why.
5. The exact toolchain and the `forge build --sizes` output at the reviewed commit and at the
   fix commit.

**Severity, in money terms.** These are our definitions; if you use your own scale, please map
each finding to both.

| Severity | Definition |
|---|---|
| Critical | Loss or permanent freeze of depositor principal (Stock Token, or USDG owed to holders or the queue) by any actor other than an honest `DEFAULT_ADMIN_ROLE` acting inside the caps; any path by which the keeper, guardian, admin, a third party, or a token holder moves a token they do not own; any way to brick `rollClose` from outside the trust assumptions in §7 |
| High | Theft or loss of a week's premium or strike proceeds beyond dust; extraction from other depositors through share mispricing; any bypass of a bytecode-enforced property in §5; any role reaching a power outside the table in §2; a liveness failure that requires a redeploy and is reachable by an external actor without a trust-assumption violation |
| Medium | Bounded loss (rounding beyond the documented dust, or capped by policy at the keeper's discretion); griefing whose cost to the attacker is comparable to the damage; a liveness failure that a trusted actor can trigger or that requires an accepted-risk actor (issuer, Paxos, Valorem owner, registry EOA) to act; mis-accounting in views or events that would lead an off-chain system to a wrong money decision |
| Low | Deviations from stated invariants or best practice with no money impact; defence-in-depth gaps; dead code with a plausible future hazard |
| Informational | Code quality, gas, documentation mismatches (Appendix A), test gaps |

**Fix and re-review.** We fix on a branch, one commit per finding where practical, each with a
regression test in the style of `VaultSecurity.t.sol`. Every fix must keep `Vault` under
EIP-170 (§8) and pass the full local gate. We ask for one re-review pass over the diff and a
re-issued report with per-finding status. Findings we decline to fix are listed in the final
report with our rationale.

**Disclosure timeline.** The report is private during the engagement and the fix window. The
final report, with statuses, is published in this repository before mainnet deposits open
(`tasks.md` (leekzor/callhouse) L-07); the exact path is to be confirmed (Appendix B). Until then the site and
SECURITY.md describe the contracts as unaudited, and a report is a favour, not a claim
(SECURITY.md §6). Nothing in this document or the report should be quoted as a security
guarantee.

**Bug bounty.** A bounty with a dedicated disclosure channel opens in mainnet week 2
(`tasks.md` (leekzor/callhouse) E-07). Its scope will mirror §3 and reuse the severity table above; the disclosure
address is the one from §1 once populated.

---

## Appendix A. Discrepancies in our own documents

So the auditor does not trip over them. The code is the spec in every case below. Resolved items
stay listed with the commit that resolved them; statuses in leekzor/callhouse files were read at
that repository's `79e6a19`.

1. **Resolved 2026-09-13.** ACCOUNTING.md §6 said "both [fees] are on the premium only" while
   the code charged 1000 bps on the whole USDG inflow, strike proceeds included. The decision was
   to make the code match the premium-only intent at 500 bps: `Vault.sol` `_accrueHarvest(feeFree)`
   L829–841, `Policy.launchDefaults` L118. ACCOUNTING.md §6, README.md (leekzor/callhouse), TECHSPEC.md (leekzor/callhouse), the
   site and the dapp now say 5% of premium, and the keeper dry run was re-run under the new rule
   (§6). One residue: the keeper's `roll_close` alert still quotes harvest gross including strike
   proceeds on an assigned week, so fee/gross read from keeper output is not the rate
   (`keeper/DRYRUN.md` (leekzor/callhouse), `tasks.md` (leekzor/callhouse) K-21).
2. **Resolved.** `README.md` (line 51 at `27d502a`) said "328 unit and invariant tests" while the
   measured count was 307. Corrected to 307 in leekzor/callhouse `cb82bf3` (this repository's
   `0bc700e`); at `a4c38b0` `README.md` L84 says "310 unit and invariant tests across 12 suites,
   21 fork tests", which is the measured figure (§6) and the one in `tasks.md` (leekzor/callhouse).
3. **Still true; explanatory, nothing to fix.** `tasks.md` (leekzor/callhouse) lists 13 defects;
   SECURITY.md §4 has 5 review rows. `tasks.md` (leekzor/callhouse) #11 merges SECURITY.md #2
   (tenor cap) and #3 (window mismatch).
4. **Resolved** in leekzor/callhouse `cb82bf3`. `README.md` (leekzor/callhouse) (line 165 at
   `27d502a`) said the launch deposit cap is "20–50 NVDA"; it now says "20 NVDA at launch"
   (L190), matching `Deploy.s.sol`'s `LAUNCH_DEPOSIT_CAP = 20e18` and `tasks.md` (leekzor/callhouse)
   L-07.
5. **Resolved** in leekzor/callhouse `7c60478`. `README.md` (leekzor/callhouse) (line 96 at
   `27d502a`) said SECURITY.md covers "audit scope". Its documentation table (L119–120) now
   describes `contracts/SECURITY.md` as the threat model, trust assumptions and the 2026-09-12
   review, and lists `contracts/docs/AUDIT-SCOPE.md`, this file, as the audit scope.
6. **Partly resolved.** `Deploy.s.sol`'s NatSpec mentioned manual linking for `SeaportOrderLib`
   only; since this repository's `6023a96` it names both libraries (L19–23). **Still open:**
   `ops/addresses.json` (leekzor/callhouse) `chains.4663.ours` has a `seaportOrderLib` slot and no
   `valoremLib` slot (`docs/DEPLOY.md` step 5 says to add one at deploy). Both libraries are
   linked (5 sites).
7. **Resolved** in this repository's `a4c38b0`. ACCOUNTING.md §7 listed six invariants while the
   suite had seven functions; the fee change added `invariant_feeNeverTouchesStrikeProceeds`, and
   §7 now lists all eight `invariant_*` functions as the code asserts them (USDG solvency is split
   into `invariant_usdgBooksBalance` and `invariant_usdgHolderSolvency`; §5 I-1 … I-7).
8. **Resolved.** `writesHalted` gates `rollOpen` (L677) and `approveListing` (L732), and those
   checks are the spec; three documents said a halt blocks `rollOpen` only. `docs/ARCHITECTURE.md`
   (leekzor/callhouse) §3 was corrected in leekzor/callhouse `cb82bf3` and now reads "Pause and halt
   block `rollOpen` and `approveListing` **only**" (L127). `README.md` (L117 at `27d502a`) was
   corrected in the same commit (this repository's `0bc700e`) and now reads "A halt blocks
   `rollOpen` and `approveListing` **only**" (L194). The audited source's own NatSpec was
   corrected in this repository's `6023a96`: `writesHalted` (L115) now says "When true, `rollOpen`
   and `approveListing` are blocked. Nothing else is." and `haltWrites` (L1005–1006) "Block
   `rollOpen` and `approveListing`. Never blocks redemptions, claims, `cancelListing`, `lockBook`
   or `rollClose`." SECURITY.md and `ops/safes.md` (leekzor/callhouse) §3 had it right.
9. **Resolved** in this repository's `6023a96`. `IValoremClear.sol`'s header referred to a
   vendored `lib/clear` tree, `script/lib/ValoremDeployer.sol` and
   `src/vendor/ValoremArtifacts.sol`, none of which exists in this checkout. The header now
   states the file's provenance: a verbatim copy of the interface in the verified source of
   Overcall's NVDA registry, itself a hand transcription of Valorem's clearinghouse at upstream
   `6436c82`, with only comments changed (§3 "Interfaces").
10. **`Policy.sol`.** `USDG_ONE` was declared and unused; **removed** in this repository's
    `6023a96`. `maxContracts` (L223) is unused in `src` (`checkContracts` re-derives the same
    formula) and is **kept on purpose** as the tested reference formula (`test/unit/Policy.t.sol`)
    that the keeper's `maxContracts` (`keeper/src/policy.ts` (leekzor/callhouse)) mirrors.
    Unchanged observation: `strikeBand` and `minPremium` are reached only through
    `checkStrike`/`checkPremium`.
11. **Resolved** in this repository's `6023a96`. `Vault.sol`'s `HALT / ADMIN` section banner
    appeared twice, with the fee-sweep section between them; the empty first copy was removed and
    the one remaining banner (L1001–1003) heads the halt and admin functions. Cosmetic.
12. **Superseded by the bootstrap plan.** `ops/safes.md` (leekzor/callhouse) §7 says "Then, and
    only then, the deployer renounces `DEFAULT_ADMIN_ROLE`". An earlier revision of this appendix
    called that wrong because `Deploy.s.sol` then always passed the Safe as `admin`. The launch plan
    is now that the deployer key IS the admin at launch (`ADMIN`), so a renounce step exists again;
    `HandoverAdmin.s.sol` performs it, after granting the Safe and seeing the Safe execute.
    `ops/safes.md` §7 should point at that script and `docs/DEPLOY.md` path A rather than raw
    `cast` calls.

## Appendix B. To be confirmed

Items in this document that are placeholders or unverified, so nobody mistakes them for
facts:

- Engagement timeline; the pinned commit and its `audit-<date>` tag; the engagement contact
  channel; the delivery mechanism for repository access (§1).
- Housekeeping before the tag. **Done:** the `writesHalted` and `haltWrites` NatSpec
  (`Vault.sol` L115, L1005–1006) and `README.md` (L194) say `rollOpen` and `approveListing`
  (Appendix A item 8; this repository's `6023a96` and `0bc700e`); the `IValoremClear.sol` header
  no longer refers to `lib/clear`, `script/lib/ValoremDeployer.sol` or
  `src/vendor/ValoremArtifacts.sol` (Appendix A item 9; `6023a96`); every line number in this
  document that points into this repository was re-derived at `a4c38b0`. **Remaining:** re-check
  those line numbers at the tag, and re-derive the step 1 and step 2 tables in `ops/safes.md`
  (leekzor/callhouse) §4, which are still at `27d502a`.
- Site hosting at `callhouse.xyz`: the domain currently serves a registrar parking redirect,
  not the site build (leekzor/callhouse-site), so the RFC 9116 path does not exist yet (§1).
- The public disclosure address (`NEXT_PUBLIC_SECURITY_CONTACT_EMAIL`, `tasks.md` (leekzor/callhouse) L-05) and the
  path where the final report will be published in the repository (§9).
- Whether Zellic's August 2023 patch review covers the whole `ed53af23 → fe39eb73` delta of
  `ValoremOptionsClearinghouse.sol`, i.e. whether the deployed source has had full-scope
  external review after the rename (§4; `ops/recon/R4-valorem-abi.md` (leekzor/callhouse) caveat 5). We have not
  diffed that range line by line.
- Source match of the live USDG implementation `0x68184c449e1a8f34fa18d289737129fd27b66f8f` to
  a specific audited commit of `paxos-token-contracts`, and whether the `TimelockController` at
  `defaultAdmin` can actually perform the UUPS upgrade (`ops/recon/R10-address-audit.md` (leekzor/callhouse)
  §UNRESOLVED, "USDG upgrade authority mechanics") (§4).
- Any Robinhood-commissioned audit of the Stock Token contracts (none found), and the contents
  of Robinhood's "Report an Issue" page (`https://docs.robinhood.com/chain/report-an-issue/`,
  which did not render for us). The freeze/blocklist facts in §4 are from
  `ops/recon/R6-stock-token.md` (leekzor/callhouse) (live reads and state-override proofs, 2026-09-12); R6 proves
  the registry-level pause by override and only infers the per-token `pause()`, and could not
  name one registry role hash (`0xb4e5de73…84f8`, held by an EOA).
- Any Seaport audit specific to 1.4, 1.5 or 1.6 (none found); the OpenZeppelin review OpenSea's
  launch post mentions (no document found; not cited).
- **Resolved:** the unit and invariant test counts and suite figures in §6 after the
  2026-09-13 fee change were re-measured at `a4c38b0` (310 across 12 suites, §6).
- The L-04 live 1-contract listing against Overcall's production validator (§7).
- The Valorem engine fee status at engagement time (off as of the 2026-09-12 fork run).
- The deployed addresses of `Vault`, `SeaportOrderLib` and `ValoremLib`, and the link targets in
  the deployed runtime (nothing is deployed yet).
- What the 2026-09-13 deploy rehearsal (`docs/DEPLOY.md`, fork block 62201116) does not prove: the
  Safe{Wallet} Transaction Builder UI importing the generated batch file (only its format and
  calldata were checked; the Safe contract executed the same calls); hardware-wallet signing and
  the Safe{Wallet} transaction service on 4663; Blockscout source verification through
  `ops/bsproxy.js` (leekzor/callhouse) (not run on a fork); and anything after configuration on
  that vault (first `rollOpen`, listing, fill), which the keeper dry run covers only on a separately
  deployed vault (§6).
- CI green on GitHub (`tasks.md` (leekzor/callhouse) L-01); every figure here is from a local run.
- The forge build the auditor reproduces with (§8).

## Appendix C. Addresses on chain 4663

All rows reconfirmed 2026-09-12 by `ops/recon` (leekzor/callhouse) (`ops/addresses.json` (leekzor/callhouse), `_reconfirmedAt
2026-09-12T18:36:00Z`, block 61322378), unless marked.

| What | Address |
|---|---|
| Valorem Clear (`ValoremOptionsClearinghouse`) | `0x9a7b40e5c1dB1Af822ef091c990b58b02C78C0C0` |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |
| Seaport ConduitController (present, unused) | `0x00000000F9490004C11Cef243f5400493c00Ad63` |
| USDG (Paxos, 6 dp, UUPS proxy) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| NVDA Stock Token (18 dp, beacon proxy) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| NVDA Stock Token implementation (at recon time) | `0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2` |
| Overcall NVDA registry | `0x8E973cE1A6884E28Ad3E377d5f670Bc0b463f4EA` |
| Overcall JUGGERNAUT registry (the trap; never wire it) | `0x65dD407955912Be814f723724cE60f91ebd72616` |
| Overcall registries owner (EOA) | `0x408adcFFebDF48EC23F1E3811A91AeD3cC951CC0` |
| Overcall fee recipient (EOA; also Valorem `feeTo`) | `0xdAe7e82A2E7D566C67E87C164B05a1C560190782` |
| Chainlink NVDA/USD `AggregatorProxy` (8 dp) | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| Chainlink USDG/USD (unused) | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |
| Chainlink sequencer uptime feed | none |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| Vault, SeaportOrderLib, ValoremLib, Admin Safe, Fee Safe, keeper, guardian | not deployed |

Launch parameters (`Deploy.s.sol`, `Policy.launchDefaults()`): `minOtmBps 300`, `maxOtmBps
1200`, `minPremiumBps 40`, `maxUtilizationBps 9500`, `protocolFeeBps 500` (5% of premium), `maxContractsCap
50`, `maxPriceAge 4 days`, `depositCap 20e18`, `conduitKey bytes32(0)`, `zone address(0)`,
name/symbol "Callhouse NVDA"/"cNVDA". Role ids: `KEEPER_ROLE =
0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab`, `GUARDIAN_ROLE =
0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041`.
