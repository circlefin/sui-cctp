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

/**
 * PTB builders that target `cctp_extensions::rescuable` (the package's only
 * module) directly rather than going through a consuming package's entry
 * wrappers in MT v2 / TMM v2.
 */

import { Transaction } from "@mysten/sui/transactions";

/**
 * Builds the "mint a `Rescuable` for someone else's object" PTB:
 * `rescuable::new` -> `rescuable::update_rescuer` -> `rescuable::destroy`,
 * with `parentObjectId` naming the object the forged `Rescuable` claims as
 * its parent.
 *
 * All three functions are public, so this sequence is well-typed Move — it is
 * only unbuildable as a transaction because `new` takes the parent's `&UID`,
 * which no PTB can produce (a `UID` is not an object and cannot be an input).
 * That is the property under test; see the `rescuable` cases in the MT v2 /
 * TMM v2 admin-event suites.
 */
export function buildForgeRescuable(
  cctpExtensionsPackageId: string,
  parentObjectId: string,
  rescuer: string,
  newRescuer: string,
): Transaction {
  const tx = new Transaction();
  const [rescuable] = tx.moveCall({
    target: `${cctpExtensionsPackageId}::rescuable::new`,
    arguments: [tx.object(parentObjectId), tx.pure.address(rescuer)],
  });
  // The payload an attacker would be after: a `RescuerChanged` event that is
  // type-identical to the one a consumer's `update_rescuer` emits.
  tx.moveCall({
    target: `${cctpExtensionsPackageId}::rescuable::update_rescuer`,
    arguments: [rescuable, tx.pure.address(newRescuer)],
  });
  // `Rescuable` has neither `key` nor `drop`, so the PTB has to consume it.
  tx.moveCall({
    target: `${cctpExtensionsPackageId}::rescuable::destroy`,
    arguments: [rescuable],
  });
  return tx;
}
