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

/// Module: handle_receive_message
/// Contains public methods for handling incoming cross-chain stablecoin transfers.
/// 
/// Please see message_transmitter::receive_message for starting the receive message flow.
/// Messages should be received in PTBs.
/// After calling message_transmitter::receive_message::receive_message, one should call 
/// handle_receive_message from this module, followed by message_transmitter::receive_message::complete_receive_message.
///
/// Note on upgrades: It is recommended to call all of these public 
/// methods from PTBs rather than directly from other packages. 
/// These functions are version gated, so if the package is upgraded, 
/// the upgraded package must be called. In most cases, we will provide 
/// a migration period where both package versions are callable for a
/// period of time to avoid breaking all callers immediately.
module token_messenger_minter::handle_receive_message {
  // === Imports ===
  use sui::{
    deny_list::{DenyList},
    event::emit
  };
  use message_transmitter::{
    receive_message::{
      StampedReceipt, 
      Receipt, 
      stamp_receipt
    },
    state::{State as MessageTransmitterState}
  };
  use stablecoin::treasury::{Self, Treasury, MintCap};
  use token_messenger_minter::{
    burn_message,
    message_transmitter_authenticator,
    state::{State},
    token_utils::{calculate_token_id},
    version_control::assert_object_version_is_compatible_with_package
  };

  // === Errors ===
  const EUnknownRemoteDomain: u64 = 0;
  const EInvalidRemoteTokenMessenger: u64 = 1;
  const EInvalidBurnMessageVersion: u64 = 2;
  const EUnknownBurnToken: u64 = 3;
  const EInvalidTokenType: u64 = 4;
  const EMissingMintCap: u64 = 5;
  const EPaused: u64 = 6;
  const EAmountOverflow: u64 = 7;

  // === Constants === 
  const MAX_U64: u256 = 18_446_744_073_709_551_615;

  // === Events ===
  public struct MintAndWithdraw has copy, drop {
    mint_recipient: address,
    amount: u64,
    mint_token: address
  }

  // === Public-Mutative Functions ===

  /// Handles an incoming message from message_transmitter, and mints 
  /// the specified token to the recipient for valid messages. Can only be called with 
  /// a mutable reference to a Receipt object, which can only be created via the 
  /// message_transmitter::receive_message function.
  /// 
  /// Reverts if:
  /// - Contract is paused
  /// - Receipt is already stamped (e.g. has already been acknowledged by this module)
  /// - Message body is not a valid BurnMessage
  /// - Remote resources are unknown or invalid (remote token messenger or remote burned token are unknown)
  /// - No MintCap for local token exists
  /// - Invalid BurnMessage version
  /// - stablecoin::mint call fails (insufficient minter allowance, deny list checks, etc.)
  /// 
  /// Parameters:
  /// - receipt: Receipt object returned from message_transmitter::receive_message.
  ///            Receipt is consumed into a StampedReceipt in stamp_receipt call which 
  ///            prevents message replays (since Receipt does not have the copy ability).
  /// - state: TokenMessengerMinter shared state object.
  /// - mt_state: MessageTransmitter shared state object.
  /// - deny_list: DenyList shared object for the stablecoin token T.
  /// - treasury: Treasury shared object for the stablecoin token T.
  /// - ctx: TxContext for the tx.
  public fun handle_receive_message<T: drop>(
    receipt: Receipt, 
    state: &mut State,
    mt_state: &MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &mut TxContext
  ): StampedReceipt {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert!(!state.paused(), EPaused);

    let remote_domain = receipt.source_domain();
    let burn_message = burn_message::from_bytes(receipt.message_body());
    let burn_token_id = burn_message.burn_token();
    assert!(burn_message.amount() <= MAX_U64, EAmountOverflow);
    let amount = burn_message.amount() as u64;
    
    // Validate the token messenger is setup correctly for the given message.
    // Requires a valid remote token messenger, correct message version, a remote token, and a mint cap.
    validate_remote_token_messenger(remote_domain, receipt.sender(), state);
    validate_burn_message_version(burn_message.version(), state);
    let local_token_id = validate_and_return_local_token<T>(remote_domain, burn_token_id, state);
    let mint_cap = validate_and_return_mint_cap(local_token_id, state);

    // Mint the Coin directly to the mint recipient
    treasury::mint(
      treasury, 
      mint_cap, 
      deny_list, 
      amount, 
      burn_message.mint_recipient(), 
      ctx
    );

    emit(
      MintAndWithdraw {
        mint_recipient: burn_message.mint_recipient(),
        amount,
        mint_token: local_token_id
      }
    );

    // Stamp the receipt so message_transmitter knows we acknowledged the message
    let auth = message_transmitter_authenticator::new();
    let stamped_receipt = stamp_receipt(receipt, auth, mt_state);

    stamped_receipt
  }

