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

/// module: version_control
/// Contains version control functions.
/// Copied from stablecoin package: 
/// https://github.com/circlefin/stablecoin-sui/blob/63fca4360821600ca8686b86f8e26d98e95927c7/packages/stablecoin/sources/version_control.move.
module message_transmitter::version_control {
    use sui::vec_set::VecSet;

    /// The current version of the package.
    const VERSION: u64 = 1;

    // === Errors ===
    const EIncompatibleVersion: u64 = 0;

    // === Methods ===
    /// Public accessor for the current package's version.
    public fun current_version(): u64 {
        VERSION
    }

    /// [Package Private] Helper function to check that the object is
    /// compatible with the current package's version.
    public(package) fun assert_object_version_is_compatible_with_package(compatible_versions: &VecSet<u64>) {
        assert!(compatible_versions.contains(&current_version()), EIncompatibleVersion);
    }
}

#[test_only]
module message_transmitter::version_control_tests {
    use sui::vec_set::{Self, VecSet};
    use message_transmitter::version_control;

    #[test, expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun assert_object_version_is_compatible_with_package__should_abort_if_not_compatible() {
        let compatible_versions: VecSet<u64> = vec_set::empty();
        version_control::assert_object_version_is_compatible_with_package(
            &compatible_versions
        )
    }

    #[test]
    fun assert_object_version_is_compatible_with_package__should_succeed_if_compatible_version_is_contained() {
        let compatible_versions: VecSet<u64> = vec_set::singleton(version_control::current_version());
        version_control::assert_object_version_is_compatible_with_package(
            &compatible_versions
        )
    }

    #[test]
    fun assert_object_version_is_compatible_with_package__should_succeed_if_one_of_multiple_compatible_versions() {
        let mut compatible_versions: VecSet<u64> = vec_set::empty();
        compatible_versions.insert(version_control::current_version());
        compatible_versions.insert(version_control::current_version() + 1);

        version_control::assert_object_version_is_compatible_with_package(
            &compatible_versions
        )
    }
}
