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

/**
 * Client for a CCTP package's `migration` module: drives the owner-gated
 * `start_migration` / `abort_migration` / `complete_migration` entry functions
 * over `State.compatible_versions`. Unlike the stablecoin equivalent these take
 * only the shared `State` (no coin type argument), so a single client serves all
 * five stateful CCTP packages, parameterized by package id + State object id.
 */

import { bcs } from "@mysten/sui/bcs";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { executeTransactionHelper } from "./upgradeHelpers";

export type MigrationAction = "start" | "abort" | "complete";

export const MIGRATION_ACTIONS: readonly MigrationAction[] = [
  "start",
  "abort",
  "complete",
];

export function isMigrationAction(value: string): value is MigrationAction {
  return (MIGRATION_ACTIONS as readonly string[]).includes(value);
}

export default class MigrationClient {
  suiClient: SuiGrpcClient;
  packageId: string;
  stateId: string;

  public constructor(
    suiClient: SuiGrpcClient,
    packageId: string,
    stateId: string,
  ) {
    this.suiClient = suiClient;
    this.packageId = packageId;
    this.stateId = stateId;
  }

  /**
   * Reads the State's owner via `state::roles` -> `roles::owner`, chained in a
   * single devInspect. The owner address is the second command's return value.
   */
  public async getOwner(): Promise<string> {
    const tx = new Transaction();
    const [roles] = tx.moveCall({
      target: `${this.packageId}::state::roles`,
      arguments: [tx.object(this.stateId)],
    });
    tx.moveCall({
      target: `${this.packageId}::roles::owner`,
      arguments: [roles],
    });

    tx.setSender(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    );
    const sim = await this.suiClient.simulateTransaction({
      transaction: tx,
      checksEnabled: false,
      include: { commandResults: true },
    });

    // The owner address is the second command's single return value.
    const returnValues = (sim as any).commandResults?.[1]?.returnValues;
    if (!returnValues?.[0]) {
      throw new Error("Failed to read State owner");
    }
    const bytes = returnValues[0].bcs;
    return bcs.Address.parse(
      bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes),
    );
  }

  /**
   * Runs a migration step: `<package>::migration::<action>_migration(state)`.
   * The owner check and version state-machine guards are enforced on-chain.
   */
  public async migrate(
    action: MigrationAction,
    signer: Ed25519Keypair,
    options: {
      gasBudget: bigint | null;
      dryRun?: boolean;
    },
  ) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.packageId}::migration::${action}_migration`,
      arguments: [tx.object(this.stateId)],
    });

    return executeTransactionHelper({
      dryRun: !!options.dryRun,
      client: this.suiClient,
      signer,
      transaction: tx,
      gasBudget: options.gasBudget != null ? BigInt(options.gasBudget) : null,
    });
  }
}
