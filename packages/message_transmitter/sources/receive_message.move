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

/// Module: receive_message
/// Contains public functions for receiving cross-chain messages.
///
/// Note on upgrades: If interacting with this module from other packages, it
/// is recommended to call the receive_message_with_package_auth and stamp_receipt 
/// methods from a PTB rather than directly from dependent packages. These functions  
/// are version gated, so if this package is upgraded, the upgraded package must be called. 
module message_transmitter::receive_message {

  // === Imports ===
  use sui::{
    event::emit,
  };
  use message_transmitter::{
    attestation::{Self},
    auth::auth_caller_identifier,
    message::{Self},
    state::{State},
    version_control::{Self, assert_object_version_is_compatible_with_package}
  };

  // === Errors ===
  const EPaused: u64 = 0;
  const EInvalidDestinationCaller: u64 = 1;
  const EInvalidDestinationDomain: u64 = 2;
  const EInvalidMessageVersion: u64 = 3;
  const ENonceAlreadyUsed: u64 = 4;
  const ERecipientNotAuth: u64 = 5;
  const EInvalidReceiptVersion: u64 = 6;

  // === Structs ===
  public struct Receipt {
    caller: address,
    recipient: address,
    source_domain: u32,
    sender: address,
    nonce: u64,
    message_body: vector<u8>,
    // Used to ensure all receipt calls are made on the same version of the package as receive_message.
    current_version: u64
  }

  public struct StampedReceipt {
    receipt: Receipt
  }

  // === Events ===
  public struct MessageReceived has copy, drop {
    caller: address,
    source_domain: u32,
    nonce: u64,
    sender: address,
    message_body: vector<u8>
  }

  // === Public-Mutative Functions ===

  /// Receives a message. Messages with a given nonce can only be received once for a 
  /// (sourceDomain, destinationDomain). 
  /// Intended to be called directly from an EOA when a package destination_caller is not specified on the message.
  /// Please use receive_message_with_package_auth if a package destination_caller is specified.
  /// 
  /// This function returns a `Receipt` struct ([Hot Potato](https://medium.com/@borispovod/move-hot-potato-pattern-bbc48a48d93c))
  /// after validating attestation and marking the nonce used. 
  /// In order to destroy the Receipt and complete the message, `stamp_receipt()` must be called with the receipt and 
  /// an authenticator struct (see the token_messenger_minter::receive_message_authenticator module for reference) and then 
  /// `complete_receive_message()` must be called with the Stamped Receipt to emit the `MessageReceived` event and complete the message. 
  /// It is recommended to call stamp_receipt and complete_receive_message functions from PTBs if possible to prevent breaking packages when an upgrade occurs. 
  /// create_stamp_receipt_ticket is safe to be called from a package as it is not version-gated.
  /// Integrating handle_receive_message calls should only allow Receipt parameters (not StampedReceipt) and should call create_stamp_receipt_ticket in the 
  /// package to prevent message replays.
  /// The Receipt/stamp pattern is used to enforce atomicity and ensure the intended receiver contract is called. 
  /// Example (in a PTB):
  /// ```
  ///     let receipt = message_transmitter::receive_message(message, attestation, &state);
  ///     let stamp_receipt_ticket = receiver_package::handle_receive_message(receipt);
  ///     let stamped_receipt = message_transmitter::stamp_receipt(stamp_receipt_ticket);
  ///     message_transmitter::complete_receive_message(receipt);
  /// ```
  /// 
  /// Reverts if:
  /// - contract is paused
  /// - the message format is invalid
  /// - the attestation is invalid
  /// - the destination domain of the message does not match the local domain
  /// - the destination caller of the message is set and does not match the caller
  /// - the message version does not match the local message version
  /// - a message from the source domain for the given nonce has already been received on the local domain
  /// 
  /// Parameters:
  /// - message: a message, in bytes, corresponding with the format defined in the `message_transmitter::message` module.
  /// - attestation: a valid attestation consisting of concatenated 65-byte signature(s) of exactly `signature_threshold` signatures, in
  ///                increasing order of attester address.
  /// - state: State shared object for the MessageTransmitter package.
  public fun receive_message(message: vector<u8>, attestation: vector<u8>, state: &mut State, ctx: &TxContext): Receipt {
    let sender = ctx.sender();
    receive_message_shared(message, attestation, sender, state)
  }

