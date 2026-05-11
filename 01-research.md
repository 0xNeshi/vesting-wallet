---
stage: research
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-11
author: 0xNeshi
previous_stage: null
tags: [vesting, finance, openzeppelin, contracts-sui]
---

# Vesting Wallet (Sui) — Research Report

## Summary
A standardized, audited Vesting Wallet primitive is missing from Sui's library landscape — `OpenZeppelin/contracts-sui` does not ship one yet (tracked under Milestone 3, issues [#155](https://github.com/OpenZeppelin/contracts-sui/issues/155) and [#156](https://github.com/OpenZeppelin/contracts-sui/issues/156)), and the only publicly visible options are an educational `locked_coin` example, a Sui docs walk-through, and the heavier `kunalabs-io/sui-smart-contracts` token-distribution protocol. Recommendation: **build** a Sui-native VestingWallet that mirrors OZ's `VestingWallet.sol` semantics with Sui adjustments (single `Coin<T>` per wallet, shared-object beneficiary model, ms-precision via `&Clock`, top-up supported, beneficiary-change via the project's existing two-step ownership transfer), plus a `VestingWalletCliff` extension matching the OZ cliff variant.

## Existing Sui Implementations

### 1. Mysten `locked_coin` example (educational)
- Source: `sui-foundation/sui-move-intro-course` — [unit-three/lesson 6 — Clock and Locked Coin](https://github.com/sui-foundation/sui-move-intro-course/blob/main/unit-three/lessons/6_clock_and_locked_coin.md)
- Shape: a `Locker` object containing `start_date`, `final_date`, `original_balance`, `current_balance`. `locked_mint` creates the locker and `transfer::public_transfer`s it to the recipient (owned object). `withdraw_vested` lets the owner claim the linearly vested portion.
- Linear curve only. No cliff. No top-up after creation. No beneficiary change. One coin type per locker (generic `T`).
- Status: **example, not a library**. Not audited, not packaged for reuse.

### 2. Sui docs — Token Vesting Strategies
- Source: [docs.sui.io/concepts/tokenomics/vesting-strategies](https://docs.sui.io/concepts/tokenomics/vesting-strategies)
- Conceptual reference for cliff, graded, hybrid (cliff + linear). Educational snippets, not a deployable package.

### 3. `kunalabs-io/sui-smart-contracts` — `token-distribution`
- Source: [kunalabs-io/sui-smart-contracts](https://github.com/kunalabs-io/sui-smart-contracts)
- Primitives: `time_locked_balance`, `time_distributor`, `accumulation_distributor`; higher-level `farm`, `pool`.
- Multi-member, weight-based distribution with `top_up`, member add/remove, change-weight. Designed for yield-farming/liquidity-mining, not "single beneficiary, simple schedule".
- README explicitly marks it **unaudited**.

### 4. OpenZeppelin Contracts for Sui — none yet
- Source: [OpenZeppelin/contracts-sui](https://github.com/OpenZeppelin/contracts-sui) (current contents at `contracts/`: only `access/ownership_transfer/{two_step.move, delayed.move}` and the math packages).
- Roadmap signal: issue [#155 "Vesting Wallet"](https://github.com/OpenZeppelin/contracts-sui/issues/155) (closed, Milestone 3) and [#156 "Vesting Wallet Cliff"](https://github.com/OpenZeppelin/contracts-sui/issues/156) (open, Milestone 3, assigned to Nenad). Both reference the Solidity v5.x `finance` page.

### Limitations across what exists
- **Single linear curve.** None expose a clean OZ-style `vestedAmount(timestamp)` hook that protocols can override.
- **No first-class cliff** in any reusable Sui module.
- **No "fund-after-creation"** semantics — OZ guarantees that deposits made after start vest "as if locked from the beginning". Locker-style implementations bake the amount in at construction.
- **No beneficiary change** path — Mysten's locker is owned by the recipient (transfer = sell unvested), kunalabs' distributors require admin reconfiguration. Neither matches OZ's `Ownable` semantics.
- **Bespoke per-protocol forks.** Cetus (xCETUS escrow/redemption), NAVI (NAVX vesting), and other Sui DeFi teams each rolled their own — increasing audit surface and divergent semantics.

## Cross-Ecosystem Implementations

### Solidity / EVM — OpenZeppelin VestingWallet
Source: [`finance/VestingWallet.sol` @ master](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/8b010f923a0f81599a3f8bab309a47ec99c62764/contracts/finance/VestingWallet.sol)

Core API (paraphrased):

```solidity
contract VestingWallet is Context, Ownable {
    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds);
    function start() public view returns (uint256);
    function duration() public view returns (uint256);
    function end() public view returns (uint256);
    function released() public view returns (uint256);                 // ether
    function released(address token) public view returns (uint256);    // per-ERC20
    function releasable() public view returns (uint256);
    function releasable(address token) public view returns (uint256);
    function release() public;                                          // ether
    function release(address token) public;                             // ERC20
    function vestedAmount(uint64 ts) public view returns (uint256);
    function vestedAmount(address token, uint64 ts) public view returns (uint256);
    // Linear curve: vested = total * (ts - start) / duration, clamped.
    function _vestingSchedule(uint256 totalAllocation, uint64 ts) internal view virtual;
}
```

Notable properties carried by the spec:
- **`vestedAmount` is `balance_now + released`**, so any *later* deposit "vests as if from the beginning".
- **Linear by default; subclass overrides `_vestingSchedule`** for any other curve.
- **Beneficiary == owner**; ownership transferable via `Ownable` (and `Ownable2Step` for safety). Documented caveat: transferring ownership can effectively sell unvested rights.
- Known issue: aggregate deposits exceeding `type(uint256).max` brick the contract ([#5793](https://github.com/openzeppelin/openzeppelin-contracts/issues/5793)). On Sui this becomes a `u64` concern, materially smaller headroom.

Cliff extension: [`finance/VestingWalletCliff.sol`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/8b010f923a0f81599a3f8bab309a47ec99c62764/contracts/finance/VestingWalletCliff.sol):

```solidity
abstract contract VestingWalletCliff is VestingWallet {
    constructor(uint64 cliffSeconds);  // reverts if cliffSeconds > duration()
    function cliff() public view returns (uint256);     // start() + cliffSeconds
    function _vestingSchedule(uint256 total, uint64 ts) override
        returns (uint256) { return ts < cliff() ? 0 : super._vestingSchedule(total, ts); }
}
```

OZ cliff semantics — **important to note**: 0 released before the cliff; at the cliff, releasable jumps to the *linear-from-start* proportion (i.e. `total * cliffSeconds / duration`), not to zero. After the cliff the underlying linear schedule continues. The tests already in `tests/vesting_wallet_tests.move` (`release_at_cliff_jumps_to_proportional`) match this exact semantic.

### Aptos Move — `aptos_framework::vesting`
Source: [aptos-core `aptos-framework/sources/vesting.move`](https://github.com/aptos-labs/aptos-core/blob/d8be469f7f0b9222013a999e31c18ed6cd9ad1d1/aptos-move/framework/aptos-framework/sources/vesting.move)

Very different design point — a heavyweight, staking-integrated grant pool:
- `VestingContract` is a resource on a derived account, with: `admin`, `grant_pool: pool_u64::Pool` (multi-shareholder shares), `beneficiaries: SimpleMap<shareholder, beneficiary>`, `vesting_schedule: VestingSchedule { schedule: vector<FixedPoint32>, start_timestamp_secs, period_duration, last_vested_period }`, `staking: StakingInfo`, `state` (active/terminated).
- Schedule is a vector of fractions per period; the last fraction repeats until the grant runs out (e.g. `[3/48, 3/48, 1/48]` with a 1-month period and 1-year cliff).
- Shareholders call `unlock_rewards` / `vest` / `distribute`; admin can change beneficiary, voter, operator, lockup, and terminate.
- Conclusion: Aptos solved a different problem (staking-aware multi-shareholder grants tied to validator commission). It is **not** the right model to port — confirms that OZ's lighter "single wallet, single beneficiary, single coin" primitive is the gap to fill on Sui.

### Other ecosystems (brief)
- **Solana** — Streamflow and other off-the-shelf vesting/streaming products dominate; vesting is treated as application-layer infra rather than a primitive in `spl-token`. Reinforces that a primitive library on Sui is a fresh niche, not a duplicate.
- **CosmWasm** — `cw-vesting` follows OZ's spirit (single-account vesting) and is the closest cross-chain analog to the proposed module.

## Ecosystem Needs

- **Token launches on Sui.** Sui's own tokenomics use cliff + linear/non-linear vesting across early-investor, Series A/B, team, and community allocations; the same shape recurs for every team that launches a Coin on Sui. They each currently roll their own or fork the Mysten example.
- **Protocol-side escrow/redemption.** Cetus' `xCETUS` redemption model and NAVI's `NAVX` allocation vesting are functional bespoke vesting flows. A standardized primitive doesn't eliminate these (they're protocol-specific), but it does provide the building block that the simpler ones could reuse.
- **`OpenZeppelin/contracts-sui` consumers.** Anyone already adopting `contracts-sui` for `access` + math primitives will reasonably expect `finance/vesting_wallet` next, by analogy with the EVM library. The pre-existing Milestone 3 issues are the demand signal.
- **Integration shape protocols need:** (1) create a wallet for a beneficiary with a schedule, (2) deposit a `Coin<T>` (possibly multiple times over time — e.g. emissions schedules), (3) permissionless `release` (anyone can poke), (4) optional cliff, (5) optional beneficiary transfer (two-step), (6) clean accessors for off-chain UIs (`released`, `releasable`, `vested_amount(now)`, `start`, `duration`, `end`).

## Gap Analysis

| Need                                     | Mysten `locked_coin` | Sui docs example | kunalabs `token-distribution` | Proposed module |
|------------------------------------------|----------------------|------------------|-------------------------------|-----------------|
| Single beneficiary, simple schedule       | ✅                  | ✅              | ✗ (multi-member)              | ✅              |
| Top-up after creation                     | ✗                   | ✗               | ✅                            | ✅              |
| Cliff support                             | ✗                   | ✅ (example)    | ✗                             | ✅              |
| Overridable schedule (OZ-style hook)      | ✗                   | ✗               | ✗                             | ✅              |
| Beneficiary changeability                 | ✗ (or sell-locker)  | ✗               | (admin reconfig)              | ✅ (two-step)   |
| Audited / library-grade                   | ✗ (educational)     | ✗               | ✗ (unaudited)                 | ✅ (planned)    |

What should be standardized:
- The `(start, duration)` schedule API and the `released / releasable / vested_amount` getter trio.
- A reusable cliff variant that does not redefine the linear curve, just gates it (matches OZ).
- Permissionless `release` with the coin routed to the beneficiary stored in state (Sui-natural mapping of "owner-only `release` to the owner" in EVM).

What is deliberately *not* aimed at being standardized: schedule semantics that depend on staking yields, multi-shareholder distribution, or token-emission farming — `kunalabs/token-distribution` already occupies that space and Aptos shows the complexity cost of bundling them.

## Sui-Model Constraints That Shape the Design

- **No `address(this).balance`.** Sui contracts hold value as `Balance<T>` or `Coin<T>` *inside* an object — `vested_amount` must use `balance_value + released` to preserve OZ's top-up semantics.
- **One coin type per wallet.** `T` is a compile-time type parameter, not a runtime token address. The EVM "release(token)" overload disappears; multi-token wallets become multiple objects.
- **Shared vs owned object — pick one for the wallet.** OZ's "anyone can call `release`, vested coin goes to the beneficiary" maps cleanly to a **shared** wallet with `beneficiary: address` stored in state. The owned-object route (transfer the wallet to the beneficiary) breaks "anyone can poke" and re-introduces the transferable-ownership = sellable-unvested problem with no clean fix. Tests in the repo already use `transfer::public_share_object` — implicit confirmation of the shared model.
- **Time is `&Clock` (milliseconds).** `start`/`duration` should be `u64` ms to align with `clock::timestamp_ms`. Tests already use ms math.
- **No `Ownable` trait, but `contracts-sui` ships `access/ownership_transfer/two_step.move`.** Beneficiary changeability should compose with that module rather than re-invent ownership.
- **`u64` overflow surface is much tighter than `u256`.** Aggregate deposits over the life of a wallet need to fit in `u64` (max ~1.8e19). For typical token decimals (9 on most Sui coins) this is comfortable, but document the bound; the analog of OZ [#5793](https://github.com/openzeppelin/openzeppelin-contracts/issues/5793) is a real concern.
- **No virtual functions / inheritance.** OZ's "subclass and override `_vestingSchedule`" must be re-expressed. Two viable options: (a) a generic `VestingWallet<T, S: VestingSchedule>` with the schedule as a type-class-style witness, or (b) ship distinct sibling modules (`vesting_wallet`, `vesting_wallet_cliff`) where the cliff module composes the linear math internally. Option (b) is what the repo's test scaffolding already implies (`vesting_wallet_cliff` as its own module).
- **No `payable` / native-currency overload.** Everything is `Coin<SUI>` like any other coin — the EVM ether/ERC20 split collapses to one path.

## Recommendation

- **Verdict:** **Build.** Filling a known gap in `OpenZeppelin/contracts-sui` (issues #155/#156, Milestone 3) with a Sui-native port of a battle-tested OZ primitive. No audited equivalent ships in Sui's library landscape today.
- **Recommended approach:** Mirror OZ `VestingWallet` semantics — shared `VestingWallet<T>` object with `beneficiary`, `start`, `duration`, `released`, `balance: Balance<T>` — backed by the OZ invariant `vested_amount(now) = total * (now - start) / duration` over `balance_value + released`. Permissionless `release(&mut self, &Clock, &mut TxContext)` transfers releasable coin to the stored beneficiary. Ship `vesting_wallet_cliff` as a sibling module wrapping the linear math, matching the OZ cliff semantics ("zero before cliff, then the underlying linear curve" — i.e. proportional jump at the cliff). Compose beneficiary change with `contracts/access/ownership_transfer/two_step.move` rather than re-implementing.
- **Key design considerations:**
  1. **Object model = shared wallet with `beneficiary: address` in state.** Allows permissionless `release` and matches OZ semantics. Reject the owned-locker model.
  2. **Top-up must preserve "vested as if from start".** `vested_amount` uses `balance_value(now) + released`, not a stored `original_balance`.
  3. **Cliff variant follows OZ exactly.** At cliff time, releasable jumps to `total * cliff / duration`; *not* a "linear-from-cliff" curve. The existing test `release_at_cliff_jumps_to_proportional` already encodes this; the implementation must match.
  4. **Time unit is `u64` milliseconds via `&Clock`.** Document this clearly — the OZ Solidity reference uses seconds.
  5. **`u64` capacity is the cliff edge case.** Either bound aggregate deposits with a depositor-side check, or accept the "wallet bricked if you try to deposit past `u64::MAX`" behavior and document it.
- **Risks:**
  - Selling unvested rights via beneficiary transfer is unsolvable at the contract level; same trade-off OZ accepted, must be documented.
  - Integer overflow on aggregate balance (`u64`) is tighter than EVM's `u256` — needs explicit consideration in the design and tests.
  - Scope creep into the kunalabs/Aptos space (multi-shareholder, staking-aware) — must be explicitly resisted to keep this a primitive.
  - Shared-object contention for `release` is theoretically possible but in practice irrelevant for vesting traffic patterns.

## Out of Scope

- **Multi-shareholder / pooled grants** — covered by `kunalabs/token-distribution` and Aptos' framework module; bundling them would defeat the "primitive" purpose.
- **Staking-aware / yield-bearing vesting** — Aptos territory; not OZ's `VestingWallet` shape.
- **Non-linear / parameterized schedule curves** beyond linear and cliff — leave as a future extension (`VestingWalletNonLinear`); OZ ships only linear + cliff in its `finance` namespace as of v5.x.
- **Streaming / per-second payouts** (à la Sablier, Streamflow) — different UX, different contention profile; not requested in #155/#156.
- **NFT-based vesting representations** (transferable vesting positions) — would re-introduce the "sell unvested rights" problem the shared-wallet model is meant to avoid.

## Dev Notes

- The repo's existing `tests/vesting_wallet_tests.move` targets `vesting_wallet_cliff` already and `sources/vesting_wallet.move` is empty — the immediate piece of work mapped to issue #156 is the **cliff extension**, but completing it cleanly requires the base `vesting_wallet` to exist first (issue #155). Treat this research as covering both; the Design stage decides whether to ship them as one PR or two.
- `OpenZeppelin/contracts-sui` already includes `access/ownership_transfer/two_step.move` — Design should compose with it rather than introduce a parallel `Ownable` analog.

## Open Questions

1. **Shared vs owned wallet — confirm shared.** The existing tests use `public_share_object`. Confirm this is the intended object model for the OZ-port (vs offering both as variants).
2. **Beneficiary changeability — in scope?** OZ v5 made beneficiary mutable via `Ownable` ([PR #4508](https://github.com/OpenZeppelin/openzeppelin-contracts/pull/4508)). Should the Sui port follow, composing with `two_step.move`, or freeze the beneficiary at construction?
3. **One coin type per wallet or generic-multi-coin via dynamic fields?** Single `Coin<T>` is the clean answer; a dynamic-field-backed multi-coin variant is technically possible but probably overkill.
4. **Schedule pluggability — sibling modules vs witness pattern?** Sibling `vesting_wallet_cliff` matches the test scaffolding; a generic `VestingWallet<T, S: drop>` with a schedule witness would be more extensible but heavier on consumers.
5. **`u64` aggregate-deposit bound — assert at `deposit` or document and accept?** Need a stance before invariants are written.
6. **Events.** OZ emits `EtherReleased`/`ERC20Released`. Should the Sui port emit a `Released` event for off-chain indexing of vesting cashflows?
