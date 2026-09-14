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

/// Module: state
/// This module contains the core global Shared State used in the message_transmitter package.
module message_transmitter_v2::state {
    // === Imports ===
    use sui::{
        coin::Coin,
        table::{Self, Table},
        transfer::Receiving,
        vec_set::{Self, VecSet},
    };
    use message_transmitter_v2::{
        roles::{Self, Roles},
        version_control
    };
    use cctp_extensions::rescuable::{Self, Rescuable};

    // === Structs ===
    public struct State has key {
        id: UID,
        /// Immutable local domain
        local_domain: u32,
        /// Immutable message body version
        message_version: u32,
        /// Max message body size
        max_message_body_size: u64,
        /// Set of enabled attesters
        enabled_attesters: VecSet<address>,
        /// Maps raw u256 nonce -> bool (true if used)
        used_nonces: Table<u256, bool>,
        /// Signature threshold for attestations
        signature_threshold: u64,
        /// Is contract paused
        paused: bool,
        /// All roles for package
        roles: Roles,
        /// The set of package version numbers that object is compatible with
        compatible_versions: VecSet<u64>,
        /// Embedded rescuable for token rescue functionality
        rescuable: Rescuable
    }

    // === Public-Mutative Functions ===

    /// Initialize the state with an immutable local domain and version, initial max message body size, attester, and initial roles.
    public(package) fun new(local_domain: u32, message_version: u32, max_message_body_size: u64, caller: address, ctx: &mut TxContext): State {
        // The embedded `Rescuable` is bound to this object's id, so
        // `rescuable::rescue_coin` rejects any other parent.
        let id = object::new(ctx);
        let rescuable = rescuable::new(&id, caller);
        State {
            id,
            roles: roles::new(caller, caller, caller, ctx),
            local_domain,
            message_version,
            max_message_body_size,
            enabled_attesters: vec_set::empty(),
            used_nonces: table::new(ctx),
            signature_threshold: 1,
            paused: false,
            compatible_versions: vec_set::singleton(version_control::current_version()),
            rescuable
        }
    }
    
    #[allow(lint(share_owned))]
    public(package) fun share_state(state: State) {
        transfer::share_object(state);
    }

    // === Getters ===

    public fun local_domain(state: &State): u32 {
        state.local_domain
    }

    public fun message_version(state: &State): u32 {
        state.message_version
    }

    public fun max_message_body_size(state: &State): u64 {
        state.max_message_body_size
    }

    public fun is_attester_enabled(state: &State, attester: address): bool {
        state.enabled_attesters.contains(&attester)
    }

    public fun get_num_enabled_attesters(state: &State): u64 {
        state.enabled_attesters.length()
    }

    public fun enabled_attesters(state: &State): &VecSet<address> {
        &state.enabled_attesters
    }

    public fun is_nonce_used(state: &State, nonce: u256): bool {
        if (state.used_nonces.contains(nonce)) {
            *state.used_nonces.borrow(nonce)
        } else false
    }

    public fun rescuable(state: &State): &Rescuable {
        &state.rescuable
    }

    public fun signature_threshold(state: &State): u64 {
        state.signature_threshold
    }

    public fun paused(state: &State): bool {
        state.paused
    }

    public fun roles(state: &State): &Roles {
        &state.roles
    }

    public fun compatible_versions(state: &State): &VecSet<u64> {
        &state.compatible_versions
    }

    // === Public-Package Functions ===

    public(package) fun roles_mut(state: &mut State): &mut Roles {
        &mut state.roles
    }

    public(package) fun set_max_message_body_size(state: &mut State, max_message_body_size: u64) {
        state.max_message_body_size = max_message_body_size;
    }

    public(package) fun enable_attester(state: &mut State, attester: address) {
        state.enabled_attesters.insert(attester);
    }

    public(package) fun disable_attester(state: &mut State, attester: address) {
        state.enabled_attesters.remove(&attester);
    }

    public(package) fun set_paused(state: &mut State, paused: bool) {
        state.paused = paused;
    }

    public(package) fun mark_nonce_used(state: &mut State, nonce: u256) {
        state.used_nonces.add(nonce, true);
    }

