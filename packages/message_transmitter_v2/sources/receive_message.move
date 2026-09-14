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

/// Module: receive_message
/// Contains public functions for receiving cross-chain messages.
///
/// Note on upgrades: If interacting with this module from other packages, it
/// is recommended to call the receive_message_with_package_auth and stamp_receipt 
/// methods from a PTB rather than directly from dependent packages. These functions  
/// are version gated, so if this package is upgraded, the upgraded package must be called. 
module message_transmitter_v2::receive_message {

  // === Imports ===
  use sui::{
    event::emit,
  };
  use message_transmitter_v2::{
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
    nonce: u256,
    finality_threshold_executed: u32,
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
    nonce: u256,
    sender: address,
    finality_threshold_executed: u32,
    message_body: vector<u8>
  }

  // === Public-Mutative Functions ===

  /// Receives a message. Messages with a given nonce can only be received once. Nonces are globally unique across source domains.
  /// Intended to be called directly from an EOA when a package destination_caller is not specified on the message.
  /// Please use receive_message_with_package_auth if a package destination_caller is specified.
  /// 
  /// This function returns a `Receipt` struct ([Hot Potato](https://medium.com/@borispovod/move-hot-potato-pattern-bbc48a48d93c))
  /// after validating attestation and marking the nonce as used.
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
  ///     let receipt = message_transmitter_v2::receive_message(message, attestation, &mut state);
  ///     let stamp_receipt_ticket = receiver_package::handle_receive_message(receipt);
  ///     let stamped_receipt = message_transmitter_v2::stamp_receipt(stamp_receipt_ticket, &state);
  ///     message_transmitter_v2::complete_receive_message(stamped_receipt, &state);
  /// ```
  ///
  /// Reverts if:
  /// - contract is paused
  /// - the message format is invalid
  /// - the attestation is invalid
  /// - the destination domain of the message does not match the local domain
  /// - the destination caller of the message is set and does not match the caller
  /// - the message version does not match the local message version
  /// - a message with the given nonce has already been received
  /// 
  /// Parameters:
  /// - message: a message, in bytes, corresponding with the format defined in the `message_transmitter_v2::message` module.
  /// - attestation: a valid attestation consisting of concatenated 65-byte signature(s) of exactly `signature_threshold` signatures, in
  ///                increasing order of attester address.
  /// - state: State shared object for the MessageTransmitter package.
  public fun receive_message(message: vector<u8>, attestation: vector<u8>, state: &mut State, ctx: &mut TxContext): Receipt {
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
  ///     let receipt = message_transmitter_v2::receive_message_with_package_auth(receive_msg_ticket, &mut state);
  ///     // create_stamp_receipt_ticket is called from inside receiver_package::handle_receive_message()
  ///     let (message_body, stamp_receipt_ticket) = receiver_package::handle_receive_message(receipt);
  ///     let stamped_receipt = message_transmitter_v2::stamp_receipt(stamp_receipt_ticket, &state);
  ///     message_transmitter_v2::complete_receive_message(stamped_receipt, &state);
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
      finality_threshold_executed: stamped_receipt.receipt.finality_threshold_executed,
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

  /// Fetch the current_version for a receipt.
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
  ): u256 {
    receipt.nonce
  }

  /// Fetch the finality_threshold_executed for a receipt.
  public fun finality_threshold_executed(
    receipt: &Receipt
  ): u32 {
    receipt.finality_threshold_executed
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

    let source_domain = message_struct.source_domain();
    let nonce = message_struct.nonce();
    assert!(!state.is_nonce_used(nonce), ENonceAlreadyUsed);
    state.mark_nonce_used(nonce);

    // Return unstamped receipt
    Receipt {
      caller: sender,
      recipient: message_struct.recipient(),
      source_domain,
      sender: message_struct.sender(),
      nonce,
      finality_threshold_executed: message_struct.finality_threshold_executed(),
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

  /// Destroys a stamped receipt (and its inner receipt) once it is no
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
      finality_threshold_executed: _,
      message_body: _,
      current_version: _
    } = receipt;
  }
  
  // === Test Functions ===
  #[test_only] use std::unit_test::{assert_eq};
  
