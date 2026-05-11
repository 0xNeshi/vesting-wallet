/// Vesting wallet primitives — Sui port of OpenZeppelin's VestingWallet
/// and VestingWalletCliff. Two shared-object types that release vested
/// `Coin<T>` to a beneficiary on a linear schedule. Top-ups vest
/// retroactively per `(balance + released) * elapsed / duration`.
///
/// State and core logic live in `VestingState` (has `store`) and are reused
/// by `vesting_wallet_cliff`. Non-cliff wallets encode "no cliff" as
/// `cliff_ms = start_ms`, which makes the cliff guard collapse into the
/// linear-math pre-start guard.
module vesting_wallet::vesting_wallet;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

const EZeroDuration: u64 = 0;
const ENotBeneficiary: u64 = 1;

// === Structs ===

public struct VestingState<phantom T> has store {
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
    cliff_ms: u64,
    released: u64,
    balance: Balance<T>,
}

public struct VestingWallet<phantom T> has key, store {
    id: UID,
    state: VestingState<T>,
}

// === Events ===

public struct Created<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
}

public struct Deposited<phantom T> has copy, drop {
    wallet_id: ID,
    amount: u64,
    new_balance: u64,
}

public struct Released<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
    total_released: u64,
    timestamp_ms: u64,
}

public struct BeneficiaryTransferred<phantom T> has copy, drop {
    wallet_id: ID,
    old_beneficiary: address,
    new_beneficiary: address,
}

// === Construction ===

public fun new<T>(
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<T> {
    assert!(duration_ms > 0, EZeroDuration);
    let id = object::new(ctx);
    let wallet_id = id.to_inner();
    let state = new_state<T>(beneficiary, start_ms, start_ms, duration_ms);
    event::emit(Created<T> { wallet_id, beneficiary, start_ms, duration_ms });
    VestingWallet { id, state }
}

public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(new<T>(beneficiary, start_ms, duration_ms, ctx));
}

// === Funding ===

public fun deposit<T>(wallet: &mut VestingWallet<T>, coin: Coin<T>) {
    let wallet_id = object::id(wallet);
    let (amount, new_balance) = state_deposit(&mut wallet.state, coin);
    event::emit(Deposited<T> { wallet_id, amount, new_balance });
}

public fun receive_and_deposit<T>(wallet: &mut VestingWallet<T>, receiving: Receiving<Coin<T>>) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

// === Release ===

public fun release<T>(wallet: &mut VestingWallet<T>, clock: &Clock, ctx: &mut TxContext) {
    let wallet_id = object::id(wallet);
    let (amount, total_released, now_ms, beneficiary) = state_release(
        &mut wallet.state,
        clock,
        ctx,
    );
    event::emit(Released<T> {
        wallet_id,
        beneficiary,
        amount,
        total_released,
        timestamp_ms: now_ms,
    });
}

// === Beneficiary rotation ===

public fun transfer_beneficiary<T>(
    wallet: &mut VestingWallet<T>,
    new_beneficiary: address,
    ctx: &TxContext,
) {
    let wallet_id = object::id(wallet);
    let old_beneficiary = state_transfer_beneficiary(&mut wallet.state, new_beneficiary, ctx);
    event::emit(BeneficiaryTransferred<T> {
        wallet_id,
        old_beneficiary,
        new_beneficiary,
    });
}

// === Views ===

public fun beneficiary<T>(wallet: &VestingWallet<T>): address {
    state_beneficiary(&wallet.state)
}

public fun start_ms<T>(wallet: &VestingWallet<T>): u64 { state_start_ms(&wallet.state) }

public fun duration_ms<T>(wallet: &VestingWallet<T>): u64 { state_duration_ms(&wallet.state) }

public fun released<T>(wallet: &VestingWallet<T>): u64 { state_released(&wallet.state) }

public fun balance_value<T>(wallet: &VestingWallet<T>): u64 { state_balance_value(&wallet.state) }

public fun vested_amount<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    state_vested_amount(&wallet.state, clock)
}

public fun releasable<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    state_releasable(&wallet.state, clock)
}

// === Core (package-visible, used by vesting_wallet_cliff) ===

public(package) fun new_state<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
): VestingState<T> {
    VestingState {
        beneficiary,
        start_ms,
        duration_ms,
        cliff_ms,
        released: 0,
        balance: balance::zero<T>(),
    }
}

public(package) fun state_deposit<T>(state: &mut VestingState<T>, coin: Coin<T>): (u64, u64) {
    let amount = coin.value();
    state.balance.join(coin.into_balance());
    (amount, state.balance.value())
}

public(package) fun state_release<T>(
    state: &mut VestingState<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64, u64, address) {
    let now_ms = clock.timestamp_ms();
    let amount = state_releasable(state, clock);
    if (amount > 0) {
        state.released = state.released + amount;
        let coin = coin::take(&mut state.balance, amount, ctx);
        transfer::public_transfer(coin, state.beneficiary);
    };
    (amount, state.released, now_ms, state.beneficiary)
}

public(package) fun state_transfer_beneficiary<T>(
    state: &mut VestingState<T>,
    new_beneficiary: address,
    ctx: &TxContext,
): address {
    assert!(ctx.sender() == state.beneficiary, ENotBeneficiary);
    let old = state.beneficiary;
    state.beneficiary = new_beneficiary;
    old
}

public(package) fun state_beneficiary<T>(state: &VestingState<T>): address { state.beneficiary }

public(package) fun state_start_ms<T>(state: &VestingState<T>): u64 { state.start_ms }

public(package) fun state_duration_ms<T>(state: &VestingState<T>): u64 { state.duration_ms }

public(package) fun state_cliff_ms<T>(state: &VestingState<T>): u64 { state.cliff_ms }

public(package) fun state_released<T>(state: &VestingState<T>): u64 { state.released }

public(package) fun state_balance_value<T>(state: &VestingState<T>): u64 { state.balance.value() }

public(package) fun state_vested_amount<T>(state: &VestingState<T>, clock: &Clock): u64 {
    let now_ms = clock.timestamp_ms();
    if (now_ms < state.cliff_ms) return 0;
    let total = state.balance.value() + state.released;
    linear_vested_amount(now_ms, state.start_ms, state.duration_ms, total)
}

public(package) fun state_releasable<T>(state: &VestingState<T>, clock: &Clock): u64 {
    state_vested_amount(state, clock) - state.released
}

/// Linear vested amount: `total * elapsed / duration`, clamped to `[0, total]`.
/// Pure — takes `now_ms` directly. Uses u128 intermediate to avoid u64 overflow.
fun linear_vested_amount(now_ms: u64, start_ms: u64, duration_ms: u64, total: u64): u64 {
    if (now_ms < start_ms) return 0;
    let elapsed = now_ms - start_ms;
    if (elapsed >= duration_ms) return total;
    (((total as u128) * (elapsed as u128) / (duration_ms as u128)) as u64)
}
