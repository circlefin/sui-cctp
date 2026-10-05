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

/// Module: message
/// This module contains the Message struct for generic CCTP v2 messages.
/// Format defined here:
/// https://developers.circle.com/stablecoins/docs/message-format#message-header.
/// Message is structured in the following format:
/// -----------------------------------------------------------
/// Field                       Bytes      Type       Index
/// version                     4          uint32     0
/// sourceDomain                4          uint32     4
/// destinationDomain           4          uint32     8
/// nonce                       32         uint256    12
/// sender                      32         bytes32    44
/// recipient                   32         bytes32    76
/// destinationCaller           32         bytes32    108
/// minFinalityThreshold        4          uint32     140
/// finalityThresholdExecuted   4          uint32     144
/// messageBody                 dynamic    bytes      148
/// -----------------------------------------------------------
module message_transmitter_v2::message {
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
  const SOURCE_DOMAIN_INDEX: u64 = 4;
  const DESTINATION_DOMAIN_INDEX: u64 = 8;
  const NONCE_INDEX: u64 = 12;
  const SENDER_INDEX: u64 = 44;
  const RECIPIENT_INDEX: u64 = 76;
  const DESTINATION_CALLER_INDEX: u64 = 108;
  const MIN_FINALITY_THRESHOLD_INDEX: u64 = 140;
  const FINALITY_THRESHOLD_EXECUTED_INDEX: u64 = 144;
  const MESSAGE_BODY_INDEX: u64 = 148;

  const VERSION_LEN: u64 = 4;
  const SOURCE_DOMAIN_LEN: u64 = 4;
  const DESTINATION_DOMAIN_LEN: u64 = 4;
  const NONCE_LEN: u64 = 32;
  const SENDER_LEN: u64 = 32;
  const RECIPIENT_LEN: u64 = 32;
  const DESTINATION_CALLER_LEN: u64 = 32;
  const MIN_FINALITY_THRESHOLD_LEN: u64 = 4;
  const FINALITY_THRESHOLD_EXECUTED_LEN: u64 = 4;

  const EMPTY_NONCE: u256 = 0;
  const EMPTY_FINALITY_THRESHOLD_EXECUTED: u32 = 0;

  // === Structs ===
  public struct Message has drop, copy {
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    nonce: u256,
    sender: address,
    recipient: address,
    destination_caller: address,
    min_finality_threshold: u32,
    finality_threshold_executed: u32,
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

  public fun nonce(message: &Message): u256 {
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

  public fun min_finality_threshold(message: &Message): u32 {
    message.min_finality_threshold
  }

  public fun finality_threshold_executed(message: &Message): u32 {
    message.finality_threshold_executed
  }

  public fun message_body(message: &Message): vector<u8> {
    message.message_body
  }

  public fun message_body_from_bytes(message_bytes: &vector<u8>): vector<u8> {
    validate_raw_message(message_bytes);
    vector_utils::slice(message_bytes, MESSAGE_BODY_INDEX, message_bytes.length())
  }

  // === Public Functions ===

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
      min_finality_threshold,
      finality_threshold_executed,
      message_body
    } = message;

    let mut result: vector<u8> = vector[];
    vector::append(&mut result, serialize_u32_be(*version));
    vector::append(&mut result, serialize_u32_be(*source_domain));
    vector::append(&mut result, serialize_u32_be(*destination_domain));
    vector::append(&mut result, serialize_u256_be(*nonce));
    vector::append(&mut result, serialize_address(*sender));
    vector::append(&mut result, serialize_address(*recipient));
    vector::append(&mut result, serialize_address(*destination_caller));
    vector::append(&mut result, serialize_u32_be(*min_finality_threshold));
    vector::append(&mut result, serialize_u32_be(*finality_threshold_executed));
    vector::append(&mut result, *message_body);

    result
  }

  // === Public-Package Functions ===

  /// Creates a new source-side `Message`. Nonce and finality_threshold_executed
  /// are zeroed; they are populated on the destination side via `from_bytes`.
  public(package) fun new(
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    sender: address,
    recipient: address,
    destination_caller: address,
    min_finality_threshold: u32,
    message_body: vector<u8>
  ): Message {
    Message {
      version, source_domain, destination_domain,
      nonce: EMPTY_NONCE,
      sender, recipient, destination_caller,
      min_finality_threshold,
      finality_threshold_executed: EMPTY_FINALITY_THRESHOLD_EXECUTED,
      message_body
    }
  }

