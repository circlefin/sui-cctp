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
/// This module contains the core global Shared State used in the
/// `token_messenger_minter_v2` package.
module token_messenger_minter_v2::state {
    // === Imports ===
    use sui::{
        address::{Self},
        bcs::{Self},
        coin::Coin,
        hash::{Self},
        table::{Self, Table},
        transfer::Receiving,
        vec_set::{Self, VecSet}
    };
    use token_messenger_minter_v2::{
        roles::{Self, Roles},
        version_control
    };
    use cctp_extensions::rescuable::{Self, Rescuable};

    // === Structs ===
    public struct State has key {
        id: UID,
        /// Immutable message body version.
        message_body_version: u32,
        /// Remote domain -> remote token messenger address (32-byte
        /// external addresses fit into Sui's `address`).
        remote_token_messengers: Table<u32, address>,
        /// Local token id -> burn limit per message.
        burn_limits_per_message: Table<address, u64>,
        /// `keccak(remote_domain, remote_token)` -> local token id.
        /// Many-to-one: multiple remote tokens can map to one local id.
        remote_tokens_to_local_tokens: Table<address, address>,
        /// Local token id -> registered handler witness-type identifier
        /// (keccak256 of the fully-qualified type name via
        /// `handler_registry::handler_identifier<W>()`), NOT a plain
        /// package address. The identifier pins the exact witness type
        /// (package + module + type), so an unrelated `drop` type from
        /// the same package cannot authenticate. Managed via
        /// `admin/handler_registry::{register,deregister}_handler`.
        handlers: Table<address, address>,
        paused: bool,
        roles: Roles,
        /// CCTP address denylist (source-side only; see `admin/denylistable`).
        denylist: Table<address, bool>,
        /// Fees on the destination side land here. Set via
        /// `admin/fee_controller::set_fee_recipient`.
        fee_recipient: address,
        /// Local burn token id -> min fee rate in 1/1000th of a basis
        /// point (denominator `MIN_FEE_MULTIPLIER = 10_000_000`). Set
        /// via `admin/fee_controller::set_min_fee`.
        min_fees: Table<address, u256>,
        /// Package versions this object is compatible with.
        compatible_versions: VecSet<u64>,
        /// Rescuer for coins stranded at this object's address. Rescue
        /// via `admin/rescuable::rescue_tokens`; rotate via
        /// `admin/role_management::update_rescuer`.
        rescuable: Rescuable
    }

    // === Public-Mutative Functions ===

    /// Initialize state. All role holders and `fee_recipient` default
    /// to `caller` and are expected to be rotated post-deployment.
    public(package) fun new(message_body_version: u32, caller: address, ctx: &mut TxContext): State {
        // The embedded `Rescuable` is bound to this object's id, so
        // `rescuable::rescue_coin` rejects any other parent.
        let id = object::new(ctx);
        let rescuable = rescuable::new(&id, caller);
        State {
            id,
            roles: roles::new(caller, caller, caller, caller, caller, ctx),
            remote_token_messengers: table::new(ctx),
            burn_limits_per_message: table::new(ctx),
            remote_tokens_to_local_tokens: table::new(ctx),
            handlers: table::new(ctx),
            paused: false,
            denylist: table::new(ctx),
            fee_recipient: caller,
            min_fees: table::new(ctx),
            message_body_version,
            compatible_versions: vec_set::singleton(version_control::current_version()),
            rescuable
        }
    }

    #[allow(lint(share_owned))]
    public(package) fun share_state(state: State) {
        transfer::share_object(state);
    }

    // === Getters ===

    public fun message_body_version(state: &State): u32 {
        state.message_body_version
    }

    public fun paused(state: &State): bool {
        state.paused
    }

    public fun roles(state: &State): &Roles {
        &state.roles
    }

    public fun remote_token_messenger_from_remote_domain(state: &State, remote_domain: u32): address {
        *state.remote_token_messengers.borrow(remote_domain)
    }

    public fun burn_limit_from_token_id(state: &State, token_id: address): u64 {
        *state.burn_limits_per_message.borrow(token_id)
    }

    public fun local_token_from_remote_token(state: &State, remote_domain: u32, remote_token: address): address {
        let key = generate_remote_token_key(remote_domain, remote_token);
        *state.remote_tokens_to_local_tokens.borrow(key)
    }

