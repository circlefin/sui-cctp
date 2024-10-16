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

/// Module: token_controller
/// Admin functions for controlling local/remote token state, including 
/// mapping address of local tokens to addresses of corresponding tokens 
/// on remote domains, and limiting the amount of each token that can 
/// be burned per message.
/// Note: This token_controller module only supports stablecoin coins: https://github.com/circlefin/stablecoin-sui/tree/master/packages/stablecoin
module token_messenger_minter::token_controller {
    // === Imports ===
    use sui::event::emit;
    use token_messenger_minter::{
        state::{State}, 
        token_utils,
        version_control::{assert_object_version_is_compatible_with_package}
    };
    use stablecoin::treasury::{MintCap, Treasury, is_authorized_mint_cap};

    // === Errors ===
    const ENotTokenController: u64 = 0;
    const EEmptyAddress: u64 = 1;
    const ETokenPairAlreadyLinked: u64 = 2;
    const ETokenPairNotLinked: u64 = 3;
    const EMintCapAlreadyAdded: u64 = 4;
    const EMintCapDoesNotExist: u64 = 5;
    const EMintCapNotDeAuthorized: u64 = 6;

    // === Events ===
    public struct SetBurnLimitPerMessage has copy, drop {
        token: address,
        burn_limit_per_message: u64,
    }

    public struct TokenPairLinked has copy, drop {
        local_token: address,
        remote_domain: u32,
        remote_token: address,
    }

    public struct TokenPairUnlinked has copy, drop {
        local_token: address,
        remote_domain: u32,
        remote_token: address,
    }

    public struct MintCapAdded has copy, drop {
        local_token: address,
        mint_cap_id: ID
    }

    public struct MintCapRemoved has copy, drop {
        local_token: address,
        mint_cap_id: ID
    }

    // === Admin Functions ===

    /// Sets the maximum burn amount per message for a given localToken after removing the existing limit (if exists). 
    /// Burns with amounts exceeding burnLimitPerMessage will revert. 
    /// Mints do not respect this value, so if this limit is reduced, previously burned tokens will still be mintable.
    /// Generic type `T` should be the Witness of the local Sui token being linked. 
    entry fun set_max_burn_amount_per_message<T: drop>(burn_limit_per_message: u64, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_token_controller(state, ctx);

      let token_id = token_utils::calculate_token_id<T>();
      if (state.burn_limit_for_token_id_exists(token_id)) {
        state.remove_burn_limit(token_id);
      };

      state.add_burn_limit(token_id, burn_limit_per_message);
      emit(SetBurnLimitPerMessage {token: token_id, burn_limit_per_message});
    }

    /// Links a pair of local and remote tokens to be supported by the TokenMessengerMinter. Associates a 
    /// (remote_domain, remote_token) pair with a localToken (e.g. a Sui Coin) by updating `remote_tokens_to_local_tokens` 
    /// mapping. A remote token (on a certain remote domain) can only map to one local token, but many remote tokens can 
    /// map to the same local token. Setting a token pair does not enable the localToken (that requires calling `set_max_burn_amount_per_message`).
    /// Note that local tokens on Sui are represented by a unique token id. See token_utils::calculate_token_id function for more info.
    /// Generic type `T` should be the Witness of the local Sui token being linked. 
    /// Remote token is the 32 byte hex representation of the token on the remote chain.
    entry fun link_token_pair<T: drop>(
        remote_domain: u32, 
        remote_token: address, 
        state: &mut State, 
        ctx: &TxContext
    ) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_token_controller(state, ctx);
      assert!(remote_token != @0x0, EEmptyAddress);
      assert!(!state.local_token_from_remote_token_exists(remote_domain, remote_token), ETokenPairAlreadyLinked);