  /// The same as receive_message, except intended to be used by a dependent package when a package as destination_caller
  /// is specified in order to run an atomic operation. This function is version-gated and should be called from a PTB 
  /// to prevent breaking changes when an upgrade occurs. 
  /// create_receive_message_ticket is safe to be called directly from a package (not version-gated).
  /// 
  /// This function uses a ReceiveMessageTicket for parameters so that the calling package can 
  /// call create_receive_message_ticket (not version-gated) from their package with parameters, and call 
  /// receive_message_with_package_auth (version-gated) from a PTB so packages don't have to be updated
  /// during CCTP package upgrades. ReceiveMessageTicket also requires an Auth parameter. This is required  
  /// whenever a package as assigned as a destination_caller. destination_caller address should be set to the
  /// auth identifier returned from the auth_caller_identifier function with the package's Auth struct.
  /// Any struct that implements the drop trait can be used as an authenticator, but it is recommended to 
  /// use a dedicated auth struct. Calling contracts should be careful to not expose these objects to the 
  /// public or else messages intended for their package could be skipped.
  /// 
  /// Example (in a PTB):
  /// ```
  ///     let receive_msg_ticket = your_package::prepare_receive_message_ticket(message, attestation);
  ///     let receipt = message_transmitter::receive_message_with_package_auth(receive_msg_ticket, &state);
  ///     // create_stamp_receipt_ticket is called from inside receiver_package::handle_receive_message()
  ///     let (message_body, stamp_receipt_ticket) = receiver_package::handle_receive_message(receipt);
  ///     let stamped_receipt = message_transmitter::stamp_receipt(stamp_receipt_ticket);
  ///     message_transmitter::complete_receive_message(stamped_receipt);
  /// ```
  /// 
  /// Parameters:
  /// - receive_message_ticket: a ticket struct containing the message, attestation, and an authenticator struct.
  /// - state: State shared object for the MessageTransmitter package.
  public fun receive_message_with_package_auth<Auth: drop>(receive_message_ticket: ReceiveMessageTicket<Auth>, state: &mut State): Receipt {
    let ReceiveMessageTicket { message, attestation, auth: _auth } = receive_message_ticket;
    let sender_identifier = auth_caller_identifier<Auth>();
    receive_message_shared(message, attestation, sender_identifier, state)
  }

  /// Stamps a receipt after verifying the intended package acknowledged the message (through the Auth struct) by
  /// returning a StampedReceipt struct that can be used to complete the message via complete_receive_message.
  /// 
  /// This function is version-gated and should be called from a PTB to prevent breaking changes when an upgrade occurs.
  /// create_stamp_receipt_ticket is safe to be called directly from a package (not version-gated), and its returned ticket 
  /// struct can be passed into stamp_receipt() in a PTB.
  /// 
  /// Reverts if:
  /// - an invalid auth module is provided
  /// 
  /// Parameters:
  /// - stamp_receipt_ticket: ticket struct created by create_stamp_receipt_ticket() with the receipt and auth struct
  public fun stamp_receipt<Auth: drop>(stamp_receipt_ticket: StampReceiptTicket<Auth>, state: &State): StampedReceipt {
    let StampReceiptTicket { receipt, auth: _auth } = stamp_receipt_ticket;
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert_valid_receipt_version(&receipt);
    assert!(receipt.recipient == auth_caller_identifier<Auth>(), ERecipientNotAuth);

    StampedReceipt { receipt }
  }

