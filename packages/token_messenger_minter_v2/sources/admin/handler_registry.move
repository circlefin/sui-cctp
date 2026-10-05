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

/// Module: handler_registry
/// Owner-managed registry mapping each token to its authorized handler,
/// identified by the handler's witness type. Consulted by `complete_mint` /
/// `complete_burn` (via `assert_is_registered_handler`) to authorize the
/// caller by its witness type.
///
/// The stored value is a 32-byte identifier: the keccak256 of the
/// handler witness type's fully-qualified name (using original,
/// publish-time package ids). Handler packages authenticate by passing
/// an instance of a drop-able witness they define; TMM derives the same
/// identifier from that witness type and compares to the registered
/// value. This binds authorization to the exact witness type (package +
/// module + type), not merely its defining package. Registration takes
/// the witness type as a type argument. Sui-idiomatic equivalent of
/// Aptos's `signer::address_of` on a resource account.
module token_messenger_minter_v2::handler_registry {
    // === Imports ===
    use std::type_name;
    use sui::{
        address,
        event::emit,
        hash,
    };
    use token_messenger_minter_v2::{
        state::State,
        version_control::assert_object_version_is_compatible_with_package
    };

    // === Errors ===
    const ENoHandlerRegistered: u64 = 0;
    const ENotRegisteredHandler: u64 = 1;
    const EInvalidTokenAddress: u64 = 2;
    const EInvalidWitness: u64 = 3;

    // === Events ===
    public struct HandlerRegistered has copy, drop {
        token_address: address,
        handler_address: address,
    }

    public struct HandlerDeregistered has copy, drop {
        token_address: address,
        handler_address: address,
    }

    // === Admin functions ===

    /// Owner-only, upsert. The authorized handler is identified by its witness
    /// type `W`, supplied as a type argument (e.g.
    /// `<handler_pkg>::handler::Auth`). Stores and emits `handler_identifier<W>()`
    /// (the type-identifier hash), the same value compared during authorization
    /// and reported by `HandlerDeregistered`.
    entry fun register_handler<W: drop>(
        state: &mut State,
        token_address: address,
        ctx: &TxContext,
    ) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.roles().owner_role().assert_sender_is_active_role(ctx);
        assert!(token_address != @0x0, EInvalidTokenAddress);

