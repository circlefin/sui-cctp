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

/// Module: burn_message
/// This module contains the BurnMessage struct for CCTP v2 TokenMessenger messages.
/// The v2 BurnMessage is variable-length: a fixed 228-byte header followed by an
/// optional, variable-length `hookData` payload.
/// Message is structured in the following format:
/// --------------------------------------------------
/// Field                 Bytes      Type       Index
/// version               4          uint32     0
/// burnToken             32         bytes32    4
/// mintRecipient         32         bytes32    36
/// amount                32         uint256    68
/// messageSender         32         bytes32    100
/// maxFee                32         uint256    132
/// feeExecuted           32         uint256    164
/// expirationBlock       32         uint256    196
/// hookData              dynamic    bytes      228
/// --------------------------------------------------
module token_messenger_minter_v2::burn_message {
  // === Imports ===
  use message_transmitter_v2::{
    deserialize::{deserialize_u32_be, deserialize_u256_be, deserialize_address},
    serialize::{serialize_u32_be, serialize_u256_be, serialize_address},
    vector_utils
  };

  // === Errors ===
  const EInvalidMessageLength: u64 = 0;

  // === Constants ===
  const VERSION_INDEX: u64 = 0;
  const BURN_TOKEN_INDEX: u64 = 4;
  const MINT_RECIPIENT_INDEX: u64 = 36;
  const AMOUNT_INDEX: u64 = 68;
  const MESSAGE_SENDER_INDEX: u64 = 100;
  const MAX_FEE_INDEX: u64 = 132;
  const FEE_EXECUTED_INDEX: u64 = 164;
  const EXPIRATION_BLOCK_INDEX: u64 = 196;
  const HOOK_DATA_INDEX: u64 = 228;

  const VERSION_LEN: u64 = 4;
  const BURN_TOKEN_LEN: u64 = 32;
  const MINT_RECIPIENT_LEN: u64 = 32;
  const AMOUNT_LEN: u64 = 32;
  const MESSAGE_SENDER_LEN: u64 = 32;
  const MAX_FEE_LEN: u64 = 32;
  const FEE_EXECUTED_LEN: u64 = 32;
  const EXPIRATION_BLOCK_LEN: u64 = 32;

  // Minimum v2 burn message length: the fixed header without any hookData.
  // 4 + 32 + 32 + 32 + 32 + 32 + 32 + 32 = 228 bytes
  const MIN_BURN_MESSAGE_LEN: u64 =
    VERSION_LEN + BURN_TOKEN_LEN + MINT_RECIPIENT_LEN + AMOUNT_LEN
    + MESSAGE_SENDER_LEN + MAX_FEE_LEN + FEE_EXECUTED_LEN + EXPIRATION_BLOCK_LEN;

  // feeExecuted and expirationBlock are always zero on outbound (source) messages;
  // they are only populated by the destination domain on the received message.
  const EMPTY_FEE_EXECUTED: u256 = 0;
  const EMPTY_EXPIRATION_BLOCK: u256 = 0;

  // === Structs ===
  public struct BurnMessage has drop, copy {
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address,
    max_fee: u256,
    fee_executed: u256,
    expiration_block: u256,
    hook_data: vector<u8>
  }

  // === Public-View Functions ===

  public fun version(message: &BurnMessage): u32 {
    message.version
  }

  public fun burn_token(message: &BurnMessage): address {
    message.burn_token
  }

  public fun mint_recipient(message: &BurnMessage): address {
    message.mint_recipient
  }

  public fun amount(message: &BurnMessage): u256 {
    message.amount
  }

  public fun message_sender(message: &BurnMessage): address {
    message.message_sender
  }

  public fun max_fee(message: &BurnMessage): u256 {
    message.max_fee
  }

  public fun fee_executed(message: &BurnMessage): u256 {
    message.fee_executed
  }

  public fun expiration_block(message: &BurnMessage): u256 {
    message.expiration_block
  }

  public fun hook_data(message: &BurnMessage): vector<u8> {
    message.hook_data
  }

  // === Public Functions ===

  /// Serialize to the wire format: fixed 228-byte header + variable `hookData`.
  public fun serialize(message: &BurnMessage): vector<u8> {
    let BurnMessage {
      version,
      burn_token,
      mint_recipient,
      amount,
      message_sender,
      max_fee,
      fee_executed,
      expiration_block,
      hook_data
    } = message;

    let mut result: vector<u8> = vector[];
    vector::append(&mut result, serialize_u32_be(*version));
    vector::append(&mut result, serialize_address(*burn_token));
    vector::append(&mut result, serialize_address(*mint_recipient));
    vector::append(&mut result, serialize_u256_be(*amount));
    vector::append(&mut result, serialize_address(*message_sender));
    vector::append(&mut result, serialize_u256_be(*max_fee));
    vector::append(&mut result, serialize_u256_be(*fee_executed));
    vector::append(&mut result, serialize_u256_be(*expiration_block));
    vector::append(&mut result, *hook_data);

    result
  }

