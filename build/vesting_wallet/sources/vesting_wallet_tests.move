#[test_only]
module vesting_wallet::vesting_wallet_tests;

use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::coin::{Self, Coin};
use sui::test_scenario as ts;
use vesting_wallet::vesting_wallet::{Self, VestingWallet};

public struct TEST_COIN has drop {}

const TREASURY: address = @0xC;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CAROL: address = @0xCC;

const START: u64 = 1_000;
const DURATION: u64 = 1_000;
const TOTAL: u64 = 1_000_000;

// === Helpers ===

fun fund_and_share(scenario: &mut ts::Scenario, beneficiary: address, amount: u64) {
    let ctx = scenario.ctx();
    let mut wallet = vesting_wallet::new<TEST_COIN>(beneficiary, START, DURATION, ctx);
    let coin = coin::mint_for_testing<TEST_COIN>(amount, ctx);
    vesting_wallet::deposit(&mut wallet, coin);
    transfer::public_share_object(wallet);
}

fun release_at(scenario: &mut ts::Scenario, now_ms: u64) {
    let mut wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(now_ms);
    vesting_wallet::release(&mut wallet, &clk, scenario.ctx());
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
fun release_midway_vests_half() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // Anyone (BOB) triggers; coin lands at ALICE.
    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION / 2);

    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, TOTAL / 2);

    // released and balance reflect the half-vest.
    let wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet::released(&wallet), TOTAL / 2);
    assert_eq!(vesting_wallet::balance_value(&wallet), TOTAL / 2);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun release_after_duration_drains_all() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION + 999); // well past end

    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, TOTAL);

    let wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet::released(&wallet), TOTAL);
    assert_eq!(vesting_wallet::balance_value(&wallet), 0);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun release_before_start_is_noop() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    scenario.next_tx(BOB);
    release_at(&mut scenario, START - 1);

    scenario.next_tx(BOB);
    let wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet::released(&wallet), 0);
    assert_eq!(vesting_wallet::balance_value(&wallet), TOTAL);
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun top_up_vests_retroactively() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // Halfway through, release the half.
    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION / 2);
    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, TOTAL / 2);

    // Top up another TOTAL at the same instant (still halfway).
    // Per OZ math: total_allocation = balance + released = (TOTAL/2 + TOTAL) + TOTAL/2 = 2 * TOTAL.
    // Vested = 2*TOTAL * 1/2 = TOTAL. Already released = TOTAL/2 → releasable = TOTAL/2 more.
    scenario.next_tx(TREASURY);
    {
        let mut wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
        let topup = coin::mint_for_testing<TEST_COIN>(TOTAL, scenario.ctx());
        vesting_wallet::deposit(&mut wallet, topup);
        ts::return_shared(wallet);
    };

    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION / 2);
    scenario.next_tx(ALICE);
    assert_received(&scenario, ALICE, TOTAL / 2);

    let wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    assert_eq!(vesting_wallet::released(&wallet), TOTAL);
    assert_eq!(vesting_wallet::balance_value(&wallet), TOTAL); // half of 2*TOTAL still locked
    ts::return_shared(wallet);

    scenario.end();
}

#[test]
fun beneficiary_can_rotate() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    // ALICE rotates to CAROL.
    scenario.next_tx(ALICE);
    {
        let mut wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
        vesting_wallet::transfer_beneficiary(&mut wallet, CAROL, scenario.ctx());
        assert_eq!(vesting_wallet::beneficiary(&wallet), CAROL);
        ts::return_shared(wallet);
    };

    // Subsequent release goes to CAROL, not ALICE.
    scenario.next_tx(BOB);
    release_at(&mut scenario, START + DURATION);

    scenario.next_tx(CAROL);
    assert_received(&scenario, CAROL, TOTAL);

    scenario.end();
}

#[test, expected_failure(abort_code = vesting_wallet::ENotBeneficiary)]
fun non_beneficiary_cannot_rotate() {
    let mut scenario = ts::begin(TREASURY);
    fund_and_share(&mut scenario, ALICE, TOTAL);

    scenario.next_tx(BOB); // BOB is not the beneficiary.
    let mut wallet: VestingWallet<TEST_COIN> = scenario.take_shared();
    vesting_wallet::transfer_beneficiary(&mut wallet, BOB, scenario.ctx());
    ts::return_shared(wallet);
    scenario.end();
}

#[test, expected_failure(abort_code = vesting_wallet::EZeroDuration)]
fun zero_duration_aborts() {
    let mut scenario = ts::begin(TREASURY);
    let wallet = vesting_wallet::new<TEST_COIN>(ALICE, START, 0, scenario.ctx());
    destroy(wallet);
    scenario.end();
}
