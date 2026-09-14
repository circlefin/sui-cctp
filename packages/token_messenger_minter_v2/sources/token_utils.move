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

/// Module: token_utils
/// This module contains token utilities like calculating a token id.
module token_messenger_minter_v2::token_utils {
    // === Imports ===
    use std::type_name::{Self};
    use sui::{hash::{Self}, address::{Self}};

    // === Public-View Functions ===

    /// Sui token id = keccak-256 of the full type name of `T`. Not
    /// the package address alone, since one package may define multiple
    /// coin witnesses.
    public fun calculate_token_id<T: drop>(): address {
      let full_type_name = type_name::with_defining_ids<T>().into_string().into_bytes();
      address::from_bytes(hash::keccak256(&full_type_name))
    }

    // === Tests ===

    #[test_only]
    public struct TestStr has drop {}

    #[test]
    fun calculate_token_id_returns_id() {
      // keccak-256 of "0000000000000000000000000000000000000000000000000000000000000000::token_utils::TestStr"
      let expected_bytes = @0x3859c5e58a0d18cdf6aa8f5a34db140a67343f2f79e4e303a7b10fd7db57b618;
      let id = calculate_token_id<TestStr>();
      assert!(id == expected_bytes, 0);
    }
}
