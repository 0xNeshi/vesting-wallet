/// A team-grants vesting program built on top of `vesting_wallet`.
///
/// # The flow
///
/// 1. Publisher calls `deploy_and_share` with the initial funding coin. The
///    program is shared in the same call; the publisher receives back the
///    program's `ID` (for off-chain tooling) and an `AdminCap` bound to that
///    specific program.
/// 2. Anyone may `top_up` the program's pool — replenishing a treasury is
///    permissionless and does not need authority.
/// 3. The admin (anyone holding the matching `AdminCap`) calls `grant` to
///    subtract from the pool, build a `VestingWallet<T>`, deposit the
///    allocation, and share the wallet — all atomically in one PTB.
/// 4. The admin may also call `top_up_grant` to top up an existing granted
///    wallet from the program's pool. This is admin-gated, unlike the
///    library's `deposit` which is permissionless.
///
/// Once a wallet has been granted, it lives on its own as a shared object.
/// `release`, `migrate_beneficiary`, and `destroy_empty` are called directly
/// on the library — this module never re-wraps them.
///
/// # Why this module wraps the library
///
/// `vesting_wallet` is intentionally schedule-only and permissionless: it
/// doesn't know about funding sources, treasuries, or admin authority. Every
/// integrator with a treasury still needs to express the same three things:
/// a single source of funds, an authority gate over new grants, and an atomic
/// "subtract from pool + create + fund + share" entrypoint. This module is
/// what that looks like. It does not rename or paper over the library — the
/// granted wallet is a plain `VestingWallet<T>` that consumers interact with
/// using the library's own API.
///
/// # Caveat: bind the AdminCap to the program by ID
///
/// In Sui, a capability is just an object — the type system alone does not
/// pin an `AdminCap` to a particular shared program. Two independently
/// deployed programs both mint `AdminCap`s of the same type; nothing about
/// `&AdminCap` distinguishes them at the call site. If a privileged
/// entrypoint accepts any `&AdminCap`, a stale or borrowed cap from program
/// A silently authorizes grants on program B.
///
/// The fix is explicit identity binding: each `AdminCap` stores the
/// `program_id` it was minted for, and every privileged entrypoint asserts
/// `admin.program_id == object::id(program)`. The
/// `stale_admin_cap_cannot_grant_on_another_program` scenario test exercises
/// this directly.
module vesting_example::team_vesting;

use sui::coin::{Self, Coin};
use sui::balance::Balance;
use vesting_wallet::vesting_wallet::{Self, VestingWallet};

// === Errors ===

const EWrongProgram: u64 = 0;

// === Types ===

/// The grants program. Holds a single `Balance<T>` pool that funds future
/// grants. `key`-only (no `store`) so this module owns the moves of the
/// `Program` itself — it cannot be passed into other modules' `transfer::*`.
public struct Program<phantom T> has key {
    id: UID,
    pool: Balance<T>,
}

/// Authority to call privileged entrypoints on a specific `Program`. The
/// `program_id` field is the binding asserted on every privileged call (see
/// module docs). `key + store` so the holder can move it through normal Sui
/// transfer plumbing — multisig, custody, etc.
public struct AdminCap has key, store {
    id: UID,
    program_id: ID,
}

// === Deployment ===

/// Build the program, share it, and return its `ID` along with a fresh
/// `AdminCap` bound to that ID. The caller decides where the cap ends up
/// (publisher address, multisig, custody, etc.) — this module does not
/// transfer it for them.
public fun deploy_and_share<T>(
    funding: Coin<T>,
    ctx: &mut TxContext,
): (ID, AdminCap) {
    let program = Program<T> {
        id: object::new(ctx),
        pool: funding.into_balance(),
    };
    let program_id = object::id(&program);
    let admin = AdminCap {
        id: object::new(ctx),
        program_id,
    };
    transfer::share_object(program);
    (program_id, admin)
}

// === Pool refill (permissionless) ===

/// Donate to the pool. No authority gate — anyone may contribute. Mirrors
/// `vesting_wallet::deposit`: funding is data, not capability.
public fun top_up<T>(program: &mut Program<T>, coin: Coin<T>) {
    program.pool.join(coin.into_balance());
}

// === Privileged grant creation ===

/// Issue a new vesting grant from the pool. Subtracts `amount` from the
/// program's pool, constructs a `VestingWallet<T>` with the supplied
/// schedule, deposits the allocation, and shares the wallet. Returns the new
/// wallet's `ID` so off-chain tooling can locate it without scraping events.
///
/// Aborts with `EWrongProgram` if the `AdminCap` was minted for a different
/// program (see the module-level caveat).
public fun grant<T>(
    program: &mut Program<T>,
    admin: &AdminCap,
    beneficiary: address,
    amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): ID {
    assert!(admin.program_id == object::id(program), EWrongProgram);

    let allocation = coin::from_balance(program.pool.split(amount), ctx);
    let mut wallet = vesting_wallet::new<T>(
        beneficiary,
        start_ms,
        cliff_ms,
        duration_ms,
        ctx,
    );
    vesting_wallet::deposit(&mut wallet, allocation);
    let wallet_id = object::id(&wallet);
    transfer::public_share_object(wallet);
    wallet_id
}

/// Top up an existing granted wallet from the pool. This is the admin-gated
/// counterpart to the library's permissionless `deposit`: it forces the
/// extra funding to come out of the program's pool rather than an arbitrary
/// coin produced elsewhere.
///
/// Because `vesting_wallet::vested_amount` reads `balance + released` fresh
/// on every call, the topped-up amount participates in vesting from the
/// schedule's original start — funds added mid-vest immediately count toward
/// the curve at the current proportion. The
/// `admin_tops_up_existing_grant_post_creation` scenario test demonstrates
/// this.
public fun top_up_grant<T>(
    program: &mut Program<T>,
    admin: &AdminCap,
    wallet: &mut VestingWallet<T>,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(admin.program_id == object::id(program), EWrongProgram);
    let coin = coin::from_balance(program.pool.split(amount), ctx);
    vesting_wallet::deposit(wallet, coin);
}

// === Accessors ===

public fun pool<T>(program: &Program<T>): u64 { program.pool.value() }

public fun program_id_of(admin: &AdminCap): ID { admin.program_id }
