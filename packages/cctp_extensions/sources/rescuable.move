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
/// Rescues `Coin<T>` objects stranded at the address of a parent object
/// (typically a shared `State` in a consuming package such as MT v2 / TMM v2).
///
/// Consumers embed a `Rescuable` field in their `State` struct and expose
/// entry wrappers that (a) enforce owner authorization for `update_rescuer`
/// and (b) thread the parent `&mut UID` plus a `Receiving<Coin<T>>` ticket
/// into `rescue_coin`.
///
/// A `Rescuable` is bound at construction to the parent it belongs to and
/// carries no authority over any other object: `new` requires the parent's
/// `&UID`, and `rescue_coin` re-checks it. This module's functions are public,
/// so anyone can build a `Rescuable` for an object of their own — the binding
/// is what keeps such an object from reaching a consumer's `State`.
module cctp_extensions::rescuable {
    // === Imports ===
    use sui::{
        coin::Coin,
        event::emit,
        transfer::Receiving
    };

    // === Errors ===
    const ENotRescuer: u64 = 0;
    const ENewRescuerSameAsOld: u64 = 1;
    const EZeroAmount: u64 = 2;
    const EInsufficientBalance: u64 = 3;
    const EInvalidRescuer: u64 = 4;
    const EWrongParent: u64 = 5;

    // === Structs ===

    /// Holds the rescuer address, bound to the parent object that embeds it.
    /// Designed to be embedded by-value inside a consuming package's `State`
    /// struct.
    ///
    /// `parent_id` is captured at construction and never changes. Because
    /// `new` and `rescue_coin` are both public, a `Rescuable` on its own must
    /// not confer authority over an unrelated object: `rescue_coin` requires
    /// the caller to present the same parent this `Rescuable` was built for,
    /// so a self-constructed `Rescuable` only ever governs its own parent.
    public struct Rescuable has store {
        parent_id: ID,
        rescuer: address,
    }

    // === Events ===

    /// `parent_id` identifies which parent object's rescuer changed. Consumers
    /// share this module, so the event type alone does not say which package
    /// or object it came from — filter on `parent_id` to attribute it.
    public struct RescuerChanged has copy, drop {
        parent_id: ID,
        new_rescuer: address,
    }

    // === Constructors / Destructors ===

    /// Create a new `Rescuable` bound to `parent`, with the given initial
    /// rescuer address.
    ///
    /// Takes the parent's `&UID` rather than its `ID`: an `ID` is copyable and
    /// derivable from any object by anyone, whereas a `UID` is only reachable
    /// from the module that defines the parent. So only that module can mint a
    /// `Rescuable` claiming its object as parent.
    public fun new(parent: &UID, rescuer: address): Rescuable {
        Rescuable { parent_id: parent.to_inner(), rescuer }
    }

    /// Destroy a `Rescuable`. Used when a consumer destructures its
    /// containing `State`.
    public fun destroy(rescuable: Rescuable) {
        let Rescuable { parent_id: _, rescuer: _ } = rescuable;
    }

    // === Views ===

    public fun rescuer(rescuable: &Rescuable): address {
        rescuable.rescuer
    }

    /// The parent object this `Rescuable` is bound to.
    public fun parent_id(rescuable: &Rescuable): ID {
        rescuable.parent_id
    }

    /// Aborts with `ENotRescuer` if the transaction sender is not the
    /// current rescuer.
    public fun assert_sender_is_rescuer(rescuable: &Rescuable, ctx: &mut TxContext) {
        assert!(rescuable.rescuer == ctx.sender(), ENotRescuer);
    }

    // === Mutations ===

