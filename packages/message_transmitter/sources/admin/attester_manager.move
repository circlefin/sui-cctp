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

/// Module: attester_manager
/// Admin functions for attester_manager functionality, including managing
/// signature threshold and enabled/disabled attesters.
module message_transmitter::attester_manager {
    // === Imports ===
    use sui::event::emit;
    use message_transmitter::{
      state::{State},
      version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    const EAttesterAlreadyEnabled: u64 = 0;
    const EAttesterNotEnabled: u64 = 1;
    const ENotAttesterManager: u64 = 2;
    const ETooFewAttestersEnabled: u64 = 3;
    const ETooFewEnabledAttesters: u64 = 4;
    const ESignatureThresholdAlreadySet: u64 = 5;
    const ESignatureThresholdTooHigh: u64 = 6;
    const EInvalidSignatureThreshold: u64 = 7;

    // === Events ===
    public struct SignatureThresholdUpdated has copy, drop {
        old_signature_threshold: u64,
        new_signature_threshold: u64
    }

    public struct AttesterEnabled has copy, drop {
        attester: address,
    }

    public struct AttesterDisabled has copy, drop {
        attester: address,
    }

    // === Admin Functions ===

    /// Called by the attester manager to enable a new attester.
    /// Requires that the new attester is currently not enabled.
    /// Calls a public(package) function so that this function can be 
    /// entry visibility while still allowing the initialize module to call enable_attester_internal.
    entry fun enable_attester(new_attester: address, state: &mut State, ctx: &TxContext) {
      enable_attester_internal(new_attester, state, ctx); 
    }

    /// Called by the attester manager to disable an attester.
    /// Requires that the attester is currently enabled. Disabling the attester is not allowed
    /// if there is only one attester enabled or if it would cause the number of attesters
    /// to become less than the signature threshold.
    entry fun disable_attester(attester: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_attester_manager(state, ctx);
      let num_enabled_attesters: u64 = state.get_num_enabled_attesters();
      assert!((num_enabled_attesters > 1), ETooFewAttestersEnabled);
      assert!((num_enabled_attesters > state.signature_threshold()), ETooFewEnabledAttesters);
      assert!(state.is_attester_enabled(attester), EAttesterNotEnabled);

      state.disable_attester(attester);
      emit(AttesterDisabled { attester });
    }

    /// Called by the attester manager to set the number of signatures required to attest to a message.
    /// Requires that the new signature threshold is nonzero, not equal to the current threshold, and
    /// does not exceed the number of enabled attesters.
    entry fun set_signature_threshold(new_signature_threshold: u64, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_attester_manager(state, ctx);
      assert!(new_signature_threshold != 0, EInvalidSignatureThreshold);
      assert!((new_signature_threshold <= state.get_num_enabled_attesters()), ESignatureThresholdTooHigh);
      assert!(new_signature_threshold != state.signature_threshold(), ESignatureThresholdAlreadySet);

      let old_signature_threshold = state.signature_threshold();
      state.set_signature_threshold(new_signature_threshold);
      emit(SignatureThresholdUpdated {old_signature_threshold, new_signature_threshold});
    }

    // === Public(Package) functions ===

    /// Called by the attester manager to enable a new attester.
    /// Requires that the new attester is currently not enabled.
    public(package) fun enable_attester_internal(new_attester: address, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      verify_attester_manager(state, ctx);
      assert!(!state.is_attester_enabled(new_attester), EAttesterAlreadyEnabled);

      state.enable_attester(new_attester);
      emit(AttesterEnabled { attester: new_attester });
    }

    // === Private Functions ===

    fun verify_attester_manager(state: &State, ctx: &TxContext) {
      assert!(ctx.sender() == state.roles().attester_manager(), ENotAttesterManager);
    }

    // === Test Functions ===
    #[test_only] use sui::{event::{num_events}, test_scenario, test_utils};
    #[test_only] use message_transmitter::{
      state,
      version_control
    };
    #[test_only] use sui_extensions::test_utils::last_event_by_type;

    // === Tests ===

    // enable_attester tests

