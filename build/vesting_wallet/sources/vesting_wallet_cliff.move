/// Vesting wallet with cliff. Releases nothing until `cliff_ms`, then follows
/// the same linear schedule as VestingWallet (computed from `start_ms`, not
/// `cliff_ms` — at the cliff boundary, vested amount jumps from 0 to
/// `total * (cliff_ms - start_ms) / duration_ms`).
///
/// Thin wrapper: state and core logic live in `vesting_wallet::VestingState`.
module vesting_wallet::vesting_wallet_cliff;

use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::transfer::Receiving;
use vesting_wallet::vesting_wallet::{Self, VestingState};

// === Errors ===

const EZeroDuration: u64 = 0;
const ECliffExceedsDuration: u64 = 1;

// === Structs ===

public struct VestingWalletCliff<phantom T> has key, store {
    id: UID,
    state: VestingState<T>,
}

// === Events ===

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
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWalletCliff<T> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_duration_ms <= duration_ms, ECliffExceedsDuration);
    let cliff_ms = start_ms + cliff_duration_ms;
    let id = object::new(ctx);
    let wallet_id = id.to_inner();
    let state = vesting_wallet::new_state<T>(beneficiary, start_ms, cliff_ms, duration_ms);
    event::emit(Created<T> {
        wallet_id,
        beneficiary,
        start_ms,
        cliff_ms,
        duration_ms,
    });
    VestingWalletCliff { id, state }
}

public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(new<T>(beneficiary, start_ms, cliff_duration_ms, duration_ms, ctx));
}

// === Funding ===

public fun deposit<T>(wallet: &mut VestingWalletCliff<T>, coin: Coin<T>) {
    let wallet_id = object::id(wallet);
    let (amount, new_balance) = vesting_wallet::state_deposit(&mut wallet.state, coin);
    event::emit(Deposited<T> { wallet_id, amount, new_balance });
}

public fun receive_and_deposit<T>(
    wallet: &mut VestingWalletCliff<T>,
    receiving: Receiving<Coin<T>>,
) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

// === Release ===

public fun release<T>(wallet: &mut VestingWalletCliff<T>, clock: &Clock, ctx: &mut TxContext) {
    let wallet_id = object::id(wallet);
    let (amount, total_released, now_ms, beneficiary) = vesting_wallet::state_release(
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
    wallet: &mut VestingWalletCliff<T>,
    new_beneficiary: address,
    ctx: &TxContext,
) {
    let wallet_id = object::id(wallet);
    let old_beneficiary = vesting_wallet::state_transfer_beneficiary(
        &mut wallet.state,
        new_beneficiary,
        ctx,
    );
    event::emit(BeneficiaryTransferred<T> {
        wallet_id,
        old_beneficiary,
        new_beneficiary,
    });
}

// === Views ===

public fun beneficiary<T>(wallet: &VestingWalletCliff<T>): address {
    vesting_wallet::state_beneficiary(&wallet.state)
}

public fun start_ms<T>(wallet: &VestingWalletCliff<T>): u64 {
    vesting_wallet::state_start_ms(&wallet.state)
}

public fun cliff_ms<T>(wallet: &VestingWalletCliff<T>): u64 {
    vesting_wallet::state_cliff_ms(&wallet.state)
}

public fun duration_ms<T>(wallet: &VestingWalletCliff<T>): u64 {
    vesting_wallet::state_duration_ms(&wallet.state)
}

public fun released<T>(wallet: &VestingWalletCliff<T>): u64 {
    vesting_wallet::state_released(&wallet.state)
}

public fun balance_value<T>(wallet: &VestingWalletCliff<T>): u64 {
    vesting_wallet::state_balance_value(&wallet.state)
}

public fun vested_amount<T>(wallet: &VestingWalletCliff<T>, clock: &Clock): u64 {
    vesting_wallet::state_vested_amount(&wallet.state, clock)
}

public fun releasable<T>(wallet: &VestingWalletCliff<T>, clock: &Clock): u64 {
    vesting_wallet::state_releasable(&wallet.state, clock)
}