  #[test_only]
  public fun create_receipt(
    caller: address,
    recipient: address,
    source_domain: u32,
    sender: address,
    nonce: u256,
    finality_threshold_executed: u32,
    message_body: vector<u8>,
    current_version: u64
  ): Receipt {
    Receipt {
      caller,
      recipient,
      source_domain,
      sender,
      nonce,
      finality_threshold_executed,
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
    assert_eq!(given_receipt.caller(), expected_receipt.caller());
    assert_eq!(given_receipt.recipient(), expected_receipt.recipient());
    assert_eq!(given_receipt.source_domain(), expected_receipt.source_domain());
    assert_eq!(given_receipt.sender(), expected_receipt.sender());
    assert_eq!(given_receipt.nonce(), expected_receipt.nonce());
    assert_eq!(given_receipt.finality_threshold_executed(), expected_receipt.finality_threshold_executed());
    assert_eq!(*given_receipt.message_body(), *expected_receipt.message_body());
  }

  #[test_only]
  public fun create_message_received_event(
    caller: address,
    source_domain: u32,
    nonce: u256,
    sender: address,
    finality_threshold_executed: u32,
    message_body: vector<u8>
  ): MessageReceived {
    MessageReceived {
      caller,
      source_domain,
      nonce,
      sender,
      finality_threshold_executed,
      message_body
    }
  }
}

// === Tests ===

#[test_only]
module message_transmitter_v2::receive_message_authenticator {
  public struct ReceiveMessageTestAuth has drop {}

  public fun new(): ReceiveMessageTestAuth {
    ReceiveMessageTestAuth {}
  }
}

#[test_only]
module message_transmitter_v2::receive_message_tests {
  use sui::{
    event::{num_events},
    test_scenario,
  };
  use std::unit_test::{destroy, assert_eq};
  use message_transmitter_v2::{
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
  const NONCE: u256 = 0x1a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff;
  const FINALITY_THRESHOLD_EXECUTED: u32 = 2000;

  // V2 message: version=1, sourceDomain=0, destDomain=1, nonce=0x1a2b3c...eeff, sender=@0x1,
  // recipient=SendMessageTestAuth, destCaller=@0x0, minFinality=1000, finalityExec=2000, body=x"1234"
  const VALID_MESSAGE: vector<u8> = x"0000000100000000000000011a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001adfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a0000000000000000000000000000000000000000000000000000000000000000000003e8000007d01234";
  const VALID_MESSAGE_ATTESTATION: vector<u8> = x"686e88c3b374aa6ad3e2b1e7a1addd813cf982b814a49c3944e4a8267fa9434d78a83d7274fce1f92d319b70d80a57d188fc4207ed5b6799ce5e32377bffcb611c";

  // Same as VALID_MESSAGE but destCaller=USER (@0x1A)
  const VALID_MESSAGE_WITH_CALLER: vector<u8> = x"0000000100000000000000011a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001adfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a000000000000000000000000000000000000000000000000000000000000001a000003e8000007d01234";
  const VALID_MESSAGE_WITH_CALLER_ATTESTATION: vector<u8> = x"4dfdc17325d9d289dd3012095376208e71a2273a2fb0e6bd4554045b1c8f7b090cc7d7fb163cf0b8158d62c99a6c252a1157496ef786f90a5caafe5e1effb0f11b";

  // Same as VALID_MESSAGE but destCaller=ReceiveMessageTestAuth
  const VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH: vector<u8> = x"0000000100000000000000011a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001adfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a69788a0ba05513421d52c216e7ae78b77ed75c9eefc6b30c27e381c51ab92a4b000003e8000007d01234";
  const VALID_MESSAGE_WITH_CALLER_WITH_PACKAGE_AUTH_ATTESTATION: vector<u8> = x"197f41946a6593976b55f26cddac95e161337eb47c5e2b27fcafb93cb44343db42995fba15ce45a745732082c3a5acc82a4a43294d40f86fd4882c5fe03a35f71b";

  // === Test Functions ===

  #[test_only]
  fun setup_state(
    scenario: &mut test_scenario::Scenario
  ): state::State {
    let ctx = test_scenario::ctx(scenario);
    let mut message_transmitter_state = state::new_for_testing(
      1, 1, 10000, @0x0, ctx
    );
    // Test attester = vm.addr(1), i.e. the EVM address of secp256k1 private key
    // `1` (the `attesterPK = 1` convention from evm-cctp-contracts TestUtils.sol).
    // The VALID_MESSAGE* attestations below are signed with that key, so it must
    // stay in sync with them; regenerate via scripts if the golden messages change.
    message_transmitter_state.enable_attester(@0x7e5f4552091a69125d5dfcb7b8c2659029395bdf);

    message_transmitter_state
  }

  // === Tests ===

  #[test]
  public fun test_receive_message_successful_no_destination_caller() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);

