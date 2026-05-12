---
stage: invariants
project: vesting-wallet
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-12
author: 0xNeshi
previous_stage: 02-design.md
tags: [vesting, finance, openzeppelin, contracts-sui, invariants]
---

# Vesting Wallet (Sui) — Invariants

## Summary

35 invariants spread across five categories: 5 type-level (Move enforces), 8 runtime
(`assert!` / explicit guards), 6 state-transition (ledger consistency across calls),
11 economic/protocol (vesting math, conservation of funds, OZ semantics), and 5
composability (permissionless poke, PTB shape, owned-mode caveats). The critical
properties are: **(a)** conservation — no path mints or burns coin internally
(INV-28); **(b)** vesting math correctness — OZ proportional-jump cliff semantics
with overflow-safe u128 intermediate (INV-23, INV-26); **(c)** released ≤ vested at
all times (INV-19); **(d)** sender-gated rotation and end-gated destroy (INV-8 to
INV-10).

## Type-Level Invariants

### INV-1: Per-coin-type wallet isolation

**Category:** Type-level

**Statement:** A `VestingWallet<T>` is generic in the coin type `T` (phantom).
A wallet for one coin type cannot be substituted for a wallet of a different coin
type at any public API entry — the type system rejects the call.

**Applies to:** All public functions.

**Enforcement mechanism:**
- Type system: `VestingWallet<phantom T>` carries `T` through every signature; the
  Move compiler refuses to mix `VestingWallet<USDC>` with operations expecting
  `VestingWallet<SUI>`.
- Runtime check: none required.
- Test: Compile a snippet that mixes types — expect compile failure.

**Violation scenario:** Impossible by construction. If hypothetically violated, a
caller could drain one coin's balance into another, corrupting downstream accounting.

**Severity:** Critical (but enforced by Move; no runtime risk).

---

### INV-2: Balance is encapsulated

**Category:** Type-level

**Statement:** `Balance<T>` lives inside `VestingWallet<T>` as a private field. No
public API returns a `&mut Balance<T>` or a `&Balance<T>` reference to the internal
field; the only public accessor (`balance<T>`) returns `u64` (the value), not the
balance object.

**Applies to:** `Balance<T>` field of `VestingWallet<T>`.

**Enforcement mechanism:**
- Type system: Move's module-private field visibility hides `wallet.balance`
  from external callers.
- Runtime check: none.
- Test: Static — confirm no `public fun` returns `&mut Balance<T>` or `&Balance<T>`.

**Violation scenario:** If a `&mut Balance<T>` were exposed, an external caller
could `balance::split` arbitrary amounts out, bypassing every vesting check.

**Severity:** Critical.

---

### INV-3: Both shared and owned topologies are reachable

**Category:** Type-level

**Statement:** `VestingWallet<T>` has both `key` and `store` abilities. `key` makes
it a top-level on-chain object; `store` lets external modules call
`transfer::public_share_object(wallet)` or `transfer::public_transfer(wallet, addr)`
on it.

**Applies to:** Wallet creation and topology selection.

**Enforcement mechanism:**
- Type system: ability declarations on `VestingWallet<T>`.
- Runtime check: none.
- Test: Two scenarios — one ending in `public_share_object`, one in
  `public_transfer`; both must compile and execute.

**Violation scenario:** If `store` were dropped, the convenience pattern of
external modules sharing/transferring the wallet would break; only the library
itself could do it. If `key` were dropped, it couldn't be a top-level object.

**Severity:** High (capability contract for consumers).

---

### INV-4: Wallet must be explicitly destroyed

**Category:** Type-level

**Statement:** `VestingWallet<T>` does NOT have `drop`. The only path that consumes
a wallet by value is `destroy_empty<T>(wallet: VestingWallet<T>, clock: &Clock)`.
Code paths cannot silently drop a wallet.

**Applies to:** `VestingWallet<T>` lifetime.

**Enforcement mechanism:**
- Type system: absence of `drop` ability on `VestingWallet<T>`.
- Runtime check: `destroy_empty` aborts if conditions aren't met (INV-9, INV-10),
  so even the destroy path enforces full-drain + ended.
- Test: Try to drop a wallet without calling `destroy_empty` — compile failure.

**Violation scenario:** A path that dropped a non-empty wallet would burn the
trapped balance permanently (effectively destroying funds — INV-28 violation).

**Severity:** Critical.

---

### INV-5: `receive_and_deposit` only accepts receipts addressed to the wallet

**Category:** Type-level

**Statement:** `Receiving<Coin<T>>` passed to `receive_and_deposit` is validated by
Sui's framework — `transfer::public_receive` only succeeds if the receipt's parent
ID matches the wallet's UID. Receipts addressed elsewhere cannot be claimed
through this wallet.

**Applies to:** `receive_and_deposit`.

