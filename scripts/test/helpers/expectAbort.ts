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

import { expect } from "@jest/globals";

/**
 * Assert that a Sui tx execution rejects with a Move abort in `moduleName`
 * at `abortCode`. `executeTransactionHelper` throws with
 * `effects.status.error` in the message, and for a Move abort that string
 * contains the module name and the abort code (in either the raw effects
 * shape `..., <code>)` or the @mysten/sui 2.x resolution shape
 * `abort code: <code>,`). Matching on both the module name and the code
 * distinguishes the intended abort from any unrelated (RPC / gas / setup)
 * failure.
 */
export const expectMoveAbort = async (
  p: Promise<unknown>,
  moduleName: string,
  abortCode: number,
): Promise<void> => {
  let error: Error | undefined;
  try {
    await p;
  } catch (e) {
    error = e as Error;
  }
  expect(error).toBeDefined();
  expect(error?.message).toContain(moduleName);
  // The abort code surfaces in one of two shapes depending on how the failure
  // is reported: the node's raw effects string (`..., <code>) in command N`,
  // via executeTransactionHelper reading effects.status.error) or the
  // @mysten/sui 2.x resolution error (`abort code: <code>,`).
  const msg = error?.message ?? "";
  expect(
    msg.includes(`, ${abortCode})`) ||
      msg.includes(`abort code: ${abortCode},`),
  ).toBe(true);
};