  /// Emits `MessageReceived` event for a stamped receipt and destroys the receipt.
  /// Cannot be called without a StampedReceipt (returned from stamp_receipt).
  /// 
  /// Parameters:
  /// - stamped_receipt: a stamped receipt initially created from a receive_message call and verified in a stamp_receipt call
  public fun complete_receive_message(stamped_receipt: StampedReceipt, state: &State) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert_valid_receipt_version(stamped_receipt.receipt());

    emit(MessageReceived {
      caller: stamped_receipt.receipt.caller,
      source_domain: stamped_receipt.receipt.source_domain,
      nonce: stamped_receipt.receipt.nonce,
      sender: stamped_receipt.receipt.sender,
      message_body: stamped_receipt.receipt.message_body
    });

    stamped_receipt.destroy_receipt();
  }

  /// Fetch the sender for a receipt.
  public fun sender(
    receipt: &Receipt
  ): address {
    receipt.sender
  }

  /// Fetch the source_domain for a receipt.
  public fun source_domain(
    receipt: &Receipt
  ): u32 {
    receipt.source_domain
  }

  /// Fetch the message_body for a receipt.
  public fun message_body(
    receipt: &Receipt
  ): &vector<u8> {
    &receipt.message_body
  }

  /// Fetch the state_compatible_versions for a receipt.
  public fun current_version(
    receipt: &Receipt
  ): u64 {
    receipt.current_version
  }

  // Fetch a reference to a receipt for a stamped receipt.
  public fun receipt(
    stamped_receipt: &StampedReceipt
  ): &Receipt {
    &stamped_receipt.receipt
  }

  /// Fetch the nonce for a receipt.
  public fun nonce(
    receipt: &Receipt
  ): u64 {
    receipt.nonce
  }

  /// Fetch the caller for a receipt.
  public fun caller(
    receipt: &Receipt
  ): address {
    receipt.caller
  }

  /// Fetch the recipient for a receipt.
  public fun recipient(
    receipt: &Receipt
  ): address {
    receipt.recipient
  }

  // === Ticket Structs/Functions ===
  /// create_receive_message_ticket and create_stamp_receipt_ticket are non version-gated functions, intended to be 
  /// called directly from other packages to create ticket structs that can be passed into public version-gated functions 
  /// outside of the calling package in a PTB. This prevents dependent packages from needing to be updated after CCTP upgrades.
  public struct ReceiveMessageTicket<Auth: drop> {
    auth: Auth,
    message: vector<u8>, 
    attestation: vector<u8>
  }

  /// Not version-gated so it can be safely called from a dependent package,
  /// and then passed to receive_message_with_package_auth (version-gated) from a PTB.
  /// See receive_message for parameter information.
  public fun create_receive_message_ticket<Auth: drop>(auth: Auth, message: vector<u8>, attestation: vector<u8>): ReceiveMessageTicket<Auth> {
    ReceiveMessageTicket {
      auth,
      message,
      attestation
    }
  }

  public struct StampReceiptTicket<Auth: drop> {
    auth: Auth,
    receipt: Receipt
  }

  /// Not version-gated so it can be safely called from a dependent package,
  /// and then passed to stamp_receipt (version-gated) from a PTB.
  public fun create_stamp_receipt_ticket<Auth: drop>(auth: Auth, receipt: Receipt): StampReceiptTicket<Auth> {
    StampReceiptTicket {
      auth,
      receipt
    }
  }

  // === Private Functions ===

  fun receive_message_shared(message: vector<u8>, attestation: vector<u8>, sender: address, state: &mut State): Receipt {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert!(!state.paused(), EPaused);

    let message_struct = message::from_bytes(&message);
    attestation::verify_attestation_signatures(message, attestation, state);

    // Validate destination domain
    let destination_domain = message_struct.destination_domain();
    assert!(destination_domain == state.local_domain(), EInvalidDestinationDomain);

    // Validate destination caller
    let destination_caller = message_struct.destination_caller();
    assert!(
      destination_caller == @0x0 || destination_caller == sender,
      EInvalidDestinationCaller
    );

    // Validate message version
    let message_version = message_struct.version();
    assert!(message_version == state.message_version(), EInvalidMessageVersion);

    // Validate nonce is available and mark it used
    let source_domain = message_struct.source_domain();
    let nonce = message_struct.nonce();
    assert!(!state.is_nonce_used(source_domain, nonce), ENonceAlreadyUsed);
    state.mark_nonce_used(source_domain, nonce);

    // Return unstamped receipt
    Receipt {
      caller: sender,
      recipient: message_struct.recipient(),
      source_domain,
      sender: message_struct.sender(),
      nonce,
      message_body: message_struct.message_body(),
      current_version: version_control::current_version()
    }
  }

  /// Asserts that the current package version matches the version stored on the Receipt. 
  /// This prevents receipt calls from being called on different package versions than receive_message 
  /// while a migration is in progress.
  fun assert_valid_receipt_version(receipt: &Receipt) {
    assert!(receipt.current_version() == version_control::current_version(), EInvalidReceiptVersion);
  }

  /// Destroys a stamped receipt (and it's inner receipt) once it is no 
  /// longer needed in complete_receive_message.
  fun destroy_receipt(stamped_receipt: StampedReceipt) {
    let StampedReceipt { 
      receipt 
    } = stamped_receipt;

    let Receipt {
      caller: _,
      recipient: _,
      source_domain: _,
      sender: _,
      nonce: _,
      message_body: _,
      current_version: _
    } = receipt;
  }
  
  // === Test Functions ===
  #[test_only] use sui::{
    test_utils::{assert_eq}
  };
  
  #[test_only]
  public fun create_receipt(
    caller: address,
    recipient: address,
    source_domain: u32,
    sender: address,
    nonce: u64,
    message_body: vector<u8>,
    current_version: u64
  ): Receipt { 
    Receipt {
      caller,
      recipient,
      source_domain,
      sender,
      nonce,
      message_body,
      current_version
    }
  }

  #[test_only]
  public fun create_stamped_receipt(receipt: Receipt): StampedReceipt { 
    StampedReceipt {
      receipt
    }
  }

  #[test_only]
  public fun assert_receipts_eq(
    given_receipt: &Receipt,
    expected_receipt: &Receipt
  ) {
    // Validate each receipt field
    assert_eq(given_receipt.caller(), expected_receipt.caller());
    assert_eq(given_receipt.recipient(), expected_receipt.recipient());
    assert_eq(given_receipt.source_domain(), expected_receipt.source_domain());
    assert_eq(given_receipt.sender(), expected_receipt.sender());
    assert_eq(given_receipt.nonce(), expected_receipt.nonce());
    assert_eq(*given_receipt.message_body(), *expected_receipt.message_body());
  }

  #[test_only]
  public fun create_message_received_event(
    caller: address,
    source_domain: u32,
    nonce: u64,
    sender: address,
    message_body: vector<u8>
  ): MessageReceived {
    MessageReceived {
      caller,
      source_domain,
      nonce,
      sender,
      message_body
    }
  }
}

