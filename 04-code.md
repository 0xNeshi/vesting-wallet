---
stage: code
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-12
author: 0xNeshi
previous_stage: 03-invariants.md
tags: [vesting, finance, openzeppelin, contracts-sui]
---

# Vesting Wallet (Sui) — Code Draft

## Summary

A single Move module (`sources/vesting_wallet.move`, ~230 lines including doc
comments) implementing the design from `02-design.md` and enforcing every
runtime invariant from `03-invariants.md`. The file is written as a minimal
self-contained example: a reader who has never seen the spec should be able to
understand the system by reading top-to-bottom. Comments cover system-level
flow only (what each function exists for, how pieces compose) — not
implementation detail (no assertion-by-assertion `INV-N:` annotations, no
arithmetic walk-throughs).

Compiles clean against `framework/testnet` rev `c2428b3aaf9c…` with
`--warnings-are-errors`.

## Modules

| Module          | Purpose                                                 | Lines | Status |
|-----------------|---------------------------------------------------------|-------|--------|
| `vesting_wallet`| Type, events, all public API, views, accessors          | ~230  | Draft  |

## Invariant Enforcement Map

| Invariant | Category    | Enforcement location                                | Mechanism                                   |
|-----------|-------------|------------------------------------------------------|---------------------------------------------|
| INV-1     | Type        | `VestingWallet<phantom T>` declaration               | Phantom type parameter                      |
| INV-2     | Type        | `balance: Balance<T>` private field                  | Module-private visibility; accessor returns `u64` |
| INV-3     | Type        | `has key, store` ability list                        | Ability declaration                         |
| INV-4     | Type        | No `drop` on `VestingWallet<T>`                      | Ability declaration; `destroy_empty` is the only consumer |
| INV-5     | Type        | `receive_and_deposit` → `transfer::public_receive`   | Framework parent-ID check                   |
| INV-6     | Runtime     | `new`                                                | `assert!(duration_ms > 0, EZeroDuration)`   |
| INV-7     | Runtime     | `new`                                                | `assert!(cliff_duration_ms <= duration_ms, EInvalidCliff)` |
| INV-8     | Runtime     | `migrate_beneficiary`                                | `assert!(ctx.sender() == wallet.beneficiary, EUnauthorized)` |
| INV-9     | Runtime     | `destroy_empty`                                      | `assert!(clock.timestamp_ms() >= start_ms + duration_ms, ENotEnded)` |
| INV-10    | Runtime     | `destroy_empty`                                      | `assert!(wallet.balance.value() == 0, ENotEmpty)` |
| INV-11    | Runtime     | `release`                                            | `if (amount == 0) return;` before any state change or emit |
| INV-12    | Runtime     | All event-emitting sites                             | Single emit per call; `release` emit gated by `amount > 0` |
| INV-13    | Runtime     | `vested_amount`                                      | `if (now < wallet.start_ms) return 0;` as first branch |
| INV-14    | State       | `start_ms`, `cliff_ms`, `duration_ms` never reassigned | No write sites exist outside `new`        |
| INV-15    | State       | `release`                                            | Only mutation is `released = released + amount` after non-zero check |
| INV-16    | State       | `deposit`, `release`                                 | Deposit increases balance only; release decreases balance by `amount` and increases `released` by same `amount` |
| INV-17    | State       | `id: UID` set in `new`, never reassigned             | No mutation site                            |
| INV-18    | State       | `release`                                            | Increments `released` by exactly `releasable(now)` |
| INV-19    | State       | `release`, `releasable`                              | `releasable = vested_amount - released`; `release` only adds that delta |
| INV-20    | Economic    | `vested_amount`                                      | Math monotone in `now`                      |
| INV-21    | Economic    | `vested_amount`                                      | First branch returns 0 when `now < start_ms` |
| INV-22    | Economic    | `vested_amount`                                      | Second branch returns 0 when `cliff_ms > 0 && now < start_ms + cliff_ms` |
| INV-23    | Economic    | `vested_amount`                                      | At cliff boundary, pre-cliff guard releases and linear formula yields `total * cliff_ms / duration_ms` |
| INV-24    | Economic    | `vested_amount`                                      | Third branch returns `total` when `now >= start_ms + duration_ms` |
| INV-25    | Economic    | `vested_amount`                                      | Linear formula in the middle branch         |
| INV-26    | Economic    | `vested_amount`                                      | `(total as u128) * elapsed / duration` cast back to `u64` |
| INV-27    | Economic    | `vested_amount`                                      | `total = balance.value() + released` re-derived per call |
| INV-28    | Economic    | All paths                                            | `Balance<T>` no-drop + `destroy_empty` requires zero balance; release uses `balance::split` + `coin::from_balance` |
| INV-29    | Economic    | `release`                                            | `wallet.beneficiary` read fresh per call    |
| INV-30    | Economic    | `migrate_beneficiary`                                | No path touches already-released coins      |
| INV-31    | Composability | `release`, `deposit`, `receive_and_deposit`, `destroy_empty` | No sender check                |
| INV-32    | Composability | `new`                                              | Returns `VestingWallet<T>` by value         |
| INV-33    | Composability | `new`, `migrate_beneficiary`                       | `beneficiary: address` accepted opaquely    |
| INV-34    | Composability | (Framework)                                        | Shared-object consensus; release computes against fresh state |
| INV-35    | Composability | Documented in module header                        | Deliberate non-property                     |

