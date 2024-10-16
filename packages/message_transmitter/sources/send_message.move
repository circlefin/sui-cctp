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

/// Module: send_message
/// Contains public functions for sending cross-chain messages.
///
/// Note on upgrades: It is recommended to call all of these public 
/// methods from PTBs rather than directly from other packages. 
/// These functions are version gated, so if the package is upgraded, 
/// the upgraded package must be called. In most cases, we will provide 
/// a migration period where both package versions are callable for a
/// period of time to avoid breaking all callers immediately.
module message_transmitter::send_message {
  // === Imports ===
  use sui::{
    event::emit,
  };
  use message_transmitter::{
    attestation,
    auth::{auth_caller_identifier},
    message::{Self, Message},
    state::{State},
    version_control::{assert_object_version_is_compatible_with_package}
  };

  // === Errors ===
  const EPaused: u64 = 0;
  const EMessageBodySizeExceedsLimit: u64 = 1;
  const EInvalidRecipient: u64 = 2;
  const EInvalidDestinationCaller: u64 = 3;
  const ENotOriginalSender: u64 = 4;
  const EIncorrectSourceDomain: u64 = 5;

  // === Events ===
  public struct MessageSent has copy, drop {
    message: vector<u8>
  }

  // === Public-Mutative Functions ===

  /// Sends a message to the destination domain and recipient.
  /// 
  /// Reverts if:
  /// - contract is paused
  /// - the Auth parameter is invalid
  /// - the message body size exceeds the limit
  /// - invalid (e.g. @0x0) recipient is given
  /// 
  /// Parameters:
  /// - send_message_ticket: a struct containing the necessary information to send a message created via create_send_message_ticket.
  public fun send_message<Auth: drop>(
    send_message_ticket: SendMessageTicket<Auth>,
    state: &mut State,
  ): Message {
    let SendMessageTicket { auth, destination_domain, recipient, message_body } = send_message_ticket;
    let destination_caller = @0x0;
    send_message_impl(state, auth, destination_domain, recipient, message_body, destination_caller)
  }

  /// Same as send_message, except the receive_message call on the destination
  /// domain must be called by `destination_caller`.
  /// 
  /// WARNING: if the `destination_caller` does not represent a valid address, then 
  /// it will not be possible to broadcast the message on the destination domain. 
  /// This is an advanced feature, and the standard send_message() should be 
  /// preferred for use cases where a specific destination caller is not required.
  /// 
  /// Note: If destination is a non-Move chain, destination_caller address should 
  /// be converted to hex and passed in in the @0x123 address format.
  public fun send_message_with_caller<Auth: drop>(
    send_message_with_caller_ticket: SendMessageWithCallerTicket<Auth>,
    state: &mut State,
  ): Message {
    let SendMessageWithCallerTicket { auth, destination_domain, recipient, message_body, destination_caller } = send_message_with_caller_ticket;
    assert!(destination_caller != @0x0, EInvalidDestinationCaller);
    send_message_impl(state, auth, destination_domain, recipient, message_body, destination_caller)
  }