  // === Private-Functions ===
  
  /// Validates that a valid known remote token messenger exists for the given remote domain and sender.
  fun validate_remote_token_messenger(remote_domain: u32, sender: address, state: &State) {
    assert!(state.remote_token_messenger_for_remote_domain_exists(remote_domain), EUnknownRemoteDomain);
    let remote_token_messenger = state.remote_token_messenger_from_remote_domain(remote_domain);
    assert!(
      remote_token_messenger == sender && sender != @0x0, 
      EInvalidRemoteTokenMessenger
    );
  }

  /// Validates a valid known local token exists for the given remote domain, burn token, and Coin type T.
  /// Returns the local token id for the given remote domain and token.
  fun validate_and_return_local_token<T: drop>(remote_domain: u32, burn_token_id: address, state: &State): address {
    assert!(
      state.local_token_from_remote_token_exists(remote_domain, burn_token_id), 
      EUnknownBurnToken
    );

    let local_token_id = state.local_token_from_remote_token(
      remote_domain, burn_token_id
    );
    assert!(calculate_token_id<T>() == local_token_id, EInvalidTokenType);

    local_token_id
  }

  /// Validates that a valid known MintCap exists for the given local token id.
  fun validate_and_return_mint_cap<T: drop>(local_token_id: address, state: &State): &MintCap<T> {
    assert!(
      state.mint_cap_for_local_token_exists(local_token_id), 
      EMissingMintCap
    );
    state.mint_cap_from_token_id<MintCap<T>>(
      local_token_id
    )
  }

  fun validate_burn_message_version(version: u32, state: &State) {
    assert!(version == state.message_body_version(), EInvalidBurnMessageVersion);
  }

  // === Test-Functions ===
  #[test_only]
  public fun create_mint_and_withdraw_event(
    mint_recipient: address,
    amount: u64,
    mint_token: address
  ): MintAndWithdraw {
    MintAndWithdraw {
      mint_recipient, amount, mint_token
    }
  }
}

#[test_only]
module token_messenger_minter::invalid_test_token {
    public struct INVALID_TEST_TOKEN has drop {}
}

#[test_only]
module token_messenger_minter::handle_receive_message_tests {
    use sui::{
        coin,
        deny_list::{Self, DenyList},
        event::{num_events},
        test_scenario::{Self, Scenario},
        test_utils::{Self, assert_eq}
    };
    use stablecoin::treasury::{Self, Treasury, MintCap};
    use token_messenger_minter::{
        burn_message,
        handle_receive_message::{Self, MintAndWithdraw, create_mint_and_withdraw_event},
        invalid_test_token::{INVALID_TEST_TOKEN},
        message_transmitter_authenticator::MessageTransmitterAuthenticator,
        state as token_messenger_state,
        token_utils::calculate_token_id,
        version_control
    };
    use message_transmitter::{
      receive_message::{Self, complete_receive_message},
      send_message::auth_caller_identifier,
      state as message_transmitter_state,
    };
    use sui_extensions::test_utils::last_event_by_type;

    public struct HANDLE_RECEIVE_MESSAGE_TESTS has drop {}

    const USER: address = @0x1A;
    const ADMIN: address = @0x2B;
    const LOCAL_DOMAIN: u32 = 0;
    const REMOTE_DOMAIN: u32 = 1;
    const REMOTE_TOKEN_MESSENGER: address = @0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1;
    const REMOTE_TOKEN: address = @0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    const MINT_RECIPIENT: address = @0x1f26414439c8d03fc4b9ca912cefd5cb508c9605;
    const AMOUNT: u64 = 1214;
    const VERSION: u32 = 0;
    const MAX_U64: u256 = 18_446_744_073_709_551_615;

