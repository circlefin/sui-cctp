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

/// Module: denylistable
/// CCTP address denylist. `owner` rotates the `denylister`, which
/// adds/removes addresses.
///
/// Checked source-side only, in `deposit_for_burn`, against the
/// resolved caller (`ctx.sender()` or `auth_caller_identifier<W>()`).
/// Destination side deliberately doesn't consult this list; the
/// recipient is passive and Sui's framework `DenyList<T>` at `0x403`
/// already blocks denylisted recipients from receiving the coin when
/// the handler mints. Matches Aptos.
///
/// Distinct from framework `DenyList` at `0x403` (which blocks
/// holding/transferring the coin entirely); the CCTP denylist only
/// blocks initiating CCTP burns.
module token_messenger_minter_v2::denylistable {
    // === Imports ===
    use sui::event::emit;
    use token_messenger_minter_v2::{
        state::State,
        version_control::assert_object_version_is_compatible_with_package
    };

    // === Errors ===
    /// Caller is not the current denylister.
    const ENotDenylister: u64 = 0;
    /// `denylister` cannot be the zero address.
    const EInvalidDenylister: u64 = 1;
    /// New `denylister` equals the current value.
    const ENewDenylisterSameAsOld: u64 = 2;
    /// Address is denylisted (raised by `assert_not_denylisted`).
    const EDenylistedAddress: u64 = 3;

    // === Events ===
    public struct Denylisted has copy, drop {
        address: address,
    }

    public struct UnDenylisted has copy, drop {
        address: address,
    }

    public struct DenylisterChanged has copy, drop {
        old_denylister: address,
        new_denylister: address,
    }

    // === Admin functions ===

    /// Denylister-only, idempotent (no event if already denylisted).
    entry fun denylist(state: &mut State, addr: address, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        assert_is_denylister(state, ctx);

        if (!state.is_denylisted(addr)) {
            state.add_denylisted_address(addr);
            emit(Denylisted { address: addr });
        };
    }

    /// Denylister-only, idempotent (no event if not denylisted).
    entry fun un_denylist(state: &mut State, addr: address, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        assert_is_denylister(state, ctx);

        if (state.is_denylisted(addr)) {
            state.remove_denylisted_address(addr);
            emit(UnDenylisted { address: addr });
        };
    }

    /// Owner-only. Rotates the `denylister` address.
    entry fun update_denylister(state: &mut State, new_denylister: address, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        state.roles().owner_role().assert_sender_is_active_role(ctx);
        assert!(new_denylister != @0x0, EInvalidDenylister);
        assert!(new_denylister != state.roles().denylister(), ENewDenylisterSameAsOld);

        let old_denylister = state.roles().denylister();
        state.roles_mut().update_denylister(new_denylister);
        emit(DenylisterChanged { old_denylister, new_denylister });
    }

    // === Package Functions ===

    /// Aborts if `addr` is on the CCTP denylist. Called only from
    /// `deposit_for_burn` (see module doc).
    public(package) fun assert_not_denylisted(state: &State, addr: address) {
        assert!(!state.is_denylisted(addr), EDenylistedAddress);
    }

    /// Aborts if the transaction's gas sponsor is on the CCTP denylist.
    /// No-op for unsponsored transactions, where `ctx.sponsor()` is `None`.
    ///
    /// Sui lets one address pay gas on behalf of another, and `ctx.sender()`
    /// alone does not see the payer. Without this screen a denylisted party
    /// could fund CCTP activity through an unlisted sender. Raises
    /// `EDenylistedAddress`, the same code as `assert_not_denylisted`.
    public(package) fun assert_sponsor_not_denylisted(state: &State, ctx: &TxContext) {
        let sponsor = ctx.sponsor();
        if (sponsor.is_some()) {
            assert!(!state.is_denylisted(*sponsor.borrow()), EDenylistedAddress);
        }
    }

    // === Private functions ===

