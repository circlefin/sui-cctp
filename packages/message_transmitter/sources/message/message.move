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

/// Module: message
/// This module contains the Message struct for generic CCTP messages.
/// Format defined here: 
/// https://developers.circle.com/stablecoins/docs/message-format#message-header.
/// Message is structured in the following format:
/// --------------------------------------------------
/// Field                 Bytes      Type       Index
/// version               4          uint32     0
/// sourceDomain          4          uint32     4
/// destinationDomain     4          uint32     8
/// nonce                 8          uint64     12
/// sender                32         bytes32    20
/// recipient             32         bytes32    52
/// destinationCaller     32         bytes32    84
/// messageBody           dynamic    bytes      116
/// --------------------------------------------------
module message_transmitter::message {
  // === Imports ===
  use message_transmitter::{
    deserialize::{deserialize_u32_be, deserialize_u64_be, deserialize_address},
    serialize::{serialize_u32_be, serialize_u64_be, serialize_address},
    vector_utils
  };

  // === Errors ===
  const EInvalidMessageLength: u64 = 0;

  // === Constants ===
  const VERSION_INDEX: u64 = 0;
  const SOURCE_DOMAIN_INDEX: u64 = 4;
  const DESTINATION_DOMAIN_INDEX: u64 = 8;
  const NONCE_INDEX: u64 = 12;
  const SENDER_INDEX: u64 = 20;
  const RECIPIENT_INDEX: u64 = 52;
  const DESTINATION_CALLER_INDEX: u64 = 84;
  const MESSAGE_BODY_INDEX: u64 = 116;

  const VERSION_LEN: u64 = 4;
  const SOURCE_DOMAIN_LEN: u64 = 4;
  const DESTINATION_DOMAIN_LEN: u64 = 4;
  const NONCE_LEN: u64 = 8;
  const SENDER_LEN: u64 = 32;
  const RECIPIENT_LEN: u64 = 32;
  const DESTINATION_CALLER_LEN: u64 = 32;

  // === Structs ===
  public struct Message has drop, copy {
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    nonce: u64,
    sender: address,
    recipient: address,
    destination_caller: address,
    message_body: vector<u8>
  }

  // === Public-View Functions ===

  public fun version(message: &Message): u32 {
    message.version 
  }

  public fun source_domain(message: &Message): u32 {
    message.source_domain 
  }

  public fun destination_domain(message: &Message): u32 {
    message.destination_domain 
  }

  public fun nonce(message: &Message): u64 {
    message.nonce 
  }

  public fun sender(message: &Message): address {
    message.sender 
  }
  
  public fun recipient(message: &Message): address {
    message.recipient 
  }

  public fun destination_caller(message: &Message): address {
    message.destination_caller 
  }

  public fun message_body(message: &Message): vector<u8> {
    message.message_body
  }

  // === Public Functions ===

  // Creates a new `Message` object from given parameters.
  public fun new(
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    nonce: u64,
    sender: address,
    recipient: address,
    destination_caller: address,
    message_body: vector<u8>
  ): Message {
    Message {
      version, source_domain, destination_domain, nonce, sender, recipient, destination_caller, message_body
    }
  }

  /// Creates a new `Message` object.
  /// Validates the message first.
  public fun from_bytes(message_bytes: &vector<u8>): Message {
    validate_raw_message(message_bytes);
    
    Message {
      version: deserialize_u32_be(message_bytes, VERSION_INDEX, VERSION_LEN),
      source_domain: deserialize_u32_be(message_bytes, SOURCE_DOMAIN_INDEX, SOURCE_DOMAIN_LEN),
      destination_domain: deserialize_u32_be(message_bytes, DESTINATION_DOMAIN_INDEX, DESTINATION_DOMAIN_LEN),
      nonce: deserialize_u64_be(message_bytes, NONCE_INDEX, NONCE_LEN),
      sender: deserialize_address(message_bytes, SENDER_INDEX, SENDER_LEN),
      recipient: deserialize_address(message_bytes, RECIPIENT_INDEX, RECIPIENT_LEN),
      destination_caller: deserialize_address(message_bytes, DESTINATION_CALLER_INDEX, DESTINATION_CALLER_LEN),
      message_body: vector_utils::slice(message_bytes, MESSAGE_BODY_INDEX, message_bytes.length())
    }
  }

  /// Serializes a given `Message` into the CCTP message format in bytes.
  public fun serialize(message: &Message): vector<u8> {
    let Message {
      version, 
      source_domain, 
      destination_domain, 
      nonce,
      sender,
      recipient,
      destination_caller,
      message_body 
    } = message;

    let mut result = vector::empty<u8>();
    vector::append(&mut result, serialize_u32_be(*version));
    vector::append(&mut result, serialize_u32_be(*source_domain));
    vector::append(&mut result, serialize_u32_be(*destination_domain));
    vector::append(&mut result, serialize_u64_be(*nonce));
    vector::append(&mut result, serialize_address(*sender));
    vector::append(&mut result, serialize_address(*recipient));
    vector::append(&mut result, serialize_address(*destination_caller));
    vector::append(&mut result, *message_body);
    
    result
  }

