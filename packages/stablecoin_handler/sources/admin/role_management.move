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

/// Module: role_management
/// StablecoinHandler role management: owner two-step transfer, plus owner
/// rotation of the single-address `mint_controller` role.
module stablecoin_handler::role_management {
    // === Imports ===
    use sui::event;
    use stablecoin_handler::{
        state::{State},
        version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    /// Caller is not the owner.
    const ENotOwner: u64 = 0;
    /// The new role address equals the current one (no-op rotation).
    const ERoleAlreadySet: u64 = 1;
    /// The new role address is the zero address.
    const EInvalidRoleAddress: u64 = 2;

    // === Events ===
    public struct MintControllerChanged has copy, drop { new_mint_controller: address }

    // === Admin Functions ===

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

    /// Owner-only. Rotates the `mint_controller` role (the key authorized to
    /// add/remove the handler's `MintCap` via `mint_controller`).
    entry fun update_mint_controller(new_mint_controller: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      assert!(state.roles().owner() == ctx.sender(), ENotOwner);
      assert!(new_mint_controller != @0x0, EInvalidRoleAddress);
      assert!(new_mint_controller != state.roles().mint_controller(), ERoleAlreadySet);

      state.roles_mut().update_mint_controller(new_mint_controller);
      event::emit(MintControllerChanged { new_mint_controller });
    }

    // === Test Functions ===

    #[test_only]
    public(package) fun create_mint_controller_changed_event(new_mint_controller: address): MintControllerChanged {
      MintControllerChanged { new_mint_controller }
    }

    #[test_only] use sui::{
      event::{num_events},
      test_scenario::{Self, Scenario},
    };
    #[test_only] use std::unit_test;
    #[test_only] use sui_extensions::test_utils::last_event_by_type;
    #[test_only] use stablecoin_handler::{
      state::{Self},
      version_control
    };

    #[test_only] const OWNER: address = @0x123;

    #[test_only]
    fun setup(): (Scenario, State) {
      let mut scenario = test_scenario::begin(@0x0);
      let state = state::new(OWNER, scenario.ctx());

      (scenario, state)
    }

    // transfer_ownership tests

    #[test]
    public fun test_transfer_ownership_successful() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        scenario.next_tx(OWNER);
        {
          transfer_ownership(new_owner, &mut state, scenario.ctx());
          assert!(*state.roles().pending_owner().borrow() == new_owner);
          assert!(state.roles().owner() == OWNER);
          assert!(num_events() == 1);
        };

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_transfer_ownership_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        {
          transfer_ownership(new_owner, &mut state, scenario.ctx());
        };

        unit_test::destroy(state);
        scenario.end();
    }

    // accept_ownership tests

    #[test]
    public fun test_accept_ownership_successful() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        scenario.next_tx(OWNER);
        transfer_ownership(new_owner, &mut state, scenario.ctx());

        scenario.next_tx(new_owner);
        {
          accept_ownership(&mut state, scenario.ctx());
          assert!(state.roles().owner() == new_owner);
          assert!(state.roles().pending_owner() == option::none());
          assert!(num_events() == 1);
        };

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_accept_ownership_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        let new_owner = @0x2;

        scenario.next_tx(OWNER);
        transfer_ownership(new_owner, &mut state, scenario.ctx());

        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(new_owner);
        {
          accept_ownership(&mut state, scenario.ctx());
        };

        unit_test::destroy(state);
        scenario.end();
    }

    // update_mint_controller tests

    #[test]
    public fun test_update_mint_controller_successful() {
        let (mut scenario, mut state) = setup();
        let new_mint_controller = @0x2;

        // Defaults to the deployer (OWNER) at init.
        assert!(state.roles().mint_controller() == OWNER);

        scenario.next_tx(OWNER);
        {
          update_mint_controller(new_mint_controller, &mut state, scenario.ctx());
          assert!(state.roles().mint_controller() == new_mint_controller);
          assert!(num_events() == 1);
          assert!(last_event_by_type<MintControllerChanged>() == create_mint_controller_changed_event(new_mint_controller));
        };

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotOwner)]
    public fun test_update_mint_controller_revert_not_owner() {
        let (mut scenario, mut state) = setup();

        // A non-owner (even the mint_controller itself) cannot rotate the role.
        scenario.next_tx(@0x2);
        update_mint_controller(@0x3, &mut state, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidRoleAddress)]
    public fun test_update_mint_controller_revert_zero_address() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        update_mint_controller(@0x0, &mut state, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ERoleAlreadySet)]
    public fun test_update_mint_controller_revert_already_set() {
        let (mut scenario, mut state) = setup();

        // mint_controller defaults to OWNER; rotating it to the same address is
        // a no-op and must abort.
        scenario.next_tx(OWNER);
        update_mint_controller(OWNER, &mut state, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_update_mint_controller_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        update_mint_controller(@0x2, &mut state, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }
}
