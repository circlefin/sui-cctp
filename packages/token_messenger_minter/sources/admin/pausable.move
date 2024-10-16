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

/// Module: pausable
/// Admin functions for contract pause functionality
module token_messenger_minter::pausable {
    // === Imports ===
    use sui::event::emit;
    use token_messenger_minter::{
      state::{State},
      version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    const ENotPauser: u64 = 0;
    const EAlreadyPaused: u64 = 1;
    const ENotPaused: u64 = 2;

    // === Events ===
    public struct Pause has copy, drop {}

    public struct Unpause has copy, drop {}

    // === Admin Functions ===
    
    /// Called by the owner to pause the contract by setting paused 
    /// to true. Only pauses functions that check this `paused` value.
    entry fun pause(state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_pauser(state, ctx);
      assert!(!state.paused(), EAlreadyPaused);

      state.set_paused(true);
      emit(Pause {});
    }

    /// Called by the owner to unpause the contract by setting paused 
    /// to false. Only pauses functions that check this `paused` value.
    entry fun unpause(state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_pauser(state, ctx);
      assert!(state.paused(), ENotPaused);

      state.set_paused(false);
      emit(Unpause {});
    }

    // === Private Functions ===
    
    fun verify_pauser(state: &State, ctx: &TxContext) {
      assert!(ctx.sender() == state.roles().pauser(), ENotPauser);
    }

    // === Test Functions ===
    #[test_only] use sui::{
      event::{num_events},
      test_scenario,
      test_utils
    };
    #[test_only] use sui_extensions::test_utils::{last_event_by_type};
    #[test_only] use token_messenger_minter::{
      state::{Self},
      version_control
    };

    // pause tests

    #[test]
    public fun test_pause_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);

        // Test: Successful pause from pauser
        scenario.next_tx(pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(state.paused(), 1);
          assert!(num_events() == 1);
          last_event_by_type<Pause>();
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotPauser)]
    public fun test_pause_not_pauser() {
        let mut scenario = test_scenario::begin(@0x0);
        let (pauser, not_pauser) = (@0x1, @0x2);

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);

        // Test: Revert if not called from pauser
        scenario.next_tx(not_pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(!state.paused(), 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EAlreadyPaused)]
    public fun test_pause_already_paused() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);

        // Test: Revert if already paused
        scenario.next_tx(pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(state.paused(), 1);
          pause(&mut state, scenario.ctx());
        };

        test_utils::destroy(state);
        scenario.end();
    }


    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_pause_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State with incompatible version
        let mut state = state::new(0, pauser, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert if incompatible version
        scenario.next_tx(pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(!state.paused(), 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    // unpause tests

    #[test]
    public fun test_unpause_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);

        // Test: Successful unpause from pauser
        scenario.next_tx(pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(state.paused(), 1);
          unpause(&mut state, scenario.ctx());
          assert!(!state.paused(), 2);
          assert!(num_events() == 2);
          last_event_by_type<Unpause>();
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotPauser)]
    public fun test_unpause_not_pauser() {
        let mut scenario = test_scenario::begin(@0x0);
        let (pauser, not_pauser) = (@0x1, @0x2);

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);
        // Pause the tx so we can test unpausing
        scenario.next_tx(pauser);
        {
          pause(&mut state, scenario.ctx());
          assert!(state.paused(), 1);
        };

        // Test: Revert if not called from pauser
        scenario.next_tx(not_pauser);
        {
          unpause(&mut state, scenario.ctx());
          assert!(state.paused(), 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotPaused)]
    public fun test_unpause_already_unpaused() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State
        let mut state = state::new(0, pauser, scenario.ctx());
        // Starts out not paused
        assert!(!state.paused(), 0);

        // Test: Revert if already unpaused
        scenario.next_tx(pauser);
        {
          unpause(&mut state, scenario.ctx());
          assert!(!state.paused(), 1);
        };

        test_utils::destroy(state);
        scenario.end();
    }


    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_unpause_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let pauser = @0x1;

        // Create a new State with incompatible version
        let mut state = state::new(0, pauser, scenario.ctx());
        state.set_paused(true);
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert if incompatible version
        scenario.next_tx(pauser);
        {
          unpause(&mut state, scenario.ctx());
          assert!(state.paused());
        };

        test_utils::destroy(state);
        scenario.end();
    }
}
