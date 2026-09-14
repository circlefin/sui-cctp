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

/// Module: rescuable
/// Entry wrapper for rescuing coins stranded at the State object's address.
module message_transmitter_v2::rescuable {
    // === Imports ===
    use sui::{
        coin::Coin,
        transfer::Receiving,
    };
    use message_transmitter_v2::{
        state::{State},
        version_control::{assert_object_version_is_compatible_with_package}
    };

    // === Admin Functions ===

    /// Rescues coins stranded at the State object's address and transfers them to the recipient.
    /// Can only be called by the current rescuer; aborts with `ENotRescuer` otherwise.
    entry fun rescue_tokens<T>(
        state: &mut State,
        coin_to_receive: Receiving<Coin<T>>,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.rescue_coin(coin_to_receive, recipient, amount, ctx);
    }

    // === Tests ===
    #[test_only] use sui::{
        coin,
        test_scenario::{Self},
    };
    #[test_only] use std::unit_test;
    #[test_only] use message_transmitter_v2::{
        state::{Self},
        version_control
    };
    #[test_only] use cctp_extensions::rescuable;

    #[test_only]
    public struct TEST_COIN has drop {}

    #[test_only] const RESCUER: address = @0x111;
    #[test_only] const RECIPIENT: address = @0x222;

    #[test_only]
    fun setup_state(scenario: &mut test_scenario::Scenario): State {
        state::new_for_testing(0, 1, 10000, RESCUER, scenario.ctx())
    }

    #[test]
    fun test_rescue_tokens_successful() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut mt_state = setup_state(&mut scenario);
        let state_addr = object::id_address(&mt_state);
        let coin_amount = 1_000_000u64;

        let coin = coin::mint_for_testing<TEST_COIN>(coin_amount, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, state_addr);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_COIN>>(coin_id);
        rescue_tokens<TEST_COIN>(&mut mt_state, ticket, RECIPIENT, coin_amount, scenario.ctx());

        scenario.next_tx(RESCUER);
        let rescued = scenario.take_from_address<Coin<TEST_COIN>>(RECIPIENT);
        assert!(rescued.value() == coin_amount);

        coin::burn_for_testing(rescued);
        unit_test::destroy(mt_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = rescuable::ENotRescuer)]
    fun test_rescue_tokens_revert_not_rescuer() {
        let non_rescuer = @0x999;
        let mut scenario = test_scenario::begin(RESCUER);
        let mut mt_state = setup_state(&mut scenario);
        let state_addr = object::id_address(&mt_state);

        let coin = coin::mint_for_testing<TEST_COIN>(1_000, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, state_addr);

        scenario.next_tx(non_rescuer);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_COIN>>(coin_id);
        rescue_tokens<TEST_COIN>(&mut mt_state, ticket, RECIPIENT, 1_000, scenario.ctx());

        unit_test::destroy(mt_state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_rescue_tokens_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut mt_state = setup_state(&mut scenario);
        let state_addr = object::id_address(&mt_state);

        mt_state.add_compatible_version(5);
        mt_state.remove_compatible_version(version_control::current_version());

        let coin = coin::mint_for_testing<TEST_COIN>(1_000, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, state_addr);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_COIN>>(coin_id);
        rescue_tokens<TEST_COIN>(&mut mt_state, ticket, RECIPIENT, 1_000, scenario.ctx());

        unit_test::destroy(mt_state);
        scenario.end();
    }
}