  // === Public-Package Functions ===

  /// Build an outbound `BurnMessage`. `feeExecuted` and
  /// `expirationBlock` are zeroed (populated on the destination).
  public(package) fun new(
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address,
    max_fee: u256,
    hook_data: vector<u8>
  ): BurnMessage {
    BurnMessage {
      version,
      burn_token,
      mint_recipient,
      amount,
      message_sender,
      max_fee,
      fee_executed: EMPTY_FEE_EXECUTED,
      expiration_block: EMPTY_EXPIRATION_BLOCK,
      hook_data
    }
  }

  /// Parse + validate from raw bytes.
  public(package) fun from_bytes(message_bytes: &vector<u8>): BurnMessage {
    validate_raw_message(message_bytes);

    BurnMessage {
      version: deserialize_u32_be(message_bytes, VERSION_INDEX, VERSION_LEN),
      burn_token: deserialize_address(message_bytes, BURN_TOKEN_INDEX, BURN_TOKEN_LEN),
      mint_recipient: deserialize_address(message_bytes, MINT_RECIPIENT_INDEX, MINT_RECIPIENT_LEN),
      amount: deserialize_u256_be(message_bytes, AMOUNT_INDEX, AMOUNT_LEN),
      message_sender: deserialize_address(message_bytes, MESSAGE_SENDER_INDEX, MESSAGE_SENDER_LEN),
      max_fee: deserialize_u256_be(message_bytes, MAX_FEE_INDEX, MAX_FEE_LEN),
      fee_executed: deserialize_u256_be(message_bytes, FEE_EXECUTED_INDEX, FEE_EXECUTED_LEN),
      expiration_block: deserialize_u256_be(message_bytes, EXPIRATION_BLOCK_INDEX, EXPIRATION_BLOCK_LEN),
      hook_data: vector_utils::slice(message_bytes, HOOK_DATA_INDEX, message_bytes.length())
    }
  }

  // === Private Functions ===

  /// A valid v2 burn message must contain at least the fixed 228-byte header;
  /// hookData is optional and may extend the message beyond that.
  fun validate_raw_message(message: &vector<u8>) {
    assert!(message.length() >= MIN_BURN_MESSAGE_LEN, EInvalidMessageLength);
  }

  // === Test Functions ===

  #[test_only]
  public fun new_for_testing(
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address,
    max_fee: u256,
    hook_data: vector<u8>
  ): BurnMessage {
    new(version, burn_token, mint_recipient, amount, message_sender, max_fee, hook_data)
  }

  #[test_only]
  public(package) fun from_bytes_for_testing(message_bytes: &vector<u8>): BurnMessage {
    from_bytes(message_bytes)
  }

  // Builds a raw v2 burn message allowing all header fields to be set explicitly
  // (including feeExecuted / expirationBlock, which `new` always zeros). Used to
  // construct destination-side fixtures for deserialization tests and by
  // downstream modules (handle_receive_message tests) that need to simulate a
  // fully-populated inbound message.
  #[test_only]
  public(package) fun build_raw_message_for_test(
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address,
    max_fee: u256,
    fee_executed: u256,
    expiration_block: u256,
    hook_data: vector<u8>
  ): vector<u8> {
    let mut result: vector<u8> = vector[];
    vector::append(&mut result, serialize_u32_be(version));
    vector::append(&mut result, serialize_address(burn_token));
    vector::append(&mut result, serialize_address(mint_recipient));
    vector::append(&mut result, serialize_u256_be(amount));
    vector::append(&mut result, serialize_address(message_sender));
    vector::append(&mut result, serialize_u256_be(max_fee));
    vector::append(&mut result, serialize_u256_be(fee_executed));
    vector::append(&mut result, serialize_u256_be(expiration_block));
    vector::append(&mut result, hook_data);
    result
  }

  /// Public wrapper of `build_raw_message_for_test` so dependent packages
  /// (e.g. stablecoin_handler) can build a fully-populated inbound burn message
  /// — including a non-zero `fee_executed` — in their own tests.
  #[test_only]
  public fun build_raw_message_for_testing(
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address,
    max_fee: u256,
    fee_executed: u256,
    expiration_block: u256,
    hook_data: vector<u8>
  ): vector<u8> {
    build_raw_message_for_test(version, burn_token, mint_recipient, amount, message_sender, max_fee, fee_executed, expiration_block, hook_data)
  }