  /// Creates a new `Message` object.
  /// Validates the message first.
  /// Has public(package) visibility so integrators can trust it when returned.
  public(package) fun from_bytes(message_bytes: &vector<u8>): Message {
    validate_raw_message(message_bytes);

    Message {
      version: deserialize_u32_be(message_bytes, VERSION_INDEX, VERSION_LEN),
      source_domain: deserialize_u32_be(message_bytes, SOURCE_DOMAIN_INDEX, SOURCE_DOMAIN_LEN),
      destination_domain: deserialize_u32_be(message_bytes, DESTINATION_DOMAIN_INDEX, DESTINATION_DOMAIN_LEN),
      nonce: deserialize_u256_be(message_bytes, NONCE_INDEX, NONCE_LEN),
      sender: deserialize_address(message_bytes, SENDER_INDEX, SENDER_LEN),
      recipient: deserialize_address(message_bytes, RECIPIENT_INDEX, RECIPIENT_LEN),
      destination_caller: deserialize_address(message_bytes, DESTINATION_CALLER_INDEX, DESTINATION_CALLER_LEN),
      min_finality_threshold: deserialize_u32_be(message_bytes, MIN_FINALITY_THRESHOLD_INDEX, MIN_FINALITY_THRESHOLD_LEN),
      finality_threshold_executed: deserialize_u32_be(message_bytes, FINALITY_THRESHOLD_EXECUTED_INDEX, FINALITY_THRESHOLD_EXECUTED_LEN),
      message_body: vector_utils::slice(message_bytes, MESSAGE_BODY_INDEX, message_bytes.length())
    }
  }

  /// Bytes message should contain all the data required for message transmitter.
  /// Message body is optional.
  fun validate_raw_message(message: &vector<u8>) {
    assert!(message.length() >= MESSAGE_BODY_INDEX, EInvalidMessageLength);
  }

  // === Test Functions ===

  #[test_only]
  public fun new_for_testing(
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    sender: address,
    recipient: address,
    destination_caller: address,
    min_finality_threshold: u32,
    message_body: vector<u8>
  ): Message {
    new(version, source_domain, destination_domain, sender, recipient, destination_caller, min_finality_threshold, message_body)
  }

  #[test_only]
  public fun from_bytes_for_testing(message_bytes: &vector<u8>): Message {
    from_bytes(message_bytes)
  }

  // Canonical V2 source-side fixture (nonce = 0, finality_threshold_executed = 0).
  // Built from the test constants below; shares addresses/body with BurnMessageV2 fixture.
  #[test_only]
  public fun get_raw_test_message(): vector<u8> {
    x"00000001000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000009f3b8679c73c2fef8b59b4f3444d4e156fb70aa5000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d00000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c9605000003e800000000000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1"
  }

  // Builds a raw V2 message allowing all header fields to be set explicitly
  // (including nonce + finality_threshold_executed, which `new` always zeros).
  // Used to construct destination-side fixtures for deserialization tests.
  #[test_only]
  fun build_raw_message_for_test(
    version: u32,
    source_domain: u32,
    destination_domain: u32,
    nonce: u256,
    sender: address,
    recipient: address,
    destination_caller: address,
    min_finality_threshold: u32,
    finality_threshold_executed: u32,
    message_body: vector<u8>
  ): vector<u8> {
    let mut result: vector<u8> = vector[];
    vector::append(&mut result, serialize_u32_be(version));
    vector::append(&mut result, serialize_u32_be(source_domain));
    vector::append(&mut result, serialize_u32_be(destination_domain));
    vector::append(&mut result, serialize_u256_be(nonce));
    vector::append(&mut result, serialize_address(sender));
    vector::append(&mut result, serialize_address(recipient));
    vector::append(&mut result, serialize_address(destination_caller));
    vector::append(&mut result, serialize_u32_be(min_finality_threshold));
    vector::append(&mut result, serialize_u32_be(finality_threshold_executed));
    vector::append(&mut result, message_body);
    result
  }

  // === Tests ===
  #[test_only]
  use std::unit_test::{assert_eq};

  #[test_only] const VERSION: u32 = 1;
  #[test_only] const SOURCE_DOMAIN: u32 = 0;
  #[test_only] const DESTINATION_DOMAIN: u32 = 1;
  #[test_only] const MIN_FINALITY_THRESHOLD: u32 = 1000;
  #[test_only] const SENDER: address = @0x0000000000000000000000009f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
  #[test_only] const RECIPIENT: address = @0x000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d0;
  #[test_only] const DESTINATION_CALLER: address = @0x0000000000000000000000001f26414439C8D03FC4b9CA912CeFd5Cb508C9605;
  #[test_only] const MESSAGE_BODY: vector<u8> = x"000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1";