    #[test]
    public fun test_handle_receive_message_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
          mint_cap, &mut scenario
        );

        scenario.next_tx(USER);
        {
          // Get a fake receipt. In real scenarios this would be returned from receive_message.
          let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message::get_raw_test_message(),
            1
          );

          let stamped_receipt = handle_receive_message::handle_receive_message(
              receipt,
              &mut token_messenger_state,
              &message_transmitter_state,
              &deny_list,
              &mut treasury,
              scenario.ctx()
          );

          complete_receive_message(stamped_receipt, &message_transmitter_state);
        };

        // 3 events -- Mint, MintAndWithdraw, MessageReceived
        assert_eq(num_events(), 3);
        let emitted_mint_and_withdraw_event = last_event_by_type<MintAndWithdraw>();
        let expected_event = create_mint_and_withdraw_event(
          MINT_RECIPIENT, AMOUNT, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>()
        );
        assert_eq(emitted_mint_and_withdraw_event, expected_event);

        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EPaused)]
    public fun test_handle_receive_message_revert_paused() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Set state to paused
        token_messenger_state.set_paused(true);

        scenario.next_tx(USER);
        {
            let receipt = receive_message::create_receipt(
              USER,
                @token_messenger_minter,
                REMOTE_DOMAIN,
                REMOTE_TOKEN_MESSENGER,
                12,
                burn_message::get_raw_test_message(),
            1
            );

            let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
                &mut token_messenger_state,
                &message_transmitter_state,
                &deny_list,
                &mut treasury,
                scenario.ctx()
            );
            test_utils::destroy(stamped_receipt);
        };

        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EUnknownRemoteDomain)]
    public fun test_handle_receive_message_revert_unknown_remote_domain() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a remote domain that is not set up
        let receipt = receive_message::create_receipt(
          USER,
            @token_messenger_minter,
            REMOTE_DOMAIN + 1,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
            receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EAmountOverflow)]
    public fun test_handle_receive_message_revert_amount_overflow() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a new burn message with a very large amount
        let burn_message = burn_message::new(
            VERSION,
            REMOTE_TOKEN,
            MINT_RECIPIENT,
            MAX_U64 + 1,
              REMOTE_TOKEN_MESSENGER
        );
        let receipt = receive_message::create_receipt(
          USER,
            @token_messenger_minter,
            REMOTE_DOMAIN + 1,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message.serialize(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
            receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidRemoteTokenMessenger)]
    public fun test_handle_receive_message_revert_invalid_remote_token_messenger() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a different remote token messenger than the one set up
        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            @0x2B,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidRemoteTokenMessenger)]
    public fun test_handle_receive_message_revert_null_address_remote_token_messenger() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Add 0x0 remote token messenger to ensure it still reverts.
        token_messenger_state.remove_remote_token_messenger(REMOTE_DOMAIN);
        token_messenger_state.add_remote_token_messenger(REMOTE_DOMAIN, @0x0);

        // Use a different remote token messenger than the one set up
        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            @0x0,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidBurnMessageVersion)]
    public fun test_handle_receive_message_revert_invalid_burn_message_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a burn message with a different version than the one set up
        let burn_message_with_different_version = burn_message::new(
            VERSION + 1,
            REMOTE_TOKEN,
            MINT_RECIPIENT,
            AMOUNT as u256,
            REMOTE_TOKEN_MESSENGER
        ).serialize();
        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message_with_different_version,
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
            receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EUnknownBurnToken)]
    public fun test_handle_receive_message_revert_unknown_burn_token() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a remote token that is not set up
        let burn_message_with_different_token = burn_message::new(
            VERSION,
            @0x12345,
            MINT_RECIPIENT,
            AMOUNT as u256,
            REMOTE_TOKEN_MESSENGER
        ).serialize();
        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message_with_different_token,
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
            receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidTokenType)]
    public fun test_handle_receive_message_revert_invalid_token_type() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Use a local token ID that does not match the expected token type
        token_messenger_state.remove_local_token_for_remote_token(REMOTE_DOMAIN, REMOTE_TOKEN);
        token_messenger_state.add_local_token_for_remote_token(REMOTE_DOMAIN, REMOTE_TOKEN, @0x12345);

        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidTokenType)]
    public fun test_handle_receive_message_revert_invalid_generic_token_type() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Setup a second token with a different type that token_messenger doesn't know about to try to pass in
        let (mint_cap_2, mut treasury_2, deny_list_2) = setup_coin<INVALID_TEST_TOKEN>(&mut scenario);

        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
            receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list_2,
            &mut treasury_2,
            scenario.ctx()
        );

        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(deny_list_2);
        test_utils::destroy(treasury);
        test_utils::destroy(treasury_2);
        test_utils::destroy(mint_cap_2);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EMissingMintCap)]
    public fun test_handle_receive_message_revert_missing_mint_cap() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );

        // Remove the mint cap for the local token
        let mint_cap = token_messenger_state.remove_mint_cap<MintCap<HANDLE_RECEIVE_MESSAGE_TESTS>>(
            calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>()
        );

        let receipt = receive_message::create_receipt(
            USER,
            @token_messenger_minter,
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            12,
            burn_message::get_raw_test_message(),
            1
        );

        let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
            &mut token_messenger_state,
            &message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );

        test_utils::destroy(mint_cap);
        test_utils::destroy(stamped_receipt);
        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    public fun test_handle_receive_message_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(
            mint_cap, &mut scenario
        );
        token_messenger_state.add_compatible_version(5);
        token_messenger_state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(USER);
        {
            let receipt = receive_message::create_receipt(
              USER,
                @token_messenger_minter,
                REMOTE_DOMAIN,
                REMOTE_TOKEN_MESSENGER,
                12,
                burn_message::get_raw_test_message(),
            1
            );

            let stamped_receipt = handle_receive_message::handle_receive_message(
                receipt,
                &mut token_messenger_state,
                &message_transmitter_state,
                &deny_list,
                &mut treasury,
                scenario.ctx()
            );
            test_utils::destroy(stamped_receipt);
        };

        test_utils::destroy(token_messenger_state);
        test_utils::destroy(message_transmitter_state);
        test_utils::destroy(deny_list);
        test_utils::destroy(treasury);
        scenario.end();
    }

    // === Test-Functions ===

    fun setup_coin<T: drop>(
      scenario: &mut Scenario
    ): (MintCap<T>, Treasury<T>, DenyList) {
      let otw = test_utils::create_one_time_witness<T>();
      let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
            otw,
            6,
            b"SYMBOL",
            b"NAME",
            b"",
            option::none(),
            true,
            scenario.ctx()
        );
        
        let mut treasury = treasury::new(
            treasury_cap, 
            deny_cap, 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx().sender(), 
            scenario.ctx()
        );
      treasury.configure_new_controller(ADMIN, ADMIN, scenario.ctx());
      scenario.next_tx(ADMIN);
      let mint_cap = scenario.take_from_address<MintCap<T>>(ADMIN);
      let deny_list = deny_list::new_for_testing(scenario.ctx());
      treasury.configure_minter(&deny_list, 999999999, scenario.ctx());
      test_utils::destroy(metadata);


      // Mint some coins for the user
      treasury::mint(
        &mut treasury, &mint_cap, &deny_list, AMOUNT as u64, USER, scenario.ctx()
      );

      (mint_cap, treasury, deny_list)
    }

    fun setup_cctp_states(
      mint_cap: MintCap<HANDLE_RECEIVE_MESSAGE_TESTS>, 
      scenario: &mut Scenario
    ): (token_messenger_state::State, message_transmitter_state::State) {
      let ctx = test_scenario::ctx(scenario);
      
      let mut token_messenger_state = token_messenger_state::new(VERSION, ADMIN, ctx);
      let message_transmitter_state = message_transmitter_state::new_for_testing(
        LOCAL_DOMAIN, VERSION, 1000, ADMIN, ctx
      );

      // Setup necessary state
      token_messenger_state.add_remote_token_messenger(
        REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER
      );
      token_messenger_state.add_mint_cap(
        calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), mint_cap
      );
      token_messenger_state.add_local_token_for_remote_token(
        REMOTE_DOMAIN, REMOTE_TOKEN, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>()
      );
      token_messenger_state.add_burn_limit(
        calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), 1000000
      );

      (token_messenger_state, message_transmitter_state)
    }
}
