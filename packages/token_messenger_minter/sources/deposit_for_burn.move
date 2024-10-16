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

/// Module: deposit_for_burn
/// Contains public methods for sending cross-chain USDC transfers.
/// 
/// Note on upgrades: If interacting with this module from other packages, it
/// is recommended to call the _with_package_auth methods from PTBs rather than 
/// directly from dependent packages. These functions are version gated, so if 
/// the package is upgraded, the upgraded package must be called. 
module token_messenger_minter::deposit_for_burn {

  // === Imports ===
  use sui::{
    coin::{Coin}, 
    deny_list::{DenyList},
    event::emit
  };
  use stablecoin::{treasury::{Self, MintCap, Treasury}};
  use message_transmitter::{
    auth::auth_caller_identifier,
    message::{Self, Message},
    send_message::{
      create_send_message_ticket, 
      create_send_message_with_caller_ticket, 
      create_replace_message_ticket, 
      replace_message, 
      send_message, 
      send_message_with_caller
    },
    state::{State as MessageTransmitterState}
  };
  use token_messenger_minter::{
    burn_message::{Self, BurnMessage},
    message_transmitter_authenticator,
    state::{State},
    token_utils::{calculate_token_id},
    version_control::{assert_object_version_is_compatible_with_package}
  };

  // === Errors ===
  const EZeroAmount: u64 = 0;
  const EZeroAddressMintRecipient: u64 = 1;
  const EInvalidDestinationDomain: u64 = 2;
  const EPaused: u64 = 3;
  const EMissingMintCap: u64 = 4;
  const EMissingBurnLimit: u64 = 5;
  const EBurnLimitExceeded: u64 = 6;
  const ESenderDoesNotMatchOriginalSender: u64 = 7;

  // === Events ===
  public struct DepositForBurn has copy, drop {
    nonce: u64,
    burn_token: address,
    amount: u64,
    depositor: address,
    mint_recipient: address,
    destination_domain: u32,
    destination_token_messenger: address,
    destination_caller: address,
  }

  // === Public-Mutative Functions ===

  /// Burns tokens to be minted on destination domain and sends a
  /// message through the MessageTransmitter package. 
  /// Intended to be called directly by EOA (rather than a dependent package).
  /// The initiating EOA will be the "owner" (e.g. message sender) of the message and
  /// have the ability to call replace_deposit_for_burn.
  /// 
  /// Reverts if:
  /// - given burn token T is not supported
  /// - given destinationDomain has no TokenMessenger registered
  /// - burn limit per message is exceeded
  /// - burn() reverts. For example, if `amount` is 0.
  /// - invalid (e.g. 0x0) mint_recipient is given
  /// - message_transmitter::send_message reverts
  /// - contract is paused
  /// 
  /// Parameters:
  /// - coins: Coin of type T to be burned. Full amount in coins will be burned.
  /// - destination_domain: domain to mint tokens on 
  /// - mint_recipient: address of mint recipient on destination domain 
  ///                   Note: If destination is a non-Move chain, mint_recipient 
  ///                   address should be converted to hex and passed in in the 
  ///                   @0x123 address format.
  /// - state: State shared object for the TokenMessengerMinter package.
  /// - deny_list: DenyList shared object for the stablecoin token T.
  /// - treasury: Treasury shared object for the stablecoin token T.
  /// - ctx: TxContext for the tx
  entry fun deposit_for_burn<T: drop>(
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address, 
    state: &State,
    message_transmitter_state: &mut MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    let message_sender = ctx.sender();
    deposit_for_burn_shared(
      coins, destination_domain, mint_recipient, @0x0, message_sender,
      state, message_transmitter_state, deny_list, treasury, ctx
    )
  }

  /// Burns tokens to be minted on destination domain and sends a
  /// message through the MessageTransmitter package. 
  /// Intended to be called with Auth struct from a dependent package. The calling package 
  /// will be the "owner" (e.g. message_sender) of the message and have the ability to call replace_deposit_for_burn_with_package_auth.
  /// Direct callers (where EOAs should be the owner) should use deposit_for_burn instead.
  /// 
  /// This function uses a DepositForBurnTicket for parameters so that the calling package can 
  /// call create_deposit_for_burn_ticket (not version-gated) from their package with parameters, and call 
  /// deposit_for_burn_with_package_auth (version-gated) from a PTB so packages don't have to be updated
  /// during CCTP package upgrades. DepositForBurnTicket also requires an Auth parameter. This is required to 
  /// securely assign a sender address associated with the calling contract to the message.
  /// Any struct that implements the drop trait can be used as an authenticator, but it is recommended to 
  /// use a dedicated auth struct. Calling contracts should be careful to not expose these objects to the 
  /// public or else messages from their package could be replaced.
  /// 
  /// Parameters:
  /// - deposit_for_burn_ticket: Struct containing parameters and authenticator struct. 
  /// - deny_list: DenyList shared object for the stablecoin token T.
  /// - treasury: Treasury shared object for the stablecoin token T.
  /// - ctx: TxContext for the tx
  public fun deposit_for_burn_with_package_auth<T: drop, Auth: drop>(
    deposit_for_burn_ticket: DepositForBurnTicket<T, Auth>,
    state: &State,
    message_transmitter_state: &mut MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    let DepositForBurnTicket { 
      auth: _auth, 
      coins, 
      destination_domain, 
      mint_recipient 
    } = deposit_for_burn_ticket;

    // Since this is called from another package, message_sender is the auth caller identifier from the given auth struct.
    let message_sender = auth_caller_identifier<Auth>();
    deposit_for_burn_shared(
      coins, destination_domain, mint_recipient, @0x0, message_sender,
      state, message_transmitter_state, deny_list, treasury, ctx
    )
  }

