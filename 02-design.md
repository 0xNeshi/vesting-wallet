---
stage: design
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-11
author: 0xNeshi
previous_stage: 01-research.md
tags: [vesting, finance, openzeppelin, contracts-sui]
---

# Vesting Wallet (Sui) — Design Document

## Summary
A single `vesting_wallet` module exposing `VestingWallet<phantom T>` — a `key + store` object that linearly releases a `Coin<T>` to a beneficiary over `duration_ms`, optionally gated by a cliff (`cliff_ms`). The cliff variant is collapsed into the base struct via a `cliff_ms` field (0 disables it) rather than shipping a sibling module — this deviates from the research recommendation in exchange for a flatter API and one shared test surface. Both shared (consensus path, OZ-standard) and owned (fast path) wallet topologies are supported because the struct carries both `key` and `store`; consumers share via `transfer::public_share_object` (a `store` capability) or use the `create_and_share` convenience factory.

## Module Structure

```
openzeppelin_utils/
└── sources/
    └── vesting_wallet.move    — single module: VestingWallet<T>, events, errors, all API
```

Single module by design. The cliff is parameterized as a field on the base struct, so there is no `vesting_wallet_cliff` sibling. Rationale: every consumer wants the same vested-amount accessor trio regardless of whether cliff is in use; splitting modules forces consumers to choose at type level, while a `cliff_ms = 0` default gives the linear-only path without API duplication.

Consumers who want safer rotation set the wallet's `beneficiary` to the address of a consumer-owned **Beneficiary object** and rotate ownership of *that* object using `OpenZeppelin/contracts-sui::access::ownership_transfer::two_step` (see Integration Patterns §C and Design Decisions §5). The vesting primitive itself stays unaware of rotation policy.

## Core Types

```move
/// A vesting wallet that linearly releases `Coin<T>` to `beneficiary` between
/// `start_ms` and `start_ms + duration_ms`. If `cliff_ms > 0`, no amount is
/// releasable before `start_ms + cliff_ms`; at the cliff boundary the releasable
/// jumps to the linear-from-start proportion (`total * cliff_ms / duration_ms`).
public struct VestingWallet<phantom T> has key, store {
    id: UID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,            // duration from start_ms; 0 disables the cliff
    duration_ms: u64,
    released: u64,            // cumulative amount paid out
    balance: Balance<T>,      // unreleased funds
}
// Abilities:
//   key   — top-level on-chain object (shared OR owned)
//   store — required so it can be transferred via public_transfer / wrapped
// Phantom T: T appears only inside Balance<T> which is itself phantom in T.
```

### Events

```move
public struct Created<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
}

public struct Deposited<phantom T> has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct Released<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
}

public struct BeneficiaryMigrated<phantom T> has copy, drop {
    wallet_id: ID,
    old_beneficiary: address,
    new_beneficiary: address,
}

public struct Destroyed<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    total_released: u64,
}
```
Phantom `T` lets indexers subscribe per coin type (the OZ analog ships `EtherReleased` + per-ERC20 `ERC20Released`).

## Public API