    /// Updates the rescuer to `new_rescuer`. Aborts with `EInvalidRescuer` if
    /// `new_rescuer` is the zero address, or `ENewRescuerSameAsOld` if it
    /// matches the existing value. Emits `RescuerChanged`.
    ///
    /// Owner authorization is the responsibility of the calling package;
    /// `Rescuable` itself does not encode any owner role.
    public fun update_rescuer(rescuable: &mut Rescuable, new_rescuer: address) {
        assert!(new_rescuer != @0x0, EInvalidRescuer);
        assert!(rescuable.rescuer != new_rescuer, ENewRescuerSameAsOld);
        rescuable.rescuer = new_rescuer;
        emit(RescuerChanged { parent_id: rescuable.parent_id, new_rescuer });
    }

    /// Rescues a `Coin<T>` that has been transferred to the address of this
    /// `Rescuable`'s parent object. Only callable by the current rescuer, and
    /// only for the parent the `Rescuable` was constructed with — passing any
    /// other object's `UID` aborts with `EWrongParent`.
    ///
    /// Receives the coin via `transfer::public_receive`, then:
    /// - if `amount` equals the coin's full balance, transfers the whole
    ///   coin to `recipient`;
    /// - otherwise splits `amount` off and transfers it to `recipient`,
    ///   sending the remainder back to the parent address so it remains
    ///   rescuable in a future call.
    public fun rescue_coin<T>(
        rescuable: &Rescuable,
        parent_id: &mut UID,
        coin_to_receive: Receiving<Coin<T>>,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(rescuable.parent_id == parent_id.to_inner(), EWrongParent);
        rescuable.assert_sender_is_rescuer(ctx);
        assert!(amount > 0, EZeroAmount);

        let mut coin = transfer::public_receive(parent_id, coin_to_receive);
        let balance = coin.value();
        assert!(balance >= amount, EInsufficientBalance);

        if (balance == amount) {
            transfer::public_transfer(coin, recipient);
        } else {
            let to_send = coin.split(amount, ctx);
            transfer::public_transfer(to_send, recipient);
            transfer::public_transfer(coin, parent_id.to_address());
        }
    }

