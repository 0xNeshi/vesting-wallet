/// A linear vesting wallet for a single coin type.
///
/// # The schedule
///
/// One wallet locks a `Balance<T>` for a single `beneficiary` and releases it
/// linearly between `start_ms` and `start_ms + duration_ms`. An optional cliff
/// (`cliff_ms`) gates releases until `start_ms + cliff_ms` — at the cliff
/// boundary, the vested amount jumps from zero straight to the linear-from-start
/// proportion (`total * cliff_ms / duration_ms`). The curve itself is not
/// shifted by the cliff; the cliff only delays when releases become reachable.
///
/// # The flow
///
/// 1. Someone calls `new` (or `create_and_share`) with the schedule.
/// 2. Anyone funds the wallet via `deposit` (direct) or `receive_and_deposit`
///    (collecting coins that were `public_transfer`'d to the wallet's address).
///    Funds added after `start_ms` retroactively participate in vesting — the
///    curve is always evaluated against `balance + released`, never a snapshot.
/// 3. Anyone can call `release` to send the currently-vested amount to the
///    beneficiary. Pre-cliff or already-claimed calls are silent no-ops.
/// 4. The beneficiary may call `migrate_beneficiary` as an exceptional
///    re-pointing. For routine rotation, consumers point `beneficiary` at a
///    consumer-owned object and rotate ownership of that object instead.
/// 5. Once vesting has ended and the balance is drained, anyone can call
///    `destroy_empty` to reclaim storage rebate.
///
/// # Topologies
///
/// `VestingWallet<T>` has `key + store`, so the consumer picks the topology
/// after `new` returns:
/// * **Shared** (recommended): `transfer::public_share_object(wallet)` —
///   anyone can poke `release`. `create_and_share` does this in one call.
/// * **Owned** (fast path): `transfer::public_transfer(wallet, addr)` — only
///   the holder can pass the wallet by `&mut` reference, so `deposit` and the
///   other state-changing calls are reachable from the holder's transactions
///   only. Outside parties who want to fund the wallet `public_transfer` their
///   `Coin<T>` directly to the wallet's object address; the holder then claims
///   each one with `receive_and_deposit`, which routes it into the same
///   internal balance as `deposit`. ⚠ If the holder transfers the wallet
///   without first calling `migrate_beneficiary`, the new holder cannot
///   re-point it (the sender gate keys off the old address) and future
///   releases keep flowing to the old beneficiary.
module vesting_wallet::vesting_wallet;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

const EZeroDuration: u64 = 0;
const EInvalidCliff: u64 = 1;
const EUnauthorized: u64 = 2;
const ENotEnded: u64 = 3;
const ENotEmpty: u64 = 4;

// === Types ===

/// The vesting wallet. Schedule fields (`start_ms`, `cliff_ms`, `duration_ms`)
/// are fixed at construction; only `balance` and `released` move over time.
/// Their sum is the wallet's "current total" and feeds every view computation.
public struct VestingWallet<phantom T> has key, store {
    id: UID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    released: u64,
    balance: Balance<T>,
}

// === Events ===
//
// One event per state-changing call (zero events for no-op `release`).
// Phantom `T` lets indexers subscribe per coin type.

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

// === Creation ===

/// Build a new wallet and return it by value. Returning by value (rather than
/// sharing internally) lets the caller chain creation, funding, and topology
/// selection in a single PTB.
public fun new<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<T> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_duration_ms <= duration_ms, EInvalidCliff);

    let wallet = VestingWallet<T> {
        id: object::new(ctx),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
        released: 0,
        balance: balance::zero<T>(),
    };

    event::emit(Created<T> {
        wallet_id: object::id(&wallet),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
    });

    wallet
}

/// Sugar for the common case: build the wallet and share it in one call.
public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<T>(beneficiary, start_ms, cliff_duration_ms, duration_ms, ctx);
    transfer::public_share_object(wallet);
}

// === Funding ===

