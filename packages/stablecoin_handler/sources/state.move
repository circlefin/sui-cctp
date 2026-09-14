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

/// Module: state
/// Core global shared State for the stablecoin_handler package.
///
/// State holds only operational fields: the roles (owner + mint_controller),
/// the set of compatible package versions (for upgrades/migration), and the
/// handler's `MintCap<USDC>`. There are no Tables/Bags and no pause flag —
/// pause is enforced in token_messenger_minter_v2, and handler identity is
/// proven via the type-witness `handler::Auth`, not stored here.
///
/// MintCap custody: unlike Aptos (which lends a TMM signer per call), Sui has
/// no signer delegation, so the handler holds its own `MintCap<USDC>` and uses
/// it directly for both directions — `treasury::mint` in
/// `handler::mint` (receive) and `treasury::burn` in
/// `handler::burn` (send). The cap is added post-deploy via
/// `mint_controller::add_mint_cap` (it can't exist at publish time, hence the
/// `Option`) and can be rotated/removed via `mint_controller::remove_mint_cap`.
module stablecoin_handler::state {
    // === Imports ===
    use sui::vec_set::{Self, VecSet};
    use stablecoin::treasury::MintCap;
    use usdc::usdc::USDC;
    use stablecoin_handler::{
        roles::{Self, Roles},
        version_control
    };

    // === Structs ===
    public struct State has key {
        id: UID,
        /// All roles for package
        roles: Roles,
        /// The set of package version numbers that object is compatible with
        compatible_versions: VecSet<u64>,
        /// The handler's USDC mint/burn authority. `none` until set post-deploy
        /// via `mint_controller::add_mint_cap`; used by `mint` to
        /// mint (receive) and by `burn` to burn (send).
        /// Rotatable/removable via `mint_controller::remove_mint_cap`.
        mint_cap: Option<MintCap<USDC>>
    }

    // === Public-Mutative Functions ===

    /// Initialize the state with initial roles. The owner and mint_controller
    /// both default to `caller`.
    public(package) fun new(caller: address, ctx: &mut TxContext): State {
        State {
            id: object::new(ctx),
            roles: roles::new(caller, caller, ctx),
            compatible_versions: vec_set::singleton(version_control::current_version()),
            mint_cap: option::none()
        }
    }

    #[allow(lint(share_owned))]
    public(package) fun share_state(state: State) {
        transfer::share_object(state);
    }

    // === Getters ===

    public fun roles(state: &State): &Roles {
        &state.roles
    }

    public fun compatible_versions(state: &State): &VecSet<u64> {
        &state.compatible_versions
    }

    /// Whether the handler's `MintCap<USDC>` has been set.
    public fun mint_cap_is_set(state: &State): bool {
        state.mint_cap.is_some()
    }

    // === Public-Package Functions ===

    public(package) fun roles_mut(state: &mut State): &mut Roles {
        &mut state.roles
    }

    /// Stores the handler's `MintCap<USDC>`. Aborts (via `Option::fill`) if one
    /// is already set; callers should guard with `mint_cap_is_set` for a
    /// descriptive error.
    public(package) fun set_mint_cap(state: &mut State, mint_cap: MintCap<USDC>) {
        state.mint_cap.fill(mint_cap);
    }

    /// Borrows the handler's `MintCap<USDC>`. Aborts if not set (call
    /// `mint_cap_is_set` first).
    public(package) fun mint_cap(state: &State): &MintCap<USDC> {
        state.mint_cap.borrow()
    }

    /// Removes and returns the handler's `MintCap<USDC>`. Aborts if not set
    /// (guard with `mint_cap_is_set`). Inverse of `set_mint_cap`.
    public(package) fun remove_mint_cap(state: &mut State): MintCap<USDC> {
        state.mint_cap.extract()
    }

    public(package) fun add_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.insert(version);
    }

    public(package) fun remove_compatible_version(state: &mut State, version: u64) {
        state.compatible_versions.remove(&version);
    }

    // === Test Functions ===
    #[test_only] use std::unit_test;

    #[test]
    fun state_new_creates_object() {
      let ctx = &mut tx_context::dummy();

      let expected_role = @0x1;
      let new_version = 5;

      let mut state_obj = new(expected_role, ctx);

      assert!(state_obj.roles().owner() == expected_role);
      assert!(state_obj.roles().pending_owner() == option::none());
      // mint_controller defaults to the deployer alongside owner
      assert!(state_obj.roles().mint_controller() == expected_role);

      // mint_cap starts unset (added post-deploy via mint_controller)
      assert!(!state_obj.mint_cap_is_set());

      // compatible_versions: add + remove round-trip
      assert!(state_obj.compatible_versions().contains(&version_control::current_version()));
      state_obj.add_compatible_version(new_version);
      assert!(state_obj.compatible_versions().contains(&new_version));
      state_obj.remove_compatible_version(new_version);
      assert!(!state_obj.compatible_versions().contains(&new_version));

      unit_test::destroy(state_obj);
    }
}