  /// Allows the sender of a previous Message (created by send_message or 
  /// send_message_with_caller) to send a new Message to replace the original as
  /// long as they have a valid attestation for the message. 
  /// The new message will reuse the original message's nonce. For a given nonce, all 
  /// replacement message(s) and the original message are valid to broadcast on the destination 
  /// domain, until the first message at the nonce confirms, at which point all others are invalidated.
  /// 
  /// Reverts if:
  /// - original message or attestation are invalid
  /// - tx sender is not the original message sender (identified by Auth parameter)
  /// - the Auth parameter is invalid
  /// - contract is paused
  /// - source domain of original message is not the local domain
  /// - new message body size exceeds the limit
  /// - recipient is invalid (@0x0)
  /// 
  /// Parameters:
  /// - replace_message_ticket: a struct containing the necessary information to replace a message created via create_replace_message_ticket.
  /// 
  /// Note: The sender of the replaced message must be the same as the caller of the original message.
  ///       This is identified using the Auth generic parameter.
  public fun replace_message<Auth: drop>(
    replace_message_ticket: ReplaceMessageTicket<Auth>,
    state: &State
  ): Message {
    let ReplaceMessageTicket { auth: _auth, original_raw_message, original_attestation, new_message_body, new_destination_caller } = replace_message_ticket;
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert!(!state.paused(), EPaused);

    attestation::verify_attestation_signatures(original_raw_message, original_attestation, state);
    let mut message = message::from_bytes(&original_raw_message);

    let sender_identifier = auth_caller_identifier<Auth>();
    assert!(message.sender() == sender_identifier, ENotOriginalSender);
    assert!(message.source_domain() == state.local_domain(), EIncorrectSourceDomain);

    let final_destination_caller = new_destination_caller.get_with_default(message.destination_caller()); 
    message.update_destination_caller(final_destination_caller);

    let final_message_body = new_message_body.get_with_default(message.message_body());
    message.update_message_body(final_message_body);    

    message.update_version(state.message_version());

    serialize_message_and_emit_event(message, state);

    message
  }

  // === Ticket Structs/Functions ===
  /// create_..._ticket functions below are non version-gated functions, intended to be 
  /// called directly from other packages to create ticket structs that can be passed into public version-gated functions 
  /// outside of the calling package in a PTB. This prevents dependent packages from needing to be updated after CCTP upgrades.
  public struct SendMessageTicket<Auth: drop> {
    auth: Auth,
    destination_domain: u32, 
    recipient: address, 
    message_body: vector<u8>,
  }

  /// Parameters:
  /// - auth: an authenticator struct 
  ///         This is required to securely assign a sender address associated with the calling contract to the message.
  ///         Any struct that implements the drop trait can be used as an authenticator, but it is recommended to 
  ///         use a dedicated auth struct.
  ///         Calling contracts should be careful to not expose these objects to the public or else messages from 
  ///         their package could be forged.
  ///         An example implementation exists in the token_messenger_minter::message_transmitter_authenticator module.
  /// - destination_domain: domain to send message to
  /// - recipient: address of message recipient on destination domain 
  ///              Note: If destination is a non-Move chain, mint_recipient 
  ///              address should be converted to hex and passed in in the 
  ///              @0x123 address format.
  /// - message_body: raw bytes content of the message
  public fun create_send_message_ticket<Auth: drop>(
    auth: Auth,
    destination_domain: u32, 
    recipient: address, 
    message_body: vector<u8>,
  ): SendMessageTicket<Auth> {
    SendMessageTicket { auth, destination_domain, recipient, message_body }
  }

  public struct SendMessageWithCallerTicket<Auth: drop> {
    auth: Auth,
    destination_domain: u32, 
    recipient: address, 
    destination_caller: address,
    message_body: vector<u8>
  }

  /// See create_send_message_ticket for other parameters
  /// Parameters:
  /// - destination_caller: address of the required caller on the destination domain.
  /// Note: If destination is a non-Move chain, destination_caller address should 
  /// be converted to hex and passed in in the @0x123 address format.
  public fun create_send_message_with_caller_ticket<Auth: drop>(
    auth: Auth,
    destination_domain: u32, 
    recipient: address, 
    destination_caller: address,
    message_body: vector<u8>
  ): SendMessageWithCallerTicket<Auth> {
    SendMessageWithCallerTicket { auth, destination_domain, recipient, destination_caller, message_body }
  }

  public struct ReplaceMessageTicket<Auth: drop> {
    auth: Auth,
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_message_body: Option<vector<u8>>,
    new_destination_caller: Option<address>
  }