      let local_token_id = token_utils::calculate_token_id<T>();
      state.add_local_token_for_remote_token(remote_domain, remote_token, local_token_id);
      emit(TokenPairLinked {local_token: local_token_id, remote_domain, remote_token});
    }

    /// Unlinks a pair of local and remote tokens for this TokenMessengerMinter. Removes link from remoteToken to 
    /// localToken for given remoteDomain by updating mapping. A remote token (on a certain remote domain) can only 
    /// map to one local token, but many remote tokens can map to the same local token. 
    /// Generic type `T` should be the Witness of the local Sui token being linked. 
    /// Remote token is the 32 byte hex representation of the token on the remote chain.
    entry fun unlink_token_pair<T: drop>(
        remote_domain: u32, 
        remote_token: address, 
        state: &mut State, 
        ctx: &TxContext
    ) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_token_controller(state, ctx);
      assert!(remote_token != @0x0, EEmptyAddress);
      assert!(state.local_token_from_remote_token_exists(remote_domain, remote_token), ETokenPairNotLinked);
      state.remove_local_token_for_remote_token(remote_domain, remote_token);
      let local_token_id = token_utils::calculate_token_id<T>();
      emit(TokenPairUnlinked {local_token: local_token_id, remote_domain, remote_token});
    }

    /// Adds a `MintCap` mint capability for the given stablecoin token, `T`. 
    /// Only one `MintCap` can be stored for any token.
    entry fun add_stablecoin_mint_cap<T: drop>(mint_cap: MintCap<T>, state: &mut State, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        verify_token_controller(state, ctx);
        let local_token_id = token_utils::calculate_token_id<T>();
        assert!(!state.mint_cap_for_local_token_exists(local_token_id), EMintCapAlreadyAdded);

        let mint_cap_id = object::id(&mint_cap);
        state.add_mint_cap(local_token_id, mint_cap);
        emit(MintCapAdded {local_token: local_token_id, mint_cap_id });
    }

    /// Removes a `MintCap` for the given stablecoin token, `T`. 
    /// `MintCap` must exist before removing.
    /// Transfers the removed `MintCap` to the caller.
    /// Requires the `MintCap` be deauthorized (`treasury::remove_minter`) before removing. 
    #[allow(lint(self_transfer))]
    entry fun remove_stablecoin_mint_cap<T: drop>(state: &mut State, treasury: &Treasury<T>, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        verify_token_controller(state, ctx);

        // Ensure MintCap exists and is de-authorized before removing.
        let local_token_id = token_utils::calculate_token_id<T>();
        assert!(state.mint_cap_for_local_token_exists(local_token_id), EMintCapDoesNotExist);
        let mint_cap_ref = state.mint_cap_from_token_id<MintCap<T>>(local_token_id);
        assert!(!is_authorized_mint_cap(treasury, object::id(mint_cap_ref)), EMintCapNotDeAuthorized);

        let mint_cap = state.remove_mint_cap<MintCap<T>>(local_token_id);
        emit(MintCapRemoved {local_token: local_token_id, mint_cap_id: object::id(&mint_cap) });
        
        transfer::public_transfer(mint_cap, ctx.sender());
    }

    // === Private Functions ===
    fun verify_token_controller(state: &State, ctx: &TxContext) {
      assert!(ctx.sender() == state.roles().token_controller(), ENotTokenController);
    }

    #[test_only]
    public fun create_set_burn_limit_per_message_event(token: address, burn_limit_per_message: u64): SetBurnLimitPerMessage {
        SetBurnLimitPerMessage {token, burn_limit_per_message}
    }

    #[test_only]
    public fun create_token_pair_linked_event(local_token: address, remote_domain: u32, remote_token: address): TokenPairLinked {
        TokenPairLinked {local_token, remote_domain, remote_token}
    }

    #[test_only]
    public fun create_token_pair_unlinked_event(local_token: address, remote_domain: u32, remote_token: address): TokenPairUnlinked {
        TokenPairUnlinked {local_token, remote_domain, remote_token}
    }

    #[test_only]
    public fun create_mint_cap_added_event(local_token: address, mint_cap_id: ID): MintCapAdded {
        MintCapAdded {local_token, mint_cap_id}
    }

    #[test_only]
    public fun create_mint_cap_removed_event(local_token: address, mint_cap_id: ID): MintCapRemoved {
        MintCapRemoved {local_token, mint_cap_id}
    }
}

