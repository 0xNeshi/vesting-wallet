/// Adoption walkthroughs for the `team_vesting` integration on top of
/// `vesting_wallet`. Each test plays out a complete actor flow over several
/// transactions — these are not unit-style coverage of the library, they're
/// integration-shaped stories an integrator can read top-to-bottom.
#[test_only]
module vesting_example::team_vesting_tests;

use std::unit_test;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario;
use vesting_example::team_vesting::{Self, Program, AdminCap};
use vesting_wallet::vesting_wallet::VestingWallet;

const PUBLISHER: address = @0xA1;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

// === Scenario 1 ====================================================
// Full lifecycle: PUBLISHER deploys + funds the program; the admin (=
// PUBLISHER) grants 1_000 SUI to ALICE on a 10-second linear schedule;
// BOB (a random third party) pokes `release` at mid-vest and again past
// end. ALICE accumulates the full grant in two payouts; the wallet is
// drained, and anyone can reclaim its storage rebate via `destroy_empty`.

#[test]
fun publisher_bootstraps_admin_grants_third_party_drives_release_and_destroy() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    // Tx 1 — PUBLISHER: deploy program (funded), share a Clock, route the
    // AdminCap to PUBLISHER's address.
    {
        let funding = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        let (_program_id, admin) = team_vesting::deploy_and_share<SUI>(
            funding,
            scenario.ctx(),
        );
        transfer::public_transfer(admin, PUBLISHER);
        clock::create_for_testing(scenario.ctx()).share_for_testing();
    };

    // Tx 2 — PUBLISHER (admin): grant 1_000 to ALICE; schedule
    // [start=1_000ms, no cliff, dur=10_000ms].
    scenario.next_tx(PUBLISHER);
    {
        let mut program = scenario.take_shared<Program<SUI>>();
        let admin = scenario.take_from_sender<AdminCap>();
        let _wallet_id = program.grant<SUI>(
            &admin,
            ALICE,
            1_000,
            1_000,
            0,
            10_000,
            scenario.ctx(),
        );
        // Pool is fully consumed by this single grant.
        assert!(program.pool() == 0);
        test_scenario::return_shared(program);
        scenario.return_to_sender(admin);
    };

    // Tx 3 — BOB: poke `release` at mid-vest. Sends 500 to ALICE.
    // Demonstrates that release is permissionless — BOB is neither admin
    // nor beneficiary.
    scenario.next_tx(BOB);
    {
        let mut wallet = scenario.take_shared<VestingWallet<SUI>>();
        let mut clk = scenario.take_shared<Clock>();
        clk.set_for_testing(6_000); // 50% elapsed
        wallet.release(&clk, scenario.ctx());
        test_scenario::return_shared(wallet);
        test_scenario::return_shared(clk);
    };

    // Tx 4 — ALICE: confirm she received the first half.
    scenario.next_tx(ALICE);
    {
        let payout = scenario.take_from_sender<Coin<SUI>>();
        assert!(payout.value() == 500);
        scenario.return_to_sender(payout);
    };

    // Tx 5 — BOB: poke once more past schedule end. Remainder vests.
    scenario.next_tx(BOB);
    {
        let mut wallet = scenario.take_shared<VestingWallet<SUI>>();
        let mut clk = scenario.take_shared<Clock>();
        clk.set_for_testing(11_001); // past end (start+duration = 11_000)
        wallet.release(&clk, scenario.ctx());
        test_scenario::return_shared(wallet);
        test_scenario::return_shared(clk);
    };

    // Tx 6 — ALICE: second payout for the other half. Both payouts now sit
    // in her inventory as separate coins; merge them and confirm the full
    // 1_000 grant landed.
    scenario.next_tx(ALICE);
    {
        let ids = test_scenario::ids_for_sender<Coin<SUI>>(&scenario);
        assert!(ids.length() == 2);
        let mut first = scenario.take_from_sender_by_id<Coin<SUI>>(*ids.borrow(0));
        let second = scenario.take_from_sender_by_id<Coin<SUI>>(*ids.borrow(1));
        assert!(first.value() == 500);
        assert!(second.value() == 500);
        first.join(second);
        assert!(first.value() == 1_000);
        scenario.return_to_sender(first);
    };

    // Tx 7 — anyone (BOB): drained wallet past end → reclaim storage.
    scenario.next_tx(BOB);
    {
        let wallet = scenario.take_shared<VestingWallet<SUI>>();
        let clk = scenario.take_shared<Clock>();
        wallet.destroy_empty(&clk);
        test_scenario::return_shared(clk);
    };

    scenario.end();
}