// === Tests ===

#[test_only]
module message_transmitter::receive_message_authenticator {
  public struct ReceiveMessageTestAuth has drop {}

  public fun new(): ReceiveMessageTestAuth {
    ReceiveMessageTestAuth {}
  }
}

#[test_only]
module message_transmitter::receive_message_tests {
  use sui::{
    event::{num_events},
    test_scenario,
    test_utils::{assert_eq, destroy}
  };
  use message_transmitter::{
    attestation,
    auth::{Self, auth_caller_identifier},
    message,
    message_transmitter_authenticator::{Self, SendMessageTestAuth},
    receive_message,
    receive_message_authenticator::{Self, ReceiveMessageTestAuth},
    state::{Self},
    version_control
  };
  use sui_extensions::test_utils::last_event_by_type;

  const USER: address = @0x1A;
  const INVALID_USER: address = @0x2B;
  const VALID_MESSAGE: vector<u8> = x"0000000000000000000000010000000000001cd80000000000000000000000000000000000000000000000000000000000000001949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfe00000000000000000000000000000000000000000000000000000000000000001234";
  const VALID_MESSAGE_ATTESTATION: vector<u8> = x"08e280f19802679344b388ed16a9537d4ff8f713858bd0e4184ad761f2998edb491dd7484648190b664f6e9c75049d9e3e092db2b753c97f44feb96ada3bc9f51c";
  const VALID_MESSAGE_WITH_CALLER: vector<u8> = x"0000000000000000000000010000000000001cd80000000000000000000000000000000000000000000000000000000000000001949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfe000000000000000000000000000000000000000000000000000000000000001a1234";
  const VALID_MESSAGE_WITH_CALLER_ATTESTATION: vector<u8> = x"6bd2d461eca43a988f109119c216406332a8630d35beec48bbb5fd105500455f64ea1bab07d8e0e301b68f783d8ba41ee620c12127872864ed284e538fb253ee1c";
  const VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH: vector<u8> = x"0000000000000000000000010000000000001cd80000000000000000000000000000000000000000000000000000000000000001949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfeda182d10342451ea8f9a01ef7964a44d91ef19e53685d579c1724d49f824d0a91234";
  const VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH_ATTESTATION: vector<u8> = x"b2897be69f5413f41a1edb31835a139f1aa32dd8621983589fa44cade41b3ba75103bdac6f480e425ea0573f6c17026abf7182828fbc8ea6da1992436021bde31c";