/// Add a coin to the wallet's balance. Permissionless — the beneficiary's
/// identity is data, not a capability, and anyone may fund.
public fun deposit<T>(wallet: &mut VestingWallet<T>, coin: Coin<T>) {
    let amount = coin.value();
    wallet.balance.join(coin.into_balance());
    event::emit(Deposited<T> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this wallet's
/// object address, then funnel it through the standard deposit path. Used by
/// emission schedules and payroll robots that don't hold a wallet reference.
public fun receive_and_deposit<T>(wallet: &mut VestingWallet<T>, receiving: Receiving<Coin<T>>) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

// === Release ===

/// Send whatever is currently vested-but-not-yet-released to the beneficiary.
/// Permissionless: anyone with a wallet reference can poke this. The recipient
/// is always read fresh from `wallet.beneficiary` at call time — never
/// snapshotted, so `migrate_beneficiary` between two releases sends the second
/// release to the new address.
///
/// If nothing is releasable (pre-cliff, or already drained at this clock), the
/// call returns silently without emitting an event or minting a zero-value
/// coin. Callers can poll-then-poke without pre-checking.
public fun release<T>(wallet: &mut VestingWallet<T>, clock: &Clock, ctx: &mut TxContext) {
    let amount = releasable(wallet, clock);
    if (amount == 0) return;

    wallet.released = wallet.released + amount;
    let coin = coin::from_balance(wallet.balance.split(amount), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<T> {
        wallet_id: object::id(wallet),
        beneficiary,
        amount,
    });
}

// === Beneficiary management ===

/// Exceptional re-pointing — single-step, sender-gated to the current
/// beneficiary. Use this only when the beneficiary address itself must change
/// (compromise recovery, topology migration).
///
/// Previously-released coins stay where they were sent; only future releases
/// flow to the new address.
public fun migrate_beneficiary<T>(
    wallet: &mut VestingWallet<T>,
    new_beneficiary: address,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == wallet.beneficiary, EUnauthorized);

    let old_beneficiary = wallet.beneficiary;
    wallet.beneficiary = new_beneficiary;

    event::emit(BeneficiaryMigrated<T> {
        wallet_id: object::id(wallet),
        old_beneficiary,
        new_beneficiary,
    });
}

// === Cleanup ===

/// Consume a fully-drained, fully-ended wallet to reclaim storage rebate.
/// Permissionless. Coins `public_transfer`'d to a destroyed wallet's address
/// after this call have no path back — pair destruction with halting any
/// upstream emissions that target this wallet.
public fun destroy_empty<T>(wallet: VestingWallet<T>, clock: &Clock) {
    assert!(clock.timestamp_ms() >= wallet.start_ms + wallet.duration_ms, ENotEnded);
    assert!(wallet.balance.value() == 0, ENotEmpty);

    let wallet_id = object::id(&wallet);
    let beneficiary = wallet.beneficiary;
    let total_released = wallet.released;

    let VestingWallet {
        id,
        beneficiary: _,
        start_ms: _,
        cliff_ms: _,
        duration_ms: _,
        released: _,
        balance,
    } = wallet;
    balance.destroy_zero();
    id.delete();

    event::emit(Destroyed<T> { wallet_id, beneficiary, total_released });
}

// === Views ===

/// The schedule curve evaluated at `clock.timestamp_ms()`.
///
/// * Pre-start: zero.
/// * Pre-cliff (when a cliff is configured): zero. At the cliff boundary the
///   value jumps directly to the linear-from-start proportion — the cliff
///   gates the curve, it does not shift it.
/// * Mid-schedule: linear in elapsed time.
/// * Post-end: clamped to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call, so deposits made at `t > start_ms`
/// immediately participate in vesting at the current proportion.
public fun vested_amount<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();

    if (now < wallet.start_ms) return 0;
    if (wallet.cliff_ms > 0 && now < wallet.start_ms + wallet.cliff_ms) return 0;

    let total = wallet.balance.value() + wallet.released;

    if (now >= wallet.start_ms + wallet.duration_ms) return total;

    let elapsed = (now - wallet.start_ms) as u128;
    let vested = ((total as u128) * elapsed) / (wallet.duration_ms as u128);
    vested as u64
}

/// What `release` would pay out if called now.
public fun releasable<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    vested_amount(wallet, clock) - wallet.released
}

// === Accessors ===

public fun beneficiary<T>(wallet: &VestingWallet<T>): address { wallet.beneficiary }

public fun start<T>(wallet: &VestingWallet<T>): u64 { wallet.start_ms }

public fun cliff<T>(wallet: &VestingWallet<T>): u64 { wallet.cliff_ms }

public fun duration<T>(wallet: &VestingWallet<T>): u64 { wallet.duration_ms }

public fun end<T>(wallet: &VestingWallet<T>): u64 { wallet.start_ms + wallet.duration_ms }

public fun released<T>(wallet: &VestingWallet<T>): u64 { wallet.released }

public fun balance<T>(wallet: &VestingWallet<T>): u64 { wallet.balance.value() }
