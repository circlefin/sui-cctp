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

/// Module: remote_token_messenger
/// Admin functions for controlling remote token messenger, including 
/// adding/removing the remote token messenger for a remote domain.
module token_messenger_minter::remote_token_messenger {
      // === Imports ===
    use sui::event::emit;
    use token_messenger_minter::{
        state::{State},
        version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    const ENotOwner: u64 = 0;
    const EEmptyAddress: u64 = 1;
    const ERemoteTokenMessengerAlreadyAdded: u64 = 2;
    const ERemoteTokenMessengerNotAdded: u64 = 3;

    // === Events ===

    public struct RemoteTokenMessengerAdded has copy, drop {
        domain: u32,
        token_messenger: address,
    }

    public struct RemoteTokenMessengerRemoved has copy, drop {
        domain: u32,
        token_messenger: address,
    }

    // === Admin Functions ===

    /// Links a pair of remote domain and remote token messenger. Adds a 
    /// (remote_domain, remote_token_messenger) pair by updating `remote_token_messengers` 
    /// mapping. A remote domain can only map to one remote token messenger. 
    /// Remote token messenger is the 32 byte hex representation of the token messenger on the remote chain.
    entry fun add_remote_token_messenger(
        remote_domain: u32, 
        remote_token_messenger: address, 
        state: &mut State, 
        ctx: &TxContext
    ) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_owner(state, ctx);
      assert!(remote_token_messenger != @0x0, EEmptyAddress);
      assert!(!state.remote_token_messenger_for_remote_domain_exists(remote_domain), ERemoteTokenMessengerAlreadyAdded);

      state.add_remote_token_messenger(remote_domain, remote_token_messenger);
      emit(RemoteTokenMessengerAdded {domain: remote_domain, token_messenger: remote_token_messenger});
    }

    /// Unlinks a pair of remote domain and remote token messenger. Adds a 
    /// (remote_domain, remote_token_messenger) pair by updating `remote_token_messengers` 
    /// mapping. A remote domain can only map to one remote token messenger. 
    /// Remote token messenger is the 32 byte hex representation of the token messenger on the remote chain.
    entry fun remove_remote_token_messenger(
        remote_domain: u32, 
        state: &mut State, 
        ctx: &TxContext
    ) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_owner(state, ctx);
      assert!(state.remote_token_messenger_for_remote_domain_exists(remote_domain), ERemoteTokenMessengerNotAdded);

      let remote_token_messenger_to_remove = state.remote_token_messenger_from_remote_domain(remote_domain);
      state.remove_remote_token_messenger(remote_domain);
      emit(RemoteTokenMessengerRemoved {domain: remote_domain, token_messenger: remote_token_messenger_to_remove});
    }

    // === Private Functions ===
    fun verify_owner(state: &State, ctx: &TxContext) {
      assert!(ctx.sender() == state.roles().owner(), ENotOwner);
    }

    // === Test Functions ===
    #[test_only] use sui::{
        event::{num_events}, 
        test_scenario::{Self}, 
        test_utils::{Self, assert_eq}
    };
    #[test_only] use sui_extensions::test_utils::{last_event_by_type};
    #[test_only] use token_messenger_minter::{
        remote_token_messenger::{Self},
        state::{Self}, 
        version_control
    };

    // === Tests ===

    // add_remote_token_messenger tests

    #[test]
    public fun test_add_remote_token_messenger_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, remote_token_messenger) = (@0x1, @0x2);
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, owner, scenario.ctx());

        // Test: Successful adding remote token messenger
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert_eq(state.remote_token_messenger_from_remote_domain(remote_domain), remote_token_messenger);
            assert!(num_events() == 1);
            let event = last_event_by_type<RemoteTokenMessengerAdded>();
            assert!(event.domain == remote_domain);
            assert!(event.token_messenger == remote_token_messenger);
        };

        // Destroy objects
        state.remove_remote_token_messenger(remote_domain);
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = remote_token_messenger::ENotOwner)]
    public fun test_add_remote_token_messenger_revert_not_owner() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, non_owner, remote_token_messenger) = (@0x1, @0x2, @0x3);
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, owner, scenario.ctx());

        // Test: Revert if the caller is not the owner
        scenario.next_tx(non_owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert!(!state.remote_token_messenger_for_remote_domain_exists(remote_domain), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = remote_token_messenger::EEmptyAddress)]
    public fun test_add_remote_token_messenger_revert_empty_address() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, remote_token_messenger) = (@0x1, @0x0);
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, owner, scenario.ctx());

        // Test: Revert if the remote token messenger is empty
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert!(!state.remote_token_messenger_for_remote_domain_exists(remote_domain), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = remote_token_messenger::ERemoteTokenMessengerAlreadyAdded)]
    public fun test_remote_token_messenger_revert_already_added() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, remote_token_messenger) = (@0x1, @0x2);
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, owner, scenario.ctx());

        // Add the remote token messenger for the first time
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert!(state.remote_token_messenger_for_remote_domain_exists(remote_domain), 0);
        };

        // Attempt to add the same remote token messenger again
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
        };

        // Destroy state and scenario
        state.remove_remote_token_messenger(remote_domain);
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_add_remote_token_messenger_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, remote_token_messenger) = (@0x1, @0x2);
        let remote_domain = 1;

        // Create a new State instance 
        let mut state = state::new(1, owner, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert!(!state.remote_token_messenger_for_remote_domain_exists(remote_domain), 0);
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    // remove_remote_token_messenger tests

    #[test]
    public fun test_remove_token_messenger_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, remote_token_messenger) = (@0x1, @0x2);
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, owner, scenario.ctx());

        // Add remote token messenger first
        scenario.next_tx(owner);
        {
            remote_token_messenger::add_remote_token_messenger(remote_domain, remote_token_messenger, &mut state, scenario.ctx());
            assert_eq(state.remote_token_messenger_from_remote_domain(remote_domain), remote_token_messenger);
        };

        // Test: Successful removing of remote token messenger
        {
            remote_token_messenger::remove_remote_token_messenger(
                remote_domain, &mut state, scenario.ctx()
            );
            // Validate the local token was removed 
            assert!(!state.remote_token_messenger_for_remote_domain_exists(remote_domain), 1);
            assert!(num_events() == 2);
            let event = last_event_by_type<RemoteTokenMessengerRemoved>();
            assert!(event.domain == remote_domain);
            assert!(event.token_messenger == remote_token_messenger);
        };

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = remote_token_messenger::ENotOwner)]
    public fun test_remove_remote_token_messenger_revert_not_owner() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, non_owner) = (@0x1, @0x2);
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, owner, scenario.ctx());

        // Test: Revert if the caller is not the owner
        scenario.next_tx(non_owner);
        remote_token_messenger::remove_remote_token_messenger(
            remote_domain, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = remote_token_messenger::ERemoteTokenMessengerNotAdded)]
    public fun test_remove_remote_token_messenger_revert_not_added() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner) = (@0x1);
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, owner, scenario.ctx());

        // Attempt to remove without adding
        scenario.next_tx(owner);
        remote_token_messenger::remove_remote_token_messenger(
            remote_domain, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_remove_remote_token_messenger_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let owner = @0x1;
        let remote_domain = 1;

        // Create a new State instance
        let mut state = state::new(1, owner, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incomaptible version
        scenario.next_tx(owner);
        remote_token_messenger::remove_remote_token_messenger(
            remote_domain, &mut state, scenario.ctx()
        );

        // Destroy objects
        test_utils::destroy(state);
        scenario.end();
    }
}
