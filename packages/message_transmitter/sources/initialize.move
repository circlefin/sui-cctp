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

/// Module: initialize
/// This module contains initialization logic for the message_transmitter package
module message_transmitter::initialize {
  // === Imports ===
  use message_transmitter::state::{Self};
  use message_transmitter::attester_manager::{Self};
  use sui_extensions::upgrade_service;

  // === Structs ===
  public struct InitCap has key, store {
    id: UID
  }

  public struct INITIALIZE has drop {}

  // === Admin Functions ===
  
  #[allow(lint(share_owned))]
  /// init (automatically called at deployment) transfers 
  /// an InitCap to the sender so they can call init_state 
  /// to initialize state with parameters.
  /// Also creates and shares the wrapped Upgrade Service.
  fun init(witness: INITIALIZE, ctx: &mut TxContext) {
    let (upgrade_service, _witness) = upgrade_service::new(
        witness,
        ctx.sender() /* admin */,
        ctx
    );
    transfer::public_share_object(upgrade_service);
    transfer::transfer(InitCap {id: object::new(ctx)}, ctx.sender());
  }

  /// Initializes and shares the State object. 
  /// Initializes state with given local_domain, message_version, max_message_body_size,
  /// attester, all roles set to the tx sender, and paused set to false.
  /// Requires (and destroys) an InitCap object which can only be created in init method, 
  /// therefore this function can only be called once. 
  public fun init_state(init_cap: InitCap, local_domain: u32, message_version: u32, max_message_body_size: u64, attester: address, ctx: &mut TxContext) {
    let mut state = state::new(local_domain, message_version, max_message_body_size, ctx.sender(), ctx);
    attester_manager::enable_attester_internal(attester, &mut state, ctx);
    state.share_state();

    // Delete the init cap so init_state can only be called once
    let InitCap {id} = init_cap;
    object::delete(id);
  }

  // === Test Functions ===
  #[test_only] use sui::test_scenario::{Self};
  #[test_only] use message_transmitter::state::{State};

  #[test]
  public fun test_init_successful() {
    let mut scenario = test_scenario::begin(@0x0);
  
    // Test: When package is deployed InitCap is transferred to caller
    init(INITIALIZE {}, scenario.ctx());
    let effects = scenario.next_tx(@0x1);
    let created_init_cap_id = effects.created()[1];
    assert!(effects.transferred_to_account()[&created_init_cap_id] == @0x0);
    // Aborts if it doesn't exist 
    let created_init_cap = scenario.take_from_address_by_id<InitCap>(@0x0, created_init_cap_id);
    test_scenario::return_to_address(@0x0, created_init_cap);

    // Clean up
    scenario.end();
  }

  #[test]
  fun test_init_state_successful() {
    let mut scenario = test_scenario::begin(@0x0);
    
    // Get InitCap to call init_state
    let init_cap = InitCap {id: object::new(scenario.ctx())};
    let init_cap_id = object::id(&init_cap);
    
    // Test: After init_state is called, shared_state was shared and InitCap was deleted.
    scenario.next_tx(@0x5);
    {
      init_state(init_cap, 1, 1, 1, @0x1, scenario.ctx());
      let effects = scenario.next_tx(@0x0);
      let shared_state = scenario.take_shared<State>();

      assert!(effects.shared().length() == 1, 0);
      assert!(effects.shared()[0] == object::id(&shared_state), 1);
      assert!(effects.deleted().contains(&init_cap_id), 2);

      test_scenario::return_shared(shared_state);
    };

    scenario.end();
  }
}