  /// Same as deposit_for_burn, except the receive_message call on the destination 
  /// domain must be called by `destination_caller`.
  /// Intended to be called directly by EOA (rather than a dependent package).
  /// 
  /// WARNING: if the `destination_caller` does not represent a valid address, then 
  /// it will not be possible to broadcast the message on the destination domain. 
  /// This is an advanced feature, and the standard deposit_for_burn() should be 
  /// preferred for use cases where a specific destination caller is not required.
  /// 
  /// Note: If destination is a non-Move chain, destination_caller address should 
  /// be converted to hex and passed in in the @0x123 address format.
  entry fun deposit_for_burn_with_caller<T: drop>(
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address, 
    destination_caller: address,
    state: &State,
    message_transmitter_state: &mut MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    deposit_for_burn_shared(
      coins, destination_domain, mint_recipient, destination_caller, ctx.sender(), 
      state, message_transmitter_state, deny_list, treasury, ctx
    )
  }

  /// Same as deposit_for_burn_with_package_auth, except the receive_message call on the destination 
  /// domain must be called by `destination_caller`.
  /// Intended to be called from a dependent package. The calling package 
  /// will be the "owner" of the message and be able to call replace_deposit_for_burn.
  /// Direct EOA (non-package) callers should use deposit_for_burn_with_caller instead.
  /// 
  /// This function uses a DepositForBurnWithCallerTicket for parameters so that the calling package can 
  /// call create_deposit_for_burn_with_caller_ticket (not version-gated) from their package, and call 
  /// deposit_for_burn_with_caller_with_package_auth (version-gated) from a PTB so packages don't have to be updated
  /// during upgrades.
  /// 
  /// WARNING: if the `destination_caller` does not represent a valid address, then 
  /// it will not be possible to broadcast the message on the destination domain. 
  /// This is an advanced feature, and the standard deposit_for_burn() should be 
  /// preferred for use cases where a specific destination caller is not required.
  /// 
  /// Note: If destination is a non-Move chain, destination_caller address should 
  /// be converted to hex and passed in in the @0x123 address format.
  public fun deposit_for_burn_with_caller_with_package_auth<T: drop, Auth: drop>(
    deposit_for_burn_with_caller_ticket: DepositForBurnWithCallerTicket<T, Auth>,
    state: &State,
    message_transmitter_state: &mut MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    let DepositForBurnWithCallerTicket { 
      auth: _auth, 
      coins, 
      destination_domain, 
      mint_recipient ,
      destination_caller
    } = deposit_for_burn_with_caller_ticket;

    let sender_identifier = auth_caller_identifier<Auth>();
    deposit_for_burn_shared(
      coins, destination_domain, mint_recipient, destination_caller, sender_identifier,
      state, message_transmitter_state, deny_list, treasury, ctx
    )
  }

  /// Allows the sender of a previous BurnMessage (created by depositForBurn or 
  /// depositForBurnWithCaller) to send a new BurnMessage to replace the original as
  /// long as they have a valid attestation for the message. 
  /// The new BurnMessage will re-use the amount and burn token of the original, 
  /// without requiring a new Coin deposit. The new message will reuse the original 
  /// message's nonce. For a given nonce, all replacement message(s) and the 
  /// original message are valid to broadcast on the destination domain, until 
  /// the first message at the nonce confirms, at which point all others are invalidated.
  /// 
  /// Intended to be called by an EOA where an EOA was the message_sender of the message. 
  /// Messages owned by Auth identifiers should use replace_deposit_for_burn_with_package_auth.
  /// 
  /// Reverts if:
  /// - original message or attestation are invalid
  /// - tx sender is not the original message sender
  /// - new mint recipient is null address (0x0)
  /// - message_transmitter::replace_message fails
  /// 
  /// Parameters:
  /// - original_raw_message: original message in bytes.
  /// - original_attestation: valid attestation for the original message in bytes.
  /// - new_destination_caller: new destination caller for message, can be @0x0 for no caller, 
  ///                           defaults to destination_caller of original_message.
  /// - new_mint_recipient: new mint recipient for the message, defaults to mint_recipient of original_message..
  entry fun replace_deposit_for_burn(
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_destination_caller: Option<address>,
    new_mint_recipient: Option<address>,
    state: &State,
    message_transmitter_state: &MessageTransmitterState,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    replace_deposit_for_burn_shared(
      original_raw_message, original_attestation, new_destination_caller, 
      new_mint_recipient, ctx.sender(), state, message_transmitter_state
    )
  }

  /// The same as replace_deposit_for_burn, but intended to be called from 
  /// a dependent package. Identifies sender from the unique identifier from the auth parameter.
  /// Intended to be called from a dependent package. The calling package 
  /// must be the sender of the original message from using deposit_for_burn_with_package_auth or deposit_for_burn_with_caller_with_package_auth.
  /// Direct callers should use replace_deposit_for_burn instead.
  /// 
  /// Parameters:
  /// - replace_deposit_for_burn_ticket: Struct containing parameters and authenticator struct. 
  public fun replace_deposit_for_burn_with_package_auth<Auth: drop>(
    replace_deposit_for_burn_ticket: ReplaceDepositForBurnTicket<Auth>,
    state: &State,
    message_transmitter_state: &MessageTransmitterState,
  ): (BurnMessage, Message) {
    let ReplaceDepositForBurnTicket { 
      auth: _auth,
      original_raw_message, 
      original_attestation, 
      new_destination_caller, 
      new_mint_recipient 
    } = replace_deposit_for_burn_ticket;

    // This function call is intended to come from a dependent package, 
    // so the sender is the auth caller identifier.
    let sender = auth_caller_identifier<Auth>();
    replace_deposit_for_burn_shared(
      original_raw_message, original_attestation, new_destination_caller, 
      new_mint_recipient, sender, state, message_transmitter_state
    )
  }

  // === Ticket Structs/Functions ===

  /// The following create_..._ticket functions are non version-gated functions, intended to be 
  /// called directly from other packages to create ticket structs that can be passed into public version-gated functions 
  /// outside of the calling package in a PTB. This prevents dependent packages from needing to be updated after CCTP upgrades.
  #[allow(lint(coin_field))]
  public struct DepositForBurnTicket<phantom T: drop, Auth: drop> {
    auth: Auth,
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address, 
  }

