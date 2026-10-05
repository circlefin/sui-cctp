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

/// Module: auth
/// This module contains auth_caller_identifier which is used to uniquely identify calling 
/// packages for various functions in the CCTP contracts. Any struct that implements the 
/// drop trait can be used as an authenticator, but it is recommended to use a dedicated struct.
/// Calling contracts should be careful to not expose these objects to the public or else messages 
/// from their package could be forged or replaced. An example implementation exists in the 
/// token_messenger_minter::message_transmitter_authenticator module.
module message_transmitter_v2::auth {
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
  ///
  /// Type-scoped: every `drop` witness a package defines yields a different
  /// identifier. Use `auth_caller_package_address<W>()` below for a
  /// package-scoped identity.
  public fun auth_caller_identifier<Auth: drop>(): address {
    let auth_type = type_name::with_defining_ids<Auth>();
    assert!(!auth_type.is_primitive(), EInvalidAuth);

    address::from_bytes(hash::keccak256(auth_type.into_string().as_bytes()))
  }

  /// Returns the original package address of a given Auth struct (pinned via
  /// `type_name::with_original_ids`, so every witness type from the package —
  /// including one introduced in a later upgrade — resolves to the package's
  /// first-published id). Package-scoped, unlike `auth_caller_identifier`
  /// above, which is type-scoped.
  ///
  /// `with_original_ids` rather than `with_defining_ids` is load-bearing: a
  /// witness type added in an upgrade has a *defining* id of the upgraded
  /// package, so a package-scoped denylist keyed on defining ids would not
  /// match it.
  public fun auth_caller_package_address<Auth: drop>(): address {
    let auth_type = type_name::with_original_ids<Auth>();
    assert!(!auth_type.is_primitive(), EInvalidAuth);
    address::from_ascii_bytes(auth_type.address_string().as_bytes())
  }
}

// === Tests ===

#[test_only]
module message_transmitter_v2::auth_tests {
  use std::unit_test::{assert_eq};
  use message_transmitter_v2::{
    auth::{Self, auth_caller_identifier, auth_caller_package_address},
    message_transmitter_authenticator::{SendMessageTestAuth},
  };

  #[test]
  public fun test_auth_caller_identifier_successful() {
    let identifier = auth_caller_identifier<SendMessageTestAuth>();
    // address(hash(0000000000000000000000000000000000000000000000000000000000000000::message_transmitter_authenticator::SendMessageTestAuth))
    let expected_identifier = @0xadfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a;
    assert_eq!(identifier, expected_identifier);
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_auth_caller_identifier_revert_primitive_type() {
    auth_caller_identifier<address>();
  }

  /// The package address is the raw original package id, not a hash — same
  /// value for every witness type published from that package.
  ///
  /// NOTE: this cannot distinguish `with_original_ids` from
  /// `with_defining_ids`. Inside a Move unit test every type is defined by
  /// the package under test at its only publish, so the two ids are always
  /// equal here. The upgrade case they differ on — a witness type introduced
  /// by a later publish — needs a real package upgrade to exercise, so a
  /// regression back to defining ids would not be caught by this suite.
  #[test]
  public fun test_auth_caller_package_address_returns_original_package_id() {
    let pkg = auth_caller_package_address<SendMessageTestAuth>();
    // `SendMessageTestAuth` is defined in this test module inside
    // `message_transmitter_v2`; test builds resolve the package address
    // to `@0x0`, matching what other tests in this module observe.
    assert_eq!(pkg, @0x0);
  }

  #[test]
  #[expected_failure(abort_code = auth::EInvalidAuth)]
  public fun test_auth_caller_package_address_revert_primitive_type() {
    auth_caller_package_address<address>();
  }
}