## Implementation Notes

* **Single module, no error sub-module.** The design proposes errors at the top
  of the main module; that's what shipped. Five error constants total.
* **Module-level doc comment is the system tour.** Per the user's brief
  ("anyone should understand the system by reading the example, not the spec"),
  the file opens with a multi-paragraph doc comment covering: what the
  schedule does, the create/fund/release/migrate/destroy lifecycle, and the
  shared-vs-owned topology choice (including the owned-mode footgun). Per-
  function comments then explain why each function exists and how it fits the
  flow — not how it executes.
* **Comments deliberately omit invariant references.** The brief said "explain
  flow, not implementation"; invariant numbers belong in the artifact's
  enforcement map (above), not inline in the source. A reader can trace
  `INV-N → source` via this table, but the source itself stays focused on
  the system narrative.
* **No `INV-N: …` inline tags.** Same reason. The enforcement map is the bridge.
* **`destroy_empty` capture-then-destructure pattern.** `object::id(&wallet)`
  and field reads happen before destructuring so the `Destroyed<T>` event has
  the data it needs after `id` is consumed by `delete()`. The destructure
  binds `balance` to call `destroy_zero` on it (required since `Balance<T>`
  has no `drop`).
* **`releasable` is `vested_amount - released` with no clamp.** The subtraction
  is safe by INV-19 (proved structural: `release` is the only mutator of
  `released`, and it can only set it to `vested_amount(now)` — never higher).
  No defensive `if (vested < released) 0` shim; the invariants guarantee the
  ordering.
* **Method-call syntax used throughout.** `wallet.balance.join(...)`,
  `coin.value()`, `id.delete()`. Move 2024 / `edition = "2024"` makes this
  uniform and matches the style in `Move.toml`.
* **`receive_and_deposit` calls back into `deposit`.** One event emission path
  (per Design Open Question §5, resolved as "one inner `Deposited<T>` per
  balance change"). The framework's `transfer::public_receive` handles the
  parent-ID check (INV-5) before the coin lands in the deposit path.

## Out of Scope

* **Tests** — deferred. The user asked for the example implementation only.
  `tests/vesting_wallet_tests.move` is unchanged from the empty starter.
* **Reference `Beneficiary` module** — Integration Pattern C is documented in
  the module's header doc comment as a recommended consumer-side pattern; no
  reference implementation ships here (Design §Out of Scope).
* **`openzeppelin_math` dependency** — the u128 intermediate in
  `vested_amount` is inline rather than routed through a math helper. The
  expression is a single line; pulling in a dependency for one cast pattern
  would obscure the example.
* **`vested_amount` u64 cast overflow guard** — none. By INV-26, the quotient
  is bounded by `total ≤ u64::MAX` so the final cast is always safe.
* **Late-deposit-after-destroy recovery** — accepted as the depositor's
  responsibility (Design §`destroy_empty` notes); no library hook.

## Dev Notes

* The code reads as a system tour — a reviewer or new contributor can open
  `sources/vesting_wallet.move` cold and rebuild the mental model from the
  module-level doc and per-section comments, without going through 01/02/03.
  The artifact's enforcement map is the bridge back to the invariants when
  the reader needs to verify a specific property.
* The single comment that flirts with implementation detail — the u128 cast in
  `vested_amount` — was left bare without a "to avoid overflow" note. Readers
  who know Sui u64 limits will recognize the pattern; readers who don't can
  consult INV-26 via this artifact.
* The owned-mode footgun (INV-35) is described in the module header's
  Topologies section with a `⚠` marker. A future reader skimming for "why
  does this have `store`" finds the answer immediately, including the trap.

## Open Questions

None outstanding. Tests are deferred by user request; nothing in the code
draft is contingent on the test stage.