    public fun local_token_from_remote_token_exists(state: &State, remote_domain: u32, remote_token: address): bool {
        let key = generate_remote_token_key(remote_domain, remote_token);
        state.remote_tokens_to_local_tokens.contains(key)
    }

    public fun remote_token_messenger_for_remote_domain_exists(state: &State, remote_domain: u32): bool {
        state.remote_token_messengers.contains(remote_domain)
    }

    public fun burn_limit_for_token_id_exists(state: &State, token_id: address): bool {
        state.burn_limits_per_message.contains(token_id)
    }

    /// Registered handler for `token_id`. Aborts if unregistered.
    public fun handler(state: &State, token_id: address): address {
        *state.handlers.borrow(token_id)
    }

    public fun handler_for_token_id_exists(state: &State, token_id: address): bool {
        state.handlers.contains(token_id)
    }

    public fun compatible_versions(state: &State): &VecSet<u64> {
        &state.compatible_versions
    }

    public fun is_denylisted(state: &State, addr: address): bool {
        state.denylist.contains(addr)
    }

    public fun fee_recipient(state: &State): address {
        state.fee_recipient
    }

    /// Min-fee rate for `token_id` (0 if unset). Units: 1/1000 bp.
    public fun min_fee(state: &State, token_id: address): u256 {
        if (state.min_fees.contains(token_id)) {
            *state.min_fees.borrow(token_id)
        } else {
            0
        }
    }

    public fun min_fee_for_token_id_exists(state: &State, token_id: address): bool {
        state.min_fees.contains(token_id)
    }

    public fun rescuable(state: &State): &Rescuable {
        &state.rescuable
    }

    // === Public-Package Functions ===

    public(package) fun roles_mut(state: &mut State): &mut Roles {
        &mut state.roles
    }

    /// Caller must ensure `addr` is not already present (guarded in
    /// `denylistable` via `is_denylisted`).
    public(package) fun add_denylisted_address(state: &mut State, addr: address) {
        state.denylist.add(addr, true);
    }

    /// Caller must ensure `addr` is present.
    public(package) fun remove_denylisted_address(state: &mut State, addr: address) {
        state.denylist.remove(addr);
    }

    public(package) fun set_fee_recipient(state: &mut State, new_fee_recipient: address) {
        state.fee_recipient = new_fee_recipient;
    }

    /// Insert or overwrite. Caller must ensure `min_fee < MIN_FEE_MULTIPLIER`.
    public(package) fun set_min_fee(state: &mut State, token_id: address, min_fee: u256) {
        if (state.min_fees.contains(token_id)) {
            *state.min_fees.borrow_mut(token_id) = min_fee;
        } else {
            state.min_fees.add(token_id, min_fee);
        }
    }

    public(package) fun set_paused(state: &mut State, paused: bool) {
        state.paused = paused;
    }

    public(package) fun add_remote_token_messenger(state: &mut State, remote_domain: u32, remote_token_messenger: address) {
        state.remote_token_messengers.add(remote_domain, remote_token_messenger);
    }

    public(package) fun add_burn_limit(state: &mut State, token_id: address, limit: u64) {
        state.burn_limits_per_message.add(token_id, limit);
    }

    public(package) fun add_local_token_for_remote_token(state: &mut State, remote_domain: u32, remote_token: address, local_token_id: address) {
        let key = generate_remote_token_key(remote_domain, remote_token);
        state.remote_tokens_to_local_tokens.add(key, local_token_id);
    }

    public(package) fun remove_remote_token_messenger(state: &mut State, remote_domain: u32): address {
        state.remote_token_messengers.remove(remote_domain)
    }

    public(package) fun remove_burn_limit(state: &mut State, token_id: address): u64 {
        state.burn_limits_per_message.remove(token_id)
    }

    public(package) fun remove_local_token_for_remote_token(state: &mut State, remote_domain: u32, remote_token: address): address {
        let key = generate_remote_token_key(remote_domain, remote_token);
        state.remote_tokens_to_local_tokens.remove(key)
    }

