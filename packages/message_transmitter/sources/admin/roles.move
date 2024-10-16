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
/// This module contains all roles for the message_transmitter package
module message_transmitter::roles {
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
        // Controls enabling and disabling attesters
        attester_manager: address
    }

    public struct OwnerRole has drop {}

    // === Public-Mutative Functions ===
    
    /// Create and return a new Roles state object
    public(package) fun new(owner: address, pauser: address, attester_manager: address, ctx: &mut TxContext): Roles {
      Roles {
        id: object::new(ctx),
        owner: two_step_role::new(OwnerRole {}, owner),
        pauser,
        attester_manager
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

    public fun attester_manager(roles: &Roles): address {
      roles.attester_manager
    }

    // === Public-Package Functions ===

    public(package) fun update_pauser(roles: &mut Roles, new_pauser: address) {
      roles.pauser = new_pauser;
    }

    public(package) fun update_attester_manager(roles: &mut Roles, new_attester_manager: address) {
      roles.attester_manager = new_attester_manager;
    }

    // === Tests ===
    #[test_only] use sui::test_utils::{Self, assert_eq};
    
    #[test]
    fun roles_new_creates_object() {
      let mut ctx = tx_context::dummy();

      let expected_owner = @0x1;
      let expected_pauser = @0x2;
      let expected_attester_manager = @0x3;
      
      let roles_obj = new(expected_owner, expected_pauser, expected_attester_manager, &mut ctx);

      assert_eq(roles_obj.owner(), expected_owner);
      assert_eq(roles_obj.pending_owner(), option::none());
      assert_eq(roles_obj.pauser(), expected_pauser);
      assert_eq(roles_obj.attester_manager(), expected_attester_manager);

      test_utils::destroy(roles_obj);
    }
}
