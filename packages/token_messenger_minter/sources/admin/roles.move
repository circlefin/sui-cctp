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

/// Module: roles
/// This module contains all roles for the package
module token_messenger_minter::roles {
    // === Imports ===
    use sui_extensions::two_step_role::{Self, TwoStepRole};

    // === Structs ===
    
    /// Track roles via EOAs (rather than Capabilities) to retain revocability.
    public struct Roles has key, store {
        id: UID,
        // Controls other roles
        owner: TwoStepRole<OwnerRole>,
        // Controls pausing/unpausing
        pauser: address,
        // Controls remote resources and burn limits
        token_controller: address
    }

    public struct OwnerRole has drop {}

    // === Public-Mutative Functions ===
    
    /// Create and return a new Roles state object
    public(package) fun new(owner: address, pauser: address, token_controller: address, ctx: &mut TxContext): Roles {
      Roles {
        id: object::new(ctx),
        owner: two_step_role::new(OwnerRole {}, owner),
        pauser,
        token_controller
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

    // === Public-Package Functions ===

    public(package) fun update_pauser(roles: &mut Roles, new_pauser: address) {
      roles.pauser = new_pauser;
    }

    public(package) fun update_token_controller(roles: &mut Roles, new_token_controller: address) {
      roles.token_controller = new_token_controller;
    }
    
    // === Tests ===
    #[test_only] use sui::test_utils;

    #[test]
    fun test_new_creates_object() {
      let mut ctx = tx_context::dummy();

      let expected_owner = @0x1;
      let expected_pauser = @0x2;
      let expected_token_controller = @0x3;
      
      let roles_obj = new(expected_owner, expected_pauser, expected_token_controller, &mut ctx);

      assert!(roles_obj.owner() == expected_owner, 0);
      assert!(roles_obj.pending_owner() == option::none(), 1);
      assert!(roles_obj.pauser() == expected_pauser, 2);
      assert!(roles_obj.token_controller() == expected_token_controller, 3);

      test_utils::destroy(roles_obj);
    }

    #[test]
    fun test_update_pauser() {
      let mut ctx = tx_context::dummy();

      let (original_pauser, new_pauser) = (@0x1, @0x2);
      
      let mut roles_obj = new(original_pauser, original_pauser, original_pauser, &mut ctx);
      assert!(roles_obj.pauser() == original_pauser, 0);

      // Test: owner is updated
      roles_obj.update_pauser(new_pauser);
      assert!(roles_obj.pauser() == new_pauser, 1);

      test_utils::destroy(roles_obj);
    }

    #[test]
    fun test_update_token_controller() {
      let mut ctx = tx_context::dummy();

      let (original_token_controller, new_token_controller) = (@0x1, @0x2);
      
      let mut roles_obj = new(original_token_controller, original_token_controller, original_token_controller, &mut ctx);
      assert!(roles_obj.token_controller() == original_token_controller, 0);

      // Test: owner is updated
      roles_obj.update_token_controller(new_token_controller);
      assert!(roles_obj.token_controller() == new_token_controller, 1);

      test_utils::destroy(roles_obj);
    }
}