**Enforcement mechanism:**
- Type system + framework: `transfer::public_receive(&mut wallet.id, receiving)`
  aborts if the receipt's parent doesn't equal `wallet.id`.
- Runtime check: framework-level, not user-visible.
- Test: Pass a `Receiving<Coin<T>>` constructed against another address — expect
  framework abort.

**Violation scenario:** Impossible — framework guarantees this. If hypothetically
violated, one wallet could "steal" coins addressed to another.

**Severity:** Critical (but framework-enforced).

---

## Runtime Invariants

### INV-6: `new` rejects zero duration

**Category:** Runtime

**Statement:** `new` aborts with `EZeroDuration` if `duration_ms == 0`. A
zero-duration wallet would divide by zero in `vested_amount`.

**Applies to:** `new`, `create_and_share`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `assert!(duration_ms > 0, EZeroDuration)`.
- Test: Call `new` with `duration_ms = 0` — expect abort with `EZeroDuration`.

**Violation scenario:** A wallet with `duration_ms == 0` would either (a) panic on
every `vested_amount` call, bricking the wallet, or (b) need a special case that
returns `total` immediately — defeating the schedule.

**Severity:** Critical (prevents bricked wallets).

---

### INV-7: `new` rejects cliff longer than duration

**Category:** Runtime

**Statement:** `new` aborts with `EInvalidCliff` if `cliff_duration_ms > duration_ms`.

**Applies to:** `new`, `create_and_share`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `assert!(cliff_duration_ms <= duration_ms, EInvalidCliff)`.
- Test: Call `new` with `cliff_duration_ms = duration_ms + 1` — expect abort.

**Violation scenario:** A wallet with `cliff > duration` would gate releases past
the end of the vesting window — funds never vest. OZ matches this check.

**Severity:** High.

---

### INV-8: `migrate_beneficiary` is sender-gated

**Category:** Runtime

**Statement:** `migrate_beneficiary` aborts with `EUnauthorized` if `ctx.sender() !=
wallet.beneficiary` at the time of the call.

**Applies to:** `migrate_beneficiary`.

**Enforcement mechanism:**
- Type system: none (Sui has no `Ownable` trait).
- Runtime check: `assert!(ctx.sender() == wallet.beneficiary, EUnauthorized)`.
- Test: Call from a non-beneficiary address — expect abort. Call from the
  beneficiary — expect success and `BeneficiaryMigrated` event.

**Violation scenario:** Anyone could re-point the beneficiary, immediately
redirecting all future releases. Direct loss of funds.

**Severity:** Critical.

---

### INV-9: `destroy_empty` requires vesting ended

**Category:** Runtime

**Statement:** `destroy_empty` aborts with `ENotEnded` if `clock.timestamp_ms() <
start_ms + duration_ms`.

**Applies to:** `destroy_empty`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `assert!(clock.timestamp_ms() >= start_ms + duration_ms, ENotEnded)`.
- Test: Destroy before `end` with balance == 0 — expect abort.

**Violation scenario:** Premature destruction of a still-vesting wallet would
discard remaining schedule and could be combined with INV-10 bypass to lose funds.
Even with balance == 0, destroying before end is wrong — late deposits could still
be expected.

**Severity:** High.

---

### INV-10: `destroy_empty` requires zero balance

**Category:** Runtime

**Statement:** `destroy_empty` aborts with `ENotEmpty` if `wallet.balance.value() > 0`.

**Applies to:** `destroy_empty`.

**Enforcement mechanism:**
- Type system: `Balance<T>` does not have `drop`, so an attempted destruction of a
  non-empty balance would also be a compile-time error if anyone tried to bypass.
  The runtime check provides the typed error and clean abort message.
- Runtime check: `assert!(wallet.balance.value() == 0, ENotEmpty)`.
- Test: Fund the wallet, advance past end, attempt destroy without release —
  expect abort with `ENotEmpty`.

**Violation scenario:** Destroying with non-zero balance would burn funds (INV-28
violation).

**Severity:** Critical.

---

### INV-11: `release` is a no-op when releasable is zero

**Category:** Runtime

**Statement:** When `releasable(wallet, clock) == 0`, `release` does not abort, does
not call `coin::from_balance`, does not call `transfer::public_transfer`, and does
not emit a `Released<T>` event. State is unchanged.

**Applies to:** `release`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: explicit `if (amount == 0) return;` early return inside `release`,
  before any balance split or transfer.
- Test: Call `release` before start, before cliff (with cliff > 0), and immediately
  after a prior `release` at the same `now` — none should emit `Released`, none
  should change `released`, none should abort.

**Violation scenario:** Aborting on zero releasable would force callers (off-chain
bots) to pre-check before poking — wasted gas and consensus traffic. Minting a
zero-value coin would also bloat the on-chain coin table.

