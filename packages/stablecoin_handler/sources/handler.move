/*
 * Copyright (c) 2026, Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/// Module: handler
/// USDC handler for the CCTP V2 multi-token architecture. Registered with
/// token_messenger_minter_v2 and responsible for burning/minting USDC for
/// cross-chain transfers, proving its identity to TMM via the unforgeable
/// type-witness `Auth`.
///
/// The handler covers the two supported CCTP flows; inbound hooks
/// (destination-side composability) are intentionally out of scope.
/// * `Auth` witness + operational layer (state / roles / version_control /
///   migration / init_state) — implemented and tested.
/// * `burn` (send) — phase 2 of the burn: the handler burns the coin
///   with its own `MintCap<USDC>` and returns a
///   `CompleteBurnTicket<USDC, Auth>` for the client PTB to feed into
///   TMM V2's `complete_burn`. PTB-composed after TMM's
///   `deposit_for_burn`.
/// * `mint` (standard receive) — mints via the handler's own
///   `MintCap<USDC>` and returns a `CompleteMintTicket<USDC, Auth>` for
///   the PTB to feed into TMM V2's `complete_mint`.
module stablecoin_handler::handler {
    // === Imports ===
    use sui::{coin::Coin, deny_list::DenyList};
    use stablecoin::treasury::{Self, Treasury};
    use usdc::usdc::USDC;
    use token_messenger_minter_v2::{
        deposit_for_burn::{
            create_complete_burn_ticket,
            get_burn_details,
            BurnReceipt,
            CompleteBurnTicket,
        },
        handle_receive_message::{Self, MintReceipt, CompleteMintTicket},
        state::State as TokenMessengerState
    };
    use stablecoin_handler::{
        state::State,
        version_control::assert_object_version_is_compatible_with_package
    };

    // === Errors ===
    /// The handler's `MintCap<USDC>` has not been installed; call
    /// `mint_controller::add_mint_cap` first.
    const EMintCapNotSet: u64 = 0;
    /// The coin handed to `burn` does not match the
    /// `BurnReceipt` amount. TMM's `complete_burn` no longer checks this (it
    /// never sees the coin), so the handler enforces it: the amount encoded in
    /// the outbound message must equal what is actually burned.
    const EBurnAmountMismatch: u64 = 1;

    // === Structs ===

    /// Unforgeable handler-identity witness. Only this package can construct an
    /// `Auth` (the constructor is `public(package)`), so passing an `Auth`
    /// value to TMM proves the caller IS this handler package. TMM's
    /// `complete_burn<T, W>` / `complete_mint<T, W>` verify it via
    /// `handler_registry::assert_is_registered_handler<Auth>`, which derives a
    /// 32-byte identifier from the witness type — keccak256 of
    /// `std::type_name::with_original_ids<Auth>().into_string()` — and compares
    /// it to the identifier registered for USDC. This binds authorization to the
    /// exact type (package + module + type). `with_original_ids` pins to the
    /// publish-time package id, so an upgraded handler keeps authenticating
    /// without re-registration.
    ///
    /// (Note: `message_transmitter_v2::auth::auth_caller_identifier` is MT's
    /// separate caller-identity mechanism — same keccak256-of-type-name idea but
    /// keyed on `with_defining_ids` — not this registry check.)
    public struct Auth has drop {}

    // === Public-Package Functions ===

    /// Constructs the handler's identity witness. `public(package)` so no other
    /// package can forge it. Passed to TMM's `complete_burn` / `complete_mint`
    /// to prove this package is the registered USDC handler.
    public(package) fun new(): Auth {
        Auth {}
    }

    // === Send path ===

    /// Phase 2 of the source-side burn. Middle step in a 3-step PTB:
    ///   1. TMM `deposit_for_burn<USDC>` yields a `BurnReceipt<USDC>` + the
    ///      unchanged coin. Use the plain variant (NOT
    ///      `deposit_for_burn_with_package_auth`) so `message_sender` is
    ///      `ctx.sender()` (the user) and the CCTP denylist screens the real
    ///      depositor.
    ///   2. THIS function — burns the coin with the handler's own `MintCap<USDC>`
    ///      via `stablecoin::treasury::burn`, then returns a
    ///      `CompleteBurnTicket<USDC, Auth>`.
    ///   3. TMM `complete_burn<USDC, Auth>` consumes the ticket,
    ///      sends the MT message, and emits `DepositForBurn`.
    ///
    /// The handler emits no event of its own — TMM emits the canonical
    /// `DepositForBurn` in step 3. Pause lives in TMM; the handler gates its
    /// own package version here so a migration can disable this path in a
    /// deprecated package version.
    ///
    /// Amount integrity: TMM's `complete_burn` no longer sees the coin, so
    /// this function asserts `coin.value() == amount` from `get_burn_details`
    /// so the outbound message can only claim what is actually burned.
    ///
    /// Aborts if:
    /// - the handler `State` is not compatible with this package version
    /// - the handler's `MintCap` is not set (`EMintCapNotSet`)
    /// - the coin value != the receipt amount (`EBurnAmountMismatch`)
    /// - `treasury::burn` reverts (framework denylist / paused / allowance)
    /// Step 3's `complete_burn` aborts separately if the handler
    /// is not the registered `Auth` for USDC or MT rejects the send.
    public fun burn(
        handler_state: &State,
        burn_receipt: BurnReceipt<USDC>,
        coin: Coin<USDC>,
        deny_list: &DenyList,
        treasury: &mut Treasury<USDC>,
        ctx: &mut TxContext,
    ): CompleteBurnTicket<USDC, Auth> {
        assert_object_version_is_compatible_with_package(handler_state.compatible_versions());
        assert!(handler_state.mint_cap_is_set(), EMintCapNotSet);

        // The burned amount must equal the amount the outbound message will
        // encode (TMM no longer verifies this — see `get_burn_details`).
        // `_burn_token` is ignored: the phantom `T` on `BurnReceipt<USDC>` +
        // `Coin<USDC>` already type-lock this to USDC, so no runtime token
        // check is needed (mirrors `mint`).
        let (_burn_token, amount, _mint_recipient) = get_burn_details(&burn_receipt);
        assert!(coin.value() == amount, EBurnAmountMismatch);

        // Burn via the handler's MintCap, then return the ticket for the PTB
        // to consume via `complete_burn`.
        treasury::burn(treasury, handler_state.mint_cap(), deny_list, coin, ctx);
        create_complete_burn_ticket<USDC, Auth>(burn_receipt, new())
    }

    // === Receive path ===

    /// Destination-side standard mint. Middle step in a 3-step PTB:
    ///   1. TMM `prepare_mint<USDC>` (on the MT `Receipt` returned from
    ///      `receive_message`) yields a `MintReceipt<USDC>`.
    ///   2. THIS function — mints `amount` USDC to `mint_recipient` and any
    ///      `fee` to the TMM-configured `fee_recipient` via the handler's own
    ///      `MintCap<USDC>`, then returns a `CompleteMintTicket<USDC, Auth>`.
    ///   3. TMM `complete_mint<USDC, Auth>` consumes the ticket,
    ///      emits `MintAndWithdraw`, and finalizes the MT receipt.
    ///
    /// The receipt's local token is guaranteed to be USDC by the phantom `T` on
    /// `MintReceipt<USDC>` (only `prepare_mint<USDC>` can produce it), so no
    /// runtime token check is needed here.
    ///
    /// Note on `tmm_state`: borrowed here only for the plain
    /// `state.fee_recipient()` accessor (not a version-gated call). Reading a
    /// state value from a TMM V2 that is incompatible with this handler is
    /// safe end-to-end: step 3's `complete_mint` version-gates on
    /// the same `tmm_state`, so an incompatible one aborts step 3 and reverts
    /// the whole PTB atomically — the mint from step 2 never becomes durable.
    ///
    /// Aborts if:
    /// - the handler `State` is not compatible with this package version
    /// - the handler's `MintCap` is not set (`EMintCapNotSet`)
    /// - `treasury::mint` reverts (framework denylist / paused / allowance)
    /// Step 3's `complete_mint` aborts separately if the handler
    /// is not the registered `Auth` for USDC or MT rejects the stamp/complete.
    public fun mint(
        handler_state: &State,
        mint_receipt: MintReceipt<USDC>,
        tmm_state: &TokenMessengerState,
        treasury: &mut Treasury<USDC>,
        deny_list: &DenyList,
        ctx: &mut TxContext,
    ): CompleteMintTicket<USDC, Auth> {
        assert_object_version_is_compatible_with_package(handler_state.compatible_versions());
        assert!(handler_state.mint_cap_is_set(), EMintCapNotSet);

        let (_local_token, mint_recipient, amount, fee) =
            handle_receive_message::get_mint_details(&mint_receipt);

        // Handler-held mint authority (see state::mint_cap). `amount` is the net
        // (gross - fee) and is guaranteed >= 1 by TMM's prepare_mint fee check.
        let mint_cap = handler_state.mint_cap();
        treasury::mint(treasury, mint_cap, deny_list, amount, mint_recipient, ctx);
        if (fee > 0) {
            treasury::mint(treasury, mint_cap, deny_list, fee, tmm_state.fee_recipient(), ctx);
        };

        // Ticket for the PTB to consume via `complete_mint`.
        handle_receive_message::create_complete_mint_ticket<USDC, Auth>(mint_receipt, new())
    }
}

#[test_only]
module stablecoin_handler::handler_tests {
    use sui::{
        address,
        clock,
        coin::Coin,
        coin_registry,
        deny_list::{Self, DenyList},
        event::num_events,
        test_scenario::{Self, Scenario},
        test_utils,
    };
    use std::type_name;
    use std::unit_test::{Self};
    use stablecoin::treasury::{Self, Treasury, MintCap};
    use usdc::usdc::USDC;
    use message_transmitter_v2::{
        auth::auth_caller_identifier,
        receive_message::{Self, Receipt},
        state as message_transmitter_state,
    };
    use token_messenger_minter_v2::{
        burn_message,
        deposit_for_burn,
        handle_receive_message::{Self, MintAndWithdraw, create_mint_and_withdraw_event},
        handler_registry,
        message_transmitter_authenticator::MessageTransmitterAuthenticator,
        state::{Self as token_messenger_state},
        token_utils::calculate_token_id,
    };
    use sui_extensions::test_utils::last_event_by_type;
    use stablecoin_handler::{
        handler::{Self, Auth},
        mint_controller::{Self, MintCapAdded, MintCapRemoved, create_mint_cap_added_event, create_mint_cap_removed_event},
        role_management,
        state,
        version_control,
    };

    const AMOUNT: u256 = 100;
    const ADMIN: address = @0xAD;
    const USER: address = @0xA1;
    const DESTINATION_DOMAIN: u32 = 2;
    const MINT_RECIPIENT: address = @0xB2;
    const REMOTE_TOKEN_MESSENGER: address = @0xD4;
    // Receive-path constants
    const REMOTE_DOMAIN: u32 = 4;
    const REMOTE_BURN_TOKEN: address = @0xcafe;
    const FEE_RECIPIENT: address = @0xFEE;
    const FINALITY_FINALIZED: u32 = 2000;

    // === Auth witness ===

    #[test]
    /// Sanity check on the `Auth` witness: it is constructible within this
    /// package, and its type resolves (via original, publish-time ids) to
    /// `@stablecoin_handler` — the package that registers as the USDC handler.
    /// The registry authorizes on the keccak256 of `Auth`'s fully-qualified type
    /// name (not the bare package address); that full type-scoped check runs
    /// end-to-end in the burn / mint tests, which register the `Auth` handler and
    /// pass `Auth`. Cross-package non-construction of `Auth` is a COMPILE-time
    /// guarantee of the `public(package)` constructor, not a runtime `#[test]`.
    fun test_auth_witness() {
        // Constructible within the package.
        let _auth = handler::new();

        // `Auth`'s type resolves (by original id) to this package — where the
        // handler registers.
        let handler_package = address::from_ascii_bytes(
            type_name::with_original_ids<Auth>().address_string().as_bytes()
        );
        assert!(handler_package == @stablecoin_handler);
    }

    // === Send path ===

    #[test]
    /// Happy path: a user bridges USDC out. Exercises the client PTB shape —
    /// TMM `deposit_for_burn` (phase 1) then `handler::burn` (phase 2, produces
    /// a `CompleteBurnTicket`) then TMM `complete_burn` (phase 3) —
    /// and asserts the canonical `DepositForBurn` is emitted with the USER as
    /// depositor (confirming the plain `ctx.sender()` send path) and that the
    /// handler emits no event of its own (event count is exactly TMM's three).
    fun test_burn_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_states(&mut scenario);

        scenario.next_tx(USER);
        {
            let coin = scenario.take_from_sender<Coin<USDC>>();
            // Phase 1: client calls TMM directly.
            let (burn_receipt, coin) = deposit_for_burn::deposit_for_burn<USDC>(
                coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
                &tmm_state, scenario.ctx(),
            );
            // Phase 2: handler burns the coin and returns a
            // `CompleteBurnTicket<USDC, Auth>` (no TMM version gate crossed).
            let complete_burn_ticket = handler::burn(
                &handler_state, burn_receipt, coin,
                &deny_list, &mut treasury, scenario.ctx(),
            );
            // Phase 3: client PTB feeds the ticket into TMM's version-gated
            // consumer against the latest TMM V2 package id. Same effective
            // semantics as the pre-ticket `handler::burn` that called
            // `complete_burn` inline.
            deposit_for_burn::complete_burn<USDC, Auth>(
                complete_burn_ticket, &tmm_state, &mt_state,
            );

            // message_sent (MT) + burn (treasury) + DepositForBurn (TMM). The
            // handler emits none of its own, so exactly 3.
            assert!(num_events() == 3);
            assert!(
                last_event_by_type<deposit_for_burn::DepositForBurn>() ==
                    deposit_for_burn::create_deposit_for_burn_event(
                        calculate_token_id<USDC>(), AMOUNT, USER, MINT_RECIPIENT,
                        DESTINATION_DOMAIN, REMOTE_TOKEN_MESSENGER, @0x0, 0, 0, x""
                    )
            );
        };

        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        unit_test::destroy(handler_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    /// The send path's phase 2 gates on the handler's own package version, so a
    /// migration can disable it in a deprecated version.
    fun test_burn_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_states(&mut scenario);

        handler_state.add_compatible_version(5);
        handler_state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(USER);
        let coin = scenario.take_from_sender<Coin<USDC>>();
        let (burn_receipt, coin) = deposit_for_burn::deposit_for_burn<USDC>(
            coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
            &tmm_state, scenario.ctx(),
        );
        // handler::burn now returns a hot-potato `CompleteBurnTicket` — but the
        // assertion above aborts before construction, so the ticket is never
        // materialized. Type-check still requires we consume it, so wire it into
        // the ticket consumer (unreachable at runtime for this test).
        let ticket = handler::burn(
            &handler_state, burn_receipt, coin,
            &deny_list, &mut treasury, scenario.ctx(),
        );
        deposit_for_burn::complete_burn<USDC, Auth>(ticket, &tmm_state, &mt_state);

        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        unit_test::destroy(handler_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handler::EMintCapNotSet)]
    /// The burn path aborts with a descriptive error if the handler's `MintCap`
    /// was never installed (it needs the cap to burn).
    fun test_burn_revert_mint_cap_not_set() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (tmm_state, mt_state) = setup_cctp_states(&mut scenario);

        // Handler State with no cap installed.
        let handler_state = state::new(ADMIN, scenario.ctx());

        scenario.next_tx(USER);
        let coin = scenario.take_from_sender<Coin<USDC>>();
        let (burn_receipt, coin) = deposit_for_burn::deposit_for_burn<USDC>(
            coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
            &tmm_state, scenario.ctx(),
        );
        let ticket = handler::burn(
            &handler_state, burn_receipt, coin,
            &deny_list, &mut treasury, scenario.ctx(),
        );
        deposit_for_burn::complete_burn<USDC, Auth>(ticket, &tmm_state, &mt_state);

        unit_test::destroy(mint_cap);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        unit_test::destroy(handler_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handler::EBurnAmountMismatch)]
    /// The burn path aborts if the coin value != the receipt amount, so the
    /// outbound message can't claim more than was burned. (TMM's `complete_burn`
    /// no longer checks this; the handler does.)
    fun test_burn_revert_amount_mismatch() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_states(&mut scenario);

        scenario.next_tx(USER);
        let coin = scenario.take_from_sender<Coin<USDC>>();
        // Receipt is for the full AMOUNT, but we hand phase 2 a smaller coin.
        let (burn_receipt, mut coin) = deposit_for_burn::deposit_for_burn<USDC>(
            coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
            &tmm_state, scenario.ctx(),
        );
        let short_coin = coin.split(1, scenario.ctx());
        let ticket = handler::burn(
            &handler_state, burn_receipt, short_coin,
            &deny_list, &mut treasury, scenario.ctx(),
        );
        deposit_for_burn::complete_burn<USDC, Auth>(ticket, &tmm_state, &mt_state);

        unit_test::destroy(coin);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        unit_test::destroy(handler_state);
        scenario.end();
    }

    // === Test helpers ===

    /// Stands up a `Treasury<USDC>` + `MintCap<USDC>` and mints `AMOUNT` USDC to
    /// USER. Mirrors the burn-side `setup_coin`, typed to the real `usdc::USDC`
    /// (a public `has drop` OTW, fabricated via `create_one_time_witness`).
    fun setup_coin(scenario: &mut Scenario): (MintCap<USDC>, Treasury<USDC>, DenyList) {
        let otw = test_utils::create_one_time_witness<USDC>();
        let (mut init, treasury_cap) = coin_registry::new_currency_with_otw(
            otw, 6, b"USDC".to_string(), b"USDC".to_string(),
            b"".to_string(), b"".to_string(), scenario.ctx()
        );
        let deny_cap = coin_registry::make_regulated(&mut init, true, scenario.ctx());
        let metadata_cap = coin_registry::finalize(init, scenario.ctx());

        let mut treasury = treasury::new(
            treasury_cap, deny_cap,
            scenario.ctx().sender(), scenario.ctx().sender(),
            scenario.ctx().sender(), scenario.ctx().sender(),
            scenario.ctx().sender(), scenario.ctx()
        );
        treasury.configure_new_controller(ADMIN, ADMIN, scenario.ctx());
        scenario.next_tx(ADMIN);
        let mint_cap = scenario.take_from_address<MintCap<USDC>>(ADMIN);
        let deny_list = deny_list::new_for_testing(scenario.ctx());
        treasury.configure_minter(&deny_list, 999999999, scenario.ctx());
        unit_test::destroy(metadata_cap);

        treasury::mint(&mut treasury, &mint_cap, &deny_list, AMOUNT as u64, USER, scenario.ctx());

        (mint_cap, treasury, deny_list)
    }

    /// Builds configured TMM + MT test states: remote messenger, burn limit,
    /// and registers THIS package's `Auth` witness as the USDC handler. TMM no
    /// longer stores a `MintCap` (the handler owns burn authority post-
    /// decoupling). The registry keys on the witness-type identifier (keccak256
    /// of the fully-qualified type name), so we register
    /// `handler_identifier_for_testing<Auth>()` so the witness check in
    /// `complete_burn<USDC, Auth>` / `complete_mint<USDC, Auth>` passes.
    fun setup_cctp_states(
        scenario: &mut Scenario
    ): (token_messenger_state::State, message_transmitter_state::State) {
        let ctx = test_scenario::ctx(scenario);
        let mut tmm_state = token_messenger_state::new_for_testing(1, ADMIN, ctx);
        let mt_state = message_transmitter_state::new_for_testing(0, 1, 1000, ADMIN, ctx);

        tmm_state.add_remote_token_messenger_for_testing(DESTINATION_DOMAIN, REMOTE_TOKEN_MESSENGER);
        tmm_state.add_burn_limit_for_testing(calculate_token_id<USDC>(), 1000000);
        tmm_state.set_handler_for_testing(
            calculate_token_id<USDC>(),
            handler_registry::handler_identifier_for_testing<Auth>(),
        );

        (tmm_state, mt_state)
    }

    // === add_mint_cap tests ===

    #[test]
    fun test_add_mint_cap_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);

        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());
        assert!(!handler_state.mint_cap_is_set());

        let mint_cap_id = object::id(&mint_cap);
        mint_controller::add_mint_cap(mint_cap, &mut handler_state, scenario.ctx());
        assert!(handler_state.mint_cap_is_set());
        assert!(num_events() == 1);
        assert!(last_event_by_type<MintCapAdded>() == create_mint_cap_added_event(mint_cap_id));

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    /// Privilege separation: after the owner rotates `mint_controller` to a
    /// distinct address, THAT address (not the owner) is the one authorized to
    /// add the cap — proving mint-cap auth is keyed on `mint_controller`, not
    /// `owner`.
    fun test_add_mint_cap_by_rotated_mint_controller() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);

        // owner == mint_controller == ADMIN at init; owner rotates the role to USER.
        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());
        role_management::update_mint_controller(USER, &mut handler_state, scenario.ctx());

        // USER (now mint_controller, and not the owner) installs the cap.
        scenario.next_tx(USER);
        mint_controller::add_mint_cap(mint_cap, &mut handler_state, scenario.ctx());
        assert!(handler_state.mint_cap_is_set());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    // === remove_mint_cap tests ===

    #[test]
    /// De-authorize the cap on the treasury, then the owner removes it from
    /// `State`; the cap is returned to the owner and `MintCapRemoved` is emitted.
    fun test_remove_mint_cap_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let mint_cap_id = object::id(&mint_cap);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);

        // De-authorize the minter (controller == ADMIN) so removal is allowed.
        scenario.next_tx(ADMIN);
        treasury.remove_minter(scenario.ctx());

        scenario.next_tx(ADMIN);
        mint_controller::remove_mint_cap(&mut handler_state, &treasury, scenario.ctx());
        assert!(!handler_state.mint_cap_is_set());
        assert!(last_event_by_type<MintCapRemoved>() == create_mint_cap_removed_event(mint_cap_id));

        // Cap returned to the owner.
        scenario.next_tx(ADMIN);
        let returned = scenario.take_from_address<MintCap<USDC>>(ADMIN);
        assert!(object::id(&returned) == mint_cap_id);

        unit_test::destroy(returned);
        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = mint_controller::ENotMintController)]
    fun test_remove_mint_cap_revert_not_mint_controller() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);

        scenario.next_tx(ADMIN);
        treasury.remove_minter(scenario.ctx());

        // Non-owner attempts removal.
        scenario.next_tx(USER);
        mint_controller::remove_mint_cap(&mut handler_state, &treasury, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = mint_controller::EMintCapNotSet)]
    fun test_remove_mint_cap_revert_not_set() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);

        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());

        // No cap ever installed.
        mint_controller::remove_mint_cap(&mut handler_state, &treasury, scenario.ctx());

        unit_test::destroy(mint_cap);
        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = mint_controller::EMintCapNotDeAuthorized)]
    fun test_remove_mint_cap_revert_not_de_authorized() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);

        // Cap is still authorized on the treasury (no remove_minter call).
        scenario.next_tx(ADMIN);
        mint_controller::remove_mint_cap(&mut handler_state, &treasury, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_remove_mint_cap_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);

        handler_state.add_compatible_version(5);
        handler_state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(ADMIN);
        mint_controller::remove_mint_cap(&mut handler_state, &treasury, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = mint_controller::ENotMintController)]
    fun test_add_mint_cap_revert_not_mint_controller() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);

        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());

        // Non-owner attempts to add the cap.
        scenario.next_tx(USER);
        mint_controller::add_mint_cap(mint_cap, &mut handler_state, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = mint_controller::EMintCapAlreadySet)]
    fun test_add_mint_cap_revert_already_set() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (cap1, mut treasury, deny_list) = setup_coin(&mut scenario);

        // Configure a second controller/minter to obtain a second MintCap.
        scenario.next_tx(ADMIN);
        treasury.configure_new_controller(@0xC2, ADMIN, scenario.ctx());
        scenario.next_tx(ADMIN);
        let cap2 = scenario.take_from_address<MintCap<USDC>>(ADMIN);

        let mut handler_state = state::new(ADMIN, scenario.ctx());
        mint_controller::add_mint_cap(cap1, &mut handler_state, scenario.ctx());
        // Second add must abort.
        mint_controller::add_mint_cap(cap2, &mut handler_state, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_add_mint_cap_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);

        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());
        handler_state.add_compatible_version(5);
        handler_state.remove_compatible_version(version_control::current_version());

        mint_controller::add_mint_cap(mint_cap, &mut handler_state, scenario.ctx());

        unit_test::destroy(handler_state);
        unit_test::destroy(treasury);
        unit_test::destroy(deny_list);
        scenario.end();
    }

    // === mint tests ===

    #[test]
    /// Standard receive (no fee): the handler mints the net amount to
    /// `mint_recipient` via its own MintCap, then returns a
    /// `CompleteMintTicket` for the PTB to feed into
    /// `complete_mint`, which emits `MintAndWithdraw` and finalizes
    /// the MT receipt. Three events: handler `Mint`, TMM `MintAndWithdraw`,
    /// MT `MessageReceived`.
    fun test_mint_no_fee_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_for_receive(&mut scenario);

        scenario.next_tx(USER);
        {
            let test_clock = clock::create_for_testing(scenario.ctx());
            let receipt = make_receipt(AMOUNT, 0, 0);
            let mint_receipt = handle_receive_message::prepare_mint<USDC>(
                receipt, &tmm_state, &test_clock,
            );
            let complete_mint_ticket = handler::mint(
                &handler_state, mint_receipt, &tmm_state,
                &mut treasury, &deny_list, scenario.ctx(),
            );
            handle_receive_message::complete_mint<USDC, Auth>(
                complete_mint_ticket, &tmm_state, &mt_state,
            );

            assert!(num_events() == 3);
            assert!(
                last_event_by_type<MintAndWithdraw>() ==
                    create_mint_and_withdraw_event(MINT_RECIPIENT, AMOUNT as u64, calculate_token_id<USDC>(), 0)
            );
            clock::destroy_for_testing(test_clock);
        };

        // Net amount delivered to the recipient.
        scenario.next_tx(MINT_RECIPIENT);
        {
            let c = scenario.take_from_address<Coin<USDC>>(MINT_RECIPIENT);
            assert!(c.value() == AMOUNT as u64);
            unit_test::destroy(c);
        };

        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(handler_state);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        scenario.end();
    }

    #[test]
    /// Receive with a fee: net (gross - fee) goes to `mint_recipient`, fee goes
    /// to the TMM-configured `fee_recipient`. Two `Mint` events + MintAndWithdraw
    /// + MessageReceived = 4.
    fun test_mint_with_fee_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_for_receive(&mut scenario);

        let gross: u256 = 100;
        let fee: u256 = 10;
        let net = (gross - fee) as u64;

        scenario.next_tx(USER);
        {
            let test_clock = clock::create_for_testing(scenario.ctx());
            let receipt = make_receipt(gross, fee, fee);
            let mint_receipt = handle_receive_message::prepare_mint<USDC>(
                receipt, &tmm_state, &test_clock,
            );
            let complete_mint_ticket = handler::mint(
                &handler_state, mint_receipt, &tmm_state,
                &mut treasury, &deny_list, scenario.ctx(),
            );
            handle_receive_message::complete_mint<USDC, Auth>(
                complete_mint_ticket, &tmm_state, &mt_state,
            );

            // 2 Mint (net + fee) + MintAndWithdraw + MessageReceived.
            assert!(num_events() == 4);
            assert!(
                last_event_by_type<MintAndWithdraw>() ==
                    create_mint_and_withdraw_event(MINT_RECIPIENT, net, calculate_token_id<USDC>(), fee as u64)
            );
            clock::destroy_for_testing(test_clock);
        };

        scenario.next_tx(MINT_RECIPIENT);
        {
            let c = scenario.take_from_address<Coin<USDC>>(MINT_RECIPIENT);
            assert!(c.value() == net);
            unit_test::destroy(c);
        };
        scenario.next_tx(FEE_RECIPIENT);
        {
            let c = scenario.take_from_address<Coin<USDC>>(FEE_RECIPIENT);
            assert!(c.value() == fee as u64);
            unit_test::destroy(c);
        };

        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(handler_state);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    /// The receive path gates on the handler's own package version before
    /// borrowing the MintCap, so a migration can disable it in a deprecated
    /// version.
    fun test_mint_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let mut handler_state = setup_handler_with_cap(mint_cap, &mut scenario);
        let (tmm_state, mt_state) = setup_cctp_for_receive(&mut scenario);

        handler_state.add_compatible_version(5);
        handler_state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(USER);
        let test_clock = clock::create_for_testing(scenario.ctx());
        let receipt = make_receipt(AMOUNT, 0, 0);
        let mint_receipt = handle_receive_message::prepare_mint<USDC>(
            receipt, &tmm_state, &test_clock,
        );
        // Assertion inside `handler::mint` aborts before ticket construction;
        // the type-checker still needs the ticket consumed.
        let ticket = handler::mint(
            &handler_state, mint_receipt, &tmm_state,
            &mut treasury, &deny_list, scenario.ctx(),
        );
        handle_receive_message::complete_mint<USDC, Auth>(
            ticket, &tmm_state, &mt_state,
        );

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(handler_state);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handler::EMintCapNotSet)]
    /// `mint` aborts with a descriptive error (not a raw option
    /// borrow) when the handler's `MintCap` was never installed.
    fun test_mint_revert_mint_cap_not_set() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (tmm_state, mt_state) = setup_cctp_for_receive(&mut scenario);

        // Handler State with no cap installed.
        let handler_state = state::new(ADMIN, scenario.ctx());

        scenario.next_tx(USER);
        let test_clock = clock::create_for_testing(scenario.ctx());
        let receipt = make_receipt(AMOUNT, 0, 0);
        let mint_receipt = handle_receive_message::prepare_mint<USDC>(
            receipt, &tmm_state, &test_clock,
        );
        let ticket = handler::mint(
            &handler_state, mint_receipt, &tmm_state,
            &mut treasury, &deny_list, scenario.ctx(),
        );
        handle_receive_message::complete_mint<USDC, Auth>(
            ticket, &tmm_state, &mt_state,
        );

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(mint_cap);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(handler_state);
        unit_test::destroy(tmm_state);
        unit_test::destroy(mt_state);
        scenario.end();
    }

    // === Receive-path helpers ===

    /// Creates a handler `State` owned by ADMIN with the given `MintCap` installed.
    fun setup_handler_with_cap(mint_cap: MintCap<USDC>, scenario: &mut Scenario): state::State {
        scenario.next_tx(ADMIN);
        let mut handler_state = state::new(ADMIN, scenario.ctx());
        mint_controller::add_mint_cap(mint_cap, &mut handler_state, scenario.ctx());
        handler_state
    }

    /// Configures TMM + MT state for a USDC receive from `REMOTE_DOMAIN`:
    /// remote messenger, remote->local token link, handler registration, and
    /// fee recipient.
    fun setup_cctp_for_receive(
        scenario: &mut Scenario
    ): (token_messenger_state::State, message_transmitter_state::State) {
        let ctx = test_scenario::ctx(scenario);
        let mut tmm_state = token_messenger_state::new_for_testing(1, ADMIN, ctx);
        let mt_state = message_transmitter_state::new_for_testing(0, 1, 1000, ADMIN, ctx);

        tmm_state.add_remote_token_messenger_for_testing(REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER);
        tmm_state.add_local_token_for_remote_token_for_testing(REMOTE_DOMAIN, REMOTE_BURN_TOKEN, calculate_token_id<USDC>());
        tmm_state.set_handler_for_testing(
            calculate_token_id<USDC>(),
            handler_registry::handler_identifier_for_testing<Auth>(),
        );
        tmm_state.set_fee_recipient_for_testing(FEE_RECIPIENT);

        (tmm_state, mt_state)
    }

    /// Builds a destination-side `Receipt` for a USDC burn message with the
    /// given gross amount / max_fee / fee_executed. Recipient is set to TMM's
    /// authenticator id so `complete_mint`'s `stamp_receipt` check passes.
    fun make_receipt(gross: u256, max_fee: u256, fee_executed: u256): Receipt {
        let body = burn_message::build_raw_message_for_testing(
            1, REMOTE_BURN_TOKEN, MINT_RECIPIENT, gross, @0x1, max_fee, fee_executed, 0, x"",
        );
        receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            99,
            FINALITY_FINALIZED,
            body,
            1,
        )
    }
}
