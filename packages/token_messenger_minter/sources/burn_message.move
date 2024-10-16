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

/// Module: burn_message
/// This module contains the BurnMessage struct for CCTP TokenMessenger  messages.
/// Format defined here: 
/// https://developers.circle.com/stablecoins/docs/message-format#message-body.
/// Message is structured in the following format:
/// --------------------------------------------------
/// Field                 Bytes      Type       Index
/// version               4          uint32     0
/// burnToken             32         bytes32    4
/// mintRecipient         32         bytes32    36
/// amount                32         uint256    68
/// messageSender         32         bytes32    100
/// --------------------------------------------------
module token_messenger_minter::burn_message {
  // === Imports ===
  use message_transmitter::{
    deserialize::{deserialize_u32_be, deserialize_u256_be, deserialize_address},
    serialize::{serialize_u32_be, serialize_u256_be, serialize_address},
  };

  // === Errors ===
  const EInvalidMessageLength: u64 = 0;

  // === Constants ===
  const VERSION_INDEX: u64 = 0;
  const BURN_TOKEN_INDEX: u64 = 4;
  const MINT_RECIPIENT_INDEX: u64 = 36;
  const AMOUNT_INDEX: u64 = 68;
  const MESSAGE_SENDER_INDEX: u64 = 100;

  const VERSION_LEN: u64 = 4;
  const BURN_TOKEN_LEN: u64 = 32;
  const MINT_RECIPIENT_LEN: u64 = 32;
  const AMOUNT_LEN: u64 = 32;
  const MESSAGE_SENDER_LEN: u64 = 32;

  // 132 bytes
  const BURN_MESSAGE_LEN: u64 = VERSION_LEN + BURN_TOKEN_LEN + MINT_RECIPIENT_LEN + AMOUNT_LEN + MESSAGE_SENDER_LEN;

  // === Structs ===
  public struct BurnMessage has drop, copy {
    version: u32,
    burn_token: address,
    mint_recipient: address,
    amount: u256,
    message_sender: address
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

  // === Public Functions ===

  /// Serializes a given `BurnMessage` into the CCTP message format in bytes.
  public fun serialize(message: &BurnMessage): vector<u8> {
    let BurnMessage {
      version, 
      burn_token, 
      mint_recipient, 
      amount,
      message_sender
    } = message;

    let mut result = vector::empty<u8>();
    vector::append(&mut result, serialize_u32_be(*version));
    vector::append(&mut result, serialize_address(*burn_token));
    vector::append(&mut result, serialize_address(*mint_recipient));
    vector::append(&mut result, serialize_u256_be(*amount));
    vector::append(&mut result, serialize_address(*message_sender));
    
    result
  }

  // === Public-Package Functions ===

  /// Creates a new `BurnMessage` object from given parameters.
  /// Has public(package) visibility so integrators can trust it when returned.
  public(package) fun new(version: u32, burn_token: address, mint_recipient: address, amount: u256, message_sender: address): BurnMessage {
    BurnMessage {
      version, burn_token, mint_recipient, amount, message_sender
    }
  }

  /// Creates a new `BurnMessage` object from bytes.
  /// Validates the message first.
  /// Has public(package) visibility so integrators can trust it when returned.
  public(package) fun from_bytes(message_bytes: &vector<u8>): BurnMessage {
    validate_raw_message(message_bytes);
    
    BurnMessage {
      version: deserialize_u32_be(message_bytes, VERSION_INDEX, VERSION_LEN),
      burn_token: deserialize_address(message_bytes, BURN_TOKEN_INDEX, BURN_TOKEN_LEN),
      mint_recipient: deserialize_address(message_bytes, MINT_RECIPIENT_INDEX, MINT_RECIPIENT_LEN),
      amount: deserialize_u256_be(message_bytes, AMOUNT_INDEX, AMOUNT_LEN),
      message_sender: deserialize_address(message_bytes, MESSAGE_SENDER_INDEX, MESSAGE_SENDER_LEN),
    }
  }

  public(package) fun update_mint_recipient(
    burn_message: &mut BurnMessage, new_mint_recipient: address
  ) {
    burn_message.mint_recipient = new_mint_recipient;
  }

