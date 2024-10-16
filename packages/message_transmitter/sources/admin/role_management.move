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

/// Module: role_management
/// MessageTransmitter role management functions
module message_transmitter::role_management {
    // === Imports ===
    use sui::event::emit;
    use message_transmitter::{
      state::{State},
      version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    const ERoleAlreadySet: u64 = 0;

    // === Events ===
    public struct AttesterManagerUpdated has copy, drop {
        previous_attester_manager: address,
        new_attester_manager: address
    }

    public struct PauserChanged has copy, drop {
        new_pauser: address,
    }

    // === Admin Functions ===

    /// Called by the owner to update the `pauser` role.
    entry fun update_pauser(new_pauser: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      validate_role_transfer(new_pauser, state.roles().pauser(), state, ctx);

      state.roles_mut().update_pauser(new_pauser);
      emit(PauserChanged {new_pauser: state.roles().pauser()});
    }

    /// Called by the owner to update the `attester_manager` role.
    entry fun update_attester_manager(new_attester_manager: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      validate_role_transfer(new_attester_manager, state.roles().attester_manager(), state, ctx);
      let previous_attester_manager = state.roles().attester_manager();

      state.roles_mut().update_attester_manager(new_attester_manager);
      emit(AttesterManagerUpdated {previous_attester_manager, new_attester_manager: state.roles().attester_manager()});
    }

    /// Proxy call to start ownership transfer
    entry fun transfer_ownership(new_owner: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      state.roles_mut().owner_role_mut().begin_role_transfer(new_owner, ctx);
    }

    /// Proxy call to accept ownership transfer
    entry fun accept_ownership(state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      state.roles_mut().owner_role_mut().accept_role(ctx);
    }

    // === Private Functions ===
    
    fun validate_role_transfer(new_address: address, current_address: address, state: &State, ctx: &TxContext) {
      state.roles().owner_role().assert_sender_is_active_role(ctx);
      assert!(new_address != current_address, ERoleAlreadySet)
    }

    // === Tests ===
    #[test_only] use sui::{
      event::{num_events}, 
      test_scenario::{Self, Scenario}, 
      test_utils
    };
    #[test_only] use message_transmitter::{
      state::{Self},
      version_control
    };
    #[test_only] use sui_extensions::{
      test_utils::{last_event_by_type},
      two_step_role
    };

    #[test_only] const OWNER: address = @0x123;

    #[test_only]
    fun setup(): (Scenario, State) {
      let mut scenario = test_scenario::begin(@0x0);
      let state = state::new(0, 0, 0, OWNER, scenario.ctx());

      (scenario, state)
    }

    // update_pauser tests

    #[test]
    public fun test_update_pauser_successful() {
        let (mut scenario, mut state) = setup();
        let new_pauser = @0x2;

        // Test: Successful update of pauser
        scenario.next_tx(OWNER);
        {
          update_pauser(new_pauser, &mut state, scenario.ctx());
          assert!(state.roles().pauser() == new_pauser);
          assert!(num_events() == 1);
          assert!(last_event_by_type<PauserChanged>().new_pauser == new_pauser);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    public fun test_update_pauser_revert_not_owner() {
        let (mut scenario, mut state) = setup();
        let (non_owner, new_pauser) = (@0x2, @0x3);

        // Test: Revert if the caller is not the owner
        scenario.next_tx(non_owner);
        {
          update_pauser(new_pauser, &mut state, scenario.ctx());
          assert!(state.roles().pauser() == OWNER);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test] 
    #[expected_failure(abort_code = ERoleAlreadySet)]
    public fun test_update_pauser_revert_already_set() {
        let (mut scenario, mut state) = setup();

        // Test: Revert if the new pauser address is the same as existing
        scenario.next_tx(OWNER);
        {
          update_pauser(state.roles().pauser(), &mut state, scenario.ctx());
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_update_pauser_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        let new_pauser = @0x2;
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert if incompatible version
        scenario.next_tx(OWNER);
        {
          update_pauser(new_pauser, &mut state, scenario.ctx());
          assert!(state.roles().pauser() == OWNER);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    // update_attester_manager tests

    #[test]
    public fun test_update_attester_manager_successful() {
        let (mut scenario, mut state) = setup();
        let new_attester_manager = @0x2;

        // Test: Successful update of attester_manager
        scenario.next_tx(OWNER);
        {
          update_attester_manager(new_attester_manager, &mut state, scenario.ctx());
          assert!(state.roles().attester_manager() == new_attester_manager, 0);
          assert!(num_events() == 1);
          let event = last_event_by_type<AttesterManagerUpdated>();
          assert!(event.previous_attester_manager == OWNER);
          assert!(event.new_attester_manager == new_attester_manager);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    public fun test_update_attester_manager_revert_not_owner() {
        let (mut scenario, mut state) = setup();
        let (non_owner, new_attester_manager) = (@0x2, @0x3);

        // Test: Revert if the caller is not the owner
        scenario.next_tx(non_owner);
        {
          update_attester_manager(new_attester_manager, &mut state, scenario.ctx());
          assert!(state.roles().attester_manager() == OWNER);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ERoleAlreadySet)]
    public fun test_update_attester_manager_revert_already_set() {
        let (mut scenario, mut state) = setup();

        // Test: Revert if the new attester_manager address is the same as existing
        scenario.next_tx(OWNER);
        {
          update_attester_manager(state.roles().attester_manager(), &mut state, scenario.ctx());
        };

        // Destroy state and scenario
        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_update_attester_manager_revert_incompatible_version() {
        let new_attester_manager = @0x2;
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert with incompatible version
        scenario.next_tx(OWNER);
        {
          update_attester_manager(new_attester_manager, &mut state, scenario.ctx());
          assert!(state.roles().attester_manager() == OWNER);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    // transfer_ownership tests

    #[test]
    public fun test_transfer_ownership_successful() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        // Test: Successful start transfer of ownership
        scenario.next_tx(OWNER);
        {
          transfer_ownership(new_owner, &mut state, scenario.ctx());
          assert!(*state.roles().pending_owner().borrow() == new_owner);
          assert!(state.roles().owner() == OWNER);
          // Event fields tested in two_step_role module
          assert!(num_events() == 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_transfer_ownership_revert__incompatible_version() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        scenario.next_tx(OWNER);
        {
          transfer_ownership(new_owner, &mut state, scenario.ctx());
          assert!(state.roles().pending_owner() == option::none());
          assert!(state.roles().owner() == OWNER);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    // accept_ownership tests

    #[test]
    public fun test_accept_ownership_successful() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        // Start transfer ownership first
        scenario.next_tx(OWNER);
        transfer_ownership(new_owner, &mut state, scenario.ctx());

        // Test: Successfully accept/transfer ownership
        scenario.next_tx(new_owner);
        {
          accept_ownership(&mut state, scenario.ctx());
          assert!(state.roles().owner() == new_owner);
          assert!(state.roles().pending_owner() == option::none());
          // Events tested in two_step_role module
          assert!(num_events() == 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
     #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_accept_ownership__incompatible_version() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        // Start transfer ownership first
        scenario.next_tx(OWNER);
        transfer_ownership(new_owner, &mut state, scenario.ctx());

        // Update version to incompatible
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        scenario.next_tx(new_owner);
        {
          accept_ownership(&mut state, scenario.ctx());
          assert!(state.roles().owner() == OWNER);
          assert!(state.roles().pending_owner() == option::some(new_owner));
        };

        test_utils::destroy(state);
        scenario.end();
    }
}
