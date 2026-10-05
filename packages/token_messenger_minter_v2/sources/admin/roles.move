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

/// Module: roles
/// All privileged roles for `token_messenger_minter_v2`.
module token_messenger_minter_v2::roles {
    // === Imports ===
    use sui_extensions::two_step_role::{Self, TwoStepRole};

    // === Structs ===

    /// Roles are stored as EOA addresses (not Capabilities) so the
    /// owner can revoke.
    public struct Roles has key, store {
        id: UID,
        /// Rotates all other roles.
        owner: TwoStepRole<OwnerRole>,
        /// Pauses / unpauses (`admin/pausable`).
        pauser: address,
        /// Remote-token config + per-message burn limits (`admin/token_controller`).
        token_controller: address,
        /// CCTP denylist (`admin/denylistable`).
        denylister: address,
        /// Per-token min-fee rates (`admin/fee_controller`).
        min_fee_controller: address
    }

    public struct OwnerRole has drop {}

    // === Public-Mutative Functions ===

    public(package) fun new(owner: address, pauser: address, token_controller: address, denylister: address, min_fee_controller: address, ctx: &mut TxContext): Roles {
      Roles {
        id: object::new(ctx),
        owner: two_step_role::new(OwnerRole {}, owner),
        pauser,
        token_controller,
        denylister,
        min_fee_controller
      }
    }

    // === Public-View Functions ===

    public(package) fun owner_role_mut(roles: &mut Roles): &mut TwoStepRole<OwnerRole> {
      &mut roles.owner
    }

    public fun owner_role(roles: &Roles): &TwoStepRole<OwnerRole> {
      &roles.owner
    }
    
    public fun owner(roles: &Roles): address {
      roles.owner.active_address()
    }

    public fun pending_owner(roles: &Roles): Option<address> {
      roles.owner.pending_address()
    }

    public fun pauser(roles: &Roles): address {
      roles.pauser
    }

    public fun token_controller(roles: &Roles): address {
      roles.token_controller
    }

    public fun denylister(roles: &Roles): address {
      roles.denylister
    }

    public fun min_fee_controller(roles: &Roles): address {
      roles.min_fee_controller
    }

    // === Public-Package Functions ===

    public(package) fun update_pauser(roles: &mut Roles, new_pauser: address) {
      roles.pauser = new_pauser;
    }

    public(package) fun update_token_controller(roles: &mut Roles, new_token_controller: address) {
      roles.token_controller = new_token_controller;
    }

    public(package) fun update_denylister(roles: &mut Roles, new_denylister: address) {
      roles.denylister = new_denylister;
    }

    public(package) fun update_min_fee_controller(roles: &mut Roles, new_min_fee_controller: address) {
      roles.min_fee_controller = new_min_fee_controller;
    }


    // === Tests ===
    #[test_only] use std::unit_test;

    #[test]
    fun test_new_creates_object() {
      let mut ctx = tx_context::dummy();

      let expected_owner = @0x1;
      let expected_pauser = @0x2;
      let expected_token_controller = @0x3;
      let expected_denylister = @0x4;
      let expected_min_fee_controller = @0x5;

      let roles_obj = new(expected_owner, expected_pauser, expected_token_controller, expected_denylister, expected_min_fee_controller, &mut ctx);

      assert!(roles_obj.owner() == expected_owner, 0);
      assert!(roles_obj.pending_owner() == option::none(), 1);
      assert!(roles_obj.pauser() == expected_pauser, 2);
      assert!(roles_obj.token_controller() == expected_token_controller, 3);
      assert!(roles_obj.denylister() == expected_denylister, 4);
      assert!(roles_obj.min_fee_controller() == expected_min_fee_controller, 5);

      unit_test::destroy(roles_obj);
    }

    #[test]
    fun test_update_pauser() {
      let mut ctx = tx_context::dummy();

      let (original_pauser, new_pauser) = (@0x1, @0x2);

      let mut roles_obj = new(original_pauser, original_pauser, original_pauser, original_pauser, original_pauser, &mut ctx);
      assert!(roles_obj.pauser() == original_pauser, 0);

      // Test: owner is updated
      roles_obj.update_pauser(new_pauser);
      assert!(roles_obj.pauser() == new_pauser, 1);

      unit_test::destroy(roles_obj);
    }

    #[test]
    fun test_update_token_controller() {
      let mut ctx = tx_context::dummy();

      let (original_token_controller, new_token_controller) = (@0x1, @0x2);

      let mut roles_obj = new(original_token_controller, original_token_controller, original_token_controller, original_token_controller, original_token_controller, &mut ctx);
      assert!(roles_obj.token_controller() == original_token_controller, 0);

      // Test: owner is updated
      roles_obj.update_token_controller(new_token_controller);
      assert!(roles_obj.token_controller() == new_token_controller, 1);

      unit_test::destroy(roles_obj);
    }

    #[test]
    fun test_update_denylister() {
      let mut ctx = tx_context::dummy();

      let (original_denylister, new_denylister) = (@0x1, @0x2);

      let mut roles_obj = new(original_denylister, original_denylister, original_denylister, original_denylister, original_denylister, &mut ctx);
      assert!(roles_obj.denylister() == original_denylister, 0);

      roles_obj.update_denylister(new_denylister);
      assert!(roles_obj.denylister() == new_denylister, 1);

      unit_test::destroy(roles_obj);
    }

    #[test]
    fun test_update_min_fee_controller() {
      let mut ctx = tx_context::dummy();

      let (original_controller, new_controller) = (@0x1, @0x2);

      let mut roles_obj = new(original_controller, original_controller, original_controller, original_controller, original_controller, &mut ctx);
      assert!(roles_obj.min_fee_controller() == original_controller, 0);

      roles_obj.update_min_fee_controller(new_controller);
      assert!(roles_obj.min_fee_controller() == new_controller, 1);

      unit_test::destroy(roles_obj);
    }
}