  /// Not version-gated so it can be safely called from a dependent package,
  /// and then passed to deposit_for_burn_with_package_auth (version-gated) from a PTB.
  /// See deposit_for_burn for parameter information.
  public fun create_deposit_for_burn_ticket<T: drop, Auth: drop>(
    auth: Auth,
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address
  ): DepositForBurnTicket<T, Auth> {
    DepositForBurnTicket { auth, coins, destination_domain, mint_recipient }
  }

  #[allow(lint(coin_field))]
  public struct DepositForBurnWithCallerTicket<phantom T: drop, Auth: drop> {
    auth: Auth,
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address, 
    destination_caller: address
  }

  /// Not version-gated so it can be safely called from a dependent package,
  /// and then passed to deposit_for_burn_with_caller_with_package_auth (version-gated) from a PTB.
  /// See deposit_for_burn for parameter information.
  public fun create_deposit_for_burn_with_caller_ticket<T: drop, Auth: drop>(
    auth: Auth,
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address,
    destination_caller: address
  ): DepositForBurnWithCallerTicket<T, Auth> {
    DepositForBurnWithCallerTicket { auth, coins, destination_domain, mint_recipient, destination_caller }
  }

  #[allow(lint(coin_field))]
  public struct ReplaceDepositForBurnTicket<Auth: drop> {
    auth: Auth,
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_destination_caller: Option<address>,
    new_mint_recipient: Option<address>,
  }

  /// Not version-gated so it can be safely called from a dependent package,
  /// and then passed to replace_deposit_for_burn_with_package_auth (version-gated) from a PTB.
  /// See replace_deposit_for_burn for parameter information.
  public fun create_replace_deposit_for_burn_ticket<Auth: drop>(
    auth: Auth,
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_destination_caller: Option<address>,
    new_mint_recipient: Option<address>,
  ): ReplaceDepositForBurnTicket<Auth> {
    ReplaceDepositForBurnTicket { auth, original_raw_message, original_attestation, new_destination_caller, new_mint_recipient }
  }

  // === Private Functions ===

  /// Shared functionality between deposit_for_burn and deposit_for_burn_with_caller.
  /// Performs validations, burns tokens, and calls message_transmitter::send_message
  /// to emit the cross-chain message.
  fun deposit_for_burn_shared<T: drop>(
    coins: Coin<T>, 
    destination_domain: u32, 
    mint_recipient: address, 
    destination_caller: address,
    message_sender: address,
    state: &State,
    message_transmitter_state: &mut MessageTransmitterState,
    deny_list: &DenyList,
    treasury: &mut Treasury<T>,
    ctx: &TxContext
  ): (BurnMessage, Message) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    let amount = coins.value();
    let token_id = calculate_token_id<T>();

    assert!(!state.paused(), EPaused);
    assert!(amount > 0, EZeroAmount);
    assert!(mint_recipient != @0x0, EZeroAddressMintRecipient);
    
    let destination_token_messenger = safe_get_remote_token_messenger(destination_domain, state);
    let mint_cap = safe_get_mint_cap(token_id, state);
    let burn_limit = safe_get_burn_limit(token_id, state);

    assert!(burn_limit >= amount, EBurnLimitExceeded);

    treasury::burn(treasury, mint_cap, deny_list, coins, ctx);

    let burn_message = burn_message::new(state.message_body_version(), token_id, mint_recipient, amount as u256, message_sender);

    let message = send_deposit_for_burn_message(
      destination_domain, 
      destination_token_messenger,
      destination_caller,
      &burn_message,
      message_transmitter_state
    );

    emit(DepositForBurn {
      nonce: message.nonce(), 
      burn_token: token_id, 
      amount, 
      depositor: message_sender, 
      mint_recipient, 
      destination_domain, 
      destination_token_messenger, 
      destination_caller
    });

