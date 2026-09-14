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

/// Module: token_controller
/// Admin surface for local/remote token pairs and per-token burn
/// limits. `T` is any `T: drop` witness. After the handler
/// decoupling, this module has no stablecoin dependency; production
/// `T` is currently a
/// [stablecoin](https://github.com/circlefin/stablecoin-sui/tree/master/packages/stablecoin)
/// coin witness, but the config surface is stablecoin-agnostic.
module token_messenger_minter_v2::token_controller {
    // === Imports ===
    use sui::event::emit;
    use token_messenger_minter_v2::{
        state::{State},
        token_utils,
        version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Errors ===
    // Numbering gaps at 4, 5, 6 (`EMintCap*`) retired with the
    // handler decoupling; do not reuse.
    const ENotTokenController: u64 = 0;
    const EEmptyAddress: u64 = 1;
    const ETokenPairAlreadyLinked: u64 = 2;
    const ETokenPairNotLinked: u64 = 3;
    /// `T` does not match the local token currently linked to the
    /// given `(remote_domain, remote_token)` pair. Mirrors
    /// `handle_receive_message::EInvalidTokenType`.
    const EInvalidTokenType: u64 = 7;
    // Code 8 is reserved and must not be reused. Setting the limit to 0 is the
    // supported way to disable burns for a token; see
    // `set_max_burn_amount_per_message` below.

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

    // === Admin Functions ===

    /// Sets (or overwrites) the per-message burn limit for `T`. Passing 0
    /// disables all future burns for `T`: `deposit_for_burn` reads the limit
    /// via `safe_get_burn_limit` and asserts `burn_limit >= amount`, and
    /// amounts are always > 0 (enforced by `EZeroAmount`), so a stored 0
    /// rejects every burn with `EBurnLimitExceeded`. This gives the token
    /// controller a way to pause burns for a specific `T` without unlinking
    /// remote pairs or deregistering the handler; call again with a positive
    /// value to re-enable. Only affects burns; existing minted tokens remain
    /// mintable if the limit is later reduced.
    ///
    /// Note the distinction between "limit is 0" (map entry present, burns
    /// intentionally disabled -> `EBurnLimitExceeded`) and "limit not set"
    /// (map entry absent, likely a misconfiguration -> `EMissingBurnLimit`).
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

    /// Links `(remote_domain, remote_token)` to `T`'s local token id.
    /// Many remote tokens can map to one local; each remote maps to
    /// only one local. Does NOT enable the local token; call
    /// `set_max_burn_amount_per_message` for that. `remote_token` is
    /// the 32-byte hex address on the remote chain.
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

    /// Unlinks `(remote_domain, remote_token)` from its local token.
    /// `T` must be the local token the pair is currently linked to;
    /// a mismatch aborts with `EInvalidTokenType` and unlinks nothing.
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
      let local_token_id = token_utils::calculate_token_id<T>();
      assert!(local_token_id == state.local_token_from_remote_token(remote_domain, remote_token), EInvalidTokenType);
      state.remove_local_token_for_remote_token(remote_domain, remote_token);
      emit(TokenPairUnlinked {local_token: local_token_id, remote_domain, remote_token});
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
}

#[test_only]
module token_messenger_minter_v2::token_controller_tests {
    use sui::{
        event::{num_events},
        test_scenario::{Self},
    };
    use std::unit_test::{Self, assert_eq};
    use sui_extensions::test_utils::{last_event_by_type};
    use token_messenger_minter_v2::{
        invalid_test_token::INVALID_TEST_TOKEN,
        state::{Self},
        token_utils::{Self},
        token_controller::{
            Self,
            SetBurnLimitPerMessage,
            TokenPairUnlinked,
            TokenPairLinked,
            create_set_burn_limit_per_message_event,
            create_token_pair_linked_event,
            create_token_pair_unlinked_event,
        },
        version_control
    };

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
            assert_eq!(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message);
            assert!(num_events() == 1);
            assert!(last_event_by_type<SetBurnLimitPerMessage>() == create_set_burn_limit_per_message_event(local_token_id, burn_limit_per_message));
        };

        state.remove_burn_limit(local_token_id);
        unit_test::destroy(state);
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
        assert_eq!(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message + 100);

        // Test: Successful setting of max burn amount per message with existing limit
        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(burn_limit_per_message, &mut state, scenario.ctx());
            assert_eq!(state.burn_limit_from_token_id(local_token_id), burn_limit_per_message);
            assert!(num_events() == 1);
            assert!(last_event_by_type<SetBurnLimitPerMessage>() == create_set_burn_limit_per_message_event(local_token_id, burn_limit_per_message));
        };

        state.remove_burn_limit(local_token_id);
        unit_test::destroy(state);
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
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    /// Setting the limit to 0 is the supported way to disable burns for a
    /// token. It succeeds, stores 0 in the map, and emits `SetBurnLimitPerMessage`
    /// with `burn_limit_per_message = 0`. The subsequent burn-time block is
    /// exercised in `deposit_for_burn_tests`.
    public fun test_set_max_burn_amount_per_message_zero_disables_burns() {
        let mut scenario = test_scenario::begin(@0x0);
        let local_token_id = token_utils::calculate_token_id<TOKEN_CONTROLLER_TESTS>();
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());

        scenario.next_tx(TOKEN_CONTROLLER);
        {
            token_controller::set_max_burn_amount_per_message<TOKEN_CONTROLLER_TESTS>(0, &mut state, scenario.ctx());
            assert!(state.burn_limit_for_token_id_exists(local_token_id));
            assert_eq!(state.burn_limit_from_token_id(local_token_id), 0);
            assert!(num_events() == 1);
            assert!(last_event_by_type<SetBurnLimitPerMessage>() == create_set_burn_limit_per_message_event(local_token_id, 0));
        };

        state.remove_burn_limit(local_token_id);
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
            assert_eq!(state.local_token_from_remote_token(remote_domain, remote_token), local_token_id);
            assert!(num_events() == 1);
            assert!(last_event_by_type<TokenPairLinked>() == create_token_pair_linked_event(local_token_id, remote_domain, remote_token));
        };

        // Destroy objects
        state.remove_local_token_for_remote_token(remote_domain, remote_token);
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
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
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = token_controller::EInvalidTokenType)]
    public fun test_unlink_token_pair_revert_invalid_token_type() {
        let mut scenario = test_scenario::begin(@0x0);
        let remote_token = @0x2;
        let remote_domain = 1;

        // Create a new State instance and link the pair to TOKEN_CONTROLLER_TESTS
        let mut state = state::new(1, TOKEN_CONTROLLER, scenario.ctx());
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::link_token_pair<TOKEN_CONTROLLER_TESTS>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Test: Revert when unlinking with a type that is not the linked local token
        scenario.next_tx(TOKEN_CONTROLLER);
        token_controller::unlink_token_pair<INVALID_TEST_TOKEN>(
            remote_domain, remote_token, &mut state, scenario.ctx()
        );

        // Destroy objects
        unit_test::destroy(state);
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
        unit_test::destroy(state);
        scenario.end();
    }

    // (Tests for `add_stablecoin_mint_cap` / `remove_stablecoin_mint_cap`
    // retired with the handler decoupling; TMM no longer stores
    // `MintCap<T>`.)
}