        let handler_id = handler_identifier<W>();
        state.set_handler(token_address, handler_id);
        emit(HandlerRegistered { token_address, handler_address: handler_id });
    }

    /// Owner-only, emergency. Aborts if no handler is registered.
    /// `HandlerDeregistered.handler_address` carries the stored handler
    /// identifier (the witness-type hash), matching `HandlerRegistered`.
    entry fun deregister_handler(
        state: &mut State,
        token_address: address,
        ctx: &TxContext,
    ) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.roles().owner_role().assert_sender_is_active_role(ctx);
        assert!(token_address != @0x0, EInvalidTokenAddress);
        assert!(state.handler_for_token_id_exists(token_address), ENoHandlerRegistered);

        let handler_address = state.remove_handler(token_address);
        emit(HandlerDeregistered { token_address, handler_address });
    }

    // === Public authorization helper ===

    /// Aborts unless the witness type `W` is exactly the registered handler
    /// for `token_id` — i.e. `handler_identifier<W>()` equals the stored
    /// identifier. Called by `handle_receive_message::complete_mint` and
    /// `deposit_for_burn::complete_burn`.
    ///
    /// Only the defining package can construct `W`, and the identifier pins the
    /// full type (package + module + type), so an unrelated `drop` type from the
    /// same package is rejected. Uses `type_name::with_original_ids` so upgraded
    /// handler packages keep authenticating without re-registration.
    ///
    /// ```move
    /// // in <handler_pkg>::handler
    /// public struct HandlerAuth has drop {}
    ///
    /// public fun mint(receipt: MintReceipt<T>, /* ... */) {
    ///     // ... handler mints the coin to the recipient here ...
    ///     token_messenger_minter_v2::handle_receive_message::complete_mint<T, HandlerAuth>(
    ///         receipt, HandlerAuth {}, state, message_transmitter_state,
    ///     );
    /// }
    /// ```
    public(package) fun assert_is_registered_handler<W: drop>(
        state: &State,
        token_id: address,
        _witness: W,
    ) {
        assert!(state.handler_for_token_id_exists(token_id), ENoHandlerRegistered);
        assert!(handler_identifier<W>() == state.handler(token_id), ENotRegisteredHandler);
    }

    // === Internal helpers ===

    /// Canonical 32-byte identifier for a handler witness type `W`: the keccak256
    /// of its fully-qualified type name rendered with original (publish-time)
    /// package ids. Using original ids keeps the identifier stable across handler
    /// package upgrades. Binds authorization to the exact type (package + module +
    /// type), not just the defining package. Aborts on a primitive `W`.
    fun handler_identifier<W: drop>(): address {
        let ty = type_name::with_original_ids<W>();
        assert!(!ty.is_primitive(), EInvalidWitness);
        address::from_bytes(hash::keccak256(ty.into_string().as_bytes()))
    }

    // === Test Functions ===
    #[test_only] use sui::{
        event::num_events,
        test_scenario::{Self, Scenario},
    };
    #[test_only] use std::unit_test::{Self, assert_eq};
    #[test_only] use sui_extensions::{
        test_utils::last_event_by_type,
        two_step_role,
    };
    #[test_only] use token_messenger_minter_v2::{
        state::{Self},
        version_control,
    };

    #[test_only] const OWNER: address = @0x111;
    #[test_only] const RANDOM: address = @0x444;
    #[test_only] const TOKEN: address = @0x555;
    #[test_only] const OTHER_TOKEN: address = @0x666;

    /// Two distinct `drop` witnesses defined in the SAME package. Authorization
    /// must bind to the exact type, so registering one must NOT authorize the
    /// other. Used to exercise `assert_is_registered_handler`.
    #[test_only]
    public struct HandlerWitness has drop {}
    #[test_only]
    public struct OtherWitness has drop {}

    #[test_only]
    fun setup(): (Scenario, State) {
        let mut scenario = test_scenario::begin(@0x0);
        let state = state::new(0, OWNER, scenario.ctx());
        (scenario, state)
    }

    /// Test-only accessor for the internal handler identifier, so other test
    /// modules in this package can compute the value stored by `register_handler`.
    #[test_only]
    public fun handler_identifier_for_testing<W: drop>(): address {
        handler_identifier<W>()
    }

    // === handler_identifier tests ===

    #[test]
    fun test_handler_identifier_pins_expected_value() {
        // Pins the exact keccak256(with_original_ids type string) form. If this
        // ever breaks, the type-name / original-id rendering changed — investigate
        // before trusting the auth check. (Mirrors auth_tests.move.)
        // Pre-hash string: <HANDLER_PKG 64-hex>::handler_registry::HandlerWitness
        let expected = @0xb0e398a60aa977c00f83f3bf29720d5d96991b5a5f7280b2d16de6235a5e68b5;
        assert_eq!(handler_identifier<HandlerWitness>(), expected);
    }

    #[test]
    fun test_handler_identifier_distinct_per_type() {
        // Distinct types in the same package must hash to distinct identifiers;
        // this is what makes authorization type-scoped rather than package-scoped.
        assert!(handler_identifier<HandlerWitness>() != handler_identifier<OtherWitness>());
    }

    // === register_handler tests ===

    #[test]
    fun test_register_handler_successful() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());
        assert!(state.handler_for_token_id_exists(TOKEN));
        assert!(state.handler(TOKEN) == handler_identifier<HandlerWitness>());
        assert!(num_events() == 1);
        let event = last_event_by_type<HandlerRegistered>();
        // The event carries the stored handler identifier (the witness-type hash).
        assert!(event.token_address == TOKEN && event.handler_address == handler_identifier<HandlerWitness>());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_register_handler_upsert_overwrites_existing() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());
        assert!(state.handler(TOKEN) == handler_identifier<HandlerWitness>());

        // Re-register the same token with a different witness type; overwrites.
        scenario.next_tx(OWNER);
        register_handler<OtherWitness>(&mut state, TOKEN, scenario.ctx());
        assert!(state.handler(TOKEN) == handler_identifier<OtherWitness>());
        let event = last_event_by_type<HandlerRegistered>();
        assert!(event.token_address == TOKEN && event.handler_address == handler_identifier<OtherWitness>());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_register_handler_multiple_tokens() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());
        register_handler<OtherWitness>(&mut state, OTHER_TOKEN, scenario.ctx());
        assert!(state.handler(TOKEN) == handler_identifier<HandlerWitness>());
        assert!(state.handler(OTHER_TOKEN) == handler_identifier<OtherWitness>());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    fun test_register_handler_revert_not_owner() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(RANDOM);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidTokenAddress)]
    fun test_register_handler_revert_zero_token() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, @0x0, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_register_handler_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === deregister_handler tests ===

    #[test]
    fun test_deregister_handler_successful() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());
        assert!(state.handler_for_token_id_exists(TOKEN));

        scenario.next_tx(OWNER);
        deregister_handler(&mut state, TOKEN, scenario.ctx());
        assert!(!state.handler_for_token_id_exists(TOKEN));
        let event = last_event_by_type<HandlerDeregistered>();
        // Deregistration reports the stored identifier (the witness-type hash).
        assert!(event.token_address == TOKEN
            && event.handler_address == handler_identifier<HandlerWitness>());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    fun test_deregister_handler_revert_not_owner() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        scenario.next_tx(RANDOM);
        deregister_handler(&mut state, TOKEN, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENoHandlerRegistered)]
    fun test_deregister_handler_revert_not_registered() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        deregister_handler(&mut state, TOKEN, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidTokenAddress)]
    fun test_deregister_handler_revert_zero_token() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        deregister_handler(&mut state, @0x0, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_deregister_handler_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        deregister_handler(&mut state, TOKEN, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === assert_is_registered_handler tests ===

    #[test]
    fun test_assert_is_registered_handler_successful() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        assert_is_registered_handler(&state, TOKEN, HandlerWitness {});

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENoHandlerRegistered)]
    fun test_assert_is_registered_handler_revert_not_registered() {
        let (scenario, state) = setup();

        // No handler registered for TOKEN.
        assert_is_registered_handler(&state, TOKEN, HandlerWitness {});

        unit_test::destroy(state);
        scenario.end();
    }

    /// Authorization is scoped to the exact witness type, not just its package.
    /// A different `drop` type from the SAME package as the registered witness
    /// must be rejected.
    #[test]
    #[expected_failure(abort_code = ENotRegisteredHandler)]
    fun test_assert_is_registered_handler_revert_wrong_type_same_package() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        register_handler<HandlerWitness>(&mut state, TOKEN, scenario.ctx());

        // OtherWitness shares HandlerWitness's package but is a different type.
        assert_is_registered_handler(&state, TOKEN, OtherWitness {});

        unit_test::destroy(state);
        scenario.end();
    }
}