  // from_bytes tests

  #[test]
  public fun test_from_bytes_successful() {
    let message = from_bytes(&get_raw_test_message());

    assert_eq!(message.version(), VERSION);
    assert_eq!(message.source_domain(), SOURCE_DOMAIN);
    assert_eq!(message.destination_domain(), DESTINATION_DOMAIN);
    assert_eq!(message.nonce(), 0);
    assert_eq!(message.sender(), SENDER);
    assert_eq!(message.recipient(), RECIPIENT);
    assert_eq!(message.destination_caller(), DESTINATION_CALLER);
    assert_eq!(message.min_finality_threshold(), MIN_FINALITY_THRESHOLD);
    assert_eq!(message.finality_threshold_executed(), 0);
    assert_eq!(message.message_body(), MESSAGE_BODY);
  }

  #[test]
  #[expected_failure(abort_code = EInvalidMessageLength)]
  public fun test_from_bytes_invalid() {
    let message = vector[1,2,3,4,5];
    from_bytes(&message);
  }

  #[test]
  #[expected_failure(abort_code = EInvalidMessageLength)]
  public fun test_from_bytes_too_short() {
    let mut message = build_raw_message_for_test(
      VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, 0, SENDER, RECIPIENT, DESTINATION_CALLER,
      MIN_FINALITY_THRESHOLD, 0, x""
    );
    message.pop_back();
    from_bytes(&message);
  }

  #[test]
  fun test_validate_raw_message() {
    let orignal_message = get_raw_test_message();
    validate_raw_message(&orignal_message)
  }

  #[test]
  public fun test_from_bytes_destination_fields() {
    let raw = build_raw_message_for_test(
      VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN,
      42,
      SENDER, RECIPIENT, DESTINATION_CALLER,
      MIN_FINALITY_THRESHOLD,
      5,
      MESSAGE_BODY
    );
    let message = from_bytes(&raw);

    assert_eq!(message.nonce(), 42);
    assert_eq!(message.min_finality_threshold(), MIN_FINALITY_THRESHOLD);
    assert_eq!(message.finality_threshold_executed(), 5);
    assert_eq!(message.message_body(), MESSAGE_BODY);
    assert_eq!(message.serialize(), raw);
  }

  #[test]
  public fun test_u256_nonce_no_truncation() {
    let large_nonce: u256 = 18446744073709551616; // u64::MAX + 1
    let raw = build_raw_message_for_test(
      VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN,
      large_nonce,
      SENDER, RECIPIENT, DESTINATION_CALLER,
      MIN_FINALITY_THRESHOLD, 0, MESSAGE_BODY
    );
    let message = from_bytes(&raw);

    assert_eq!(message.nonce(), large_nonce);
    assert_eq!(message.serialize(), raw);
  }

  #[test]
  public fun test_message_body_from_bytes() {
    let raw_message = get_raw_test_message();
    assert_eq!(message_body_from_bytes(&raw_message), MESSAGE_BODY);
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
    let message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, SENDER, RECIPIENT, DESTINATION_CALLER, MIN_FINALITY_THRESHOLD, MESSAGE_BODY);

    assert_eq!(message.version(), VERSION);
    assert_eq!(message.source_domain(), SOURCE_DOMAIN);
    assert_eq!(message.destination_domain(), DESTINATION_DOMAIN);
    assert_eq!(message.nonce(), 0);
    assert_eq!(message.sender(), SENDER);
    assert_eq!(message.recipient(), RECIPIENT);
    assert_eq!(message.destination_caller(), DESTINATION_CALLER);
    assert_eq!(message.min_finality_threshold(), MIN_FINALITY_THRESHOLD);
    assert_eq!(message.finality_threshold_executed(), 0);
    assert_eq!(message.message_body(), MESSAGE_BODY);
    assert_eq!(message_body_from_bytes(&message.serialize()), MESSAGE_BODY);
  }

  #[test]
  public fun new_message_serialize_successful() {
    let message = new(VERSION, SOURCE_DOMAIN, DESTINATION_DOMAIN, SENDER, RECIPIENT, DESTINATION_CALLER, MIN_FINALITY_THRESHOLD, MESSAGE_BODY);
    let raw_message = get_raw_test_message();

    assert_eq!(message.serialize(), raw_message);
  }

}
