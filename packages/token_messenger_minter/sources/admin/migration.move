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

/// module: migration
/// Contains admin functions for migrating the package and state object to new versions.
module token_messenger_minter::migration {
    // === Imports ===
    use std::u64::{min, max};
    use sui::event;
    use token_messenger_minter::{
      state::State,
      version_control
    };

    // === Errors === 

    /// Migration related error codes, starting at 100.
    const ENotOwner: u64 = 0;
    const EMigrationStarted: u64 = 100;
    const EMigrationNotStarted: u64 = 101;
    const EObjectMigrated: u64 = 102;
    const ENotPendingVersion: u64 = 103;

    // === Events ===

    public struct MigrationStarted has copy, drop {
        compatible_versions: vector<u64>
    }

    public struct MigrationAborted has copy, drop {
        compatible_versions: vector<u64>
    }

    public struct MigrationCompleted has copy, drop {
        compatible_versions: vector<u64>
    }

    // === Public functions ===

    /// Starts the migration process, making the State object be
    /// additionally compatible with this package's version.
    entry fun start_migration(state: &mut State, ctx: &TxContext) {
        assert!(state.roles().owner() == ctx.sender(), ENotOwner);
        assert!(state.compatible_versions().size() == 1, EMigrationStarted);

        let active_version = state.compatible_versions().keys()[0];
        assert!(active_version < version_control::current_version(), EObjectMigrated);

        state.add_compatible_version(version_control::current_version());
        
        event::emit(MigrationStarted {
            compatible_versions: *state.compatible_versions().keys()
        });
    }

    /// Aborts the migration process, reverting the State object's compatibility
    /// to the previous version.
    entry fun abort_migration(state: &mut State, ctx: &TxContext) {
        assert!(state.roles().owner() == ctx.sender(), ENotOwner);
        assert!(state.compatible_versions().size() == 2, EMigrationNotStarted);

        let pending_version = max(
            state.compatible_versions().keys()[0],
            state.compatible_versions().keys()[1]
        );
        assert!(pending_version == version_control::current_version(), ENotPendingVersion);

        state.remove_compatible_version(pending_version);

        event::emit(MigrationAborted {
            compatible_versions: *state.compatible_versions().keys()
        });
    }

    /// Completes the migration process, making the State object be
    /// only compatible with this package's version.
    entry fun complete_migration(state: &mut State, ctx: &TxContext) {
        assert!(state.roles().owner() == ctx.sender(), ENotOwner);
        assert!(state.compatible_versions().size() == 2, EMigrationNotStarted);

        let (version_a, version_b) = (
          state.compatible_versions().keys()[0], 
          state.compatible_versions().keys()[1]
        );
        let (active_version, pending_version) = (
          min(version_a, version_b), 
          max(version_a, version_b)
        );

        assert!(pending_version == version_control::current_version(), ENotPendingVersion);

        state.remove_compatible_version(active_version);

        event::emit(MigrationCompleted {
            compatible_versions: *state.compatible_versions().keys()
        });
    }

    // === Test-Functions ===

    #[test_only]
    public(package) fun create_migration_started_event(compatible_versions: vector<u64>): MigrationStarted {
        MigrationStarted { compatible_versions }
    }

    #[test_only]
    public(package) fun create_migration_aborted_event(compatible_versions: vector<u64>): MigrationAborted {
        MigrationAborted { compatible_versions }
    }

    #[test_only]
    public(package) fun create_migration_completed_event(compatible_versions: vector<u64>): MigrationCompleted {
        MigrationCompleted { compatible_versions }
    }
}

#[test_only]
module token_messenger_minter::migration_tests {
    use sui::{
        event,
        test_scenario::{Self, Scenario}, 
        test_utils::{Self, assert_eq},
    };
    use token_messenger_minter::{
        migration,
        state::{Self, State},
        version_control
    };
    use sui_extensions::test_utils::{last_event_by_type};

    // Test addresses
    const DEPLOYER: address = @0x0;
    const OWNER: address = @0x10;
    const RANDOM_ADDRESS: address = @0x1000;

    public struct MIGRATION_TESTS has drop {}