    (burn_message, message)
  }

  /// Shared functionality between replace_deposit_for_burn and replace_deposit_for_burn_with_package_auth.
  /// Replaces a given BurnMessage if sender is the same as the original message sender.
  /// Returns the updated BurnMessage and Message.
  fun replace_deposit_for_burn_shared(
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_destination_caller: Option<address>,
    new_mint_recipient: Option<address>,
    sender: address,
    state: &State,
    message_transmitter_state: &MessageTransmitterState
  ): (BurnMessage, Message) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    let original_message_body = message::message_body_from_bytes(&original_raw_message);
    let mut burn_message = burn_message::from_bytes(&original_message_body);

    // sender could either be an EOA or an Auth identifier.
    assert!(burn_message.message_sender() == sender, ESenderDoesNotMatchOriginalSender);

    let final_new_mint_recipient = new_mint_recipient.get_with_default(burn_message.mint_recipient());
    assert!(final_new_mint_recipient != @0x0, EZeroAddressMintRecipient);
    burn_message.update_mint_recipient(final_new_mint_recipient);
    burn_message.update_version(state.message_body_version());

    let new_message_body = option::some(burn_message.serialize());

    let authenticator = message_transmitter_authenticator::new();
    let ticket = create_replace_message_ticket(
      authenticator, original_raw_message, original_attestation, new_message_body, new_destination_caller
    );
    let new_message = replace_message(
      ticket, message_transmitter_state
    ); 

    emit(DepositForBurn {
      nonce: new_message.nonce(), 
      burn_token: burn_message.burn_token(), 
      amount: burn_message.amount() as u64, 
      depositor: sender, 
      mint_recipient: final_new_mint_recipient, 
      destination_domain: new_message.destination_domain(), 
      destination_token_messenger: new_message.recipient(), 
      destination_caller: new_message.destination_caller()
    });

    (burn_message, new_message)
  }

  /// Fetches the remote token messsenger, first validating that it exists.
  fun safe_get_remote_token_messenger(remote_domain: u32, state: &State): address {
    assert!(state.remote_token_messenger_for_remote_domain_exists(remote_domain), EInvalidDestinationDomain);
    state.remote_token_messenger_from_remote_domain(remote_domain)
  }

  /// Fetches the mint cap, first validating that it exists.
  fun safe_get_mint_cap<T>(local_token_id: address, state: &State): &MintCap<T> {
    assert!(state.mint_cap_for_local_token_exists(local_token_id), EMissingMintCap);
    state.mint_cap_from_token_id<MintCap<T>>(local_token_id)
  }

  /// Fetches the burn limit, first validating that it exists.
  fun safe_get_burn_limit(local_token_id: address, state: &State): u64 {
    assert!(state.burn_limit_for_token_id_exists(local_token_id), EMissingBurnLimit);
    state.burn_limit_from_token_id(local_token_id)
  }

  /// Sends a message through message_transmitter package.
  fun send_deposit_for_burn_message(
    destination_domain: u32,
    destination_token_messenger: address,
    destination_caller: address,
    burn_message: &BurnMessage, 
    message_transmitter_state: &mut MessageTransmitterState
  ): Message {
    // Create a new message_transmitter_authenticator to pass to message_transmitter
    let authenticator = message_transmitter_authenticator::new();

    // Create the ticket and send the message. TokenMessengerMinter doesn't follow the pattern of returning the ticket
    // and calling send_message in a PTB because TokenMessengerMinter and MessageTransmitter are controlled by the same 
    // owner so upgrades can be coordinated between the two.
    let message;
    if (destination_caller == @0x0) {
      let ticket = create_send_message_ticket(authenticator, destination_domain, destination_token_messenger, burn_message.serialize());
      message = send_message(ticket, message_transmitter_state)
    } else {
      let ticket = create_send_message_with_caller_ticket(authenticator, destination_domain, destination_token_messenger, destination_caller, burn_message.serialize());
      message = send_message_with_caller(ticket, message_transmitter_state)
    };

    message
  }

  #[test_only]
  public fun create_deposit_for_burn_event(    
      nonce: u64,
      burn_token: address,
      amount: u64,
      depositor: address,
      mint_recipient: address,
      destination_domain: u32,
      destination_token_messenger: address,
      destination_caller: address
    ): DepositForBurn {
      DepositForBurn {nonce, burn_token, amount, depositor,mint_recipient, destination_domain, destination_token_messenger, destination_caller}
  }
}

#[test_only]
module token_messenger_minter::deposit_for_burn_tests {
  use sui::{
    coin::{Self, Coin},
    deny_list::{Self, DenyList},
    event::{num_events},
    test_scenario::{Self, Scenario},
    test_utils::{Self, assert_eq},
  };
  use message_transmitter::{
    attester_manager,
    auth::auth_caller_identifier,
    message::{Self, Message}, 
    message_transmitter_authenticator,
    state as message_transmitter_state,
  };
  use stablecoin::treasury::{Self, Treasury, MintCap};
  use token_messenger_minter::{
    burn_message::{Self, BurnMessage},
    deposit_for_burn,
    message_transmitter_authenticator::{MessageTransmitterAuthenticator},
    state as token_messenger_state,
    token_utils::calculate_token_id,
    version_control
  };
  use sui_extensions::test_utils::last_event_by_type;

  // Test token type
  public struct DEPOSIT_FOR_BURN_TESTS has drop {}

  const AMOUNT: u256 = 100;
  const ADMIN: address = @0xAD;
  const USER: address = @0xA1;
  const DESTINATION_DOMAIN: u32 = 2;
  const MINT_RECIPIENT: address = @0xB2;
  const DESTINATION_CALLER: address = @0xC3;
  const REMOTE_TOKEN_MESSENGER: address = @0xD4;

  const NEW_DESTINATION_CALLER: address = @0xABCD;
  const NEW_MINT_RECIPIENT: address = @0x5678;
  const ORIGINAL_MINT_RECIPIENT: address = @0x9ABC;

  // === Tests ===

