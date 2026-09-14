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

/// Module: fee_controller
/// Per-token min-fee configuration and the `fee_recipient` address.
/// `owner` rotates `min_fee_controller` and `fee_recipient`;
/// `min_fee_controller` sets per-token rates.
///
/// `calculate_min_fee_amount` is consumed by `deposit_for_burn`
/// (source side) to gate the sender's `max_fee`. `prepare_mint`
/// (destination side) does not re-derive a fee; it just validates
/// the wire `fee_executed` against `max_fee` and `amount`.
///
/// Precision: `min_fee` is in 1/1000 bp
/// (denominator `MIN_FEE_MULTIPLIER = 10_000_000`), so 100_000 = 100 bp = 1%.
module token_messenger_minter_v2::fee_controller {
    // === Imports ===
    use sui::event::emit;
    use token_messenger_minter_v2::{
        state::State,
        version_control::assert_object_version_is_compatible_with_package
    };

    // === Errors ===
    /// Caller is not the current min_fee_controller.
    const ENotMinFeeController: u64 = 0;
    /// `min_fee_controller` cannot be the zero address.
    const EInvalidMinFeeController: u64 = 1;
    /// New `min_fee_controller` equals the current value.
    const ENewMinFeeControllerSameAsOld: u64 = 2;
    /// `fee_recipient` cannot be the zero address.
    const EInvalidFeeRecipient: u64 = 3;
    /// New `fee_recipient` equals the current value.
    const ENewFeeRecipientSameAsOld: u64 = 4;
    /// `min_fee` must be strictly less than `MIN_FEE_MULTIPLIER`.
    const EMinFeeTooHigh: u64 = 5;
    /// `calculate_min_fee_amount` requires `amount > 1` when a fee is set.
    const EAmountTooLow: u64 = 6;

    // === Constants ===
    /// Precision denominator (1/1000 bp). `min_fee == MIN_FEE_MULTIPLIER`
    /// is 100% and disallowed (see `set_min_fee`).
    const MIN_FEE_MULTIPLIER: u256 = 10_000_000;

    // === Events ===
    public struct MinFeeControllerSet has copy, drop {
        min_fee_controller: address,
    }

    public struct MinFeeSet has copy, drop {
        token_address: address,
        min_fee: u256,
    }

    public struct FeeRecipientSet has copy, drop {
        fee_recipient: address,
    }

    // === View-only functions ===

    /// Min fee for `amount` of `token_id`:
    /// * Returns 0 if no rate is configured (or rate is 0). `amount`
    ///   is not validated in this case.
    /// * Otherwise aborts with `EAmountTooLow` if `amount <= 1`
    ///   (preserves the downstream `fee < amount` invariant).
    /// * Computes `(amount * min_fee) / MIN_FEE_MULTIPLIER`, floored
    ///   up to 1 when `min_fee > 0`.
    public(package) fun calculate_min_fee_amount(state: &State, token_id: address, amount: u256): u256 {
        let min_fee = state.min_fee(token_id);
        if (min_fee == 0) {
            return 0
        };

        assert!(amount > 1, EAmountTooLow);

        let min_fee_amount = (amount * min_fee) / MIN_FEE_MULTIPLIER;
        if (min_fee_amount == 0) {
            return 1
        };
        min_fee_amount
    }

    // === Admin functions ===

    /// Owner-only.
    entry fun set_min_fee_controller(state: &mut State, new_min_fee_controller: address, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.roles().owner_role().assert_sender_is_active_role(ctx);
        assert!(new_min_fee_controller != @0x0, EInvalidMinFeeController);
        assert!(new_min_fee_controller != state.roles().min_fee_controller(), ENewMinFeeControllerSameAsOld);

        state.roles_mut().update_min_fee_controller(new_min_fee_controller);
        emit(MinFeeControllerSet { min_fee_controller: new_min_fee_controller });
    }

    /// Owner-only.
    entry fun set_fee_recipient(state: &mut State, new_fee_recipient: address, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.roles().owner_role().assert_sender_is_active_role(ctx);
        assert!(new_fee_recipient != @0x0, EInvalidFeeRecipient);
        assert!(new_fee_recipient != state.fee_recipient(), ENewFeeRecipientSameAsOld);

        state.set_fee_recipient(new_fee_recipient);
        emit(FeeRecipientSet { fee_recipient: new_fee_recipient });
    }

