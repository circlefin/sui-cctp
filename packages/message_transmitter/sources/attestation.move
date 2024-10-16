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

/// Module: attestation
/// This module contains all attestation processing logic for the message_transmitter package
module message_transmitter::attestation {
  // === Imports ===

  use sui::{
    address::{Self},
    hash::{Self},
    ecdsa_k1::{Self},
  };
  use message_transmitter::state::{State};
  use message_transmitter::vector_utils;

  // === Errors ===

  const EInvalidAttestationLength: u64 = 0;
  const EInvalidSignatureOrder: u64 = 1;
  const ESignerIsNotAttester: u64 = 2;
  const EInvalidSignatureRecoveryId: u64 = 3;
  const EInvalidSignatureSValue: u64 = 4;

  // === Constants ===

  const SIGNATURE_LENGTH: u64 = 65;
  const HALF_CURVE_ORDER: address = @0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

  /// The ecdsa_k1 module identifies the hash functions used in signing through a u8 value.
  /// The value is 0 for KECCAK256, but constants are internal to their module, so we must redefine it here.
  /// https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/crypto/ecdsa_k1.move#L35
  const KECCAK256_ID: u8 = 0;

  // === Public-Package Functions ===

  /// Verifies that the attestation for a message, comprised of one or more concatenated 65-byte signatures, is valid.
  /// Reverts if invalid. A valid attestation requires the following conditions to be met:
  /// 1. length of `attestation` == 65 (signature length) * signature_threshold
  /// 2. addresses recovered from attestation must be in increasing order.
  ///    For example, if signature A is signed by address 0x1..., and signature B
  ///    is signed by address 0x2..., attestation must be passed as AB.
  /// 3. no duplicate signers
  /// 4. all signers must be enabled attesters
  /// 
  /// Based on Christian Lundkvist's Simple Multisig
  /// (https://github.com/christianlundkvist/simple-multisig/tree/560c463c8651e0a4da331bd8f245ccd2a48ab63d)
  public(package) fun verify_attestation_signatures(message: vector<u8>, attestation: vector<u8>, state: &State) {
    let signature_threshold = state.signature_threshold();
    assert!(attestation.length() == signature_threshold * SIGNATURE_LENGTH, EInvalidAttestationLength);

    let mut latest_attester_address = @0x0;
    let mut i = 0u64;
    while (i < signature_threshold) {
      let signature = vector_utils::slice(&attestation, i * SIGNATURE_LENGTH, (i + 1) * SIGNATURE_LENGTH);
      verify_low_s_value(signature);

      let normalized_signature = normalize_attestation(signature);
      let recovered_attester = recover_attester(&normalized_signature, &message);

      // Signatures must be in increasing order of address, and may not duplicate signatures from same address.
      // Addresses may not be directly compared, so they must be cast to u256 first.
      assert!(recovered_attester.to_u256() > latest_attester_address.to_u256(), EInvalidSignatureOrder);
      assert!(state.is_attester_enabled(recovered_attester), ESignerIsNotAttester);

      latest_attester_address = recovered_attester;
      i = i + 1;
    }
  }

  // === Private Functions ===

  /// Checks if `s` value of signature is in the lower half of curve order
  /// Using Secp256k1Ecdsa Half Curve order from OpenZeppelin ecdsa recover
  /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/ECDSA.sol#L137
  fun verify_low_s_value(signature: vector<u8>) {
      // Signature is made of r(32 bytes) + s(32 bytes) + v(1 byte)
      let signature_s_value = vector_utils::slice(&signature, 32, SIGNATURE_LENGTH-1);
      let signature_s_address = address::from_bytes(signature_s_value);

      assert!(signature_s_address.to_u256() <= HALF_CURVE_ORDER.to_u256(), EInvalidSignatureSValue);
  }

  /// Helper function to recover the attester from a signature and message.
  fun recover_attester(signature: &vector<u8>, message: &vector<u8>): address {
    // Recover the compressed public key from the signature and message, then decompress it.
    let recovered_key = ecdsa_k1::secp256k1_ecrecover(signature, message, KECCAK256_ID);
    let decompressed_pubkey = ecdsa_k1::decompress_pubkey(&recovered_key);

    // Remove the 0x04 prefix from the public key prior to hashing.
    let sliced_decompressed_pubkey = vector_utils::slice(&decompressed_pubkey, 1, decompressed_pubkey.length());

    // Hash the public key and take the last 20 bytes to fetch the attester.
    let hashed_pubkey = hash::keccak256(&sliced_decompressed_pubkey);
    let attester = vector_utils::slice(&hashed_pubkey, hashed_pubkey.length() - 20, hashed_pubkey.length());

    // Prepend the attester with 12 empty bytes to produce a Sui address.
    let mut attester_address = x"000000000000000000000000";
    attester_address.append(attester);

    address::from_bytes(attester_address)
  }

  /// Helper function to normalize the v-value for an attestation.
  /// Circle attestations provide v = 27 or 28, while Sui expects v between 0 and 3.
  /// This function normalizes by subtracting 27 from v.
  fun normalize_attestation(attestation: vector<u8>): vector<u8> {
    let mut normalized_attestation = vector_utils::slice(&attestation, 0, SIGNATURE_LENGTH - 1);
    let mut attestation_v = vector_utils::slice(&attestation, SIGNATURE_LENGTH - 1, SIGNATURE_LENGTH);
    let v = attestation_v.pop_back();

    assert!(v >= 27 && v <= 28, EInvalidSignatureRecoveryId);
    normalized_attestation.push_back(v - 27);

    normalized_attestation
  }