  public(package) fun update_version(
    burn_message: &mut BurnMessage, new_version: u32
  ) {
    burn_message.version = new_version;
  }

  // === Private Functions ===

  fun validate_raw_message(message: &vector<u8>) {
    assert!(message.length() == BURN_MESSAGE_LEN, EInvalidMessageLength);
  }

  // === Test Functions ===

  #[test_only]
  public fun new_for_testing(version: u32, burn_token: address, mint_recipient: address, amount: u256, message_sender: address): BurnMessage {
    new(version, burn_token, mint_recipient, amount, message_sender)
  }

  #[test_only]
  public(package) fun from_bytes_for_testing(message_bytes: &vector<u8>): BurnMessage {
    from_bytes(message_bytes)
  }

  // Following test message is based on ->
  // ETH (Source): https://sepolia.etherscan.io/tx/0x151c196be83e2fcbd84204a521ee0a758a5e7335ac7d2c0958ef840fd485dc61
  // AVAX (Destination): https://testnet.snowtrace.io/tx/0xa98d5c33b7571609875f56ae148563411377392c87b9e8cebd483683a0e36413
  // Burn Token: 0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238
  // Mint Recipient: 0x0000000000000000000000001F26414439C8D03FC4B9CA912CEFD5CB508C9605
  // Amount: 1214
  // Sender: 0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1

  #[test_only]
  public fun get_raw_test_message(): vector<u8> {
    x"000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1"
  }

  // === Tests ===
  #[test_only]
  use sui::test_utils::{assert_eq};

  #[test_only] const VERSION: u32 = 0;
  #[test_only] const BURN_TOKEN: address = @0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
  #[test_only] const MINT_RECIPIENT: address = @0x0000000000000000000000001F26414439C8D03FC4B9CA912CEFD5CB508C9605;
  #[test_only] const AMOUNT: u256 = 1214;
  #[test_only] const MESSAGE_SENDER: address = @0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1;

  // from_bytes tests

  #[test]
  public fun test_from_bytes_successful() {
    let message = from_bytes(&get_raw_test_message());

    assert_eq(message.version(), VERSION);
    assert_eq(message.burn_token(), BURN_TOKEN);
    assert_eq(message.mint_recipient(), MINT_RECIPIENT);
    assert_eq(message.amount(), AMOUNT);
    assert_eq(message.message_sender(), MESSAGE_SENDER);
  }

  #[test]
  #[expected_failure(abort_code = EInvalidMessageLength)]
  public fun test_from_bytes_invalid() {
    let message = vector[1,2,3,4,5];
    from_bytes(&message);
  }

  #[test]
  fun test_validate_raw_message() {
    let orignal_message = get_raw_test_message();
    validate_raw_message(&orignal_message)
  }

  // serialize tests

  #[test]
  public fun test_serialize_successful() {
    let raw_message = get_raw_test_message();
    let message = from_bytes(&raw_message);
    let serialized = message.serialize();
    
    assert_eq(raw_message, serialized);
  }

  // new tests

  #[test]
  public fun new_message_successful() {
    let message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER);

    assert_eq(message.version(), VERSION);
    assert_eq(message.burn_token(), BURN_TOKEN);
    assert_eq(message.mint_recipient(), MINT_RECIPIENT);
    assert_eq(message.amount(), AMOUNT);
    assert_eq(message.message_sender(), MESSAGE_SENDER);
  }

  #[test]
  public fun new_message_serialize_successful() {
    let message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER);
    let raw_message = get_raw_test_message();

    assert_eq(message.serialize(), raw_message);
  }

  // update_mint_recipient tests

  #[test]
  public fun update_mint_recipient_successful() {
    let mut message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER);
    assert_eq(message.mint_recipient(), MINT_RECIPIENT);

    message.update_mint_recipient(MESSAGE_SENDER);
    assert_eq(message.mint_recipient(), MESSAGE_SENDER);
  }

  // update_version tests

  #[test]
  public fun update_version_successful() {
    let mut message = new(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER);
    assert_eq(message.version(), VERSION);

    message.update_version(VERSION+1);
    assert_eq(message.version(), VERSION+1);
  }
}