  /// Parameters:
  /// - auth: an authenticator struct, must match the auth used to send the original message.
  /// - original_raw_message: original message in bytes.
  /// - original_attestation: valid attestation for the original message in bytes.
  /// - new_message_body: new message body, defaults to body of the original message.
  /// - new_destination_caller: new destination caller for message, can be @0x0 for no caller, 
  ///                           defaults to destination_caller of original_message.
  public fun create_replace_message_ticket<Auth: drop>(
    auth: Auth,
    original_raw_message: vector<u8>,
    original_attestation: vector<u8>,
    new_message_body: Option<vector<u8>>,
    new_destination_caller: Option<address>
  ): ReplaceMessageTicket<Auth> {
    ReplaceMessageTicket { auth, original_raw_message, original_attestation, new_message_body, new_destination_caller }
  }

  // === Private Functions ===
  
  /// Shared implementation for sending a message.
  fun send_message_impl<Auth: drop>(
    state: &mut State,
    _auth: Auth, 
    destination_domain: u32, 
    recipient: address, 
    message_body: vector<u8>,
    destination_caller: address
  ): Message {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert!(!state.paused(), EPaused);

    let sender_identifier = auth_caller_identifier<Auth>();
    let nonce = state.reserve_and_increment_nonce();

    let message = message::new(
      state.message_version(),
      state.local_domain(),
      destination_domain,
      nonce,
      sender_identifier,
      recipient,
      destination_caller,
      message_body
    );

    serialize_message_and_emit_event(message, state);

    message
  }

  /// Shared functionality between send_message, send_message_with_caller, and replace_message.
  /// Performs validations and emits a MessageSent event for the serialized message.
  fun serialize_message_and_emit_event(    
    message: Message,
    state: &State
  ) {
    assert!(message.message_body().length() <= state.max_message_body_size(), EMessageBodySizeExceedsLimit);
    assert!(message.recipient() != @0x0, EInvalidRecipient);

    let serialized_message = message.serialize();
    emit(MessageSent{ message: serialized_message });
  }

  // === Test Functions ===

  #[test_only]
  public fun create_message_sent_event(
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    nonce: u64,
    sender: address,
    recipient: address,
    destination_caller: address,
    message_body: vector<u8>
  ): MessageSent {
    let message = message::new(version, source_domain, destination_domain, nonce, sender, recipient, destination_caller, message_body);
    MessageSent { message: message.serialize() }
  }
}

// === Tests ===

#[test_only]
module message_transmitter::message_transmitter_authenticator {
  public struct SendMessageTestAuth has drop {}

  public fun new(): SendMessageTestAuth {
    SendMessageTestAuth {}
  }
}

#[test_only]
module message_transmitter::send_message_tests {
  use sui::{
    event::{num_events},
    test_scenario,
    test_utils::{Self, assert_eq}
  };
  use message_transmitter::{
    attestation,
    auth::{Self, auth_caller_identifier},
    message,
    message_transmitter_authenticator,
    send_message,
    state,
    version_control
  };
  use sui_extensions::test_utils::last_event_by_type;

  const RECIPIENT: address = @0x1A;
  const DEST_CALLER: address = @0x2A;
  const ATTESTER: address = @0xBcd4042DE499D14e55001CcbB24a551F3b954096;

  #[test_only]
  fun get_valid_send_message_and_attestation(state: &state::State): (vector<u8>, vector<u8>) {
      let original_message = message::new(
        state.message_version(),
        0,
        1,
        7384,
        auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
        @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
        @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
        x"1234",
      );
      let serialized_message = original_message.serialize();
      let original_attestation = x"ec683cd0a4324b5bf45fbb329f9f883207a56311caf4dd3e247b1687fbeafa8a278b232dc51f77db03e3630185bb9be6286e65d53f1734dd607a06526e97d1791b";
      (serialized_message, original_attestation)
  }

  #[test_only]
  fun get_invalid_send_message_and_attestation(state: &state::State): (vector<u8>, vector<u8>) {
    let original_message = message::new(
      state.message_version(),
      0,
      1,
      7384,
      @0x1234,
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      x"1234",
    );
    let serialized_message = original_message.serialize();
    let original_attestation = x"e8334264b7fa8e70b61be9f759cfb1710ba8b7c8dac3a39a7dbb5abba1bb94136521cc61c85e45ba92237dfe738cf60d99a441f0cdabe5fbdb5902bbdd396ab71c";
    (serialized_message, original_attestation)
  }