    #[test, expected_failure(abort_code = migration::ENotOwner)]
    fun start_migration__should_fail_is_caller_is_not_owner() {
        let (mut state, mut scenario) = setup();

        // Some random address attempts to start a migration, should fail.
        scenario.next_tx(RANDOM_ADDRESS);
        test_start_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::EMigrationStarted)]
    fun start_migration__should_fail_if_migration_started() {
        let (mut state, mut scenario) = setup();

        // Start a migration to this package.
        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);
        
        // Attempt to start another migration, should fail.
        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::EObjectMigrated)]
    fun start_migration__should_fail_if_state_is_migrated() {
        let (mut state, mut scenario) = setup();

        // Complete a migration flow to this package.
        {
            scenario.next_tx(OWNER);
            test_start_migration(&mut state, &mut scenario);
            
            scenario.next_tx(OWNER);
            test_complete_migration(&mut state, &mut scenario);
        };

        // Attempt to start a migration to this package again, should fail.
        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test]
    fun start_migration__should_succeed_and_pass_all_assertions() {
        let (mut state, mut scenario) = setup();

        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::ENotOwner)]
    fun abort_migration__should_fail_is_caller_is_not_owner() {
        let (mut state, mut scenario) = setup();

        // Some random address attempts to start a migration, should fail.
        scenario.next_tx(RANDOM_ADDRESS);
        test_abort_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::EMigrationNotStarted)]
    fun abort_migration__should_fail_if_migration_not_started() {
        let (mut state, mut scenario) = setup();

        // Attempt to abort a migration that has not started, should fail.
        scenario.next_tx(OWNER);
        test_abort_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::ENotPendingVersion)]
    fun abort_migration__should_fail_if_the_pending_version_is_not_this_package_version() {
        let (mut state, mut scenario) = setup();

        // Start a migration flow to a later package.
        scenario.next_tx(OWNER);
        start_migration_to_custom_version_for_testing(&mut state, version_control::current_version() + 100);

        // Attempt to abort the migration using this package, should fail.
        scenario.next_tx(OWNER);
        test_abort_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test]
    fun abort_migration__should_succeed_and_pass_all_assertions() {
        let (mut state, mut scenario) = setup();

        // Start a migration.    
        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);

        // Abort the migration.
        scenario.next_tx(OWNER);
        test_abort_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::ENotOwner)]
    fun complete_migration__should_fail_is_caller_is_not_owner() {
        let (mut state, mut scenario) = setup();

        // Some random address attempts to start a migration, should fail.
        scenario.next_tx(RANDOM_ADDRESS);
        test_complete_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::EMigrationNotStarted)]
    fun complete_migration__should_fail_if_migration_not_started() {
        let (mut state, mut scenario) = setup();

        // Attempt to complete a migration that has not started, should fail.
        scenario.next_tx(OWNER);
        test_complete_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test, expected_failure(abort_code = migration::ENotPendingVersion)]
    fun complete_migration__should_fail_if_the_pending_version_is_not_this_package_version() {
        let (mut state, mut scenario) = setup();

        // Start a migration flow to a later package.
        scenario.next_tx(OWNER);
        start_migration_to_custom_version_for_testing(&mut state, version_control::current_version() + 100);

        // Attempt to complete the migration using this package, should fail.
        scenario.next_tx(OWNER);
        test_complete_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    #[test]
    fun complete_migration__should_succeed_and_pass_all_assertions() {
        let (mut state, mut scenario) = setup();

        // Start a migration.    
        scenario.next_tx(OWNER);
        test_start_migration(&mut state, &mut scenario);

        // Complete the migration.
        scenario.next_tx(OWNER);
        test_complete_migration(&mut state, &mut scenario);

        cleanup(state, scenario);
    }

    // === Helpers ===

    /// Sets up an outdated State object that is initialized with
    /// (package's version - 1). 
    fun setup(): (State, Scenario) {
        let mut scenario = test_scenario::begin(DEPLOYER);
        let mut state = state::new(0, OWNER, scenario.ctx());
        
        let previous_version = version_control::current_version() - 1;
        
        state.remove_compatible_version(version_control::current_version());
        state.add_compatible_version(previous_version);
        assert_eq(*state.compatible_versions().keys(), vector[previous_version]);
        
        (state, scenario)
    }

    fun cleanup(state: State, scenario: Scenario) {
        test_utils::destroy(state);
        scenario.end();
    }

    fun test_start_migration(state: &mut State, scenario: &mut Scenario) {
        migration::start_migration(state, scenario.ctx());

        let updated_compatible_versions = state.compatible_versions().keys();
        assert_eq(updated_compatible_versions.length(), 2);
        assert_eq(updated_compatible_versions.contains(&version_control::current_version()), true);

        assert_eq(event::num_events(), 1);
        assert_eq(
            last_event_by_type(),
            migration::create_migration_started_event(*updated_compatible_versions)
        );
    }

    fun test_abort_migration(state: &mut State, scenario: &mut Scenario) {
        migration::abort_migration(state, scenario.ctx());

        let updated_compatible_versions = state.compatible_versions().keys();
        assert_eq(updated_compatible_versions.length(), 1);
        assert_eq(updated_compatible_versions.contains(&version_control::current_version()), false);

        assert_eq(event::num_events(), 1);
        assert_eq(
            last_event_by_type(),
            migration::create_migration_aborted_event(*updated_compatible_versions)
        );
    }

    fun test_complete_migration(state: &mut State, scenario: &mut Scenario) {
        migration::complete_migration(state, scenario.ctx());

        let updated_compatible_versions = state.compatible_versions().keys();
        assert_eq(*updated_compatible_versions, vector[version_control::current_version()]);

        assert_eq(event::num_events(), 1);
        assert_eq(
            last_event_by_type(),
            migration::create_migration_completed_event(*updated_compatible_versions)
        );
    }

    fun start_migration_to_custom_version_for_testing(state: &mut State, version: u64) {
        assert_eq(state.compatible_versions().keys().length(), 1);

        state.add_compatible_version(version);

        assert_eq(state.compatible_versions().keys().length(), 2);
        assert_eq(state.compatible_versions().contains(&version), true);
    }
}
