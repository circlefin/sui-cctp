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
 * Sui-transaction test helpers shared across bridge + admin E2E suites.
 * Every function is jest-scoped (test-only) — kept out of `scripts/sui/`
 * because it presumes `@jest/globals` and a fixed gas budget convention.
 */

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

import {
  executeTransactionHelper,
  SuiTxResponse,
  TxEvent,
} from "../../sui/helpers";

/**
 * Default gas budget for E2E test transactions. Generous enough for any
 * single-PTB admin call or multi-move-call bridge PTB; sized once here so
 * individual tests don't sprinkle magic numbers.
 */
export const TEST_GAS_BUDGET = 1_000_000_000;

/**
 * Execute a Sui `Transaction` as `signer` against `client`. Sets the shared
 * test gas budget and unwraps `executeTransactionHelper`'s response
 * (which itself throws on any on-chain failure with the underlying
 * `effects.status.error`, letting `expectMoveAbort` match against it).
 */
export const execAs = async (
  client: SuiGrpcClient,
  signer: Ed25519Keypair,
  tx: Transaction,
): Promise<SuiTxResponse> => {
  tx.setGasBudget(TEST_GAS_BUDGET);
  return executeTransactionHelper({ client, signer, transaction: tx });
};

/**
 * Find the first event on a tx whose `type` contains every substring.
 *
 * Substring matching (rather than exact type name) lets callers ignore the
 * package id prefix, which varies per deploy. Passing multiple substrings
 * disambiguates generics — e.g. `RoleTransferStarted<OwnerRole>` vs
 * another role's transfer — with a single call:
 *
 * ```ts
 * findEvent(tx, "two_step_role::RoleTransferStarted", "::roles::OwnerRole")
 * ```
 *
 * Throws a diagnostic listing all event types on the tx if no match is
 * found, so a failed test doesn't require a follow-up log-inspection round
 * trip.
 */
export const findEvent = (
  tx: SuiTxResponse,
  ...typeSubstrings: string[]
): TxEvent => {
  const event = tx.events?.find((e) =>
    typeSubstrings.every((s) => e.type.includes(s)),
  );
  if (!event) {
    throw new Error(
      `Event not found matching [${typeSubstrings.join(", ")}]. ` +
        `Actual event types: ${(tx.events ?? []).map((e) => e.type).join(", ")}`,
    );
  }
  return event;
};