**Severity:** Medium (UX / cost, not safety).

---

### INV-12: Event emission contract

**Category:** Runtime

**Statement:** Events are emitted by exactly one call site each, with the documented
shape and emission gates:

| Event | Emitter | Gate | Cardinality per call |
|-------|---------|------|----------------------|
| `Created<T>` | `new` | always | exactly 1 |
| `Deposited<T>` | `deposit`, `receive_and_deposit` | always (per deposit operation) | exactly 1 per call |
| `Released<T>` | `release` | only when `amount > 0` (paired with INV-11) | 0 or 1 |
| `BeneficiaryMigrated<T>` | `migrate_beneficiary` | only after auth passes | exactly 1 (or 0 on abort) |
| `Destroyed<T>` | `destroy_empty` | always (after both gates pass) | exactly 1 |

**Applies to:** All event-emitting functions.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: control flow inside each function emits at most one event of each
  type. `release` event is gated behind the same `amount > 0` check as INV-11.
- Test: For each function, inspect the test scenario's emitted events and assert
  count + field values.

**Violation scenario:** Extra or missing events corrupt indexer state — duplicate
`Created` would create phantom wallets in dashboards; missed `Released` would mis-
account cashflow.

**Severity:** Medium (off-chain correctness; no on-chain fund risk).

---

### INV-13: `vested_amount` guards `now < start_ms` underflow

**Category:** Runtime

**Statement:** When `clock.timestamp_ms() < start_ms`, `vested_amount` returns 0
via an explicit guard, before computing `now - start_ms` (which would underflow u64).

**Applies to:** `vested_amount` (and transitively `releasable`).

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `if (now < start_ms) return 0;` as the first branch.
- Test: Call `vested_amount` with `clock.timestamp_ms()` set to `start_ms - 1` —
  expect `0`. Without the guard this would abort on u64 underflow.

**Violation scenario:** Without the guard, every pre-start view call would abort,
bricking the wallet's UI surface until `start_ms` arrives.

**Severity:** Critical (bricks view functions; would also affect `release` which
calls into the same math).

---

## State Transition Invariants

### INV-14: Schedule fields are immutable after creation

**Category:** State transition

**Statement:** Once `new` returns a `VestingWallet<T>`, the fields `start_ms`,
`cliff_ms`, and `duration_ms` never change for the lifetime of the wallet. No
public function modifies them; no internal path does either.

**Applies to:** `start_ms`, `cliff_ms`, `duration_ms` fields.

**Enforcement mechanism:**
- Type system: Move's field-level mutation visibility — no `public fun` returns
  `&mut VestingWallet<T>` in a shape that allows direct mutation of these fields
  outside the module.
- Runtime check: none required (no mutation site exists).
- Test: Property test — for an arbitrary sequence of `deposit`, `release`,
  `migrate_beneficiary`, `receive_and_deposit` calls, accessors `start()`,
  `cliff()`, `duration()` return identical values before and after.

**Violation scenario:** A mutable schedule would let an attacker (if combined with
INV-8 bypass) shorten `duration_ms` and immediately vest everything.

**Severity:** Critical.

---

### INV-15: `released` is monotonically non-decreasing

**Category:** State transition

**Statement:** `wallet.released` only increases (by amounts equal to the
corresponding `Released<T>.amount`) or stays the same across any sequence of public
calls. It never decreases.

**Applies to:** `released` field; affects `release`, `releasable`, `vested_amount`
indirectly.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: the only mutation site is `wallet.released = wallet.released +
  amount` inside `release`, after the zero-check (INV-11).
- Test: Property test — sequence of operations, assert `released` is monotone.

**Violation scenario:** A decreasing `released` could let the wallet pay out more
than `total` cumulatively — fund creation (INV-28 violation).

**Severity:** Critical.

---

### INV-16: Balance + released = sum of deposits (ledger conservation)

**Category:** State transition

**Statement:** At every observable point, `balance.value() + released ==
Σ(deposits)` where `Σ(deposits)` is the sum of `Coin<T>.value()` across all
successful `deposit` and `receive_and_deposit` calls on this wallet.

**Applies to:** Whole-wallet ledger consistency.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: every state transition either (a) increases `balance` by a coin's
  value and leaves `released` unchanged (deposit paths), or (b) decreases `balance`
  by `amount` and increases `released` by the same `amount` (`release`).
- Test: Test scenario tracks `Σ(deposits)` off-chain and asserts the equation after
  every step.

**Violation scenario:** Breakage means either coins were paid out without being
recorded (under-counted `released`) or recorded without being paid out (over-counted
`released`) — both corrupt the "vested as if from start" semantic.

**Severity:** Critical.

---

### INV-17: Wallet identity (UID/ID) is stable

**Category:** State transition