    /// Insert or overwrite. Auth + address invariants are the caller's job.
    public(package) fun set_handler(state: &mut State, token_id: address, handler_address: address) {
        if (state.handlers.contains(token_id)) {
            *state.handlers.borrow_mut(token_id) = handler_address;
        } else {
            state.handlers.add(token_id, handler_address);
        }
    }

    /// Aborts if no entry exists.
    public(package) fun remove_handler(state: &mut State, token_id: address): address {
        state.handlers.remove(token_id)
    }

    public(package) fun add_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.insert(version);
    }

    public(package) fun remove_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.remove(&version);
    }

    public(package) fun rescuable_mut(state: &mut State): &mut Rescuable {
        &mut state.rescuable
    }

    /// Rescuer-only; delegates to `cctp_extensions::rescuable::rescue_coin`.
    public(package) fun rescue_coin<T>(
        state: &mut State,
        coin_to_receive: Receiving<Coin<T>>,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        rescuable::rescue_coin(&state.rescuable, &mut state.id, coin_to_receive, recipient, amount, ctx);
    }

    // === Private Functions ===

    /// Helper function for calculating the key for a (remote_domain, remote_token) pair in a Table.
    /// (remote_domain, remote_token) keys in Tables are represented as an address of the keccak256 
    /// hash of their concatenated bytes. keccak256 returns a 32 bytes array so this can always be
    /// represented as an address type.
    fun generate_remote_token_key(remote_domain: u32, remote_token: address): address {
        // Create (remote_domain, remote_token) concatenated bytes vector
        let mut remote_resource = bcs::to_bytes(&remote_domain);
        remote_resource.append(b"-");
        remote_resource.append(remote_token.to_bytes());
        
        // Hash them and return
        address::from_bytes(hash::keccak256(&remote_resource))
    }

    // === Test Functions ===
    #[test_only] use std::unit_test;
    #[test_only] use token_messenger_minter_v2::state::{Self};

    #[test_only]
    public fun new_for_testing(message_body_version: u32, caller: address, ctx: &mut TxContext): State {
        let id = object::new(ctx);
        let rescuable = rescuable::new(&id, caller);
        State {
            id,
            roles: roles::new(caller, caller, caller, caller, caller, ctx),
            remote_token_messengers: table::new(ctx),
            burn_limits_per_message: table::new(ctx),
            remote_tokens_to_local_tokens: table::new(ctx),
            handlers: table::new(ctx),
            paused: false,
            denylist: table::new(ctx),
            fee_recipient: caller,
            min_fees: table::new(ctx),
            message_body_version,
            compatible_versions: vec_set::singleton(version_control::current_version()),
            rescuable
        }
    }

    /// Test-only public wrappers so dependent packages (e.g. stablecoin_handler)
    /// can configure a TMM `State` in their own tests. The production mutators
    /// are `public(package)` and thus not reachable cross-package. Mirrors the
    /// Aptos TMM `*_for_testing` helpers used by its handler tests.
    #[test_only]
    public fun add_remote_token_messenger_for_testing(state: &mut State, remote_domain: u32, remote_token_messenger: address) {
        state.add_remote_token_messenger(remote_domain, remote_token_messenger);
    }

    #[test_only]
    public fun add_burn_limit_for_testing(state: &mut State, token_id: address, limit: u64) {
        state.add_burn_limit(token_id, limit);
    }

    #[test_only]
    public fun set_handler_for_testing(state: &mut State, token_id: address, handler_address: address) {
        state.set_handler(token_id, handler_address);
    }

    #[test_only]
    public fun add_local_token_for_remote_token_for_testing(state: &mut State, remote_domain: u32, remote_token: address, local_token_id: address) {
        state.add_local_token_for_remote_token(remote_domain, remote_token, local_token_id);
    }

    #[test_only]
    public fun set_fee_recipient_for_testing(state: &mut State, new_fee_recipient: address) {
        state.set_fee_recipient(new_fee_recipient);
    }

    // new tests

    #[test]
    fun state_new_creates_object() {
      let ctx = &mut tx_context::dummy();

      let expected_msg_version = 1;
      let expected_role = @0x1;
      let expected_remote_token_messenger = @0x1;
      let expected_burn_limit = 100;
      let expected_local_token = @0x5;
      let expected_remote_token = @0x6;
      let remote_domain = 5;
      let new_version = 5;

      // Create state object and add some objects to the maps
      let mut state_obj = state::new(expected_msg_version, expected_role, ctx);
      state_obj.add_remote_token_messenger(0, expected_remote_token_messenger);
      state_obj.add_burn_limit(expected_local_token, expected_burn_limit);
      state_obj.add_local_token_for_remote_token(remote_domain, expected_remote_token, expected_local_token);
      state_obj.set_paused(true);

      assert!(state_obj.message_body_version() == expected_msg_version);
      assert!(state_obj.paused() == true);
      assert!(state_obj.roles().owner() == expected_role);
      assert!(state_obj.roles().pending_owner() == option::none());
      assert!(state_obj.roles().pauser() == expected_role);
      assert!(state_obj.roles().token_controller() == expected_role);
      assert!(state_obj.roles().denylister() == expected_role);
      assert!(state_obj.roles().min_fee_controller() == expected_role);
      assert!(state_obj.rescuable().rescuer() == expected_role);
      assert!(state_obj.remote_token_messenger_for_remote_domain_exists(0));
      assert!(state_obj.remote_token_messenger_from_remote_domain(0) == expected_remote_token_messenger);
      assert!(state_obj.burn_limit_for_token_id_exists(expected_local_token));
      assert!(state_obj.burn_limit_from_token_id(expected_local_token) == expected_burn_limit);
      assert!(state_obj.local_token_from_remote_token_exists(remote_domain, expected_remote_token) == true);
      assert!(state_obj.local_token_from_remote_token(remote_domain, expected_remote_token) == expected_local_token);

      // denylist: defaults to not-denylisted; add + remove round-trip
      let denylist_target = @0x9;
      assert!(!state_obj.is_denylisted(denylist_target));
      state_obj.add_denylisted_address(denylist_target);
      assert!(state_obj.is_denylisted(denylist_target));
      state_obj.remove_denylisted_address(denylist_target);
      assert!(!state_obj.is_denylisted(denylist_target));

      // handlers: unregistered token returns false; set + overwrite + remove round-trip
      let handler_token = @0x7;
      let (handler_a, handler_b) = (@0xaa, @0xbb);
      assert!(!state_obj.handler_for_token_id_exists(handler_token));
      state_obj.set_handler(handler_token, handler_a);
      assert!(state_obj.handler_for_token_id_exists(handler_token));
      assert!(state_obj.handler(handler_token) == handler_a);
      state_obj.set_handler(handler_token, handler_b);
      assert!(state_obj.handler(handler_token) == handler_b);
      assert!(state_obj.remove_handler(handler_token) == handler_b);
      assert!(!state_obj.handler_for_token_id_exists(handler_token));

      // fee_recipient defaults to caller and can be updated in-place
      assert!(state_obj.fee_recipient() == expected_role);
      let new_fee_recipient = @0x7;
      state_obj.set_fee_recipient(new_fee_recipient);
      assert!(state_obj.fee_recipient() == new_fee_recipient);

      // min_fees defaults to 0 for unregistered tokens; set + overwrite
      let fee_token = @0x8;
      assert!(!state_obj.min_fee_for_token_id_exists(fee_token));
      assert!(state_obj.min_fee(fee_token) == 0);
      state_obj.set_min_fee(fee_token, 100_000);
      assert!(state_obj.min_fee_for_token_id_exists(fee_token));
      assert!(state_obj.min_fee(fee_token) == 100_000);
      state_obj.set_min_fee(fee_token, 200_000);
      assert!(state_obj.min_fee(fee_token) == 200_000);

      state_obj.add_compatible_version(new_version);
      assert!(state_obj.compatible_versions().contains(&new_version));
      state_obj.remove_compatible_version(new_version);
      assert!(!state_obj.compatible_versions().contains(&new_version));

      // Empty the tables before destroying
      assert!(state_obj.remove_remote_token_messenger(0) == expected_remote_token_messenger);
      assert!(state_obj.remove_burn_limit(expected_local_token) == expected_burn_limit);
      assert!(state_obj.remove_local_token_for_remote_token(remote_domain, expected_remote_token) == expected_local_token);

      unit_test::destroy(state_obj);
    }
}
