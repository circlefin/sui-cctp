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

/// Module: mint_controller
/// Admin entries for managing the handler's `MintCap<USDC>` in `State`:
/// `add_mint_cap` (one-shot deposit) and `remove_mint_cap` (rotation/recovery,
/// requires the cap be de-authorized on the treasury first). Both are gated on
/// the `mint_controller` role. Analog of
/// `token_messenger_minter_v2::token_controller::{add,remove}_stablecoin_mint_cap`.
module stablecoin_handler::mint_controller {
    // === Imports ===
    use sui::event;
    use stablecoin::treasury::{MintCap, Treasury, is_authorized_mint_cap};
    use usdc::usdc::USDC;
    use stablecoin_handler::{
        state::State,
        version_control::assert_object_version_is_compatible_with_package
    };

    // === Errors ===
    /// Caller is not the `mint_controller`.
    const ENotMintController: u64 = 0;
    /// A `MintCap` is already stored (one-shot add).
    const EMintCapAlreadySet: u64 = 1;
    /// No `MintCap` is stored to remove.
    const EMintCapNotSet: u64 = 2;
    /// The `MintCap` is still authorized on the treasury; de-authorize it
    /// (`treasury::remove_minter`) before removing.
    const EMintCapNotDeAuthorized: u64 = 3;

    // === Events ===
    public struct MintCapAdded has copy, drop { mint_cap_id: ID }
    public struct MintCapRemoved has copy, drop { mint_cap_id: ID }

    // === Admin Functions ===

    /// `mint_controller`-only. Stores the handler's `MintCap<USDC>` so
    /// `mint` can mint on the destination side. One-shot: aborts if
    /// a cap is already set. The cap is created + transferred to the
    /// `mint_controller` by the stablecoin treasury's minter configuration at
    /// deploy time; this moves it into the handler's shared `State`.
    entry fun add_mint_cap(mint_cap: MintCap<USDC>, state: &mut State, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        assert!(state.roles().mint_controller() == ctx.sender(), ENotMintController);
        assert!(!state.mint_cap_is_set(), EMintCapAlreadySet);

        let mint_cap_id = object::id(&mint_cap);
        state.set_mint_cap(mint_cap);
        event::emit(MintCapAdded { mint_cap_id });
    }

    /// `mint_controller`-only. Removes the handler's `MintCap<USDC>` and returns
    /// it to the caller — for minter rotation, fixing a mis-installed cap, or
    /// reclaiming it on decommission. Requires the cap be de-authorized on the
    /// treasury first (`treasury::remove_minter`), so an active mint authority
    /// can't be pulled out from under the receive path by accident. Mirrors
    /// TMM's `token_controller::remove_stablecoin_mint_cap`.
    #[allow(lint(self_transfer))]
    entry fun remove_mint_cap(state: &mut State, treasury: &Treasury<USDC>, ctx: &TxContext) {
        assert_object_version_is_compatible_with_package(state.compatible_versions());
        assert!(state.roles().mint_controller() == ctx.sender(), ENotMintController);
        assert!(state.mint_cap_is_set(), EMintCapNotSet);
        assert!(!is_authorized_mint_cap(treasury, object::id(state.mint_cap())), EMintCapNotDeAuthorized);

        let mint_cap = state.remove_mint_cap();
        event::emit(MintCapRemoved { mint_cap_id: object::id(&mint_cap) });
        transfer::public_transfer(mint_cap, ctx.sender());
    }

    // === Test Functions ===

    #[test_only]
    public(package) fun create_mint_cap_added_event(mint_cap_id: ID): MintCapAdded {
        MintCapAdded { mint_cap_id }
    }

    #[test_only]
    public(package) fun create_mint_cap_removed_event(mint_cap_id: ID): MintCapRemoved {
        MintCapRemoved { mint_cap_id }
    }
}