    #[test]
    public fun test_enable_attester_successful() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, new_attester) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Successfully enabled attester
      scenario.next_tx(attester_manager);
      {
        enable_attester(new_attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(new_attester));
        assert!(num_events() == 1);
        assert!(last_event_by_type<AttesterEnabled>().attester == new_attester);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotAttesterManager)]
    public fun test_enable_attester_revert_not_attester_manager() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, non_attester_manager, new_attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the caller is not the attester manager
      scenario.next_tx(non_attester_manager);
      {
        enable_attester(new_attester, &mut state, scenario.ctx());
        assert!(!state.is_attester_enabled(new_attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EAttesterAlreadyEnabled)]
    public fun test_enable_attester_revert_already_enabled() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, new_attester) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the attester is already enabled
      scenario.next_tx(attester_manager);
      {
        enable_attester(new_attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(new_attester));
        enable_attester(new_attester, &mut state, scenario.ctx());
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_enable_attester_revert_incompatible_version() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, new_attester) = (@0x1, @0x2);

      // Create a new State instance with incompatible state
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());
      state.add_compatible_version(5);
      state.remove_compatible_version(version_control::current_version());

      // Test: Revert if the version is incompatible
      {
        enable_attester(new_attester, &mut state, scenario.ctx());
        assert!(!state.is_attester_enabled(new_attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    // disable_attester tests

    #[test]
    public fun test_disable_attester_successful() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, first_attester, second_attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Successfully disabled attester
      scenario.next_tx(attester_manager);
      {
        enable_attester(first_attester, &mut state, scenario.ctx());
        enable_attester(second_attester, &mut state, scenario.ctx());
        disable_attester(second_attester, &mut state, scenario.ctx());
        assert!(!state.is_attester_enabled(second_attester));
        assert!(num_events() == 3);
        assert!(last_event_by_type<AttesterDisabled>().attester == second_attester);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotAttesterManager)]
    public fun test_disable_attester_revert_not_attester_manager() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, non_attester_manager, attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Enable attesters
      scenario.next_tx(attester_manager);
      {
        enable_attester(attester, &mut state, scenario.ctx());
      };

      // Test: Revert if the caller is not the attester manager
      scenario.next_tx(non_attester_manager);
      {
        disable_attester(attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ETooFewAttestersEnabled)]
    public fun test_disable_attester_revert_too_few_attesters() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, attester) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if only one attester is enabled
      scenario.next_tx(attester_manager);
      {
        enable_attester(attester, &mut state, scenario.ctx());
        disable_attester(attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ETooFewEnabledAttesters)]
    public fun test_disable_attester_revert_too_few_enabled_attesters() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, first_attester, second_attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());
      state.set_signature_threshold(2);

      // Test: Revert if the number of attesters would go below the signature threshold
      scenario.next_tx(attester_manager);
      {
        enable_attester(first_attester, &mut state, scenario.ctx());
        enable_attester(second_attester, &mut state, scenario.ctx());
        disable_attester(second_attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(second_attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EAttesterNotEnabled)]
    public fun test_disable_attester_revert_attester_not_enabled() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, first_attester, second_attester, third_attester) = (@0x1, @0x2, @0x3, @0x4);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the attester is not enabled
      scenario.next_tx(attester_manager);
      {
        enable_attester(first_attester, &mut state, scenario.ctx());
        enable_attester(second_attester, &mut state, scenario.ctx());
        disable_attester(third_attester, &mut state, scenario.ctx());
        assert!(!state.is_attester_enabled(third_attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_disable_attester_revert_incompatible_version() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, attester) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Enable attester and change version
      scenario.next_tx(attester_manager);
      {
        enable_attester(attester, &mut state, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());
      };

      // Test: Revert for incompatible version
      {
        disable_attester(attester, &mut state, scenario.ctx());
        assert!(state.is_attester_enabled(attester));
      };

      test_utils::destroy(state);
      scenario.end();
    }

    // set_signature_threshold tests

    #[test]
    public fun test_set_signature_threshold_successful() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, first_attester, second_attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Successfully set new signature threshold
      scenario.next_tx(attester_manager);
      {
        enable_attester(first_attester, &mut state, scenario.ctx());
        enable_attester(second_attester, &mut state, scenario.ctx());
        set_signature_threshold(2, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 2);
        assert!(num_events() == 3);
        let event = last_event_by_type<SignatureThresholdUpdated>();
        assert!(event.old_signature_threshold == 1);
        assert!(event.new_signature_threshold == 2);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotAttesterManager)]
    public fun test_set_signature_threshold_revert_not_attester_manager() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, not_attester_manager) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the caller is not the attester manager
      scenario.next_tx(not_attester_manager);
      {
        set_signature_threshold(2, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 1);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidSignatureThreshold)]
    public fun test_set_signature_threshold_revert_invalid_signature_threshold() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager) = (@0x1);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the signature threshold is 0
      scenario.next_tx(attester_manager);
      {
        set_signature_threshold(0, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 1);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ESignatureThresholdTooHigh)]
    public fun test_set_signature_threshold_revert_signature_threshold_too_high() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, first_attester, second_attester) = (@0x1, @0x2, @0x3);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the signature threshold is too high
      scenario.next_tx(attester_manager);
      {
        enable_attester(first_attester, &mut state, scenario.ctx());
        enable_attester(second_attester, &mut state, scenario.ctx());
        set_signature_threshold(3, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 1);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ESignatureThresholdAlreadySet)]
    public fun test_set_signature_threshold_revert_signature_threshold_already_set() {
      let mut scenario = test_scenario::begin(@0x0);
      let (attester_manager, attester) = (@0x1, @0x2);

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

      // Test: Revert if the signature threshold is already set
      scenario.next_tx(attester_manager);
      {
        enable_attester(attester, &mut state, scenario.ctx());
        set_signature_threshold(1, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 1);
      };

      test_utils::destroy(state);
      scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_set_signature_threshold_revert_incompatible_version() {
      let mut scenario = test_scenario::begin(@0x0);
      let attester_manager = @0x1;

      // Create a new State instance
      let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());
      state.add_compatible_version(5);
      state.remove_compatible_version(version_control::current_version());

      // Test: Revert for incompatible version
      scenario.next_tx(attester_manager);
      {
        set_signature_threshold(2, &mut state, scenario.ctx());
        assert!(state.signature_threshold() == 1);
      };

      test_utils::destroy(state);
      scenario.end();
    }
 }
