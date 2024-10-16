/*
 * Copyright (c) 2024, Circle Internet Group, Inc. All rights reserved.
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
/// This module contains the core global Shared State used in the token_messenger_minter package.
module token_messenger_minter::state {
    // === Imports ===
    use sui::{
        address::{Self},
        bag::{Self, Bag},
        bcs::{Self},
        hash::{Self},
        table::{Self, Table},
        vec_set::{Self, VecSet}
    };
    use token_messenger_minter::{
        roles::{Self, Roles},
        version_control
    };

    // === Structs ===
    public struct State has key {
        id: UID,
        /// Immutable message body version 
        message_body_version: u32, 
        /// Map from remote domain to remote token messenger address
        /// Use `address` type to represent remote addresses since Sui addresses 
        /// are conveniently 32 bytes and the CCTP protocol specifies 32 byte arrays 
        /// for representing external addresses.
        remote_token_messengers: Table<u32, address>,
        /// Map from local token ID to burn limit amount
        burn_limits_per_message: Table<address, u64>,
        /// Map from keccak(remote_domain, remote_token) to local token ID
        /// A remote token (on a certain remote domain) can only map to one 
        /// local token, but many remote tokens can map to the same local token.
        remote_tokens_to_local_tokens: Table<address, address>,
        /// Mapping of token ID to MintCap for minting 
        /// Use a Bag so we can store multiple different capability types
        mint_caps: Bag,
        /// Is contract paused
        paused: bool,
        /// All roles for package
        roles: Roles,
        /// The set of package version numbers that object is compatible with
        compatible_versions: VecSet<u64>
    }

    // === Public-Mutative Functions ===

    /// Initialize the state with an immutable version and initial roles. Roles should be separated to different addresses later.
    public(package) fun new(message_body_version: u32, caller: address, ctx: &mut TxContext): State {
        State {
            id: object::new(ctx),
            roles: roles::new(caller, caller, caller, ctx),
            remote_token_messengers: table::new(ctx),
            burn_limits_per_message: table::new(ctx),
            remote_tokens_to_local_tokens: table::new(ctx),
            mint_caps: bag::new(ctx),
            paused: false,
            message_body_version,
            compatible_versions: vec_set::singleton(version_control::current_version())
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

    public fun mint_cap_for_local_token_exists(state: &State, local_token_id: address): bool {
        state.mint_caps.contains(local_token_id)
    }

    public fun burn_limit_for_token_id_exists(state: &State, token_id: address): bool {
        state.burn_limits_per_message.contains(token_id)
    }

    public fun compatible_versions(state: &State): &VecSet<u64> {
        &state.compatible_versions
    }

    // === Public-Package Functions ===

    public(package) fun roles_mut(state: &mut State): &mut Roles {
        &mut state.roles
    }

    public(package) fun mint_cap_from_token_id<T: store>(state: &State, token_id: address): &T {
        state.mint_caps.borrow(token_id)
    }

    public(package) fun set_paused(state: &mut State, paused: bool) {
        state.paused = paused;
    }

    public(package) fun add_mint_cap<T: store>(state: &mut State, token_id: address, mint_cap: T) {
        state.mint_caps.add(token_id, mint_cap);
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

    public(package) fun remove_mint_cap<T: store>(state: &mut State, token_id: address): T {
        state.mint_caps.remove(token_id)
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

    public(package) fun add_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.insert(version);
    }

    public(package) fun remove_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.remove(&version);
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
    #[test_only] use sui::test_utils;
    #[test_only] use token_messenger_minter::state::{Self};

    #[test_only]
    public struct TestCap has store, key {
      id: UID,
      address: address
    }

    // new tests

    #[test]
    fun state_new_creates_object() {
      let ctx = &mut tx_context::dummy();

      let expected_msg_version = 1;
      let expected_role = @0x1;
      let expected_remote_token_messenger = @0x1;
      let mint_cap = TestCap { id: object::new(ctx), address: ctx.fresh_object_address() };
      let expected_mint_cap_id = mint_cap.address;
      let expected_burn_limit = 100;
      let expected_local_token = @0x5;
      let expected_remote_token = @0x6;
      let remote_domain = 5;
      let new_version = 5;
      
      // Create state object and add some objects to the maps
      let mut state_obj = state::new(expected_msg_version, expected_role, ctx);
      state_obj.add_mint_cap(expected_local_token, mint_cap);
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
      assert!(state::mint_cap_for_local_token_exists(&state_obj, expected_local_token));
      assert!(&state::mint_cap_from_token_id<TestCap>(&state_obj, expected_local_token).address == expected_mint_cap_id);
      assert!(state_obj.remote_token_messenger_for_remote_domain_exists(0));
      assert!(state_obj.remote_token_messenger_from_remote_domain(0) == expected_remote_token_messenger);
      assert!(state_obj.burn_limit_for_token_id_exists(expected_local_token));
      assert!(state_obj.burn_limit_from_token_id(expected_local_token) == expected_burn_limit);
      assert!(state_obj.local_token_from_remote_token_exists(remote_domain, expected_remote_token) == true);
      assert!(state_obj.local_token_from_remote_token(remote_domain, expected_remote_token) == expected_local_token);
      
      state_obj.add_compatible_version(new_version);
      assert!(state_obj.compatible_versions().contains(&new_version));
      state_obj.remove_compatible_version(new_version);
      assert!(!state_obj.compatible_versions().contains(&new_version));

      // Empty the tables and bags before destroying
      let TestCap {id: mint_id, address: mint_cap_address} = state_obj.remove_mint_cap<TestCap>(expected_local_token);
      assert!(mint_cap_address == expected_mint_cap_id);
      assert!(state_obj.remove_remote_token_messenger(0) == expected_remote_token_messenger);
      assert!(state_obj.remove_burn_limit(expected_local_token) == expected_burn_limit);
      assert!(state_obj.remove_local_token_for_remote_token(remote_domain, expected_remote_token) == expected_local_token);
      mint_id.delete();

      test_utils::destroy(state_obj);
    }
}
