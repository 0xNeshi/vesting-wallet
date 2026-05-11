#[test_only]
module vesting_wallet::vesting_wallet_cliff_tests;

use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;
use vesting_wallet::vesting_wallet_cliff::{Self, VestingWalletCliff};

public struct TEST_COIN has drop {}

const TREASURY: address = @0xC;
const ALICE: address = @0xA;
const BOB: address = @0xB;

const START: u64 = 1_000;
const CLIFF_DURATION: u64 = 200;
const DURATION: u64 = 1_000;
const TOTAL: u64 = 1_000_000;

// Absolute cliff timestamp for assertions.
const CLIFF_AT: u64 = START + CLIFF_DURATION; // 1_200

// === Helpers ===

fun fund_and_share(scenario: &mut ts::Scenario, beneficiary: address, amount: u64) {
    let ctx = scenario.ctx();
    let mut wallet = vesting_wallet_cliff::new<TEST_COIN>(
        beneficiary,
        START,
        CLIFF_DURATION,
        DURATION,
        ctx,
    );
    let coin = coin::mint_for_testing<TEST_COIN>(amount, ctx);
    vesting_wallet_cliff::deposit(&mut wallet, coin);
    transfer::public_share_object(wallet);
}

fun release_at(scenario: &mut ts::Scenario, now_ms: u64) {
    let mut wallet: VestingWalletCliff<TEST_COIN> = scenario.take_shared();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(now_ms);
    vesting_wallet_cliff::release(&mut wallet, &clk, scenario.ctx());
    clock::destroy_for_testing(clk);
    ts::return_shared(wallet);
}

fun assert_received(scenario: &ts::Scenario, who: address, amount: u64) {
    let coin: Coin<TEST_COIN> = scenario.take_from_address(who);
    assert_eq!(coin.value(), amount);
    coin::burn_for_testing(coin);
}

// === Tests ===

#[test]
fun no_release_before_cliff() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // Halfway between start and cliff — past start, before cliff.
    // Linear math would yield TOTAL * 100 / 1000 = 100_000, but cliff gates it to 0.
    scenario.next_tx(BOB);
    release_at(&mut scenario, START + CLIFF_DURATION / 2);

    scenario.next_tx(BOB);
    let wallet: VestingWalletCliff<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet_cliff::released(&wallet), 0);
    assert_eq!(vesting_wallet_cliff::balance_value(&wallet), TOTAL);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun release_at_cliff_jumps_to_proportional() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // Exactly at the cliff, vested = TOTAL * cliff_duration / duration = 200_000.
    scenario.next_tx(BOB);
    release_at(&mut scenario, CLIFF_AT);

    let expected = TOTAL * CLIFF_DURATION / DURATION;
    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, expected);

    let wallet: VestingWalletCliff<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet_cliff::released(&wallet), expected);
    assert_eq!(vesting_wallet_cliff::balance_value(&wallet), TOTAL - expected);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun release_after_duration_drains_all() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION + 1);

    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, TOTAL);

    let wallet: VestingWalletCliff<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet_cliff::released(&wallet), TOTAL);
    assert_eq!(vesting_wallet_cliff::balance_value(&wallet), 0);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun cliff_then_continued_linear_release() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // Release at cliff: gets 200_000.
    scenario.next_tx(BOB);
    release_at(&mut scenario, CLIFF_AT);
    let cliff_release = TOTAL * CLIFF_DURATION / DURATION;
    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, cliff_release);

    // Release at midpoint (start+500): linear vested = TOTAL * 500/1000 = 500_000.
    // Already released = 200_000 → releasable = 300_000.
    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION / 2);
    let midpoint_total = TOTAL * (DURATION / 2) / DURATION;
    let second_release = midpoint_total - cliff_release;
    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, second_release);

    let wallet: VestingWalletCliff<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet_cliff::released(&wallet), midpoint_total);
    ts::return_shared(wallet);

    scenario.end();
}

#[test, expected_failure(abort_code = vesting_wallet_cliff::ECliffExceedsDuration)]
fun cliff_longer_than_duration_aborts() {
    let mut scenario = ts::begin(TREASURY);
    let wallet = vesting_wallet_cliff::new<TEST_COIN>(
        ALICE,
        START,
        DURATION + 1,
        DURATION,
        scenario.ctx(),
    );
    destroy(wallet);
    scenario.end();
}

#[test, expected_failure(abort_code = vesting_wallet_cliff::EZeroDuration)]
fun zero_duration_aborts() {
    let mut scenario = ts::begin(TREASURY);
    let wallet = vesting_wallet_cliff::new<TEST_COIN>(
        ALICE,
        START,
        0,
        0,
        scenario.ctx(),
    );
    destroy(wallet);
    scenario.end();
}
