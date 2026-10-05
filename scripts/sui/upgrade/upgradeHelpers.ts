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
 * Helpers for the CCTP upgrade/migration tooling. Ported from the stablecoin-sui
 * submodule (typescript/scripts/helpers/index.ts) rather than imported directly:
 * that tree ships as raw TS on a different @mysten/sui install, and the
 * TypeScript compiler cannot resolve its bare imports across the submodule
 * boundary.
 * These are the subset the upgrade scripts need, with a dry-run + gas-budget aware
 * transaction executor that the repo's existing helpers.ts does not provide.
 */

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { MIST_PER_SUI } from "@mysten/sui/utils";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import readline from "readline/promises";

import { SuiTxResponse, toSuiTxResponse } from "../helpers";

export const DEFAULT_GAS_BUDGET = BigInt(1) * MIST_PER_SUI; // 1 SUI

export class TransactionError extends Error {
  transactionOutput: SuiTxResponse;

  constructor(message: string | undefined, transactionOutput: SuiTxResponse) {
    super(message);
    this.transactionOutput = transactionOutput;
  }
}

/**
 * Builds, (optionally dry-runs), signs, submits, and waits for a transaction.
 * When `dryRun` is true the transaction is only simulated and the dry-run
 * response is returned without submitting.
 */
export async function executeTransactionHelper(args: {
  dryRun: boolean;
  signer: Ed25519Keypair;
  client: SuiGrpcClient;
  transaction: Transaction;
  gasBudget: bigint | null;
}): Promise<SuiTxResponse> {
  if (args.gasBudget) {
    args.transaction.setGasBudget(args.gasBudget);
  }

  args.transaction.setSenderIfNotSet(args.signer.toSuiAddress());

  if (args.dryRun) {
    // `simulateTransaction` (checks disabled) is the gRPC replacement for the
    // old `dryRunTransactionBlock`. The simulate result uses the same
    // `{ Transaction | FailedTransaction }` shape as an executed tx, so the same
    // `include` fields populate the adapted `SuiTxResponse` — request them all so
    // the operator's dry-run preview shows the object types, balance changes, and
    // events they'll see on the real tx, not just bare status + object ids.
    const sim = await args.client.simulateTransaction({
      transaction: args.transaction,
      checksEnabled: false,
      include: {
        effects: true,
        objectTypes: true,
        balanceChanges: true,
        events: true,
      },
    });
    const simOutput = toSuiTxResponse(sim);

    // A simulation can fail for the same reasons a real tx can — and for one
    // that only shows up here: package upgrade compatibility is enforced while
    // executing the `Upgrade` command, so an incompatible upgrade surfaces as
    // `PackageUpgradeError { IncompatibleUpgrade }` in the simulated effects.
    // Without this check the failure is merely *printed*, the process exits 0,
    // and a `--dry-run` that actually rejected the upgrade reads as a pass to
    // anyone skimming output or checking an exit code.
    if (simOutput.effects.status.status === "failure") {
      throw new TransactionError(simOutput.effects.status.error, simOutput);
    }

    return simOutput;
  }

  const res = await args.client.signAndExecuteTransaction({
    signer: args.signer,
    transaction: args.transaction,
    include: {
      effects: true,
      balanceChanges: true,
      events: true,
      objectTypes: true,
    },
  });
  const txOutput = toSuiTxResponse(res);
  await args.client.waitForTransaction({ digest: txOutput.digest });

  if (txOutput.effects.status.status === "failure") {
    throw new TransactionError(txOutput.effects.status.error, txOutput);
  }

  return txOutput;
}

/** Interactive Y/N gate. Auto-confirms when NODE_ENV === "TESTING". */
export async function waitForUserConfirmation(): Promise<boolean> {
  if (process.env.NODE_ENV === "TESTING") {
    return true;
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  let userResponse: boolean;
  while (true) {
    const response = (await rl.question("Are you sure? (Y/N): ")).toUpperCase();
    if (response != "Y" && response != "N") {
      continue;
    }
    userResponse = response === "Y";
    break;
  }
  rl.close();

  return userResponse;
}