  // === Tests ===
  #[test_only] use sui::{test_scenario, test_utils};
  #[test_only] use message_transmitter::state::{Self};
  #[test_only] use message_transmitter::attester_manager::{Self};

  // Sample attestations are pulled from the following transaction
  // https://sepolia.etherscan.io/tx/0x151c196be83e2fcbd84204a521ee0a758a5e7335ac7d2c0958ef840fd485dc61

  #[test_only] const FIRST_ATTESTER: address = @0x0Ce39e399e2038C435Cc097833d5c58f5E9A7E98;
  #[test_only] const SECOND_ATTESTER: address = @0xC0b11b8850107DE6e92cF63E3B2CCB179b72F21C;
  #[test_only] const FIRST_ATTESTATION: vector<u8> = x"16a47e516fca2826c186fdd1ea00ac3c48e46d41d3756187b5f83424b76633dd7f9a45bd9ee5b3cc187de0a40ee20c8841d77ee0933e6d83a626060f15fbb1e51b";
  #[test_only] const SECOND_ATTESTATION: vector<u8> = x"4bff09dbfcca2ddb8af1cf8e14670f19096e6de130af14cb7ce21b1e9ccfa76c025d1eddf2dee7f0915861d87d423b62d3afa286f110eef38f6c27f3ccc4169d1c";
  #[test_only] const ATTESTATION: vector<u8> = x"16a47e516fca2826c186fdd1ea00ac3c48e46d41d3756187b5f83424b76633dd7f9a45bd9ee5b3cc187de0a40ee20c8841d77ee0933e6d83a626060f15fbb1e51b4bff09dbfcca2ddb8af1cf8e14670f19096e6de130af14cb7ce21b1e9ccfa76c025d1eddf2dee7f0915861d87d423b62d3afa286f110eef38f6c27f3ccc4169d1c";
  #[test_only] const RAW_MESSAGE: vector<u8> = x"000000000000000000000001000000000003f3140000000000000000000000009f3b8679c73c2fef8b59b4f3444d4e156fb70aa5000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d00000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c9605000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1";

  #[test]
  public fun test_verify_signature_successful() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Test: successfully verify a signature
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());
      attester_manager::enable_attester(SECOND_ATTESTER, &mut state, scenario.ctx());
      attester_manager::set_signature_threshold(2, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, ATTESTATION, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidAttestationLength)]
  public fun test_verify_signature_revert_invalid_attestation_length() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Test: revert when verifying a signature due to invalid attestation length
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, ATTESTATION, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidSignatureOrder)]
  public fun test_verify_signature_revert_invalid_signature_order() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Create an invalid attestation with the first/second attestation swapped
    let mut invalid_attestation = SECOND_ATTESTATION;
    invalid_attestation.append(FIRST_ATTESTATION);

    // Test: revert when verifying a signature due to invalid signature order
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());
      attester_manager::enable_attester(SECOND_ATTESTER, &mut state, scenario.ctx());
      attester_manager::set_signature_threshold(2, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, invalid_attestation, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidSignatureOrder)]
  public fun test_verify_signature_revert_duplicate_signer() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Create an invalid attestation with attestations from the same signer twice in a row
    let mut invalid_attestation = FIRST_ATTESTATION;
    invalid_attestation.append(FIRST_ATTESTATION);

    // Test: revert when verifying a signature due to duplicate signers
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());
      attester_manager::enable_attester(SECOND_ATTESTER, &mut state, scenario.ctx());
      attester_manager::set_signature_threshold(2, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, invalid_attestation, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = ESignerIsNotAttester)]
  public fun test_verify_signature_revert_invalid_signer() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Test: revert when verifying a signature due to signer not being an attester
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, SECOND_ATTESTATION, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidSignatureRecoveryId)]
  public fun test_verify_signature_revert_recovery_id_too_high() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Create an invalid attestation with the last byte changed
    let mut invalid_attestation = FIRST_ATTESTATION;
    invalid_attestation.pop_back();
    invalid_attestation.push_back(31);

    // Test: revert when verifying a signature due to an invalid signature recovery id (too high)
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, invalid_attestation, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidSignatureRecoveryId)]
  public fun test_verify_signature_revert_recovery_id_too_low() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Create an invalid attestation with the last byte changed
    let mut invalid_attestation = FIRST_ATTESTATION;
    invalid_attestation.pop_back();
    invalid_attestation.push_back(26);

    // Test: revert when verifying a signature due to an invalid signature recovery id (too low)
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, invalid_attestation, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = EInvalidSignatureSValue)]
  public fun test_verify_signature_revert_invalid_signature_s_value() {
    let mut scenario = test_scenario::begin(@0x0);
    let (attester_manager) = (@0x1);

    // Create a new State instance
    let mut state = state::new(0, 0, 0, attester_manager, scenario.ctx());

    // Create an invalid attestation with the S value too high (HALF_CURVE_ORDER + 1)
    let starting_attestation = FIRST_ATTESTATION;
    let mut invalid_attestation = vector_utils::slice(&starting_attestation, 0, 32);
    invalid_attestation.append(address::from_u256(address::to_u256(HALF_CURVE_ORDER) + 1).to_bytes());
    invalid_attestation.push_back(27);

    // Test: revert when verifying a signature due to an invalid signature recovery id (too low)
    scenario.next_tx(attester_manager);
    {
      attester_manager::enable_attester(FIRST_ATTESTER, &mut state, scenario.ctx());

      verify_attestation_signatures(RAW_MESSAGE, invalid_attestation, &state);
    };

    test_utils::destroy(state);
    scenario.end();
  }
}