  // Canonical 228-byte fixture (empty hookData, feeExecuted = 0, expirationBlock = 0).
  // Shares the core burn fields with the v1 fixture so cross-module consumer tests
  // (deposit_for_burn, handle_receive_message) keep the same expected values.
  // Burn Token: 0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238
  // Mint Recipient: 0x0000000000000000000000001F26414439C8D03FC4B9CA912CEFD5CB508C9605
  // Amount: 1214
  // Sender: 0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1
  #[test_only]
  public fun get_raw_test_message(): vector<u8> {
    x"000000010000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  }

  // === Tests ===
  #[test_only]
  use std::unit_test::{assert_eq};

  #[test_only] const VERSION: u32 = 1;
  #[test_only] const BURN_TOKEN: address = @0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
  #[test_only] const MINT_RECIPIENT: address = @0x0000000000000000000000001F26414439C8D03FC4B9CA912CEFD5CB508C9605;
  #[test_only] const AMOUNT: u256 = 1214;
  #[test_only] const MESSAGE_SENDER: address = @0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1;

  // from_bytes tests

  #[test]
  public fun test_from_bytes_successful() {
    let message = from_bytes(&get_raw_test_message());

    assert_eq!(message.version(), VERSION);
    assert_eq!(message.burn_token(), BURN_TOKEN);
    assert_eq!(message.mint_recipient(), MINT_RECIPIENT);
    assert_eq!(message.amount(), AMOUNT);
    assert_eq!(message.message_sender(), MESSAGE_SENDER);
    assert_eq!(message.max_fee(), 0);
    assert_eq!(message.fee_executed(), 0);
    assert_eq!(message.expiration_block(), 0);
    assert_eq!(message.hook_data(), x"");
  }

  #[test]
  #[expected_failure(abort_code = EInvalidMessageLength)]
  public fun test_from_bytes_invalid() {
    let message = vector[1,2,3,4,5];
    from_bytes(&message);
  }

  // A message that is one byte short of the fixed header must be rejected.
  #[test]
  #[expected_failure(abort_code = EInvalidMessageLength)]
  public fun test_from_bytes_too_short() {
    let mut message = get_raw_test_message();
    message.pop_back();
    from_bytes(&message);
  }

  #[test]
  fun test_validate_raw_message() {
    let orignal_message = get_raw_test_message();
    validate_raw_message(&orignal_message)
  }

  // Deserializes a destination-side message with non-zero feeExecuted / expirationBlock.
  #[test]
  public fun test_from_bytes_destination_fields() {
    let raw = build_raw_message_for_test(
      VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER,
      1, // max_fee
      1, // fee_executed
      2815337, // expiration_block
      x""
    );
    let message = from_bytes(&raw);

    assert_eq!(message.max_fee(), 1);
    assert_eq!(message.fee_executed(), 1);
    assert_eq!(message.expiration_block(), 2815337);
    assert_eq!(message.hook_data(), x"");
    // Round-trips exactly, preserving the destination-populated fields.
    assert_eq!(message.serialize(), raw);
  }

  // hookData: small payload is parsed and round-trips.
  #[test]
  public fun test_from_bytes_small_hook_data() {
    let hook = x"deadbeef";
    let raw = build_raw_message_for_test(
      VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, 1, 0, 0, hook
    );
    let message = from_bytes(&raw);

    assert_eq!(message.hook_data(), hook);
    assert_eq!(message.max_fee(), 1);
    assert_eq!(message.serialize(), raw);
  }

  // hookData: large payload (256 bytes) is parsed and round-trips.
  #[test]
  public fun test_from_bytes_large_hook_data() {
    let mut hook: vector<u8> = vector[];
    let mut i: u64 = 0;
    while (i < 256) {
      hook.push_back((i % 256) as u8);
      i = i + 1;
    };
    let raw = build_raw_message_for_test(
      VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, 0, 0, 0, hook
    );
    let message = from_bytes(&raw);

    assert_eq!(message.hook_data(), hook);
    assert_eq!(message.hook_data().length(), 256);
    assert_eq!(message.serialize(), raw);
  }

  // serialize tests

  #[test]
  public fun test_serialize_successful() {
    let raw_message = get_raw_test_message();
    let message = from_bytes(&raw_message);
    let serialized = message.serialize();

    assert_eq!(raw_message, serialized);
  }

  // new tests

  #[test]
  public fun new_message_successful() {
    let message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, 0, x"");

    assert_eq!(message.version(), VERSION);
    assert_eq!(message.burn_token(), BURN_TOKEN);
    assert_eq!(message.mint_recipient(), MINT_RECIPIENT);
    assert_eq!(message.amount(), AMOUNT);
    assert_eq!(message.message_sender(), MESSAGE_SENDER);
    assert_eq!(message.max_fee(), 0);
    // `new` always zeros these outbound.
    assert_eq!(message.fee_executed(), 0);
    assert_eq!(message.expiration_block(), 0);
    assert_eq!(message.hook_data(), x"");
  }

  #[test]
  public fun new_message_serialize_successful() {
    let message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, 0, x"");
    let raw_message = get_raw_test_message();

    assert_eq!(message.serialize(), raw_message);
  }

  #[test]
  public fun new_message_with_hook_data_round_trips() {
    let hook = x"cafe1234";
    let message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, 7, hook);
    let parsed = from_bytes(&message.serialize());

    assert_eq!(parsed.max_fee(), 7);
    assert_eq!(parsed.hook_data(), hook);
    assert_eq!(parsed.fee_executed(), 0);
    assert_eq!(parsed.expiration_block(), 0);
  }

}