    fun assert_is_denylister(state: &State, ctx: &TxContext) {
        assert!(ctx.sender() == state.roles().denylister(), ENotDenylister);
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
    #[test_only] const DENYLISTER: address = @0x222;
    #[test_only] const RANDOM: address = @0x333;
    #[test_only] const TARGET: address = @0x444;

    #[test_only]
    fun setup(): (Scenario, State) {
        let mut scenario = test_scenario::begin(@0x0);
        // All roles default to OWNER; separate the denylister from OWNER to
        // exercise the owner-vs-denylister boundary in tests.
        let mut state = state::new(0, OWNER, scenario.ctx());
        scenario.next_tx(OWNER);
        update_denylister(&mut state, DENYLISTER, scenario.ctx());
        (scenario, state)
    }

    // === defaults ===

    #[test]
    fun test_defaults_from_state_new() {
        let mut scenario = test_scenario::begin(@0x0);
        let state = state::new(0, OWNER, scenario.ctx());
        // denylister defaults to the caller (OWNER); nothing denylisted yet.
        assert!(state.roles().denylister() == OWNER);
        assert!(!state.is_denylisted(TARGET));
        unit_test::destroy(state);
        scenario.end();
    }

    // === denylist tests ===

    #[test]
    fun test_denylist_successful() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());
        assert!(state.is_denylisted(TARGET));
        assert!(num_events() == 1);
        assert!(last_event_by_type<Denylisted>().address == TARGET);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_denylist_idempotent() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());
        assert!(state.is_denylisted(TARGET));

        // Second call is a no-op: still denylisted, no new event emitted.
        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());
        assert!(state.is_denylisted(TARGET));
        assert!(num_events() == 0);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotDenylister)]
    fun test_denylist_revert_not_denylister() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(RANDOM);
        denylist(&mut state, TARGET, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_denylist_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === un_denylist tests ===

    #[test]
    fun test_un_denylist_successful() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());
        assert!(state.is_denylisted(TARGET));

        scenario.next_tx(DENYLISTER);
        un_denylist(&mut state, TARGET, scenario.ctx());
        assert!(!state.is_denylisted(TARGET));
        assert!(num_events() == 1);
        assert!(last_event_by_type<UnDenylisted>().address == TARGET);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    fun test_un_denylist_idempotent_when_not_denylisted() {
        let (mut scenario, mut state) = setup();

        // Removing an address that was never denylisted is a no-op, no event.
        scenario.next_tx(DENYLISTER);
        un_denylist(&mut state, TARGET, scenario.ctx());
        assert!(!state.is_denylisted(TARGET));
        assert!(num_events() == 0);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotDenylister)]
    fun test_un_denylist_revert_not_denylister() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(RANDOM);
        un_denylist(&mut state, TARGET, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_un_denylist_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(DENYLISTER);
        un_denylist(&mut state, TARGET, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === update_denylister tests ===

    #[test]
    fun test_update_denylister_successful() {
        let mut scenario = test_scenario::begin(@0x0);
        let mut state = state::new(0, OWNER, scenario.ctx());

        scenario.next_tx(OWNER);
        // Current denylister is OWNER (default from state::new).
        update_denylister(&mut state, DENYLISTER, scenario.ctx());
        assert!(state.roles().denylister() == DENYLISTER);
        assert!(num_events() == 1);
        let event = last_event_by_type<DenylisterChanged>();
        assert!(event.old_denylister == OWNER && event.new_denylister == DENYLISTER);

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = two_step_role::ESenderNotActiveRole)]
    fun test_update_denylister_revert_not_owner() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(RANDOM);
        update_denylister(&mut state, RANDOM, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidDenylister)]
    fun test_update_denylister_revert_zero_address() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        update_denylister(&mut state, @0x0, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENewDenylisterSameAsOld)]
    fun test_update_denylister_revert_same_as_old() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(OWNER);
        // Current denylister is DENYLISTER after setup().
        update_denylister(&mut state, DENYLISTER, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_update_denylister_revert_incompatible_version() {
        let (mut scenario, mut state) = setup();
        state.add_compatible_version(5);
        state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(OWNER);
        update_denylister(&mut state, RANDOM, scenario.ctx());

        unit_test::destroy(state);
        scenario.end();
    }

    // === assert_not_denylisted tests ===

    #[test]
    fun test_assert_not_denylisted_success() {
        let (scenario, state) = setup();
        // TARGET is not denylisted → passes.
        assert_not_denylisted(&state, TARGET);
        unit_test::destroy(state);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EDenylistedAddress)]
    fun test_assert_not_denylisted_revert() {
        let (mut scenario, mut state) = setup();

        scenario.next_tx(DENYLISTER);
        denylist(&mut state, TARGET, scenario.ctx());
        assert_not_denylisted(&state, TARGET);

        unit_test::destroy(state);
        scenario.end();
    }
}
