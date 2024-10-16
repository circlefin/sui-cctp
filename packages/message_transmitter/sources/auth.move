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

/// Module: auth
/// This module contains auth_caller_identifier which is used to uniquely identify calling 
/// packages for various functions in the CCTP contracts. Any struct that implements the 
/// drop trait can be used as an authenticator, but it is recommended to use a dedicated struct.
/// Calling contracts should be careful to not expose these objects to the public or else messages 
/// from their package could be forged or replaced. An example implementation exists in the 
/// token_messenger_minter::message_transmitter_authenticator module.
module message_transmitter::auth {
  // === Imports ===
  use std::type_name::{Self};
  use sui::{
    address, hash
  };

  // === Errors ===
  const EInvalidAuth: u64 = 0;

  // === Public-View Functions ===
  
  /// Returns the identifier of a given Auth struct.
  /// Identifier is the keccak256 hash of the full type name. This ensures the package,
  /// module, and type are encoded in the identifier.
  public fun auth_caller_identifier<Auth: drop>(): address {
    let auth_type = type_name::get<Auth>();
    assert!(!auth_type.is_primitive(), EInvalidAuth);

    address::from_bytes(hash::keccak256(auth_type.into_string().as_bytes()))
  }
}

// === Tests ===

#[test_only]
module message_transmitter::auth_tests {
  use sui::{
    test_utils::assert_eq
  };
  use message_transmitter::{
    auth::{Self, auth_caller_identifier},
    message_transmitter_authenticator::{SendMessageTestAuth},
  };

  #[test]
  public fun test_auth_caller_identifier_successful() {
    let identifier = auth_caller_identifier<SendMessageTestAuth>();
    // address(hash(0000000000000000000000000000000000000000000000000000000000000001::message_transmitter_authenticator::SendMessageTestAuth))
    let expected_identifier = @0x949764be99bacbf6297178f1b467586bac40d0012cb816d5c1a2ea9167e79dfe;
    assert_eq(identifier, expected_identifier);
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_auth_caller_identifier_revert_primitive_type() {
    auth_caller_identifier<address>();
  }

}