    /// `min_fee_controller`-only. `min_fee < MIN_FEE_MULTIPLIER`;
    /// `min_fee == 0` disables the fee for `burn_token`.
    entry fun set_min_fee(state: &mut State, burn_token: address, min_fee: u256, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        assert_is_min_fee_controller(state, ctx);
        assert!(min_fee < MIN_FEE_MULTIPLIER, EMinFeeTooHigh);

        state.set_min_fee(burn_token, min_fee);
        emit(MinFeeSet { token_address: burn_token, min_fee });
    }

    // === Private functions ===

    fun assert_is_min_fee_controller(state: &State, ctx: &TxContext) {
        assert!(ctx.sender() == state.roles().min_fee_controller(), ENotMinFeeController);
    }

    // === Test Functions ===
    #[test_only] use sui::{
        event::num_events,
        test_scenario::{Self, Scenario},
    };
    #[test_only] use std::unit_test;
    #[test_only] use sui_extensions::{
        test_utils::last_event_by_type,
        two_step_role,
    };
    #[test_only] use token_messenger_minter_v2::{
        state::{Self},
        version_control,
    };

    #[test_only] const OWNER: address = @0x111;
    #[test_only] const MIN_FEE_CONTROLLER: address = @0x222;
    #[test_only] const RANDOM: address = @0x333;
    #[test_only] const TOKEN: address = @0x444;
    #[test_only] const OTHER_TOKEN: address = @0x555;

    #[test_only]
    fun setup(): (Scenario, State) {
        let mut scenario = test_scenario::begin(@0x0);
        // All roles + fee_recipient default to OWNER
        let mut state = state::new(0, OWNER, scenario.ctx());
        // Separate the min_fee_controller from OWNER to exercise the
        // owner-vs-controller boundary in tests.
        scenario.next_tx(OWNER);
        set_min_fee_controller(&mut state, MIN_FEE_CONTROLLER, scenario.ctx());
        (scenario, state)
    }

    // === view / default tests ===

    #[test]
    fun test_defaults_from_state_new() {
        let mut scenario = test_scenario::begin(@0x0);
        let state = state::new(0, OWNER, scenario.ctx());
        assert!(state.roles().min_fee_controller() == OWNER);
        assert!(state.fee_recipient() == OWNER);
        // Unregistered token returns 0
        assert!(state.min_fee(TOKEN) == 0);
        unit_test::destroy(state);
        scenario.end();
    }

    // === set_min_fee_controller tests ===

    #[test]
    fun test_set_min_fee_controller_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        set_min_fee_controller(&mut state, MIN_FEE_CONTROLLER, scenario.ctx());
        assert!(state.roles().min_fee_controller() == MIN_FEE_CONTROLLER);
        assert!(num_events() == 1);
        assert!(last_event_by_type<MinFeeControllerSet>().min_fee_controller == MIN_FEE_CONTROLLER);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    fun test_set_min_fee_controller_revert_not_owner() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(RANDOM);
        set_min_fee_controller(&mut state, MIN_FEE_CONTROLLER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidMinFeeController)]
    fun test_set_min_fee_controller_revert_zero_address() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        set_min_fee_controller(&mut state, @0x0, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENewMinFeeControllerSameAsOld)]
    fun test_set_min_fee_controller_revert_same_as_old() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        // Current controller is OWNER (default from state::new)
        set_min_fee_controller(&mut state, OWNER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_set_min_fee_controller_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        set_min_fee_controller(&mut state, MIN_FEE_CONTROLLER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === set_fee_recipient tests ===

    #[test]
    fun test_set_fee_recipient_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());
        let new_recipient = @0x777;

        scenario.next_tx(OWNER);
        set_fee_recipient(&mut state, new_recipient, scenario.ctx());
        assert!(state.fee_recipient() == new_recipient);
        assert!(num_events() == 1);
        assert!(last_event_by_type<FeeRecipientSet>().fee_recipient == new_recipient);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    fun test_set_fee_recipient_revert_not_owner() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(RANDOM);
        set_fee_recipient(&mut state, @0x777, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidFeeRecipient)]
    fun test_set_fee_recipient_revert_zero_address() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        set_fee_recipient(&mut state, @0x0, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENewFeeRecipientSameAsOld)]
    fun test_set_fee_recipient_revert_same_as_old() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        // Current recipient is OWNER (default from state::new)
        set_fee_recipient(&mut state, OWNER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_set_fee_recipient_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        set_fee_recipient(&mut state, @0x777, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === set_min_fee tests ===

    #[test]
    fun test_set_min_fee_successful() {
        let (mut scenario, mut state) = setup();
        let rate = 100_000;

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, rate, scenario.ctx());
        assert!(state.min_fee(TOKEN) == rate);
        let event = last_event_by_type<MinFeeSet>();
        assert!(event.token_address == TOKEN && event.min_fee == rate);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_set_min_fee_updates_existing() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 100_000, scenario.ctx());
        assert!(state.min_fee(TOKEN) == 100_000);

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 200_000, scenario.ctx());
        assert!(state.min_fee(TOKEN) == 200_000);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_set_min_fee_zero_allowed() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 0, scenario.ctx());
        assert!(state.min_fee(TOKEN) == 0);
        assert!(state.min_fee_for_token_id_exists(TOKEN));

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotMinFeeController)]
    fun test_set_min_fee_revert_not_controller_random() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(RANDOM);
        set_min_fee(&mut state, TOKEN, 100, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotMinFeeController)]
    fun test_set_min_fee_revert_not_controller_owner() {
        // Owner is not the min_fee_controller after setup() ran.
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        set_min_fee(&mut state, TOKEN, 100, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EMinFeeTooHigh)]
    fun test_set_min_fee_revert_at_multiplier() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, MIN_FEE_MULTIPLIER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EMinFeeTooHigh)]
    fun test_set_min_fee_revert_above_multiplier() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, MIN_FEE_MULTIPLIER + 1, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_set_min_fee_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 100, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === calculate_min_fee_amount tests ===

    #[test]
    fun test_calculate_min_fee_amount_unregistered_returns_zero() {
        let (scenario, state) = setup();
        // OTHER_TOKEN was never registered; amount check must NOT fire.
        assert!(calculate_min_fee_amount(&state, OTHER_TOKEN, 0) == 0);
        assert!(calculate_min_fee_amount(&state, OTHER_TOKEN, 1) == 0);
        assert!(calculate_min_fee_amount(&state, OTHER_TOKEN, 1_000_000) == 0);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_calculate_min_fee_amount_zero_rate_returns_zero() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 0, scenario.ctx());
        // Registered-but-zero rate short-circuits, no amount check.
        assert!(calculate_min_fee_amount(&state, TOKEN, 0) == 0);
        assert!(calculate_min_fee_amount(&state, TOKEN, 1_000_000) == 0);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_calculate_min_fee_amount_typical() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        // 100 basis points (100_000 / 10_000_000 == 0.01)
        set_min_fee(&mut state, TOKEN, 100_000, scenario.ctx());
        // (1_000_000 * 100_000) / 10_000_000 == 10_000
        assert!(calculate_min_fee_amount(&state, TOKEN, 1_000_000) == 10_000);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_calculate_min_fee_amount_floor_edge_case() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 100_000, scenario.ctx());
        // (50 * 100_000) / 10_000_000 == 0 (integer division), but rate > 0
        // → floored up to 1.
        assert!(calculate_min_fee_amount(&state, TOKEN, 50) == 1);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_calculate_min_fee_amount_max_boundary() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        // Highest legal rate: MIN_FEE_MULTIPLIER - 1 = 9_999_999
        set_min_fee(&mut state, TOKEN, MIN_FEE_MULTIPLIER - 1, scenario.ctx());
        // With amount == MIN_FEE_MULTIPLIER, min_fee_amount == amount - 1.
        // This is the largest value the helper can return while preserving
        // `min_fee_amount < amount` for downstream validation.
        let amount = MIN_FEE_MULTIPLIER;
        assert!(calculate_min_fee_amount(&state, TOKEN, amount) == amount - 1);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EAmountTooLow)]
    fun test_calculate_min_fee_amount_revert_amount_zero() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 100_000, scenario.ctx());
        calculate_min_fee_amount(&state, TOKEN, 0);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EAmountTooLow)]
    fun test_calculate_min_fee_amount_revert_amount_one() {
        let (mut scenario, mut state) = setup();
        scenario.next_tx(MIN_FEE_CONTROLLER);
        set_min_fee(&mut state, TOKEN, 100_000, scenario.ctx());
        calculate_min_fee_amount(&state, TOKEN, 1);
        unit_test::destroy(state);
        scenario.end();
    }
}
