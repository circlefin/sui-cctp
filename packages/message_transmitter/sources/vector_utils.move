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

/// Module: vector_utils
/// Provides vector utilities that are not included
/// in the sui::vector module.
module message_transmitter::vector_utils {
  // === Errors ===

  const EStartIndexOutOfBounds: u64 = 0;
  const EEndIndexOutOfBounds: u64 = 1;

  // === Public-View Functions ===

  /// Performs a deep-copy of a portion of vector selected from `start` to
  /// `end` (`end` not included).
  public fun slice<T: copy>(data: &vector<T>, start_index: u64, end_index: u64): vector<T> {
    assert!(end_index > start_index, EEndIndexOutOfBounds);
    assert!(start_index < data.length(), EStartIndexOutOfBounds);
    assert!(end_index <= data.length(), EEndIndexOutOfBounds);

    let mut result = vector::empty<T>();
    let mut i = start_index;
    
    while (i < end_index) { 
      result.push_back(copy data[i]);
      i = i + 1;
    };

    result
  }

  // === Test Functions ===

  #[test]
  fun test_slice_normal_case_successful() {
    let data = vector[1, 2, 3, 4, 5];
    let result = slice(&data, 1, 4);
    assert!(result == vector[2, 3, 4], 0);
  }

  #[test]
  fun test_slice_entire_vector_successful() {
      let data = vector[1, 2, 3, 4, 5];
      let result = slice(&data, 0, 5);
      assert!(result == data, 0);
  }

  #[test]
  fun test_slice_single_element_successful() {
      let data = vector[1, 2, 3, 4, 5];
      let result = slice(&data, 2, 3);
      assert!(result == vector[3], 0);
  }

  #[test]
  fun test_slice_generic_type_successful() {
      let data = vector[b"hello", b"world", b"move"];
      let result = slice(&data, 0, 2);
      assert!(result == vector[b"hello", b"world"], 0);
  }

  #[test]
  #[expected_failure(abort_code = EEndIndexOutOfBounds)]
  fun test_slice_invalid_indices_start_gt_end() {
      let data = vector[1, 2, 3, 4, 5];
      slice(&data, 3, 2);
  }

  #[test]
  #[expected_failure(abort_code = EEndIndexOutOfBounds)]
  fun test_slice_invalid_indices_start_eq_end() {
      let data = vector[1, 2, 3, 4, 5];
      let result = slice(&data, 2, 2);
      assert!(vector::is_empty(&result), 0);
  }

  #[test]
  #[expected_failure(abort_code = EStartIndexOutOfBounds)]
  fun test_slice_start_index_out_of_bounds() {
      let data = vector[1, 2, 3, 4, 5];
      slice(&data, 5, 6);
  }

  #[test]
  #[expected_failure(abort_code = EEndIndexOutOfBounds)]
  fun test_slice_end_index_out_of_bounds() {
      let data = vector[1, 2, 3, 4, 5];
      slice(&data, 2, 6);
  }
}