// === Scenario 2 ====================================================
// Retroactive funding: the admin grants ALICE a small wallet, then later
// tops it up from the pool. The library's curve reads `balance + released`
// fresh, so the topped-up amount participates in vesting from the schedule's
// original `start_ms` — ALICE ends up with the full topped-up total at end.

#[test]
fun admin_tops_up_existing_grant_post_creation() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    // Tx 1 — PUBLISHER: deploy with 1_000 in the pool, share the clock.
    {
        let funding = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        let (_, admin) = team_vesting::deploy_and_share<SUI>(
            funding,
            scenario.ctx(),
        );
        transfer::public_transfer(admin, PUBLISHER);
        clock::create_for_testing(scenario.ctx()).share_for_testing();
    };

    // Tx 2 — admin: grant 500 to ALICE; pool retains 500.
    scenario.next_tx(PUBLISHER);
    {
        let mut program = scenario.take_shared<Program<SUI>>();
        let admin = scenario.take_from_sender<AdminCap>();
        let _id = program.grant<SUI>(
            &admin,
            ALICE,
            500,
            0, // start at t=0
            0, // no cliff
            10_000, // 10s duration
            scenario.ctx(),
        );
        assert!(program.pool() == 500);
        test_scenario::return_shared(program);
        scenario.return_to_sender(admin);
    };

    // Tx 3 — admin: top up the existing wallet with the remaining 500.
    // Pool drains; wallet now holds 1_000 against the same schedule.
    scenario.next_tx(PUBLISHER);
    {
        let mut program = scenario.take_shared<Program<SUI>>();
        let admin = scenario.take_from_sender<AdminCap>();
        let mut wallet = scenario.take_shared<VestingWallet<SUI>>();
        program.top_up_grant<SUI>(
            &admin,
            &mut wallet,
            500,
            scenario.ctx(),
        );
        assert!(program.pool() == 0);
        assert!(wallet.balance() == 1_000);
        test_scenario::return_shared(program);
        scenario.return_to_sender(admin);
        test_scenario::return_shared(wallet);
    };

    // Tx 4 — BOB: poke release at end. ALICE should receive the full 1_000,
    // *including the post-creation top-up* — that's the retroactive
    // property of the library's curve.
    scenario.next_tx(BOB);
    {
        let mut wallet = scenario.take_shared<VestingWallet<SUI>>();
        let mut clk = scenario.take_shared<Clock>();
        clk.set_for_testing(10_001);
        wallet.release(&clk, scenario.ctx());
        test_scenario::return_shared(wallet);
        test_scenario::return_shared(clk);
    };

    // Tx 5 — ALICE: full topped-up amount lands in one payout.
    scenario.next_tx(ALICE);
    {
        let payout = scenario.take_from_sender<Coin<SUI>>();
        assert!(payout.value() == 1_000);
        scenario.return_to_sender(payout);
    };

    scenario.end();
}

// === Scenario 3 ====================================================
// Caveat: an AdminCap minted for program A cannot authorize a `grant` on
// program B. This is the Sui-specific "bind the cap to its shared object
// by ID" footgun called out in the module docs. Without the `assert!`
// inside `grant`, this test would silently succeed.

#[test]
#[expected_failure(abort_code = team_vesting::EWrongProgram)]
fun stale_admin_cap_cannot_grant_on_another_program() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    // Tx 1 — PUBLISHER: deploy two independent programs. Keep A's
    // AdminCap; discard B's so the test can't accidentally use it.
    let program_b_id = {
        let funding_a = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        let (_id_a, admin_a) = team_vesting::deploy_and_share<SUI>(
            funding_a,
            scenario.ctx(),
        );

        let funding_b = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        let (id_b, admin_b) = team_vesting::deploy_and_share<SUI>(
            funding_b,
            scenario.ctx(),
        );

        transfer::public_transfer(admin_a, PUBLISHER);
        unit_test::destroy(admin_b);
        id_b
    };

    // Tx 2 — PUBLISHER: attempt to grant against program B using A's cap.
    // Must abort with `EWrongProgram`.
    scenario.next_tx(PUBLISHER);
    {
        let mut program_b = scenario.take_shared_by_id<Program<SUI>>(program_b_id);
        let admin_a = scenario.take_from_sender<AdminCap>();
        let _id = program_b.grant<SUI>(
            &admin_a,
            ALICE,
            100,
            0,
            0,
            1_000,
            scenario.ctx(),
        );
        // Unreachable on abort. Lines below exist only so the function
        // type-checks; the test framework expects the abort above.
        test_scenario::return_shared(program_b);
        scenario.return_to_sender(admin_a);
    };

    scenario.end();
}