  #[test_only]
  fun setup_state(
    scenario: &mut test_scenario::Scenario
  ): state::State {
    let ctx = test_scenario::ctx(scenario);
    let mut message_transmitter_state = state::new_for_testing(
      0, 0, 10000, @0x0, ctx
    );
    message_transmitter_state.enable_attester(ATTESTER);

    message_transmitter_state
  }

  #[test] 
  public fun test_send_message_successful() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect to successfully send message
    let ticket = send_message::create_send_message_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );

    assert_eq(num_events(), 1);
    let message_sent_event = last_event_by_type<send_message::MessageSent>();
    assert_eq(message_sent_event, send_message::create_message_sent_event(
      0, 
      0, 
      0, 
      0, 
      auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
      RECIPIENT,
      @0x0,
      x"1234",
    ));
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = send_message::EPaused)]
  public fun test_send_message_revert_paused() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Update message transmitter state to paused
    mt_state.set_paused(true);

    // Expect call to revert due to paused state
    let ticket = send_message::create_send_message_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_send_message_revert_invalid_auth() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect call to revert due to invalid authenticator
    let ticket = send_message::create_send_message_ticket(
      @0x123, 0, RECIPIENT, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EMessageBodySizeExceedsLimit)]
  public fun test_send_message_revert_message_size_exceeds_max() {
    let mut scenario = test_scenario::begin(@0x0);
    // Initialize state with message size limit of 1 to trigger error
    let mut mt_state = state::new_for_testing(
      0, 0, 1, @0x0, scenario.ctx()
    );

    // Expect call to revert due to too large message body
    let ticket = send_message::create_send_message_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EInvalidRecipient)]
  public fun test_send_message_revert_invalid_recipient() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect call to revert due to invalid recipient
    let ticket = send_message::create_send_message_ticket(
      message_transmitter_authenticator::new(), 0, @0x0, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_send_message_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);
    
    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Expect call to revert due to incompatible version
    let ticket = send_message::create_send_message_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, x"1234"
    );
    send_message::send_message(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test] 
  public fun test_send_message_with_caller_successful() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect to successfully send message with caller
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );

    assert_eq(num_events(), 1);
    let message_sent_event = last_event_by_type<send_message::MessageSent>();
    assert_eq(message_sent_event, send_message::create_message_sent_event(
      0, 
      0, 
      0, 
      0, 
      auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
      RECIPIENT,
      DEST_CALLER,
      x"1234",
    ));
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EPaused)]
  public fun test_send_message_with_caller_revert_paused() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Update message transmitter state to paused
    mt_state.set_paused(true);

    // Expect to revert due to paused state
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EInvalidDestinationCaller)]
  public fun test_send_message_with_caller_revert_invalid_destination_caller() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect to revert due to invalid destination_caller
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, @0x0, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_send_message_with_caller_revert_invalid_auth() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect to revert due to invalid authenticator
    let ticket = send_message::create_send_message_with_caller_ticket(
      @0x123, 0, RECIPIENT, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EMessageBodySizeExceedsLimit)]
  public fun test_send_message_with_caller_revert_message_size_exceeds_max() {
    let mut scenario = test_scenario::begin(@0x0);
    // Initialize state with message size limit of 1 to trigger error
    let mut mt_state = state::new_for_testing(
      0, 0, 1, @0x0, scenario.ctx()
    );

    // Expect to revert due to too large message
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EInvalidRecipient)]
  public fun test_send_message_with_caller_revert_invalid_recipient() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Expect to revert due to invalid recipient
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, @0x0, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_send_message_with_caller_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);
    
    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Expect call to revert due to incompatible version
    let ticket = send_message::create_send_message_with_caller_ticket(
      message_transmitter_authenticator::new(), 0, RECIPIENT, DEST_CALLER, x"1234"
    );
    send_message::send_message_with_caller(
      ticket, &mut mt_state
    );
    
    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  public fun test_replace_message_successful_no_changes() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect to successfully replace message without changes
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);
    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    assert_eq(num_events(), 1);
    let message_sent_event = last_event_by_type<send_message::MessageSent>();
    assert_eq(message_sent_event, send_message::create_message_sent_event(
      0, 
      0, 
      1, 
      7384, 
      auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      x"1234",
    ));

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  public fun test_replace_message_successful_change_message_body() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect to successfully replace message with new message body
    let new_message_body = x"123456";
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::some(new_message_body), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    assert_eq(num_events(), 1);
    let message_sent_event = last_event_by_type<send_message::MessageSent>();
    assert_eq(message_sent_event, send_message::create_message_sent_event(
      0, 
      0, 
      1, 
      7384, 
      auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      new_message_body,
    ));

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  public fun test_replace_message_successful_change_destination_caller() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect to successfully replace message with new destination caller
    let new_destination_caller = @0x3B;
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::some(new_destination_caller)
    );
    send_message::replace_message(ticket, &mt_state);

    assert_eq(num_events(), 1);
    let message_sent_event = last_event_by_type<send_message::MessageSent>();
    assert_eq(message_sent_event, send_message::create_message_sent_event(
      0, 
      0, 
      1, 
      7384, 
      auth_caller_identifier<message_transmitter_authenticator::SendMessageTestAuth>(),
      @0x1CD223dBC9ff35fF6B29dAB2339ACC842BF58cCb,
      new_destination_caller,
      x"1234",
    ));

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EPaused)]
  public fun test_replace_message_revert_paused() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);

    // Update message transmitter state to paused
    mt_state.set_paused(true);

    // Expect call to revert due to paused message transmitter state
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);
    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_replace_message_revert_invalid_auth() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect call to revert due to invalid auth
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);
    let ticket = send_message::create_replace_message_ticket(
      @0x1234, message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = attestation::EInvalidAttestationLength)]
  public fun test_replace_message_revert_invalid_attestation() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect call to revert due to invalid attestation
    let (message, mut attestation) = get_valid_send_message_and_attestation(&mt_state);
    attestation.pop_back();

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::ENotOriginalSender)]
  public fun test_replace_message_revert_not_original_sender() {
    let mut scenario = test_scenario::begin(@0x0);
    let mt_state = setup_state(&mut scenario);

    // Expect call to revert due to invalid sender
    let (message, attestation) = get_invalid_send_message_and_attestation(&mt_state);

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EIncorrectSourceDomain)]
  public fun test_replace_message_revert_incorrect_source_domain() {
    let mut scenario = test_scenario::begin(@0x0);
    // Initialize state with different local domain to trigger error
    let mut mt_state = state::new_for_testing(
      1, 0, 10000, @0x0, scenario.ctx()
    );
    mt_state.enable_attester(ATTESTER);

    // Expect call to revert due to incorrect source domain
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = send_message::EMessageBodySizeExceedsLimit)]
  public fun test_replace_message_revert_message_size_exceeds_max() {
    let mut scenario = test_scenario::begin(@0x0);
    // Initialize state with message size limit of 1 to trigger error
    let mut mt_state = state::new_for_testing(
      0, 0, 1, @0x0, scenario.ctx()
    );
    mt_state.enable_attester(ATTESTER);

    // Expect call to revert due to message size exceeding limit
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);

    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_replace_message_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(@0x0);
    let mut mt_state = setup_state(&mut scenario);
    
    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Expect call to revert due to incompatible version
    let (message, attestation) = get_valid_send_message_and_attestation(&mt_state);
    let ticket = send_message::create_replace_message_ticket(
      message_transmitter_authenticator::new(), message, attestation, option::none(), option::none()
    );
    send_message::replace_message(ticket, &mt_state);

    test_utils::destroy(mt_state);
    scenario.end();
  }
}