#[test_only]
module token_messenger_minter::token_controller_tests {
    use sui::{
        coin, 
        deny_list,
        event::{num_events}, 
        test_scenario::{Self, Scenario}, 
        test_utils::{Self, assert_eq}
    };
    use sui_extensions::test_utils::{last_event_by_type};
    use token_messenger_minter::{
        state::{Self}, 
        token_utils::{Self}, 
        token_controller::{
            Self, 
            MintCapAdded, 
            MintCapRemoved, 
            SetBurnLimitPerMessage, 
            TokenPairUnlinked, 
            TokenPairLinked, 
            create_mint_cap_added_event, 
            create_mint_cap_removed_event,
            create_set_burn_limit_per_message_event, 
            create_token_pair_linked_event, 
            create_token_pair_unlinked_event,
        },
        version_control
    };
    use stablecoin::treasury::{Self, MintCap, Treasury};

    public struct TOKEN_CONTROLLER_TESTS has drop {}

    const TOKEN_CONTROLLER: address = @0x1;

    // set_max_burn_amount_per_message tests

    #[test]
    public fun test_set_max_burn_amount_per_message_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let burn_limit_per_message = 100;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Successful setting of max burn amount per message
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message, &mut state, scenario.ctx());
            assert_eq(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message);
            assert!(num_events() == 1);
            assert!(last_event_by_type<SetBurnLimitPerMessage>() == create_set_burn_limit_per_message_event(local_token_id, burn_limit_per_message));
        };

        state.remove_burn_limit(local_token_id);
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    public fun test_set_max_burn_amount_per_message_with_existing_limit_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let burn_limit_per_message = 100;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance and set the initial limit
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message + 100, &mut state, scenario.ctx());
        assert_eq(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message + 100);

        // Test: Successful setting of max burn amount per message with existing limit
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message, &mut state, scenario.ctx());
            assert_eq(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message);
            assert!(num_events() == 1);
            assert!(last_event_by_type<SetBurnLimitPerMessage>() == create_set_burn_limit_per_message_event(local_token_id, burn_limit_per_message));
        };

        state.remove_burn_limit(local_token_id);
        test_utils::destroy(state);
        scenario.end();
    }
    
    #[test]
    #[expected_failure(abort_code = token_controller::ENotTokenController)]
    public fun test_set_max_burn_amount_per_message_revert_not_token_controller() {
      let mut scenario = test_scenario::begin(@0x0);
        let not_token_controller = @0x2;
        let burn_limit_per_message = 100;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the caller is not the token controller
        scenario.next_tx(not_token_controller);
        token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message, &mut state, scenario.ctx());

        state.remove_burn_limit(local_token_id);
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_set_max_burn_amount_per_message_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let burn_limit_per_message = 100;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message, &mut state, scenario.ctx());

        state.remove_burn_limit(local_token_id);
        test_utils::destroy(state);
        scenario.end();
    }

    // link_token_pair tests

    #[test]
    public fun test_link_token_pair_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance 
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Successful linking of token pair
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            assert_eq(state.local_token_from_remote_token(remote_domain, remote_token), local_token_id);
            assert!(num_events() == 1);
            assert!(last_event_by_type<TokenPairLinked>() == create_token_pair_linked_event(local_token_id, remote_domain, remote_token));
        };

        // Destroy objects
        state.remove_local_token_for_remote_token(remote_domain, remote_token);
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ENotTokenController)]
    public fun test_link_token_pair_revert_not_token_controller() {
        let mut scenario = test_scenario::begin(@0x0);
        let (non_token_controller, remote_token) = (@0x2, @0x3);
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the caller is not the token controller
        scenario.next_tx(non_token_controller);
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            assert!(!state.local_token_from_remote_token_exists(remote_domain, remote_token), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EEmptyAddress)]
    public fun test_link_token_pair_revert_empty_address() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x0;
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the remote token address is empty
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            assert!(!state.local_token_from_remote_token_exists(remote_domain, remote_token), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ETokenPairAlreadyLinked)]
    public fun test_link_token_pair_revert_already_linked() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Link the token pair for the first time
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert!(state.local_token_from_remote_token(remote_domain, remote_token) == local_token_id, 0);

            // Attempt to link the same token pair again
            scenario.next_tx(TOKEN_CONTROLLER);
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_link_token_pair_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            assert!(!state.local_token_from_remote_token_exists(remote_domain, remote_token), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    // unlink_token_pair tests

    #[test]
    public fun test_unlink_token_pair_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Link a token pair first
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(remote_domain, remote_token, &mut state, scenario.ctx());
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert!(state.local_token_from_remote_token(remote_domain, remote_token) == local_token_id, 0);
        };

        // Test: Successful unlinking of token pair
        {
            token_controller::unlink_token_pair<TOKEN_CONTROLLER_TESTS>(
                remote_domain, remote_token, &mut state, scenario.ctx()
            );
            // Validate the local token was removed 
            assert!(!state.local_token_from_remote_token_exists(remote_domain, remote_token), 1);
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert!(num_events() == 2);
            assert!(last_event_by_type<TokenPairUnlinked>() == create_token_pair_unlinked_event(local_token_id, remote_domain, remote_token));
        };

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ENotTokenController)]
    public fun test_unlink_token_pair_revert_not_token_controller() {
        let mut scenario = test_scenario::begin(@0x0);
        let (non_token_controller, remote_token) = (@0x2, @0x3);
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the caller is not the token controller
        scenario.next_tx(non_token_controller);
        token_controller::unlink_token_pair<TOKEN_CONTROLLER_TESTS>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EEmptyAddress)]
    public fun test_unlink_token_pair_revert_empty_address() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x0;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the remote token address is empty
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::unlink_token_pair<TOKEN_CONTROLLER_TESTS>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ETokenPairNotLinked)]
    public fun test_unlink_token_pair_revert_already_linked() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Attempt to unlink without linking
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::unlink_token_pair<TOKEN_CONTROLLER_TESTS>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_unlink_token_pair_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        token_controller::unlink_token_pair<TOKEN_CONTROLLER_TESTS>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    // add_stablecoin_mint_cap tests

    #[test]
    public fun test_add_stablecoin_mint_cap_successful() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);

        // Test: Successful linking of token pair
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            let mint_cap_id_address = object::id_address(&mint_cap);
            let mint_cap_id = object::id(&mint_cap);
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            assert_eq(
                object::id_address(state.mint_cap_from_token_id<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id)), 
                mint_cap_id_address
            );
            assert!(num_events() == 1);
            assert!(last_event_by_type<MintCapAdded>() == create_mint_cap_added_event(local_token_id, mint_cap_id));
        };

        // Destroy objects
        test_utils::destroy(state.remove_mint_cap<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id));
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ENotTokenController)]
    public fun test_add_stablecoin_mint_cap_revert_not_token_controller() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let non_token_controller = @0x2;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);

        // Test: Revert if the caller is not the token controller
        scenario.next_tx(non_token_controller);
        {
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            assert!(!state.mint_cap_for_local_token_exists(local_token_id), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EMintCapAlreadyAdded)]
    public fun test_add_stablecoin_mint_cap_revert_already_added() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (scenario, treasury, mint_cap) = setup_mint_cap(scenario);
        let (mut scenario, treasury2, mint_cap2) = setup_mint_cap(scenario);

        // Add the mint cap for the first time
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            let mint_cap_id = object::id_address(&mint_cap);
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert_eq(object::id_address(state.mint_cap_from_token_id<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id)), mint_cap_id);

            // Attempt to add the same mint cap again
            scenario.next_tx(TOKEN_CONTROLLER);
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap2, &mut state, scenario.ctx()
            );
            assert_eq(object::id_address(state.mint_cap_from_token_id<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id)), mint_cap_id);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        test_utils::destroy(treasury2);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_add_stablecoin_mint_cap_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        {
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            assert!(!state.mint_cap_for_local_token_exists(local_token_id), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        scenario.end();
    }

    // remove_stablecoin_mint_cap tests

    #[test]
    public fun test_remove_stablecoin_mint_cap_successful() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (mut scenario, mut treasury, mint_cap) = setup_mint_cap(scenario);
        let mint_cap_id_address = object::id_address(&mint_cap);
        let mint_cap_id = object::id(&mint_cap);
        
        // de-authorize the minter so it can be removed later
        scenario.next_tx(@0x1);
        { treasury.remove_minter(scenario.ctx()) };

        // Add a mint cap first and deauthorize it
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert_eq(object::id_address(state.mint_cap_from_token_id<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id)), mint_cap_id_address);
        };

        // Test: Successfully remove mint cap
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::remove_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                &mut state, &treasury, scenario.ctx()
            );
            assert!(num_events() == 1);
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert!(last_event_by_type<MintCapRemoved>() == create_mint_cap_removed_event(local_token_id, mint_cap_id));
        };

        scenario.end();
        // Validate the transferred mint_cap mint cap is the same one we linked above.
        assert_eq(test_scenario::most_recent_id_for_address<MintCap<TOKEN_CONTROLLER_TESTS>>(TOKEN_CONTROLLER).extract(), mint_cap_id_address.to_id());

        // Destroy objects
        test_utils::destroy(state);
        test_utils::destroy(treasury);
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EMintCapNotDeAuthorized)]
    public fun test_remove_stablecoin_mint_cap_revert_not_de_authorized() {
        let mut scenario = test_scenario::begin(TOKEN_CONTROLLER);

        // Create a new State instance and get mint cap
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);
        let mint_cap_id_address = object::id_address(&mint_cap);

        // Add a mint cap first
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::add_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                mint_cap, &mut state, scenario.ctx()
            );
            let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
            assert_eq(object::id_address(state.mint_cap_from_token_id<MintCap<TOKEN_CONTROLLER_TESTS>>(local_token_id)), mint_cap_id_address);
        };

        // Revert: MintCap not de-authorized
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::remove_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                &mut state, &treasury, scenario.ctx()
            );
            // assert!(num_events() == 1);
        };

        // Destroy objects
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::ENotTokenController)]
    public fun test_remove_stablecoin_mint_cap_revert_not_token_controller() {
        let scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let non_token_controller = @0x2;
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Test: Revert if the caller is not the token controller
        scenario.next_tx(non_token_controller);
        {
            token_controller::remove_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                &mut state, &treasury, scenario.ctx()
            );
            assert!(!state.mint_cap_for_local_token_exists(local_token_id), 0);
        };


        // Destroy objects
        test_utils::destroy(state);
        test_utils::destroy(mint_cap);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EMintCapDoesNotExist)]
    public fun test_remove_stablecoin_mint_cap_revert_already_linked() {
        let scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        // Attempt to remove cap without adding
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::remove_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
            &mut state, &treasury, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        test_utils::destroy(mint_cap);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_remove_stablecoin_mint_cap_revert_incompatible_version() {
        let scenario = test_scenario::begin(TOKEN_CONTROLLER);
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
        let (mut scenario, treasury, mint_cap) = setup_mint_cap(scenario);

        // Create a new State instance
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        {
            token_controller::remove_stablecoin_mint_cap<TOKEN_CONTROLLER_TESTS>(
                &mut state, &treasury, scenario.ctx()
            );
            assert!(!state.mint_cap_for_local_token_exists(local_token_id), 0);
        };

        // Destroy objects
        test_utils::destroy(state);
        test_utils::destroy(treasury);
        test_utils::destroy(mint_cap);
        scenario.end();
    }

    /// === Test Helpers ===
    fun setup_mint_cap(mut scenario: Scenario): (Scenario, Treasury<TOKEN_CONTROLLER_TESTS>, MintCap<TOKEN_CONTROLLER_TESTS>) {
        let otw = test_utils::create_one_time_witness<TOKEN_CONTROLLER_TESTS>();
        let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
            otw,
            6,
            b"SYMBOL",
            b"NAME",
            b"",
            option::none(),
            true,
            scenario.ctx()
        );
        
        let mut treasury = treasury::new(
            treasury_cap, 
            deny_cap, 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx()
        );
        treasury.configure_new_controller(@0x1, @0x1, scenario.ctx());
        let deny_list = deny_list::new_for_testing(scenario.ctx());
        treasury.configure_minter(&deny_list, 1, scenario.ctx());
        scenario.next_tx(@0x1);
        let mint_cap = scenario.take_from_address<MintCap<TOKEN_CONTROLLER_TESTS>>(@0x1);
        test_utils::destroy(metadata);
        test_utils::destroy(deny_list);

        (scenario, treasury, mint_cap)
    }
}
