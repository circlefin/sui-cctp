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

/// Module: message_size
/// Admin functions for contract message size management functionality
module message_transmitter::message_size {
    // === Imports ===
    use sui::event::emit;
    use message_transmitter::{
      state::{State},
      version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    const ENotOwner: u64 = 0;

    // === Events ===
    public struct MaxMessageBodySizeUpdated has copy, drop {
      new_max_message_body_size: u64,
    }

    // === Admin Functions ===

    /// Called by the owner to update the `max_message_body_size`.
    entry fun set_max_message_body_size(new_max_message_body_size: u64, state: &mut State, ctx: &TxContext) {
      assert_object_version_is_compatible_with_package(state.compatible_versions());
      assert!(ctx.sender() == state.roles().owner(), ENotOwner);

      state.set_max_message_body_size(new_max_message_body_size);
      emit(MaxMessageBodySizeUpdated{new_max_message_body_size});
    }

    // === Tests ===

    #[test_only] use sui::{event::{num_events}, test_scenario, test_utils};
    #[test_only] use message_transmitter::{
      state::{Self},
      version_control
    };
    #[test_only] use sui_extensions::test_utils::last_event_by_type;

    #[test]
    public fun test_set_max_message_body_size_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner) = (@0x1);

        // Create a new State instance
        let mut state = state::new(0, 0, 0, owner, scenario.ctx());

        // Test: Successful update of max message body size
        scenario.next_tx(owner);
        {
          set_max_message_body_size(100, &mut state, scenario.ctx());
          assert!(state.max_message_body_size() == 100);
          assert!(num_events() == 1);
          assert!(last_event_by_type<MaxMessageBodySizeUpdated>().new_max_message_body_size == 100);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotOwner)]
    public fun test_set_max_message_body_size_revert_not_owner() {
        let mut scenario = test_scenario::begin(@0x0);
        let (owner, non_owner) = (@0x1, @0x2);

        // Create a new State instance
        let mut state = state::new(0, 0, 0, owner, scenario.ctx());

        // Test: Revert if the caller is not the owner
        scenario.next_tx(non_owner);
        {
          set_max_message_body_size(100, &mut state, scenario.ctx());
          assert!(state.max_message_body_size() == 0);
        };

        test_utils::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_set_max_message_body_size_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let owner = @0x1;

        // Create a new State instance with incompatible version
        let mut state = state::new(0, 0, 0, owner, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        // Test: Revert for incompatible version
        scenario.next_tx(owner);
        {
          set_max_message_body_size(100, &mut state, scenario.ctx());
          assert!(state.max_message_body_size() == 0);
        };

        test_utils::destroy(state);
        scenario.end();
    }
}