  #[test]
  fun test_deposit_for_burn_successful() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Perform deposit_for_burn
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (burn_message, message) = deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        MINT_RECIPIENT,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );

      // Assert correct BurnMessage values
      assert_eq(burn_message.version(), 1);
      assert_eq(burn_message.burn_token(), calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
      assert_eq(burn_message.mint_recipient(), MINT_RECIPIENT);
      assert_eq(burn_message.amount(), AMOUNT);
      assert_eq(burn_message.message_sender(), USER);

      // Assert correct Message values
      assert_eq(message.version(), 1);
      assert_eq(message.source_domain(), 0);
      assert_eq(message.destination_domain(), 2);
      assert_eq(message.nonce(), 0);
      assert_eq(message.sender(), auth_caller_identifier<MessageTransmitterAuthenticator>());
      assert_eq(message.recipient(), REMOTE_TOKEN_MESSENGER);
      assert_eq(message.destination_caller(), @0x0);
      assert_eq(
        message.message_body(),
        x"00000001aa9d562b0a114a7cfa31074ac0ac0a543a25b034ba38830c82e7163775c94c8600000000000000000000000000000000000000000000000000000000000000b2000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000a1"
      );

      // num of events include message_sent, burn, and deposit for burn events
      assert!(num_events() == 3);
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(last_event_by_type<deposit_for_burn::DepositForBurn>() == deposit_for_burn::create_deposit_for_burn_event(0,burn_token, AMOUNT as u64, USER, MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, @0x0));
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  fun test_deposit_for_burn_with_package_auth_successful() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Perform deposit_for_burn
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let auth = message_transmitter_authenticator::new();
      let auth_id = auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>();
      let ticket = deposit_for_burn::create_deposit_for_burn_ticket(auth, coins, DESTINATION_DOMAIN, MINT_RECIPIENT);
      let (burn_message, message) = deposit_for_burn::deposit_for_burn_with_package_auth(
        ticket,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );

      // Assert correct BurnMessage values
      assert_eq(burn_message.version(), 1);
      assert_eq(burn_message.burn_token(), calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
      assert_eq(burn_message.mint_recipient(), MINT_RECIPIENT);
      assert_eq(burn_message.amount(), AMOUNT);
      assert_eq(burn_message.message_sender(), auth_id);

      // Assert correct Message values
      assert_eq(message.version(), 1);
      assert_eq(message.source_domain(), 0);
      assert_eq(message.destination_domain(), 2);
      assert_eq(message.nonce(), 0);
      assert_eq(message.sender(), auth_caller_identifier<MessageTransmitterAuthenticator>());
      assert_eq(message.recipient(), REMOTE_TOKEN_MESSENGER);
      assert_eq(message.destination_caller(), @0x0);
      assert_eq(
        message.message_body(),
        x"00000001aa9d562b0a114a7cfa31074ac0ac0a543a25b034ba38830c82e7163775c94c8600000000000000000000000000000000000000000000000000000000000000b20000000000000000000000000000000000000000000000000000000000000064949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfe"
      );

      // num of events include message_sent, burn, and deposit for burn events
      assert!(num_events() == 3);
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert_eq(
        last_event_by_type<deposit_for_burn::DepositForBurn>(),
        deposit_for_burn::create_deposit_for_burn_event(0,burn_token, AMOUNT as u64, auth_id, MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, @0x0)
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  fun test_deposit_for_burn_with_caller_successful() {
      let mut scenario = test_scenario::begin(ADMIN);
      let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
      let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
        mint_cap, &mut scenario
      );

      // Perform deposit_for_burn_with_caller
      scenario.next_tx(USER);
      {
        let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
        let (burn_message, message) = deposit_for_burn::deposit_for_burn_with_caller(
          coins,
          DESTINATION_DOMAIN,
          MINT_RECIPIENT,
          DESTINATION_CALLER,
          &token_messenger_state,
          &mut message_transmitter_state,
          &deny_list,
          &mut treasury,
          scenario.ctx()
        );

        // Assert correct BurnMessage values
        assert_eq(burn_message.version(), 1);
        assert_eq(burn_message.burn_token(), calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
        assert_eq(burn_message.mint_recipient(), MINT_RECIPIENT);
        assert_eq(burn_message.amount(), AMOUNT);
        assert_eq(burn_message.message_sender(), USER);

        // Assert correct Message values
        assert_eq(message.version(), 1);
        assert_eq(message.source_domain(), 0);
        assert_eq(message.destination_domain(), 2);
        assert_eq(message.nonce(), 0);
        assert_eq(message.sender(), auth_caller_identifier< MessageTransmitterAuthenticator>());
        assert_eq(message.recipient(), REMOTE_TOKEN_MESSENGER);
        assert_eq(message.destination_caller(), DESTINATION_CALLER);
        // Hardcoded expected message body
        assert_eq(
          message.message_body(), 
          x"00000001aa9d562b0a114a7cfa31074ac0ac0a543a25b034ba38830c82e7163775c94c8600000000000000000000000000000000000000000000000000000000000000b2000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000a1"
        );

        // num of events include message sent, burn, and deposit for burn events
        assert!(num_events() == 3);
        let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
        assert!(last_event_by_type<deposit_for_burn::DepositForBurn>() == deposit_for_burn::create_deposit_for_burn_event(0, burn_token, AMOUNT as u64, USER, MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, DESTINATION_CALLER));
      };

      // Clean up
      test_utils::destroy(deny_list);
      test_utils::destroy(treasury);
      test_utils::destroy(token_messenger_state);
      test_utils::destroy(message_transmitter_state);
      scenario.end();
  }

  #[test]
  fun test_deposit_for_burn_with_caller_with_package_auth_successful() {
      let mut scenario = test_scenario::begin(ADMIN);
      let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
      let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
        mint_cap, &mut scenario
      );

      // Perform deposit_for_burn_with_caller_with_package_auth
      scenario.next_tx(USER);
      {
        let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
        let auth = message_transmitter_authenticator::new();
        let auth_id = auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>();
        let ticket = deposit_for_burn::create_deposit_for_burn_with_caller_ticket(auth, coins, DESTINATION_DOMAIN, MINT_RECIPIENT, DESTINATION_CALLER);
        let (burn_message, message) = deposit_for_burn::deposit_for_burn_with_caller_with_package_auth(
          ticket,
          &token_messenger_state,
          &mut message_transmitter_state,
          &deny_list,
          &mut treasury,
          scenario.ctx()
        );

        // Assert correct BurnMessage values
        assert_eq(burn_message.version(), 1);
        assert_eq(burn_message.burn_token(), calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
        assert_eq(burn_message.mint_recipient(), MINT_RECIPIENT);
        assert_eq(burn_message.amount(), AMOUNT);
        assert_eq(burn_message.message_sender(), auth_id);

        // Assert correct Message values
        assert_eq(message.version(), 1);
        assert_eq(message.source_domain(), 0);
        assert_eq(message.destination_domain(), 2);
        assert_eq(message.nonce(), 0);
        assert_eq(message.sender(), auth_caller_identifier<MessageTransmitterAuthenticator>());
        assert_eq(message.recipient(), REMOTE_TOKEN_MESSENGER);
        assert_eq(message.destination_caller(), DESTINATION_CALLER);
        // Hardcoded expected message body
        assert_eq(
          message.message_body(), 
          x"00000001aa9d562b0a114a7cfa31074ac0ac0a543a25b034ba38830c82e7163775c94c8600000000000000000000000000000000000000000000000000000000000000b20000000000000000000000000000000000000000000000000000000000000064949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfe"
        );

        // num of events include message sent, burn, and deposit for burn events
        assert!(num_events() == 3);
        let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
        assert_eq(
          last_event_by_type<deposit_for_burn::DepositForBurn>(), 
          deposit_for_burn::create_deposit_for_burn_event(0, burn_token, AMOUNT as u64, auth_id, MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, DESTINATION_CALLER)
        );
      };

      // Clean up
      test_utils::destroy(deny_list);
      test_utils::destroy(treasury);
      test_utils::destroy(token_messenger_state);
      test_utils::destroy(message_transmitter_state);
      scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EPaused)]
  fun test_deposit_for_burn_when_paused() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );
    
    // Setup necessary state and pause
    token_messenger_state.set_paused(true);

    // Attempt deposit_for_burn while paused
    scenario.next_tx(USER);
    {
        let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
        deposit_for_burn::deposit_for_burn(
            coins,
            DESTINATION_DOMAIN,
            MINT_RECIPIENT,
            &token_messenger_state,
            &mut message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EZeroAmount)]
  fun test_deposit_for_burn_zero_amount() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );
    
    // Attempt deposit_for_burn with zero amount
    scenario.next_tx(USER);
    {
      let mut coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let coins_zero = coin::take(coins.balance_mut(), 0, scenario.ctx());
      deposit_for_burn::deposit_for_burn(
          coins_zero,
          DESTINATION_DOMAIN,
          MINT_RECIPIENT,
          &token_messenger_state,
          &mut message_transmitter_state,
          &deny_list,
          &mut treasury,
          scenario.ctx()
      );
      test_utils::destroy(coins);
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EZeroAddressMintRecipient)]
  fun test_deposit_for_burn_zero_address_mint_recipient() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Attempt deposit_for_burn with zero address mint recipient
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        @0x0,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EInvalidDestinationDomain)]
  fun test_deposit_for_burn_invalid_destination_domain() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );
    
    // Attempt deposit_for_burn with invalid destination domain
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      deposit_for_burn::deposit_for_burn(
          coins,
          DESTINATION_DOMAIN + 1,
          MINT_RECIPIENT,
          &token_messenger_state,
          &mut message_transmitter_state,
          &deny_list,
          &mut treasury,
          scenario.ctx()
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EMissingMintCap)]
  fun test_deposit_for_burn_missing_mint_cap() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Setup necessary state (remove mint cap)
    let mint_cap = token_messenger_state.remove_mint_cap<MintCap<DEPOSIT_FOR_BURN_TESTS>>(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>()
    );
    test_utils::destroy(mint_cap);

    // Attempt deposit_for_burn for token with missing mint cap
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        MINT_RECIPIENT,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EMissingBurnLimit)]
  fun test_deposit_for_burn_missing_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Setup necessary state (remove burn limit)
    token_messenger_state.remove_burn_limit(calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());

    // Attempt deposit_for_burn with missing burn limit
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        MINT_RECIPIENT,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EBurnLimitExceeded)]
  fun test_deposit_for_burn_exceed_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Setup necessary state with a 1 burn limit
    token_messenger_state.remove_burn_limit(calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
    token_messenger_state.add_burn_limit(calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(), 1);

    // Attempt deposit_for_burn exceeding burn limit
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        MINT_RECIPIENT,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  fun test_deposit_for_burn_at_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );

    // Setup necessary state with burn limit equal to coin amount
    token_messenger_state.remove_burn_limit(calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
    token_messenger_state.add_burn_limit(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(), AMOUNT as u64
    );

    // Perform deposit_for_burn at burn limit
    scenario.next_tx(USER);
    {
      let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (burn_message, _) = deposit_for_burn::deposit_for_burn(
        coins,
        DESTINATION_DOMAIN,
        MINT_RECIPIENT,
        &token_messenger_state,
        &mut message_transmitter_state,
        &deny_list,
        &mut treasury,
        scenario.ctx()
      );

      // Assert correct amount
      assert_eq(burn_message.amount(), AMOUNT);
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  fun test_deposit_for_burn_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, mut message_transmitter_state) = setup_cctp_states(
      mint_cap, &mut scenario
    );
    token_messenger_state.add_compatible_version(5);
    token_messenger_state.remove_compatible_version(version_control::current_version());
    
    // Attempt deposit_for_burn, revert with incompatible version
    scenario.next_tx(USER);
    {
        let coins = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
        deposit_for_burn::deposit_for_burn(
            coins,
            DESTINATION_DOMAIN,
            MINT_RECIPIENT,
            &token_messenger_state,
            &mut message_transmitter_state,
            &deny_list,
            &mut treasury,
            scenario.ctx()
        );
    };

    // Clean up
    test_utils::destroy(deny_list);
    test_utils::destroy(treasury);
    test_utils::destroy(token_messenger_state);
    test_utils::destroy(message_transmitter_state);
    scenario.end();
  }

  // replace_deposit_for_burn tests

  #[test]
  fun test_replace_deposit_for_burn_successful() {
    let mut admin_scenario = test_scenario::begin(ADMIN);
    let admin_ctx = test_scenario::ctx(&mut admin_scenario);
    let mut message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, admin_ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, admin_ctx);

    attester_manager::enable_attester(@0xbcd4042de499d14e55001ccbb24a551f3b954096, &mut message_transmitter_state, admin_ctx);
    test_scenario::end(admin_scenario);

    let mut user_scenario = test_scenario::begin(USER);
    let user_ctx = test_scenario::ctx(&mut user_scenario);

    // Create original message and burn message
    let nonce = 10;
    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(
      1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER
    );
    let original_message = create_mock_message(
      1, 0, 2, nonce, auth_caller_identifier<MessageTransmitterAuthenticator>(), REMOTE_TOKEN_MESSENGER, @0x0, burn_message.serialize()
    );
    let original_raw_message = original_message.serialize();
    let original_attestation = x"84e237e1467d8c4d3e8e79d2c165fd4cb5b91f6742e11a740de0b97a4cb720972f136da0ad945b780d3e748658ba2502e134e6b3db2f51ed4b458870c0a56f321b";

    // Call replace_deposit_for_burn
    let (new_burn_message, new_message) = deposit_for_burn::replace_deposit_for_burn(
      original_raw_message,
      original_attestation,
      option::some(NEW_DESTINATION_CALLER),
      option::some(NEW_MINT_RECIPIENT),
      &token_messenger_state,
      &message_transmitter_state,
      user_ctx
    );

    // Assert burn message fields
    assert_eq(new_burn_message.version(), 1);
    assert_eq(new_burn_message.burn_token(), token_id);
    assert_eq(new_burn_message.mint_recipient(), NEW_MINT_RECIPIENT);
    assert_eq(new_burn_message.amount(), 100);
    assert_eq(new_burn_message.message_sender(), USER);

    // Assert message fields
    assert_eq(new_message.version(), 1);
    assert_eq(new_message.source_domain(), 0);
    assert_eq(new_message.destination_domain(), 2);
    assert_eq(new_message.nonce(), nonce);
    assert_eq(new_message.sender(), auth_caller_identifier<MessageTransmitterAuthenticator>());
    assert_eq(new_message.recipient(), REMOTE_TOKEN_MESSENGER);
    assert_eq(new_message.destination_caller(), NEW_DESTINATION_CALLER);
    assert_eq(new_message.message_body(), new_burn_message.serialize());

    assert_eq(num_events(), 2);
    let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    assert_eq(last_event_by_type<deposit_for_burn::DepositForBurn>(), deposit_for_burn::create_deposit_for_burn_event(nonce, burn_token, AMOUNT as u64, USER, NEW_MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, NEW_DESTINATION_CALLER));

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(user_scenario);
  }

   #[test]
  fun test_replace_deposit_for_burn_with_package_auth_successful() {
    let mut admin_scenario = test_scenario::begin(ADMIN);
    let admin_ctx = test_scenario::ctx(&mut admin_scenario);
    let mut message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, admin_ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, admin_ctx);

    attester_manager::enable_attester(@0xbcd4042de499d14e55001ccbb24a551f3b954096, &mut message_transmitter_state, admin_ctx);
    test_scenario::end(admin_scenario);

    // Create original message and burn message
    let auth_id = auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>();
    let nonce = 10;
    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(
      1, token_id, ORIGINAL_MINT_RECIPIENT, 100, auth_id
    );
    let original_message = create_mock_message(
      1, 0, 2, nonce, auth_caller_identifier<MessageTransmitterAuthenticator>(), REMOTE_TOKEN_MESSENGER, @0x0, burn_message.serialize()
    );
    let original_raw_message = original_message.serialize();
    let original_attestation = x"21bb68570d977ec08120a349fa37615ef548cd98e8de3a4142802cf85c33f65a220626d6ea31bea28f5004e448b14ec85dc227a28a882c985ff8d3976e51f4951c";

    // Call replace_deposit_for_burn_with_package_auth
    let auth = message_transmitter_authenticator::new();
    let ticket = deposit_for_burn::create_replace_deposit_for_burn_ticket(auth, original_raw_message, original_attestation, option::some(NEW_DESTINATION_CALLER), option::some(NEW_MINT_RECIPIENT));
    let (new_burn_message, new_message) = deposit_for_burn::replace_deposit_for_burn_with_package_auth(
      ticket,
      &token_messenger_state,
      &message_transmitter_state
    );

    // Assert burn message fields
    assert_eq(new_burn_message.version(), 1);
    assert_eq(new_burn_message.burn_token(), token_id);
    assert_eq(new_burn_message.mint_recipient(), NEW_MINT_RECIPIENT);
    assert_eq(new_burn_message.amount(), 100);
    assert_eq(new_burn_message.message_sender(), auth_id);

    // Assert message fields
    assert_eq(new_message.version(), 1);
    assert_eq(new_message.source_domain(), 0);
    assert_eq(new_message.destination_domain(), 2);
    assert_eq(new_message.nonce(), nonce);
    assert_eq(new_message.sender(), auth_caller_identifier<MessageTransmitterAuthenticator>());
    assert_eq(new_message.recipient(), REMOTE_TOKEN_MESSENGER);
    assert_eq(new_message.destination_caller(), NEW_DESTINATION_CALLER);
    assert_eq(new_message.message_body(), new_burn_message.serialize());

    assert_eq(num_events(), 2);
    let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    assert_eq(
      last_event_by_type<deposit_for_burn::DepositForBurn>(), 
      deposit_for_burn::create_deposit_for_burn_event(nonce, burn_token, AMOUNT as u64, auth_id, NEW_MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, NEW_DESTINATION_CALLER)
    );

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
  }

  #[test]
  fun test_replace_deposit_for_burn_same_mint_recipient() {
    let mut admin_scenario = test_scenario::begin(ADMIN);
    let admin_ctx = test_scenario::ctx(&mut admin_scenario);
    let mut message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, admin_ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, admin_ctx);

    attester_manager::enable_attester(@0xbcd4042de499d14e55001ccbb24a551f3b954096, &mut message_transmitter_state, admin_ctx);
    test_scenario::end(admin_scenario);

    let mut user_scenario = test_scenario::begin(USER);
    let user_ctx = test_scenario::ctx(&mut user_scenario);

    let nonce = 10;
    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(
      1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER
    );
    let original_message = create_mock_message(
      1, 0, 2, nonce, auth_caller_identifier<MessageTransmitterAuthenticator>(), REMOTE_TOKEN_MESSENGER, @0x0, burn_message.serialize()
    );
    let original_raw_message = original_message.serialize();
    let original_attestation = x"84e237e1467d8c4d3e8e79d2c165fd4cb5b91f6742e11a740de0b97a4cb720972f136da0ad945b780d3e748658ba2502e134e6b3db2f51ed4b458870c0a56f321b";

    let (new_burn_message, new_message) = deposit_for_burn::replace_deposit_for_burn(
      original_raw_message,
      original_attestation,
      option::some(NEW_DESTINATION_CALLER),
      option::none(), // Use same as original
      &token_messenger_state,
      &message_transmitter_state,
      user_ctx
    );

    assert_eq(new_burn_message.mint_recipient(), ORIGINAL_MINT_RECIPIENT);
    assert_eq(new_message.destination_caller(), NEW_DESTINATION_CALLER);

    assert_eq(num_events(), 2);
    let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    assert_eq(last_event_by_type<deposit_for_burn::DepositForBurn>(), deposit_for_burn::create_deposit_for_burn_event(nonce, burn_token, AMOUNT as u64, USER, ORIGINAL_MINT_RECIPIENT, 2, REMOTE_TOKEN_MESSENGER, NEW_DESTINATION_CALLER));

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(user_scenario);
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::ESenderDoesNotMatchOriginalSender)]
  fun test_replace_deposit_for_burn_sender_mismatch() {
    let mut scenario = test_scenario::begin(@0x9999); // Different sender
    let ctx = test_scenario::ctx(&mut scenario);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER);
    let original_message = create_mock_message(1, 0, 2, 10, USER, @0x5678, @0x0, burn_message.serialize());
    let original_raw_message = original_message.serialize();
    let original_attestation = x"";

    deposit_for_burn::replace_deposit_for_burn(
      original_raw_message,
      original_attestation,
      option::some(NEW_DESTINATION_CALLER),
      option::some(NEW_MINT_RECIPIENT),
      &token_messenger_state,
      &message_transmitter_state,
      ctx
    );

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(scenario);
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::ESenderDoesNotMatchOriginalSender)]
  fun test_replace_deposit_for_burn_with_package_auth_sender_mismatch() {
    let mut scenario = test_scenario::begin(@0x9999); // Different sender
    let ctx = test_scenario::ctx(&mut scenario);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    // Create original message owned by USER (rather than auth identifier)
    let burn_message = create_mock_burn_message(1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER);
    let original_message = create_mock_message(1, 0, 2, 10, USER, @0x5678, @0x0, burn_message.serialize());
    let original_raw_message = original_message.serialize();
    let original_attestation = x"";

    let auth = message_transmitter_authenticator::new();
    let ticket = deposit_for_burn::create_replace_deposit_for_burn_ticket(auth, original_raw_message, original_attestation, option::some(NEW_DESTINATION_CALLER), option::some(NEW_MINT_RECIPIENT));
    deposit_for_burn::replace_deposit_for_burn_with_package_auth(
      ticket,
      &token_messenger_state,
      &message_transmitter_state
    );

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(scenario);
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EZeroAddressMintRecipient)]
  fun test_replace_deposit_for_burn_zero_address_mint_recipient() {
    let mut scenario = test_scenario::begin(USER);
    let ctx = test_scenario::ctx(&mut scenario);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );
    let token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(
      1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER
    );
    let original_message = create_mock_message(
      1, 0, 2, 10, USER, @0x5678, @0x0, burn_message.serialize()
    );
    let original_raw_message = original_message.serialize();
    let original_attestation = x"";

    deposit_for_burn::replace_deposit_for_burn(
      original_raw_message,
      original_attestation,
      option::some(NEW_DESTINATION_CALLER),
      option::some(@0x0), // Zero address mint recipient
      &token_messenger_state,
      &message_transmitter_state,
      ctx
    );

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(scenario);
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  fun test_replace_deposit_for_burn_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(USER);
    let ctx = test_scenario::ctx(&mut scenario);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );
    let mut token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);
    token_messenger_state.add_compatible_version(5);
    token_messenger_state.remove_compatible_version(version_control::current_version());

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    let burn_message = create_mock_burn_message(
      1, token_id, ORIGINAL_MINT_RECIPIENT, 100, USER
    );
    let original_message = create_mock_message(
      1, 0, 2, 10, USER, @0x5678, @0x0, burn_message.serialize()
    );
    let original_raw_message = original_message.serialize();
    let original_attestation = x"";

    deposit_for_burn::replace_deposit_for_burn(
      original_raw_message,
      original_attestation,
      option::some(NEW_DESTINATION_CALLER),
      option::some(@0x0), // Zero address mint recipient
      &token_messenger_state,
      &message_transmitter_state,
      ctx
    );

    test_utils::destroy(message_transmitter_state);
    test_utils::destroy(token_messenger_state);
    test_scenario::end(scenario);
  }

  // === Test Helpers ===

  fun setup_coin(
    scenario: &mut Scenario
  ): (MintCap<DEPOSIT_FOR_BURN_TESTS>, Treasury<DEPOSIT_FOR_BURN_TESTS>, DenyList) {
    let otw = test_utils::create_one_time_witness<DEPOSIT_FOR_BURN_TESTS>();
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
    let mint_cap = scenario.take_from_address<MintCap<DEPOSIT_FOR_BURN_TESTS>>(ADMIN);
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
    mint_cap: MintCap<DEPOSIT_FOR_BURN_TESTS>, 
    scenario: &mut Scenario
  ): (token_messenger_state::State, message_transmitter_state::State) {
    let ctx = test_scenario::ctx(scenario);
    
    let mut token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );

    // Setup necessary state
    token_messenger_state.add_remote_token_messenger(
      DESTINATION_DOMAIN, REMOTE_TOKEN_MESSENGER
    );
    token_messenger_state.add_mint_cap(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(), mint_cap
    );
    token_messenger_state.add_burn_limit(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(), 1000000
    );

    (token_messenger_state, message_transmitter_state)
  }

  // Helper function to create a mock burn message
  fun create_mock_burn_message(
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address
  ): BurnMessage {
    burn_message::new(version, burn_token, mint_recipient, amount, message_sender)
  }

  // Helper function to create a mock message
  fun create_mock_message(
      version: u32,
      source_domain: u32,
      destination_domain: u32,
      nonce: u64,
      sender: address,
      recipient: address,
      destination_caller: address,
      message_body: vector<u8>
  ): Message {
      message::new_for_testing(
          version,
          source_domain,
          destination_domain,
          nonce,
          sender,
          recipient,
          destination_caller,
          message_body
      )
  }
}