**Statement:** The `wallet.id` (and the `ID` it derives) is set once inside `new`
and never changes. `migrate_beneficiary` does not change `id`; rotations preserve
on-chain object identity so indexers tracking the wallet by ID never lose it.

**Applies to:** `id` field.

**Enforcement mechanism:**
- Type system: `UID` has no public mutation API; `object::new` is the only
  constructor.
- Runtime check: none required.
- Test: Capture the wallet's `ID` after `new`, do arbitrary operations, capture
  again — must be equal.

**Violation scenario:** ID drift would break indexers and the Beneficiary-object
pattern (which uses the indirection-target's address as a long-lived handle).

**Severity:** High.

---

### INV-18: After `release`, `releasable` at the same clock is zero

**Category:** State transition

**Statement:** For any `clock` value, calling `release(&mut wallet, &clock, ctx)`
followed by `releasable(&wallet, &clock)` at the same `clock.timestamp_ms()`
returns 0.

**Applies to:** `release` ↔ `releasable` consistency.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `release` increments `released` by exactly the value of
  `releasable(now)`, so `vested_amount(now) - released == 0` immediately after.
- Test: At several timestamps (pre-cliff, mid-vest, post-end), call `release` then
  `releasable` — expect 0.

**Violation scenario:** Residual releasable after release indicates a mismatch
between `vested_amount` and the amount actually paid out — either under-pay
(beneficiary loses funds) or over-pay (impossible without violating INV-16, but
worth checking).

**Severity:** High.

---

### INV-19: `released` never exceeds `vested_amount(now)`

**Category:** State transition

**Statement:** At every observable point in time, `wallet.released <=
vested_amount(wallet, clock)` for the current `clock.timestamp_ms()`.

**Applies to:** Whole-wallet correctness.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `release` computes `amount = releasable = vested_amount(now) -
  released`, then increments `released` by `amount`. New `released` equals
  `vested_amount(now)` — never exceeds.
- Test: Property — at every step assert `released <= vested_amount(now)`.

**Violation scenario:** Over-release would mean the wallet pays out before time —
investor cliff cheating, team grants leaking ahead of schedule. Critical OZ
property.

**Severity:** Critical.

---

## Economic / Protocol Invariants

### INV-20: `vested_amount` is non-decreasing in time (given constant total)

**Category:** Economic / Protocol

**Statement:** For a wallet with no intervening deposits or releases between `t1`
and `t2` (`t1 <= t2`), `vested_amount(wallet, clock_at_t1) <= vested_amount(wallet,
clock_at_t2)`.

**Applies to:** `vested_amount`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: math is `total * (now - start) / duration` clamped — `now`
  monotone implies output monotone.
- Test: Sample `vested_amount` at increasing timestamps without intervening
  deposits/releases — assert non-decreasing.

**Violation scenario:** A non-monotone schedule would let beneficiaries see funds
"un-vest" — confusing and would break downstream invariants (INV-19).

**Severity:** High.

---

### INV-21: Pre-start: `vested_amount == 0`

**Category:** Economic / Protocol

**Statement:** When `clock.timestamp_ms() < start_ms`, `vested_amount(wallet,
clock) == 0` regardless of `cliff_ms` (paired with INV-13).

**Applies to:** `vested_amount`, `releasable`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: pre-start guard (INV-13) returns 0.
- Test: With `start_ms = 1000`, sample at `clock = 999` — expect 0.

**Violation scenario:** Pre-start vesting would defeat the "delayed start" use case
(grant signed today, vests starting next quarter).

**Severity:** Critical.

---

### INV-22: Pre-cliff: `vested_amount == 0` (when cliff > 0)

**Category:** Economic / Protocol

**Statement:** When `cliff_ms > 0` and `start_ms <= clock.timestamp_ms() < start_ms
+ cliff_ms`, `vested_amount(wallet, clock) == 0`.

**Applies to:** `vested_amount`, `releasable`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `if (cliff_ms > 0 && now < start_ms + cliff_ms) return 0;` inside
  `vested_amount`.
- Test: With `cliff_ms = 1000`, `start_ms = 0`, sample at `clock = 999` —
  expect 0. At `clock = 0` — expect 0.

**Violation scenario:** Releasable funds before cliff would violate the OZ cliff
contract — a team member with a 1-year cliff could claim partial vest in month 1.

**Severity:** Critical.

---

### INV-23: Cliff boundary: proportional jump

**Category:** Economic / Protocol

**Statement:** When `cliff_ms > 0` and `clock.timestamp_ms() == start_ms +
cliff_ms`, `vested_amount(wallet, clock) == (total * cliff_ms) / duration_ms`
where `total = balance.value() + released`. This is the OZ "cliff gates, doesn't
break the curve" semantic — at the cliff boundary, vesting jumps from 0 to the
linear-from-start proportion (not to zero, not to a linear-from-cliff curve).

**Applies to:** `vested_amount`, `releasable`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: when `now == start_ms + cliff_ms`, the pre-cliff guard releases
  control and the standard linear formula applies. `now - start_ms == cliff_ms`,
  so the formula yields `total * cliff_ms / duration_ms`.
- Test: With `duration_ms = 4000`, `cliff_ms = 1000`, `total = 1000`, sample at
  `clock = start_ms + 999` — expect 0; at `clock = start_ms + 1000` — expect 250.
  Hits the existing `release_at_cliff_jumps_to_proportional` test mentioned in
  research §Dev Notes.

**Violation scenario:** Wrong cliff math is the most common bug class in vesting
contracts — implementations that compute "linear from cliff" instead of "linear
from start, gated at cliff" silently underpay beneficiaries by `cliff/duration`
proportion forever.

**Severity:** Critical.

---

### INV-24: Post-end: `vested_amount == total`

**Category:** Economic / Protocol

**Statement:** When `clock.timestamp_ms() >= start_ms + duration_ms`,
`vested_amount(wallet, clock) == balance.value() + released`.

**Applies to:** `vested_amount`, `releasable`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: explicit branch `if (now >= start_ms + duration_ms) return
  balance + released;` inside `vested_amount` — this is the "clamp to total"
  step.
- Test: Sample at `clock = end`, `clock = end + 1`, `clock = u64::MAX` — all
  return `balance + released`.

**Violation scenario:** If post-end didn't clamp, the linear formula `total * (now
- start) / duration` could exceed `total` (since `now - start > duration`),
violating INV-19.

**Severity:** Critical.

---

### INV-25: Linear schedule between (cliff or start) and end

**Category:** Economic / Protocol

**Statement:** In the open interval `(start_ms + max(cliff_ms, 0), start_ms +
duration_ms)`, `vested_amount(wallet, clock) == (total * (now - start_ms)) /
duration_ms` (with u128 intermediate; integer division floors).

**Applies to:** `vested_amount`.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: standard linear formula in the middle branch of `vested_amount`.
- Test: With known `(start, duration, total)`, sample at several intermediate
  timestamps and verify against off-chain re-computation.

**Violation scenario:** Anything other than linear-from-start (e.g.
linear-from-cliff, exponential, stair-stepped) violates the OZ contract and the
explicit Design Decisions Log §1.

**Severity:** Critical.

---

### INV-26: Vested-amount math uses u128 intermediate, fits in u64

**Category:** Economic / Protocol

**Statement:** The computation is `((total as u128) * ((now - start_ms) as u128)
/ (duration_ms as u128)) as u64`. The u128 multiplication absorbs the
worst-case `u64::MAX * u64::MAX < u128::MAX`. The final cast to u64 is safe
because the quotient is at most `total <= u64::MAX`.

**Applies to:** `vested_amount` arithmetic.

**Enforcement mechanism:**
- Type system: explicit `as u128` / `as u64` casts.
- Runtime check: math itself; no separate assert needed.
- Test: With `total = u64::MAX`, `duration_ms = u64::MAX`, `now - start_ms = u64
  ::MAX - 1` — expect `vested_amount` to return a u64 close to but not exceeding
  `u64::MAX` without aborting.

**Violation scenario:** A u64-only multiplication overflows for any realistic
9-decimal coin × multi-year ms duration (10¹⁸ × 10¹¹ = 10²⁹). Without u128,
deposits would brick at common amounts. The OZ analog is issue #5793 with `u256`
— Sui's tighter u64 makes this MORE important, not less.

**Severity:** Critical.

---

### INV-27: Post-deposit "vests as if from the beginning"

**Category:** Economic / Protocol

**Statement:** `vested_amount` is computed against `total = balance.value() +
released` at the time of the query — NOT against a stored "original allocation"
captured at construction. Therefore a deposit made at time `t > start_ms`
immediately participates in vesting at the proportion `(t - start_ms) /
duration_ms`. After the deposit, `vested_amount(now)` jumps by `(deposit_amount *
(t - start_ms)) / duration_ms`.

**Applies to:** `vested_amount`, `releasable`, all deposit paths.

**Enforcement mechanism:**
- Type system: `vested_amount` does not store an `original_balance` field; it
  re-derives total from `balance + released`.
- Runtime check: none required (it's a derivation, not an assert).
- Test: Create a 1000ms wallet with 0 starting balance, advance to t=500, deposit
  1000 — `vested_amount(500)` should immediately read 500 (half-vested
  retroactively), not 0 (linear-from-deposit-time).

**Violation scenario:** Storing `original_balance` and computing against it would
break the OZ "fund-after-creation" semantic — recurring emissions schedules and
payroll top-ups would each create a fresh schedule, defeating the design.

**Severity:** Critical (defines the library's core differentiator vs every
existing Sui locker).

---

### INV-28: Conservation of funds (no minting, no burning)

**Category:** Economic / Protocol

**Statement:** Within the library, no code path creates `Coin<T>` out of thin air
or destroys `Coin<T>` value. Specifically: (a) `release` only moves value from
`wallet.balance` into a fresh `Coin<T>` via `coin::from_balance`, conserving total
value; (b) `destroy_empty` requires `balance.value() == 0` (INV-10), so no value
is lost when the wallet is consumed; (c) `migrate_beneficiary` touches no balance.

**Applies to:** All public functions; whole-library accounting.

**Enforcement mechanism:**
- Type system: `Balance<T>` has no `drop`; the framework prevents value loss at
  the type level. The `wallet.balance` field is a `Balance<T>`, so dropping a
  non-empty wallet is impossible (INV-4).
- Runtime check: INV-10 enforces empty-balance at destroy; release paths use
  `balance::split` and `coin::from_balance`, both value-preserving.
- Test: Property test — for any sequence of operations, off-chain ledger
  `Σ(deposits) - Σ(release amounts) == wallet.balance.value()` always holds (this
  is also INV-16 from the other direction).

**Violation scenario:** Any minting path would let a malicious upgrade or bug
create coins; any burning path would destroy beneficiary funds. The library must
be a pure accounting layer over coin movement.

**Severity:** Critical.

---

### INV-29: Release sends to the CURRENT beneficiary

**Category:** Economic / Protocol

**Statement:** `release` reads `wallet.beneficiary` at the moment of the call and
`public_transfer`s the released coin to that address. If `migrate_beneficiary` is
called between two releases, the second release pays the new beneficiary — there
is no snapshot or "at-vesting-time" beneficiary.

**Applies to:** `release` ↔ `migrate_beneficiary` interaction.

**Enforcement mechanism:**
- Type system: none.
- Runtime check: `release` reads `wallet.beneficiary` directly; no caching.
- Test: Create wallet for Alice, vest partially, call `release` → Alice receives.
  Migrate to Bob, vest further, call `release` again → Bob receives the
  newly-vested portion. Alice's prior coin stays with Alice.

**Violation scenario:** Snapshotting beneficiary at vesting time (rather than at
release time) would require per-block accounting and would conflict with the
"vests as if from start" semantic. The simpler "current beneficiary at release
time" rule is OZ's choice too.

**Severity:** High (semantic clarity for indexers and beneficiaries).

---

### INV-30: Prior releases are not clawed back by rotation

**Category:** Economic / Protocol

**Statement:** When `migrate_beneficiary(wallet, new_addr)` is called, coins that
were previously released to the old beneficiary stay with the old beneficiary.
Only future releases flow to `new_addr` (per INV-29).

**Applies to:** `migrate_beneficiary` semantics; user expectations.

**Enforcement mechanism:**
- Type system: released coins are no longer the wallet's responsibility — they
  are owned by their recipient. The library has no path to reach them.
- Runtime check: none required.
- Test: Same scenario as INV-29 — assert Alice's coin balance is unchanged after
  the migrate.

**Violation scenario:** A "clawback on rotate" semantic would let a compromised
beneficiary's key holder rotate and then drain prior releases — but the design
explicitly accepts the "rotation can effectively sell unvested rights" tradeoff
(matches OZ).

**Severity:** Medium (documented design choice, not a safety property — but
worth capturing so tests verify the chosen semantics).

---

## Composability Invariants

### INV-31: Permissionless poke and fund

**Category:** Composability

**Statement:** `release`, `deposit`, `receive_and_deposit`, and `destroy_empty`
require no capability and no specific sender — any address with a valid
`&mut VestingWallet<T>` reference (which, for shared wallets, is anyone) can call
them.

**Applies to:** `release`, `deposit`, `receive_and_deposit`, `destroy_empty`.

**Enforcement mechanism:**
- Type system: no `Cap` parameter on these functions.
- Runtime check: no `ctx.sender()` comparison anywhere in these paths.
- Test: For each function, call from an unrelated address and assert success.

**Violation scenario:** Adding sender gates would break the OZ "anyone can poke"
contract and prevent off-chain bots from acting as relays for beneficiaries.

**Severity:** High (consumer contract).

---

### INV-32: Single-PTB compositions are reachable

**Category:** Composability

**Statement:** A consumer can compose `new` + `deposit` + `transfer::public_share_object`
(or `transfer::public_transfer`) in a single PTB. Likewise: `new` + `deposit` +
`release` is reachable in one transaction. Likewise: `receive_and_deposit` +
`release` in one transaction.

**Applies to:** API surface design (function shapes and ability bounds).

**Enforcement mechanism:**
- Type system: `new` returns `VestingWallet<T>` by value (not by reference and
  not shared internally), letting PTBs chain it into `deposit` then any topology
  finalizer.
- Runtime check: none.
- Test: PTB-style test scenarios chaining `new` → `deposit` → `public_share_object`
  → (separate tx) `release`. Also a chain `new` → `deposit` → `release` in one
  tx for the owned-mode case.

**Violation scenario:** If `new` instead took `&mut TxContext` and immediately
shared the wallet internally (no return value), every PTB would need a second
transaction to deposit — defeating the presale-style use case (Integration
Pattern A in the design).

**Severity:** High.

---

### INV-33: Beneficiary may be any address, including object IDs

**Category:** Composability

**Statement:** The `beneficiary: address` field can hold any 32-byte address,
including the address of a Move object (used by the Beneficiary-object pattern
in Design Integration Pattern C). The library makes no assumption that the
beneficiary corresponds to an externally-owned account.

**Applies to:** `new`, `migrate_beneficiary`, `release`.

**Enforcement mechanism:**
- Type system: `address` is opaque — Move does not distinguish "user address" vs
  "object address" at the type level.
- Runtime check: none.
- Test: Create a wallet pointing at an object's address (Beneficiary-object
  pattern), advance time, release — assert the released coin is transferred to
  the object's address.

**Violation scenario:** A check like "is this a user wallet" would break Pattern
C entirely and force consumers needing rotation safety into the migrate-
beneficiary path (which has its own UX cost).

**Severity:** High (composability contract).

---

### INV-34: Shared-mode concurrent release is safe

**Category:** Composability

**Statement:** When `VestingWallet<T>` is a shared object and two transactions
both attempt `release`, Sui consensus serializes them. The total paid out across
both transactions equals `releasable(now_at_finalization)`, not `2 *
releasable(now)`. The second to finalize observes a higher `released` and
typically pays out 0 (INV-11 no-op) or a small delta if time advanced between
finalizations.

**Applies to:** `release` under shared topology.

**Enforcement mechanism:**
- Type system + Sui runtime: shared-object consensus ordering.
- Runtime check: each `release` computes `releasable` fresh against current state
  — there is no read-then-write race window inside the transaction.
- Test: Document. (A two-tx race test is hard to author deterministically in
  `test_scenario`; cover via the simpler "two back-to-back releases at the same
  clock" test, which exercises the same idempotency property — see INV-18.)

**Violation scenario:** A non-atomic `release` (e.g. reading `vested_amount` then
later subtracting `released` based on a stale read) would double-pay in a race.
Move's transaction atomicity prevents this by construction.

**Severity:** Critical (but framework-guaranteed).

---

### INV-35: Owned-mode footgun is NOT prevented at the type level

**Category:** Composability

**Statement:** In owned mode, a holder can `transfer::public_transfer(wallet,
new_owner)` to move the object without first calling `migrate_beneficiary`. When
this happens, the wallet's `beneficiary` field still points to the old address,
and subsequent releases flow there. The new owner cannot fix this: their
`migrate_beneficiary` call fails INV-8 (sender is not the stored beneficiary).
The wallet is effectively trapped — operationally bricked from the new owner's
perspective.

**This is a deliberate non-property: the library does NOT prevent it.** Captured
here so tests can assert it (verifying the documented behavior) and so a future
revisor knows the design decision (Design Decisions §2, "Owned-mode footgun
documented but not preventable at the type level without dropping `store`").

**Applies to:** Owned mode operational guarantees.

**Enforcement mechanism:**
- Type system: dropping `store` would prevent this — but also kill the
  `public_share_object` ergonomics. The design picks ergonomics over guard
  rails here.
- Runtime check: none.
- Test: Owned-mode test scenario — create wallet with Alice as beneficiary and
  holder, `public_transfer` to Bob, attempt `migrate_beneficiary` from Bob —
  expect abort (INV-8). Releases continue going to Alice. Document this is
  intentional, not a bug.

**Violation scenario:** Not a safety violation — it's a UX failure mode. The
"violation" would be silently *changing* this behavior in the future (e.g.,
adding a `&UID` check that lets the holder re-point) which would surprise
consumers depending on the current shape.

**Severity:** Medium (operational, not safety).

---

## Invariant Coverage Matrix

| Function | Invariants | Enforcement |
|----------|-----------|-------------|
| `new<T>` | INV-1, INV-2, INV-3, INV-4, INV-6, INV-7, INV-12, INV-14, INV-17, INV-32 | Type + Runtime |
| `create_and_share<T>` | INV-1, INV-2, INV-3, INV-4, INV-6, INV-7, INV-12, INV-14, INV-17, INV-32 | Type + Runtime |
| `deposit<T>` | INV-2, INV-12, INV-16, INV-27, INV-28, INV-31 | Type + Runtime |
| `receive_and_deposit<T>` | INV-2, INV-5, INV-12, INV-16, INV-27, INV-28, INV-31 | Type + Runtime |
| `release<T>` | INV-11, INV-12, INV-13, INV-15, INV-16, INV-18, INV-19, INV-26, INV-28, INV-29, INV-31, INV-34 | Type + Runtime |
| `migrate_beneficiary<T>` | INV-8, INV-12, INV-14, INV-17, INV-30 | Runtime |
| `destroy_empty<T>` | INV-4, INV-9, INV-10, INV-12, INV-28, INV-31 | Type + Runtime |
| `vested_amount<T>` | INV-13, INV-20, INV-21, INV-22, INV-23, INV-24, INV-25, INV-26, INV-27 | Runtime |
| `releasable<T>` | INV-19, INV-21, INV-22, INV-26 | Runtime (derives from vested_amount) |
| `beneficiary<T>`, `start<T>`, `cliff<T>`, `duration<T>`, `end<T>`, `released<T>`, `balance<T>` | INV-14, INV-17 (read-only witnesses) | Type |

## Out of Scope

* **Late deposits after `destroy_empty`** — coins `public_transfer`'d to a
  destroyed wallet's address have no `&mut VestingWallet` to be claimed against.
  Their fate is the depositor's responsibility (Design §Public API,
  `destroy_empty` notes). No library invariant covers their recovery.
* **Selling unvested rights via `migrate_beneficiary`** — beneficiary can re-point
  to a buyer's address. Unsolvable at the contract level (OZ accepts the same
  tradeoff). Documented in `answers.md` §Tradeoff summary; no invariant enforces
  non-sale.
* **`u64` aggregate-deposit overflow boundaries** — at `Σ(deposits) > u64::MAX`,
  `balance::join` aborts (framework-level). No library invariant or typed error
  wraps this. Depositor must bound their own accumulation. (Design §Error
  Constants, §Decisions Log #7.)
* **Shared-object contention SLOs** — concurrent `release` finalizes correctly
  (INV-34) but the library makes no claim about throughput under contention. Not
  expected to matter for vesting cashflows.
* **Off-chain time skew between `clock.timestamp_ms()` and wall-clock** — the
  library trusts whatever the Clock object reports. No invariant constrains
  Clock accuracy.
* **Front-running between `migrate_beneficiary` and `release`** — a release that
  finalizes ahead of an in-flight migrate pays the old beneficiary; this is the
  documented INV-29 semantic, not a bug. No invariant on ordering guarantees
  between concurrent rotations and releases.
* **Re-entrancy** — Move has no re-entrancy in the EVM sense; no invariant
  required.

## Dev Notes

* INV-23 (cliff proportional jump) is the single most important math invariant
  and the one most likely to be implemented incorrectly. The research-stage
  reference test `release_at_cliff_jumps_to_proportional` (which does not yet
  exist in `tests/`) directly verifies this — Stage 5 must author it as one of
  the first tests.
* INV-26 (u128 intermediate) is non-obvious from a casual read of OZ's Solidity
  reference (which uses u256 throughout and is silent about overflow). The
  Stage 4 implementation must be written with the u128 cast in mind from line
  one — retrofitting it later means re-running every math test.
* INV-27 (vests-as-if-from-start) is the library's core differentiator vs every
  existing Sui locker. If a future revisor proposes "store original_balance for
  gas savings," this invariant is the reason to reject it.
* INV-35 is intentionally a *negative* invariant — "this is NOT prevented."
  Stage 5 should include a test that demonstrates the trap behavior so future
  readers know it's intentional. A linter or reviewer noticing the gap and
  "fixing" it would silently change the library's contract.
* Event invariants (INV-12) span every emitting function. Consider a small
  test-only helper that captures `event::events_by_type<T>()` for each event
  shape and asserts cardinality — reduces per-test boilerplate.
* No `EOverflow` constant — overflow protection lives in the math (INV-26) and
  in `balance::join`'s framework abort (out of scope above). Tests should still
  exercise large-value scenarios to ensure no abort path other than the
  documented framework-level one is reachable.

## Open Questions

None. The Design stage closed all of its open questions before producing the
artifact (`02-design.md` §Open Questions). The invariants stage extracted only
what the design committed to — every property here traces to either a design
decision or a research-stage requirement, with no unresolved interpretation
needed.

Carried forward to Stage 4 (Code Draft):
* The exact order of operations inside `release` (zero-check before any
  state mutation or event emission — INV-11) should be encoded explicitly in
  code comments referencing INV-11.
* INV-13's `now < start_ms` guard must be the FIRST branch in `vested_amount`,
  before any subtraction.
* INV-26 cast pattern (`as u128` → multiply → divide → `as u64`) should be a
  single helper or inline expression — not split across statements, which
  would invite a future "let me simplify this" refactor that reintroduces u64
  arithmetic.
