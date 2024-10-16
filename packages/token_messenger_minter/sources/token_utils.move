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

/// Module: token_utils
/// This module contains token utilities like calculating a token id.
module token_messenger_minter::token_utils {
    // === Imports ===
    use std::type_name::{Self};
    use sui::{hash::{Self}, address::{Self}};

    // === Public-View Functions ===

    /// Calculates the unique token id for a given coin Witness Type T. 
    /// CCTP defines a Sui Token id as the keccak-256 hash of it's full type name. 
    /// We cannot use the package address alone as it could contain multiple coin Witnesses.
    public fun calculate_token_id<T: drop>(): address {
      let full_type_name = type_name::get<T>().into_string().into_bytes();
      address::from_bytes(hash::keccak256(&full_type_name))
    }

    // === Tests ===

    #[test_only]
    public struct TestStr has drop {}

    #[test]
    fun calculate_token_id_returns_id() {
      // Pre-calculate hash of the TestStr typename (0000000000000000000000000000000000000000000000000000000000000002::token_utils::TestStr)
      let expected_bytes = @0xf9f9bf6008c46a66c228f4e44f81b3e14ea6e14d1578aad1bfce9621bf7dd9be;
      
      // Test: should return the expected (pre-caluclated) bytes
      let id = calculate_token_id<TestStr>();
      assert!(id == expected_bytes, 0);
    }
}