  // === Public-Package Functions ===

  public(package) fun update_message_body(
    message: &mut Message, new_message_body: vector<u8>
  ) {
    message.message_body = new_message_body;
  }

  public(package) fun update_destination_caller(
    message: &mut Message, new_destination_caller: address
  ) {
    message.destination_caller = new_destination_caller;
  }

  public(package) fun update_version(
    message: &mut Message, new_version: u32
  ) {
    message.version = new_version;
  }

  /// Bytes message should contain all the data required for message transmitter. 
  /// Message body is optional.
  public(package) fun validate_raw_message(message: &vector<u8>) {
    assert!(message.length() >= MESSAGE_BODY_INDEX, EInvalidMessageLength);
  }

  // === Test Functions ===

  // Following test message is based on ->
  // ETH (Source): https://sepolia.etherscan.io/tx/0x151c196be83e2fcbd84204a521ee0a758a5e7335ac7d2c0958ef840fd485dc61
  // AVAX (Destination): https://testnet.snowtrace.io/tx/0xa98d5c33b7571609875f56ae148563411377392c87b9e8cebd483683a0e36413
  // Nonce: 258836
  // Sender: 0x0000000000000000000000009f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5 (ETH TokenMessenger)
  // Recipient: 0x000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d0 (AVAX TokenMessenger)
  //
  // Custom destination caller: 0x1f26414439C8D03FC4b9CA912CeFd5Cb508C9605

  #[test_only]
  public fun get_raw_test_message(): vector<u8> {
    x"000000000000000000000001000000000003f3140000000000000000000000009f3b8679c73c2fef8b59b4f3444d4e156fb70aa5000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d00000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c9605000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1"
  }

  // === Tests ===
  #[test_only]
  use sui::test_utils::{assert_eq};

  #[test_only] const VERSION: u32 = 0;
  #[test_only] const SOURCE_DOMAIN: u32 = 0;
  #[test_only] const DESTINATION_DOMAIN: u32 = 1;
  #[test_only] const NONCE: u64 = 258836;
  #[test_only] const SENDER: address = @0x0000000000000000000000009f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
  #[test_only] const RECIPIENT: address = @0x000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d0;
  #[test_only] const DESTINATION_CALLER: address = @0x0000000000000000000000001f26414439C8D03FC4b9CA912CeFd5Cb508C9605;
  #[test_only] const MESSAGE_BODY: vector<u8> = x"000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1";


  // from_bytes tests

  #[test]
  public fun test_from_bytes_successful() {
    let message = from_bytes(&get_raw_test_message());

    assert_eq(message.version(), VERSION);
    assert_eq(message.source_domain(), SOURCE_DOMAIN);
    assert_eq(message.destination_domain(), DESTINATION_DOMAIN);
    assert_eq(message.nonce(), NONCE);
    assert_eq(message.sender(), SENDER);
    assert_eq(message.recipient(), RECIPIENT);
    assert_eq(message.destination_caller(), DESTINATION_CALLER);
    assert_eq(message.message_body(), MESSAGE_BODY);
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
    let message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, NONCE, SENDER, RECIPIENT, DESTINATION_CALLER, MESSAGE_BODY);

    assert_eq(message.version(), VERSION);
    assert_eq(message.source_domain(), SOURCE_DOMAIN);
    assert_eq(message.destination_domain(), DESTINATION_DOMAIN);
    assert_eq(message.nonce(), NONCE);
    assert_eq(message.sender(), SENDER);
    assert_eq(message.recipient(), RECIPIENT);
    assert_eq(message.destination_caller(), DESTINATION_CALLER);
    assert_eq(message.message_body(), MESSAGE_BODY);
  }

  #[test]
  public fun new_message_serialize_successful() {
    let message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, NONCE, SENDER, RECIPIENT, DESTINATION_CALLER, MESSAGE_BODY);
    let raw_message = get_raw_test_message();

    assert_eq(message.serialize(), raw_message);
  }

  // update_message_body tests

  #[test]
  public fun update_message_body_successful() {
    let mut message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, NONCE, SENDER, RECIPIENT, DESTINATION_CALLER, MESSAGE_BODY);
    assert_eq(message.message_body(), MESSAGE_BODY);

    let new_message_body = x"123456";
    message.update_message_body(new_message_body);
    assert_eq(message.message_body(), new_message_body);
  }

  // update_destination_caller tests

  #[test]
  public fun update_destination_caller_successful() {
    let mut message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, NONCE, SENDER, RECIPIENT, DESTINATION_CALLER, MESSAGE_BODY);
    assert_eq(message.destination_caller(), DESTINATION_CALLER);

    message.update_destination_caller(SENDER);
    assert_eq(message.destination_caller(), SENDER);
  }

  // update_version tests

  #[test]
  public fun update_version_successful() {
    let mut message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, NONCE, SENDER, RECIPIENT, DESTINATION_CALLER, MESSAGE_BODY);
    assert_eq(message.version(), VERSION);

    message.update_version(VERSION+1);
    assert_eq(message.version(), VERSION+1);
  }
}