    let receipt = receive_message::receive_message(VALID_MESSAGE, VALID_MESSAGE_ATTESTATION, &mut mt_state, scenario.ctx());
    let expected_receipt = receive_message::create_receipt(
      USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1
    );

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(NONCE));

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
    let expected_receipt = receive_message::create_receipt(
      auth_id, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1
    );

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(NONCE));

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
    let expected_receipt = receive_message::create_receipt(
      USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1
    );

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(NONCE));

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
    let expected_receipt = receive_message::create_receipt(
      auth_id, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1
    );

    receive_message::assert_receipts_eq(&receipt, &expected_receipt);
    assert!(mt_state.is_nonce_used(NONCE));

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

    // V2 message with destination domain 2 (state expects 1)
    let message = x"0000000100000000000000021a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001a000003e8000007d01234";
    let attestation = x"2ec1d9a625b6f7adb59ea3862053a5b87b93533927db0f7c1c18736c71e0f5be68eff04a06b972f11c890b4b67e6d590d43ca9ca49ecadba488b55b0469c83411b";

    let receipt = receive_message::receive_message(message, attestation, &mut mt_state, scenario.ctx());

    destroy(receipt);
    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = receive_message::EInvalidDestinationCaller)]
  public fun test_receive_message_revert_invalid_destination_caller() {
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

    // V2 message with version 2 (state expects 1)
    let message = x"0000000200000000000000011a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001a000003e8000007d01234";
    let attestation = x"0843a84b93489f08afc75f5b439ce4848ccc979a29287bd3faa3bfc3b8f9d9a56db784504f8bbd27e583a4e22bb7edfe40d44bbe324a6cdeeb006b3a1206bf831c";

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

    mt_state.mark_nonce_used(NONCE);

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

    let expected_receipt = receive_message::create_receipt(
      USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1
    );
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

    let receipt = receive_message::create_receipt(USER, USER, 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1);
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

    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1);
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

    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, @0x1, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 123);
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
    assert!(mt_state.is_nonce_used(NONCE));

    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);
    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    assert!(mt_state.is_nonce_used(NONCE));
    assert_eq!(num_events(), 1);
    let message_received_event = last_event_by_type<receive_message::MessageReceived>();
    assert_eq!(
      message_received_event,
      receive_message::create_message_received_event(USER, 0, NONCE, @0x1, FINALITY_THRESHOLD_EXECUTED, x"1234")
    );

    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  public fun test_complete_receive_message_revert_incompatible_state_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, USER, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 1);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    destroy(mt_state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = receive_message::EInvalidReceiptVersion)]
  public fun test_complete_receive_message_revert_incompatible_receipt_version() {
    let mut scenario = test_scenario::begin(USER);
    let mut mt_state = setup_state(&mut scenario);
    let receipt = receive_message::create_receipt(USER, auth_caller_identifier<SendMessageTestAuth>(), 0, USER, NONCE, FINALITY_THRESHOLD_EXECUTED, x"1234", 123);
    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = receive_message::create_stamp_receipt_ticket(auth, receipt);

    let stamped_receipt = receive_message::stamp_receipt(stamp_receipt_ticket, &mt_state);

    mt_state.add_compatible_version(5);
    mt_state.remove_compatible_version(version_control::current_version());

    receive_message::complete_receive_message(stamped_receipt, &mt_state);

    destroy(mt_state);
    scenario.end();
  }
}