    // === Test Functions ===
    #[test_only] use sui::{
        coin,
        event::num_events,
        test_scenario::{Self, Scenario}
    };
    #[test_only] use std::unit_test;
    #[test_only] use sui_extensions::test_utils::last_event_by_type;

    #[test_only] const RESCUER: address = @0x111;
    #[test_only] const NEW_RESCUER: address = @0x222;
    #[test_only] const RECIPIENT: address = @0x333;
    #[test_only] const NON_RESCUER: address = @0x444;

    #[test_only]
    public struct TestParent has key, store {
        id: UID,
    }

    #[test_only]
    public struct USDC has drop {}

    #[test_only]
    public struct OTHER has drop {}

    #[test_only]
    fun new_parent(scenario: &mut Scenario): TestParent {
        TestParent { id: object::new(scenario.ctx()) }
    }

    // new / destroy tests

    #[test]
    fun test_new_sets_rescuer_and_parent() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        assert!(rescuable.rescuer() == RESCUER);
        assert!(rescuable.parent_id() == parent.id.to_inner());
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    #[test]
    fun test_new_binds_distinct_parents_distinctly() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let other_parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let other_rescuable = new(&other_parent.id, RESCUER);
        assert!(rescuable.parent_id() != other_rescuable.parent_id());
        rescuable.destroy();
        other_rescuable.destroy();
        unit_test::destroy(parent);
        unit_test::destroy(other_parent);
        scenario.end();
    }

    #[test]
    fun test_destroy() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    // assert_sender_is_rescuer tests

    #[test]
    fun test_assert_sender_is_rescuer_succeeds() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        rescuable.assert_sender_is_rescuer(scenario.ctx());
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotRescuer)]
    fun test_assert_sender_is_rescuer_aborts_when_not_rescuer() {
        let mut scenario = test_scenario::begin(NON_RESCUER);
        let parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        rescuable.assert_sender_is_rescuer(scenario.ctx());
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    // update_rescuer tests

    #[test]
    fun test_update_rescuer_successful() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let mut rescuable = new(&parent.id, RESCUER);
        rescuable.update_rescuer(NEW_RESCUER);
        assert!(rescuable.rescuer() == NEW_RESCUER);
        assert!(num_events() == 1);
        let event = last_event_by_type<RescuerChanged>();
        assert!(event.new_rescuer == NEW_RESCUER);
        // The event identifies which parent object's rescuer changed, so
        // consumers sharing this module remain distinguishable off-chain.
        assert!(event.parent_id == parent.id.to_inner());
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInvalidRescuer)]
    fun test_update_rescuer_revert_zero_address() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let mut rescuable = new(&parent.id, RESCUER);
        rescuable.update_rescuer(@0x0);
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENewRescuerSameAsOld)]
    fun test_update_rescuer_revert_same() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let mut rescuable = new(&parent.id, RESCUER);
        rescuable.update_rescuer(RESCUER);
        rescuable.destroy();
        unit_test::destroy(parent);
        scenario.end();
    }

    // rescue_coin tests

    #[test]
    fun test_rescue_coin_full_balance() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();
        let coin_amount = 1_000_000u64;

        // Strand a coin at the parent's address.
        let coin = coin::mint_for_testing<USDC>(coin_amount, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, parent_addr);

        // Rescue the full amount.
        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            ticket,
            RECIPIENT,
            coin_amount,
            scenario.ctx(),
        );

        // Recipient should now hold the entire coin; nothing should remain
        // at the parent address.
        scenario.next_tx(RESCUER);
        let rescued = scenario.take_from_address<Coin<USDC>>(RECIPIENT);
        assert!(rescued.value() == coin_amount);
        assert!(test_scenario::ids_for_address<Coin<USDC>>(parent_addr).length() == 0);

        coin::burn_for_testing(rescued);
        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }

    #[test]
    fun test_rescue_coin_partial_balance_splits_remainder_back() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();
        let coin_amount = 1_000_000u64;
        let rescue_amount = 300_000u64;

        let coin = coin::mint_for_testing<USDC>(coin_amount, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, parent_addr);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            ticket,
            RECIPIENT,
            rescue_amount,
            scenario.ctx(),
        );

        scenario.next_tx(RESCUER);
        let rescued = scenario.take_from_address<Coin<USDC>>(RECIPIENT);
        assert!(rescued.value() == rescue_amount);
        // The remainder coin sits at the parent address as a received-object
        // and remains rescuable in a follow-up call.
        let remainder_ids = test_scenario::ids_for_address<Coin<USDC>>(parent_addr);
        assert!(remainder_ids.length() == 1);

        coin::burn_for_testing(rescued);
        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = ENotRescuer)]
    fun test_rescue_coin_revert_not_rescuer() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();
        let coin_amount = 1_000u64;

        let coin = coin::mint_for_testing<USDC>(coin_amount, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, parent_addr);

        // Switch sender to a non-rescuer for the rescue attempt.
        scenario.next_tx(NON_RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            ticket,
            RECIPIENT,
            coin_amount,
            scenario.ctx(),
        );

        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }

    /// The abuse case this binding exists to stop: `new` is public, so anyone
    /// can build a `Rescuable` naming themselves as rescuer. Pointing it at
    /// someone else's parent object must not receive that parent's coins.
    #[test]
    #[expected_failure(abort_code = EWrongParent)]
    fun test_rescue_coin_revert_foreign_rescuable() {
        let mut scenario = test_scenario::begin(NON_RESCUER);
        let mut victim_parent = new_parent(&mut scenario);
        let attacker_parent = new_parent(&mut scenario);
        let victim_addr = victim_parent.id.to_address();

        // Coin stranded at the victim parent's address.
        let coin = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, victim_addr);

        // Attacker's own `Rescuable`, naming the attacker as rescuer, so the
        // `ENotRescuer` check would pass on its own.
        let attacker_rescuable = new(&attacker_parent.id, NON_RESCUER);

        scenario.next_tx(NON_RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &attacker_rescuable,
            &mut victim_parent.id,
            ticket,
            NON_RESCUER,
            1_000,
            scenario.ctx(),
        );

        unit_test::destroy(victim_parent);
        unit_test::destroy(attacker_parent);
        attacker_rescuable.destroy();
        scenario.end();
    }

    /// Mirror of the above with the parents swapped: a legitimate `Rescuable`
    /// cannot be used to drain a different object, even by the real rescuer.
    #[test]
    #[expected_failure(abort_code = EWrongParent)]
    fun test_rescue_coin_revert_wrong_parent_same_rescuer() {
        let mut scenario = test_scenario::begin(RESCUER);
        let parent = new_parent(&mut scenario);
        let mut other_parent = new_parent(&mut scenario);
        let other_addr = other_parent.id.to_address();

        let coin = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, other_addr);

        let rescuable = new(&parent.id, RESCUER);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut other_parent.id,
            ticket,
            RECIPIENT,
            1_000,
            scenario.ctx(),
        );

        unit_test::destroy(parent);
        unit_test::destroy(other_parent);
        rescuable.destroy();
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EZeroAmount)]
    fun test_rescue_coin_revert_zero_amount() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();

        let coin = coin::mint_for_testing<USDC>(1_000, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, parent_addr);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            ticket,
            RECIPIENT,
            0,
            scenario.ctx(),
        );

        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = EInsufficientBalance)]
    fun test_rescue_coin_revert_insufficient_balance() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();

        let coin = coin::mint_for_testing<USDC>(100, scenario.ctx());
        let coin_id = object::id(&coin);
        transfer::public_transfer(coin, parent_addr);

        scenario.next_tx(RESCUER);
        let ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            ticket,
            RECIPIENT,
            101,
            scenario.ctx(),
        );

        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }

    #[test]
    fun test_rescue_coin_multiple_coin_types() {
        let mut scenario = test_scenario::begin(RESCUER);
        let mut parent = new_parent(&mut scenario);
        let rescuable = new(&parent.id, RESCUER);
        let parent_addr = parent.id.to_address();
        let usdc_amount = 500u64;
        let other_amount = 700u64;

        let usdc = coin::mint_for_testing<USDC>(usdc_amount, scenario.ctx());
        let usdc_id = object::id(&usdc);
        transfer::public_transfer(usdc, parent_addr);

        let other = coin::mint_for_testing<OTHER>(other_amount, scenario.ctx());
        let other_id = object::id(&other);
        transfer::public_transfer(other, parent_addr);

        // Rescue both coin types in the same tx.
        scenario.next_tx(RESCUER);
        let usdc_ticket = test_scenario::receiving_ticket_by_id<Coin<USDC>>(usdc_id);
        rescue_coin<USDC>(
            &rescuable,
            &mut parent.id,
            usdc_ticket,
            RECIPIENT,
            usdc_amount,
            scenario.ctx(),
        );
        let other_ticket = test_scenario::receiving_ticket_by_id<Coin<OTHER>>(other_id);
        rescue_coin<OTHER>(
            &rescuable,
            &mut parent.id,
            other_ticket,
            RECIPIENT,
            other_amount,
            scenario.ctx(),
        );

        scenario.next_tx(RESCUER);
        let rescued_usdc = scenario.take_from_address<Coin<USDC>>(RECIPIENT);
        let rescued_other = scenario.take_from_address<Coin<OTHER>>(RECIPIENT);
        assert!(rescued_usdc.value() == usdc_amount);
        assert!(rescued_other.value() == other_amount);

        coin::burn_for_testing(rescued_usdc);
        coin::burn_for_testing(rescued_other);
        unit_test::destroy(parent);
        rescuable.destroy();
        scenario.end();
    }
}
