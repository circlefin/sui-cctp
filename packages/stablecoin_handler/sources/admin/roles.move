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
/// This module contains all roles for the stablecoin_handler package:
/// * `owner` (two-step) — authorizes package upgrades/migration and rotates
///   the `mint_controller` role.
/// * `mint_controller` (single-address) — authorizes adding/removing the
///   handler's `MintCap<USDC>`.
/// There is no pause role; pausing is enforced in token_messenger_minter_v2.
module stablecoin_handler::roles {
    // === Imports ===
    use sui_extensions::two_step_role::{Self, TwoStepRole};

    // === Structs ===

    /// Track roles via EOAs (rather than Capabilities) to retain revocability.
    public struct Roles has key, store {
        id: UID,
        // Controls upgrades/migration
        owner: TwoStepRole<OwnerRole>,
        // Manages the handler's `MintCap<USDC>` (add/remove). Single-address
        // role, rotated by the owner via `role_management::update_mint_controller`.
        // Mirrors TMM's `token_controller` (mint-cap custody is an operational
        // key, kept distinct from the upgrade-authority owner).
        mint_controller: address
    }

    public struct OwnerRole has drop {}

    // === Public-Mutative Functions ===

    /// Create and return a new Roles state object
    public(package) fun new(owner: address, mint_controller: address, ctx: &mut TxContext): Roles {
      Roles {
        id: object::new(ctx),
        owner: two_step_role::new(OwnerRole {}, owner),
        mint_controller
      }
    }

    // === Public-View Functions ===

    public(package) fun owner_role_mut(roles: &mut Roles): &mut TwoStepRole<OwnerRole> {
      &mut roles.owner
    }

    public fun owner(roles: &Roles): address {
      roles.owner.active_address()
    }

    public fun pending_owner(roles: &Roles): Option<address> {
      roles.owner.pending_address()
    }

    public fun mint_controller(roles: &Roles): address {
      roles.mint_controller
    }

    public(package) fun update_mint_controller(roles: &mut Roles, new_mint_controller: address) {
      roles.mint_controller = new_mint_controller;
    }

    // === Tests ===
    #[test_only] use std::unit_test;

    #[test]
    fun test_new_creates_object() {
      let mut ctx = tx_context::dummy();

      let expected_owner = @0x1;
      let expected_mint_controller = @0x2;

      let roles_obj = new(expected_owner, expected_mint_controller, &mut ctx);

      assert!(roles_obj.owner() == expected_owner, 0);
      assert!(roles_obj.pending_owner() == option::none(), 1);
      assert!(roles_obj.mint_controller() == expected_mint_controller, 2);

      unit_test::destroy(roles_obj);
    }
}
