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

/// Module: deserialize
/// Contains deserialization methods specific to the CCTP message format.
/// We cannot use BCS directly for uint deserialization because BCS uses 
/// little-endian, while CCTP messages use big-endian. So in all uint 
/// deserialization methods, reverse the bytes before calling into BCS.
module message_transmitter::deserialize {
  // === Imports ===  
  use sui::bcs;
  use message_transmitter::vector_utils;

  // === Public-View Functions ===

  public fun deserialize_u32_be(data: &vector<u8>, index: u64, size: u64): u32 {
    let mut sliced_data = vector_utils::slice(data, index, index+size);
    vector::reverse(&mut sliced_data);
    let mut bcs_bytes = bcs::new(sliced_data);
  
    bcs_bytes.peel_u32()
  }

  public fun deserialize_u64_be(data: &vector<u8>, index: u64, size: u64): u64 {
    let mut sliced_data = vector_utils::slice(data, index, index+size);
    vector::reverse(&mut sliced_data);
    let mut bcs_bytes = bcs::new(sliced_data);
  
    bcs_bytes.peel_u64()
  }

  public fun deserialize_u256_be(data: &vector<u8>, index: u64, size: u64): u256 {
    let mut sliced_data = vector_utils::slice(data, index, index+size);
    vector::reverse(&mut sliced_data);
    let mut bcs_bytes = bcs::new(sliced_data);
    
    bcs_bytes.peel_u256()
  }

  public fun deserialize_address(data: &vector<u8>, index: u64, size: u64): address {
    let sliced_data = vector_utils::slice(data, index, index+size);
    let mut bcs_bytes = bcs::new(sliced_data);
    
    bcs_bytes.peel_address()
  }

  // === Test Functions ===

  #[test]
  public fun test_deserialize_u32_be() {
      let num: u32 = 1234567;
      let mut serialized = bcs::to_bytes(&num);
      vector::reverse(&mut serialized);

      let deserialized = deserialize_u32_be(&serialized, 0, serialized.length());
      assert!(deserialized == num);
  }

  #[test]
  public fun test_deserialize_u64_be() {
      let num: u64 = 123456789;
      let mut serialized = bcs::to_bytes(&num);
      vector::reverse(&mut serialized);

      let deserialized = deserialize_u64_be(&serialized, 0, serialized.length());
      assert!(deserialized == num);
  }

  #[test]
  public fun test_deserialize_u256_be() {
      let num: u256 = 123456789123456789123456789;
      let mut serialized = bcs::to_bytes(&num);
      vector::reverse(&mut serialized);

      let deserialized = deserialize_u256_be(&serialized, 0, serialized.length());
      assert!(deserialized == num);
  }

  #[test]
  public fun test_deserialize_address() {
      let address: address = @0xa9fb1b3009dcb79e2fe346c16a604b8fa8ae0a79;
      let serialized = bcs::to_bytes(&address);

      let deserialized = deserialize_address(&serialized, 0, serialized.length());
      assert!(deserialized == address);
  }
}