    public(package) fun rescuable_mut(state: &mut State): &mut Rescuable {
        &mut state.rescuable
    }

    public(package) fun rescue_coin<T>(
        state: &mut State,
        coin_to_receive: Receiving<Coin<T>>,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        rescuable::rescue_coin(&state.rescuable, &mut state.id, coin_to_receive, recipient, amount, ctx);
    }

    public(package) fun set_signature_threshold(state: &mut State, signature_threshold: u64) {
        state.signature_threshold = signature_threshold;
    } 

    public(package) fun add_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.insert(version);
    }

    public(package) fun remove_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.remove(&version);
    }

    // === Test Functions ===

    #[test_only]
    public fun new_for_testing(
        local_domain: u32,
        message_version: u32,
        max_message_body_size: u64,
        caller: address,
        ctx: &mut TxContext
    ): State {
        let id = object::new(ctx);
        let rescuable = rescuable::new(&id, caller);
        State {
            id,
            roles: roles::new(caller, caller, caller, ctx),
            local_domain,
            message_version,
            max_message_body_size,
            enabled_attesters: vec_set::empty(),
            used_nonces: table::new(ctx),
            signature_threshold: 1,
            paused: false,
            compatible_versions: vec_set::singleton(version_control::current_version()),
            rescuable
        }
    }

    #[test_only]
    public fun remove_used_nonce(state: &mut State, nonce: u256) {
        state.used_nonces.remove(nonce);
    }

    #[test_only] use message_transmitter_v2::state::{Self};
    #[test_only] use std::unit_test;

    // === Tests === 

    #[test]
    fun state_new_creates_object() {
        let ctx = &mut tx_context::dummy();

        let expected_msg_version = 1;
        let expected_role = @0x1;
        let expected_local_domain = 0;
        let initial_max_message_body_size = 100;
        let expected_max_message_body_size = 200;
        let initial_attester = @0x2;
        let expected_attester = @0x3;
        let expected_signature_threshold = 2;
        let used_nonce: u256 = 0xaabb00112233445566778899aabbccddeeff00112233445566778899aabbccdd;
        let unused_nonce: u256 = 0xff00112233445566778899aabbccddeeff00112233445566778899aabbccdd00;
        let new_version = 5;

        // Create state object, then modify and add some objects to the maps
        let mut state_obj = state::new(expected_local_domain, expected_msg_version, initial_max_message_body_size, expected_role, ctx);
        state_obj.set_max_message_body_size(expected_max_message_body_size);
        state_obj.set_paused(true);
        state_obj.mark_nonce_used(used_nonce);
        state_obj.set_signature_threshold(expected_signature_threshold);
        state_obj.enable_attester(initial_attester);
        state_obj.enable_attester(expected_attester);
        state_obj.disable_attester(initial_attester);

        assert!(state_obj.local_domain() == expected_local_domain);
        assert!(state_obj.message_version() == expected_msg_version);
        assert!(state_obj.max_message_body_size() == expected_max_message_body_size);
        assert!(state_obj.is_nonce_used(used_nonce));
        assert!(!state_obj.is_nonce_used(unused_nonce));
        assert!(state_obj.signature_threshold() == expected_signature_threshold);
        assert!(state_obj.paused());

        assert!(state_obj.is_attester_enabled(expected_attester));
        assert!(!state_obj.is_attester_enabled(initial_attester));
        assert!(state_obj.get_num_enabled_attesters() == 1);
        assert!(state_obj.enabled_attesters().contains(&expected_attester));
        assert!(!state_obj.enabled_attesters().contains(&initial_attester));

        assert!(state_obj.roles().owner() == expected_role);
        assert!(state_obj.roles().pending_owner() == option::none());
        assert!(state_obj.roles().pauser() == expected_role);
        assert!(state_obj.roles().attester_manager() == expected_role);

        assert!(state_obj.rescuable().rescuer() == expected_role);

        state_obj.add_compatible_version(new_version);
        assert!(state_obj.compatible_versions().contains(&new_version));
        state_obj.remove_compatible_version(new_version);
        assert!(!state_obj.compatible_versions().contains(&new_version));

        // Empty table before destroying
        state_obj.remove_used_nonce(used_nonce);
        unit_test::destroy(state_obj);
    }
}
