/**
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

// Custom jest test sequencer: run the upgrade/migration specs last, with the
// default ordering in between.
//
// `test/upgrade.e2e*.test.ts` publish a real on-chain package upgrade and
// complete a migration, which sets the shared deployment's State
// `compatible_versions` to {2} and version-locks the originally-deployed
// (VERSION 1) package. Any suite that runs afterward against that deployment
// would abort in `version_control::assert_object_version_is_compatible_with_package`.
//
// Jest's default sequencer ignores CLI argument order, so ordering must be
// enforced here. Every other spec keeps its default ordering, sequenced before
// the upgrade group. New tests need no changes unless they match the
// `upgrade.e2e*` name below.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const Sequencer = require("@jest/test-sequencer").default;

const isUpgradeSpec = (test) =>
  /upgrade\.e2e(\.v2)?\.test\.[jt]sx?$/.test(test.path);

class UpgradeLastSequencer extends Sequencer {
  sort(tests) {
    const ordered = super.sort(tests);
    return [
      ...ordered.filter((t) => !isUpgradeSpec(t)),
      ...ordered.filter(isUpgradeSpec),
    ];
  }
}

module.exports = UpgradeLastSequencer;