```move
/// Create a new vesting wallet. Returns it by value — caller decides what to do
/// with it. Because `VestingWallet<T>` has `store`, the caller can:
///   * share it via `sui::transfer::public_share_object(wallet)` (OZ-standard
///     topology — anyone can poke `release`),
///   * transfer it via `sui::transfer::public_transfer(wallet, addr)` (owned
///     topology — fast path),
///   * or wrap it inside another object.
/// No library-side `share` wrapper is provided; `public_share_object` is the
/// idiomatic Sui call and works directly on any `key + store` type.
/// Aborts:
///   EZeroDuration  — duration_ms == 0
///   EInvalidCliff  — cliff_duration_ms > duration_ms
public fun new<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<T>

/// Convenience: create + `public_share_object` in one call. Recommended path
/// for the common case — matches OZ semantics (anyone can `release`, vested
/// coin flows to beneficiary).
public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
)

/// Fund the wallet directly. Permissionless — anyone can fund.
/// Post-condition: balance increases by coin.value().
/// Note: later deposits vest "as if locked from the beginning"
/// (OZ invariant — vested_amount uses balance + released).
public fun deposit<T>(wallet: &mut VestingWallet<T>, coin: Coin<T>)

/// Claim a coin that was public-transferred directly to the wallet's address
/// (Sui's "transfer-to-object" pattern), then route it into the balance.
/// Permissionless — anyone can claim on the wallet's behalf.
public fun receive_and_deposit<T>(
    wallet: &mut VestingWallet<T>,
    receiving: Receiving<Coin<T>>,
)

/// Permissionless poke. Computes releasable, mints a `Coin<T>` from the
/// internal Balance, and `public_transfer`s it to the stored beneficiary.
/// No-op (zero-amount, no event) if releasable is 0.
public fun release<T>(
    wallet: &mut VestingWallet<T>,
    clock: &Clock,
    ctx: &mut TxContext,
)

/// Exceptional-event escape hatch — re-point the wallet at a different
/// recipient address (typically a new Beneficiary object after a
/// compromise or topology migration). NOT the routine rotation path:
/// for routine key rotation, use the Beneficiary-object pattern
/// (Integration Patterns §C) and rotate ownership of that object.
///
/// Gated: `ctx.sender() == wallet.beneficiary`. Single-step — typo'd
/// address bricks future cashflow until another `migrate_beneficiary`
/// fixes it (the previous beneficiary must still control the sender).
/// Already-released coins stay where they were sent.
///
/// ⚠ Owned-mode consumers: if you intend to also hand the object off
/// to a new owner via `transfer::public_transfer`, call
/// `migrate_beneficiary` FIRST (while you are still both holder and
/// beneficiary). Otherwise the auth gate becomes unreachable — see
/// Object Ownership Model § Owned-mode footgun.
///
/// Aborts:
///   EUnauthorized — sender is not the current beneficiary
public fun migrate_beneficiary<T>(
    wallet: &mut VestingWallet<T>,
    new_beneficiary: address,
    ctx: &TxContext,
)

/// Permissionless. Consumes a fully-vested, fully-drained wallet and
/// reclaims its storage. Aborts if the vesting period hasn't ended or any
/// balance remains. Late deposits arriving at the wallet's address after
/// destroy are the depositor's responsibility (same as transferring to any
/// non-existent address) — pair destroy with halting any upstream
/// emissions / payroll routing.
/// Aborts:
///   ENotEnded  — now < start_ms + duration_ms
///   ENotEmpty  — balance.value() > 0
public fun destroy_empty<T>(wallet: VestingWallet<T>, clock: &Clock)

// ── Views ────────────────────────────────────────────────────────────────────

/// total * f(now), where total = balance + released and
///   f(now) = 0                                  if now < start_ms + cliff_ms
///          = 1                                  if now >= start_ms + duration_ms
///          = (now - start_ms) / duration_ms     otherwise
/// Math uses u128 intermediate to avoid u64 overflow on `total * elapsed`.
public fun vested_amount<T>(wallet: &VestingWallet<T>, clock: &Clock): u64

/// vested_amount(now) - released
public fun releasable<T>(wallet: &VestingWallet<T>, clock: &Clock): u64

// Plain accessors (return stored fields)
public fun beneficiary<T>(wallet: &VestingWallet<T>): address
public fun start<T>(wallet: &VestingWallet<T>): u64               // ms
public fun cliff<T>(wallet: &VestingWallet<T>): u64               // ms (duration from start)
public fun duration<T>(wallet: &VestingWallet<T>): u64            // ms
public fun end<T>(wallet: &VestingWallet<T>): u64                 // ms; start + duration
public fun released<T>(wallet: &VestingWallet<T>): u64
public fun balance<T>(wallet: &VestingWallet<T>): u64       // balance.value()
```

## Object Ownership Model

| Object | Ownership | Reasoning |
|--------|-----------|-----------|
| `VestingWallet<T>` (shared) | Shared (default, via `create_and_share` or `transfer::public_share_object`) | OZ semantics: anyone can `release`, beneficiary is data not ownership. No contention risk in practice — vesting cashflows are low-frequency. |
| `VestingWallet<T>` (owned)  | Owned (via `new` + `transfer::public_transfer`) | Fast path for single-tenant flows (treasury vesting itself a grant to a known address). Trades public pokeability for no-consensus latency. |
| `Balance<T>` (field)        | Wrapped inside `VestingWallet<T>` | No direct access from outside; mutated only via `deposit` / `release`. |
| `Coin<T>` (release output)  | Owned by `beneficiary` (sent via `public_transfer`) | Matches "vested funds flow to beneficiary" — released coins are normal user-owned coins, immediately spendable. |