  // === Test Functions ===

  #[test_only]
  fun setup_state(
    scenario: &mut test_scenario::Scenario
  ): state::State {
    let ctx = test_scenario::ctx(scenario);
    let mut message_transmitter_state = state::new_for_testing(
      1, 0, 10000, @0x0, ctx
    );
    message_transmitter_state.enable_attester(@0xbcd4042de499d14e55001ccbb24a551f3b954096);

    message_transmitter_state
  }

  // === Tests ===

  #[test] 
  public fun test_receive_message_successful_no_destination_caller() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());
    let expected_receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(0, 7384));

    destroy(receipt);
    destroy(expected_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  public fun test_receive_message_with_package_auth_successful_no_destination_caller() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let auth = receive_message_authenticator::new();
    let receive_message_ticket = receive_message::create_receive_message_ticket(auth, VALID_MESSAGE, VALID_MESSAGE_ATTESTATION);
    let receipt = receive_message::receive_message_with_package_auth(receive_message_ticket, &mut mt_state);
    let auth_id = auth_caller_identifier<ReceiveMessageTestAuth>();
    let expected_receipt = receive_message::create_receipt(auth_id, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(0, 7384));

    destroy(receipt);
    destroy(expected_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  public fun test_receive_message_successful_with_destination_caller() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE_WITH_CALLER, VALID_MESSAGE_WITH_CALLER_ATTESTATION, &mut mt_state, scenario.ctx());
    let expected_receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(0, 7384));

    destroy(receipt);
    destroy(expected_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  public fun test_receive_message_with_package_auth_successful_with_destination_caller() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let auth = receive_message_authenticator::new();
    let auth_id = auth_caller_identifier<ReceiveMessageTestAuth>();
    let receive_message_ticket = receive_message::create_receive_message_ticket(auth, VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH, VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH_ATTESTATION);

    let receipt = receive_message::receive_message_with_package_auth(receive_message_ticket, &mut mt_state);
    let expected_receipt = receive_message::create_receipt(auth_id, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(0, 7384));

    destroy(receipt);
    destroy(expected_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = receive_message::EPaused)]
  public fun test_receive_message_revert_paused() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    
    // Set state to paused
    mt_state.set_paused(true);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = message::EInvalidMessageLength)]
  public fun test_receive_message_revert_invalid_message_length() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Use malformed message
    let message = x"1234";

    let receipt = receive_message::receive_message(message, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = attestation::EInvalidAttestationLength)]
  public fun test_receive_message_revert_invalid_attestation() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    
    // Use invalid attestation
    let attestation = x"1234";

    let receipt = receive_message::receive_message(VALID_MESSAGE, attestation, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = receive_message::EInvalidDestinationDomain)]
  public fun test_receive_message_revert_incorrect_destination_domain() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Use message and attestation with destination domain 2
    let message = x"0000000000000000000000020000000000001cd80000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000001234";
    let attestation = x"5c0fce0a69d89e2144e25c957eac85ad5dfcbdf8182fc2b3a5f9e56ebb0c559961a6cad5f7eeba132d6cca1f3f6e65e6334499ebdf4c27a5638c4cf79e0960231b";

    let receipt = receive_message::receive_message(message, attestation, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = receive_message::EInvalidDestinationCaller)]
  public fun test_receive_message_revert_invalid_destination_caller() {
    // Attempt to receive message with incorrect caller
    let mut scenario = test_scenario::begin(INVALID_USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE_WITH_CALLER, VALID_MESSAGE_WITH_CALLER_ATTESTATION, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = receive_message::EInvalidMessageVersion)]
  public fun test_receive_message_revert_incorrect_message_version() { 
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Use message and attestation for message version 2
    let message = x"0000000200000000000000010000000000001cd80000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000001234";
    let attestation = x"7a2f4d74e18652854006026a8d2c3865e149e271a588a49b684e7abeef5fc9f24a107a6e25008e902af298f6878b9ec5bc4075586e8b6006b789bc1ef3fd92541b";

    let receipt = receive_message::receive_message(message, attestation, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = receive_message::ENonceAlreadyUsed)]
  public fun test_receive_message_revert_nonce_already_used() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Mark nonce already used prior to attempting receive
    mt_state.mark_nonce_used(0, 7384);
    
    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test] 
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_receive_message_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    
    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    let receipt = receive_message::receive_message(
      VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx()
    );

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  public fun test_stamp_receipt_successful() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);
    
    let expected_receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);
    let receipt = stamped_receipt.receipt();
    receive_message::assert_receipts_eq(
      &expected_receipt, 
      receipt
    );

    destroy(expected_receipt);
    destroy(stamped_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_stamp_receipt_revert_invalid_auth() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());

    // Attempt to use an invalid authenticator
    let auth = @0x123;
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    destroy(stamped_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = receive_message::ERecipientNotAuth)]
  public fun test_stamp_receipt_revert_recipient_not_auth() {
    let mut scenario = test_scenario::begin(USER);
    let mt_state = setup_state(&mut scenario);

    // Create receipt where the recipient is a user address
    let receipt = receive_message::create_receipt(USER, USER, 0, @0x1, 7384, x"1234", 1);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    destroy(stamped_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_stamp_receipt_revert_incompatible_state_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Create receipt where the recipient is a user address
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 1);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    destroy(stamped_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_stamp_receipt_revert_incompatible_receipt_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Create receipt where the recipient is a user address
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, 7384, x"1234", 123);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    destroy(stamped_receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  public fun test_complete_receive_message_successful() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);
    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    assert_eq(num_events(), 1);
    let message_received_event = last_event_by_type<receive_message::MessageReceived>();
    assert_eq(
      message_received_event, 
      receive_message::create_message_received_event(USER, 0, 7384, @0x1, x"1234"
    ));

    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_complete_receive_message_revert_incompatible_state_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, USER, 7384, x"1234", 1);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Attempt to complete with an incorrect version
    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = receive_message::EInvalidReceiptVersion)]
  public fun test_complete_receive_message_revert_incompatible_receipt_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, USER, 7384, x"1234", 123);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    // Add a new version and remove the current version
    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    // Attempt to complete with an incorrect version
    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    destroy(mt_state);
    scenario.end();
  }
}