### Why both shared and owned

The struct carries `key + store`. Consumers pick at creation time:

* **Shared (recommended).** `create_and_share` (or `new` → `transfer::public_share_object(wallet)`). Anyone can call `release`. Beneficiary is changeable via `migrate_beneficiary`. The `store` ability is what makes `public_share_object` callable from any module — no library-side wrapper needed.
* **Owned (fast path).** `new` + `transfer::public_transfer(wallet, beneficiary)`. Only the object holder can submit txs that touch it. `deposit` via direct ref becomes impossible for outside parties — fund via `receive_and_deposit` (public-transfer the coin to the wallet's object address, then the holder claims it).

⚠ **Owned-mode footgun — always rotate the beneficiary BEFORE handing off the object.**
Because `VestingWallet<T>` has `store`, the current holder can call `sui::transfer::public_transfer(wallet, new_addr)` to move the object to anyone. But `migrate_beneficiary` is gated by `ctx.sender() == wallet.beneficiary`, not by object ownership. So:

* If the current holder (= current beneficiary) **first** calls `migrate_beneficiary(&mut w, new_addr, ctx)` and **then** `public_transfer(w, new_addr)` — correct hand-off, new owner can keep using the wallet, future releases pay the new beneficiary.
* If the holder skips the rotation and just `public_transfer`s the wallet to a new address, the wallet's stored `beneficiary` field still points to the old address. The new holder can call `release` — but funds keep flowing to the old beneficiary. The new holder cannot fix it either: `migrate_beneficiary` requires `ctx.sender() == beneficiary` (the old address, which no longer holds the object). The wallet is effectively trapped — releasable coins flow somewhere the new "owner" can't touch, and the rotation gate can't be reached.

**Rule of thumb for owned-mode consumers:** treat `migrate_beneficiary` and `public_transfer` as a paired operation — never `public_transfer` an owned vesting wallet without rotating first. In shared mode this footgun doesn't exist (the object isn't owned, so there's no "transfer the object" step). Documented; not preventable at the type level without dropping the `store` ability (which would also kill the `public_share_object` ergonomics — see Open Question §2).

## Integration Patterns

Two consumer shapes:

### A. Presale-style atomic settle + vest
```move
// Single-tx: settle a presale buy, lock the allocation in a vesting wallet,
// share so the buyer (or anyone) can poke release later.
// `VestingWallet<T>` has `store`, so the consumer module can call
// `transfer::public_share_object` directly — no library wrapper required.
public fun buy_with_vesting<SALE, PAY>(
    presale: &mut Presale<SALE>,
    payment: Coin<PAY>,
    start_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let allocation = presale::settle(presale, payment, ctx);     // compute + withdraw SALE
    let mut wallet = vesting_wallet::new<SALE>(ctx.sender(), start_ms, duration_ms, ctx);
    vesting_wallet::deposit(&mut wallet, allocation);
    transfer::public_share_object(wallet);
}
```

### B. Top-up via transfer-to-object (emissions / payroll)
```move
// Off-chain payroll script or treasury robot doesn't need a wallet ref —
// it just public-transfers the coin to the wallet's object address.
transfer::public_transfer(salary_coin, wallet_address);

// Later, any tx with a wallet ref claims it:
let receiving: Receiving<Coin<TOKEN>> = ...; // built from the digest
vesting_wallet::receive_and_deposit(&mut wallet, receiving);
```

OZ invariant carries: that post-deposit "vests as if from the beginning" — `vested_amount(now)` reads `balance + released`, not a stored cap.

### C. Beneficiary-object indirection (recommended for safe rotation)

Instead of pointing `wallet.beneficiary` at a human address, point it at the address of a **consumer-defined `Beneficiary` object** owned by the real recipient. Rotation = transfer ownership of the `Beneficiary` object (which composes natively with `two_step.move`). The wallet's stored `beneficiary` field never changes; `migrate_beneficiary` is reserved for exceptional re-pointing (e.g. migrating away from a compromised Beneficiary object).

```
                 +-----------------------+
                 |  VestingWallet<T>     |  shared
                 |  beneficiary = ID_B   |  ←── set once, ~immutable in practice
                 +----------┬------------+
                            │  release(): public_transfer(coin, ID_B)
                            ▼
                 +-----------------------+
                 |  Beneficiary          |  owned by Alice (rotate via two_step)
                 |  id = ID_B            |
                 +----------┬------------+
                            │  claim_to_sender(self, receiving, ctx)
                            ▼
                       Coin<T> → ctx.sender()
```

Sketch of a consumer-side `beneficiary` module (lives in the consumer's package, not in this library):

```move
module my_consumer::beneficiary;

public struct Beneficiary has key {        // key only — no `store`, so only this
    id: UID,                                // module can move it (gated rotation)
    // ... optional: two_step pending state, label, allowlist, etc.
}

public fun new(ctx: &mut TxContext): Beneficiary {
    Beneficiary { id: object::new(ctx) }
}

public fun address_of(b: &Beneficiary): address { b.id.to_address() }

/// Owner-only: claim a vested payout that landed at this Beneficiary's address.
public fun claim_to_sender<T>(
    b: &mut Beneficiary,
    receiving: Receiving<Coin<T>>,
    ctx: &mut TxContext,
) {
    let coin = transfer::public_receive(&mut b.id, receiving);
    transfer::public_transfer(coin, ctx.sender());
}

// Rotation API uses two_step.move internally — propose_owner / accept_owner.
```

Wiring up:

```move
let mut b = beneficiary::new(ctx);
let beneficiary_addr = beneficiary::address_of(&b);
transfer::transfer(b, alice);                       // owned by Alice

vesting_wallet::create_and_share<TOKEN>(
    beneficiary_addr, start_ms, cliff_ms, duration_ms, ctx,
);
// Future releases land at beneficiary_addr; Alice claims with claim_to_sender.
// To rotate Alice → Bob: beneficiary::propose_owner(&mut b, bob); then
// beneficiary::accept_owner(&mut b, ctx) signed by Bob.  No vesting wallet
// state changes.
```

**Why this works where wrapping `migrate_beneficiary` doesn't.** Rotation in this pattern is `transfer::public_transfer`-of-an-object, which is exactly what `two_step.move` is built for. No wrapper module ever needs to call `migrate_beneficiary` — so the `ctx.sender() == beneficiary` auth gate isn't in the way.

**Costs.** Each payout is one extra hop: `release` lands the coin at the Beneficiary object's address, then the owner claims via `claim_to_sender` (collapsible into one PTB). Indexers / off-chain UIs must resolve the Beneficiary indirection to answer "who is being paid?". A new failure surface: losing/burning/freezing the Beneficiary object freezes inbound cashflow targeting it.

**When to use which pattern.**
* If the recipient is a long-lived entity that may need key rotation (team grants, investor allocations) → use this pattern.
* If the recipient is fixed-for-life and the simpler topology is preferable (single-tx releases, no claim step) → use Pattern A with a plain address.

## Error Constants

```move
const EZeroDuration: u64 = 0;   // duration_ms == 0 — would divide by zero
const EInvalidCliff: u64 = 1;   // cliff_duration_ms > duration_ms
const EUnauthorized: u64 = 2;   // migrate_beneficiary called by a non-beneficiary sender
const ENotEnded: u64    = 3;    // destroy_empty before start_ms + duration_ms
const ENotEmpty: u64    = 4;    // destroy_empty with balance > 0
```

Notes:
* `release` never aborts — if releasable is 0, it's a no-op (no event, no zero-value coin minted).
* `deposit` / `receive_and_deposit` never abort on auth (permissionless); a depositor that overflows the `balance` `u64` aborts inside `balance::join` (framework-level).
* No `EOverflow` constant — overflow protection lives in the `u128` intermediate of `vested_amount`, not in user-visible errors.

## Events

| Event | Emitted by | Fields | Purpose |
|-------|------------|--------|---------|
| `Created<T>` | `new` | wallet_id, beneficiary, start_ms, cliff_ms, duration_ms | Index new vesting grants |
| `Deposited<T>` | `deposit` (both direct and receive paths) | wallet_id, amount | Track top-ups for accounting |
| `Released<T>` | `release` (only when amount > 0) | wallet_id, beneficiary, amount | Cashflow stream for off-chain dashboards |
| `BeneficiaryMigrated<T>` | `migrate_beneficiary` | wallet_id, old_beneficiary, new_beneficiary | Audit trail for key rotations |
| `Destroyed<T>` | `destroy_empty` | wallet_id, beneficiary, total_released | Close out cashflow streams; signal indexers to stop polling the wallet |

`Created` fires inside `new` so it always precedes any `Deposited` from the same tx. `Released` fires only on non-zero pay-outs to keep indexer noise down on pre-cliff / no-op pokes. `Destroyed` is the terminal event on a wallet — indexers can treat it as a stream-closed marker.

## Design Decisions Log

1. **Single struct with `cliff_ms` field instead of sibling `vesting_wallet_cliff` module.** Deviation from research recommendation. Rationale: collapses two modules into one, every consumer gets identical views, cliff is just a gate that defaults to off when `cliff_ms == 0`. Cost: every wallet carries one extra `u64` field (~8 bytes) even when unused — negligible. Cost: the `T`-witness-based "subclass" extensibility OZ offers in Solidity is not on the table here, but no concrete need for non-linear/cliff schedules surfaced in research.

2. **`key + store` abilities — both shared and owned supported.** Outline explicitly endorses both topologies. `store` is what lets external modules call `transfer::public_share_object` and `transfer::public_transfer` on the wallet directly, so the library doesn't need its own `share` wrapper — `public_share_object` is the idiomatic Sui entry. Shared is recommended; owned is documented as a fast-path with a known footgun.

3. **Balance as `Balance<T>`, not `Coin<T>`.** `Balance<T>` is the in-object value primitive; `Coin<T>` exists for transfer. `release` wraps the released balance into a `Coin<T>` and `public_transfer`s it.

4. **Permissionless `release` and `deposit`.** The beneficiary's identity is data, not capability. Anyone can fund, anyone can poke; only the beneficiary receives.

5. **Single-step `migrate_beneficiary` (not two-step) — and it's not wrappable.** The recommended path for safe rotation is wrapping  the **Beneficiary-object pattern** (Integration Patterns §C): point `wallet.beneficiary` at a consumer-owned `Beneficiary` object, and rotate ownership of that object using `two_step.move`. `migrate_beneficiary` stays in the API as an exceptional-event escape hatch (e.g. migrate to a new Beneficiary object after compromise), where single-step is acceptable because it's not a routine operation.

6. **`u128` intermediate for vested-amount math.** `total * elapsed` overflows u64 at realistic numbers (10¹⁸-base-unit token × 10¹¹-ms-duration = 10²⁹). Compute `((total as u128) * (elapsed as u128) / (duration_ms as u128)) as u64`. Result still fits in u64 because the quotient is ≤ total ≤ u64::MAX. Can use `openzeppelin_math`.

7. **u64 aggregate-deposit bound — depositor's problem, not enforced at wallet level.** `balance::join` already aborts on overflow. No extra check or error constant — relying on framework-level abort. (Research Open Question #5 — taking the "document and accept" stance.)

8. **`release` is a no-op when releasable == 0.** Avoids minting a zero-value coin, avoids emitting noise events. Cheaper than an abort because callers (off-chain bots) can poll-then-poke without needing to pre-check.

9. **`Created` event fires inside `new`.** Even if the wallet is created then immediately destroyed (e.g. wrapped/consumed by a custom factory in the same tx) the event still records the intent. Trade-off: consumers using `new` purely as a builder primitive will see `Created` events for objects that never become shared/owned. Acceptable — `new` returning a `VestingWallet` strongly implies "this is the one you'll use."

10. **No library-side `share` wrapper.** `VestingWallet<T>` has `store`, so any consumer module can call `sui::transfer::public_share_object(wallet)` directly — no need for the library to re-export the operation. `create_and_share` is sugar that composes `new` + `public_share_object` for the common case.

11. **Ship `destroy_empty` for storage rebate.** Earlier draft deferred cleanup ("OZ doesn't have it"), but that parity argument doesn't carry over to Sui — storage rebate is real value, and at the scale projects actually use vesting (hundreds of grants per launch) reclaiming it matters. The function is permissionless, gated by two conditions: (a) `clock.timestamp_ms() >= start_ms + duration_ms` (fully past `end`), and (b) `balance.value() == 0` (fully drained). When both hold the schedule is finished and there's nothing left to grief. Late deposits arriving after destroy are the depositor's problem — same as `public_transfer` to any non-existent address; pair destroy with halting upstream emissions/payroll routing. Rebate flows to the tx sponsor (per Sui's storage-rebate rules), which is the natural caller in practice (the beneficiary themselves). Aborts: `ENotEnded`, `ENotEmpty`. Terminal event: `Destroyed<T>`.

## Out of Scope

* **Multi-shareholder / pooled grants** — covered by `kunalabs/token-distribution`; bundling defeats "primitive" purpose. Research §Out of Scope.
* **Staking-aware / yield-bearing vesting**.
* **Non-linear / arbitrary-curve schedules** — only linear + cliff.
* **Streaming / per-second payouts** (Sablier-style) — different UX, different contention profile.
* **Multi-coin wallet** — one `T` per wallet; multi-coin requires multiple wallets.
* **Pause / revoke** — vesting commitments are intended to be irrevocable.
* **Two-step beneficiary transfer at the wallet level** — single-step only on `migrate_beneficiary` (the gate makes wrapping impossible). Consumers compose `two_step.move` at the Beneficiary-object layer instead (Integration Patterns §C).
* **Reference `Beneficiary` module shipped in this package** — the pattern is documented but not implemented here; consumers (or a future sibling package) own that code.
* **Beneficiary-side capability object** — beneficiary is `address`, not a `BeneficiaryCap`. Keeps the model close to OZ's `Ownable`.

## Dev Notes

* Repo state: `sources/vesting_wallet.move` and `tests/vesting_wallet_tests.move` exist but are empty (just `module ...;` lines). Research §Dev Notes referenced a `release_at_cliff_jumps_to_proportional` test — that test does not exist yet; will be authored in Stage 5.
* Sibling-module split (research recommendation) was rejected in favor of a unified struct. If a future non-linear schedule is needed, it can ship as a new module `vesting_wallet_nonlinear` reusing the same accessor naming — current design doesn't preclude it.
* Owned-mode footgun is documented but not prevented. If the team later decides `store` is too dangerous, dropping it (forcing shared-only) is a one-line breaking change — flag for Invariants stage.
* The Beneficiary-object pattern (Integration Patterns §C) is the recommended way to get safe rotation. If consumer demand surfaces, consider shipping a reference `Beneficiary` module as a sibling package in a follow-up.

## Open Questions

All resolved at the end of Stage 2 — no questions carried forward to Invariants. Resolutions folded into the design above; recorded here for traceability.

1. **`release` return value vs auto-transfer.** *Resolved: auto-transfer.* Released coin is `public_transfer`'d to the stored beneficiary. PTB-composability requests can be revisited if a concrete consumer needs them.
2. **Drop `store` to force shared-only?** *Resolved: keep `key + store`.* Both shared and owned topologies are supported. The owned-mode footgun is documented; the Beneficiary-object pattern (Integration Patterns §C) eliminates it in practice for consumers who want rotation safety.
3. **Event emission on no-op `release`?** *Resolved: stay silent.* `release` emits `Released<T>` only when `amount > 0`. Indexers can subscribe to tx-level events if they need to confirm pokes.
4. **`vested_amount` when `now < start_ms` with `cliff_ms == 0`.** *Resolved: returns 0 via an explicit guard in the implementation.* Will be encoded as an invariant in Stage 3.
5. **Event count when `receive_and_deposit` fans into `deposit`.** *Resolved: one inner `Deposited<T>` event per balance change.* No separate `Received` event; the receive path is a funding source, not a distinct economic action.
6. **Ship a reference `Beneficiary` module in this package?** *Resolved: no.* The pattern stays documented (Integration Patterns §C); consumers implement their own. A future sibling package can ship one if demand surfaces.
7. **Rename / restrict `transfer_beneficiary`.** *Resolved: rename to `migrate_beneficiary`, no further restriction.* Function semantics unchanged (single-step, sender-gated). Naming alone now signals "exceptional re-pointing, not routine rotation." Witness/package-visibility/cap-object alternatives were considered and rejected as overweight for an escape hatch (see chat trace for the three shapes that were on the table).
