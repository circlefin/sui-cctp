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
 * Drives a package's state migration after an upgrade. Owner-gated.
 *
 *   yarn upgrade:migrate <start|abort|complete> \
 *     --package <message_transmitter_v2|token_messenger_minter_v2|stablecoin_handler|message_transmitter|token_messenger_minter> \
 *     [--dry-run]
 *
 * Sequence for a version bump: start -> (verify) -> complete. `abort` reverts a
 * pending migration started but not yet completed.
 */

import { Command } from "commander";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import MigrationClient, {
  isMigrationAction,
  MIGRATION_ACTIONS,
} from "./migrationClient";
import UpgradeServiceClient from "./upgradeServiceClient";
import {
  loadRpcUrl,
  loadSigner,
  loadUpgradeTarget,
  parsePackageKey,
  PACKAGE_KEYS,
} from "./upgradeConfig";
import { waitForUserConfirmation } from "./upgradeHelpers";
import { inspectObject, log } from "../helpers";

async function main() {
  const program = new Command();
  program
    .argument("<action>", `migration action: ${MIGRATION_ACTIONS.join("|")}`)
    .requiredOption(
      "--package <name>",
      `package to operate on (full name or short alias): ${PACKAGE_KEYS.join(", ")}`,
    )
    .option(
      "--key <suiprivkey>",
      "signer private key (default: SUI_DEPLOYER_KEY)",
    )
    .option("--rpc-url <url>", "fullnode RPC url")
    .option("--gas-budget <mist>", "gas budget in MIST")
    .option("--dry-run", "simulate without submitting", false)
    .parse(process.argv);

  const action = program.args[0];
  if (!isMigrationAction(action)) {
    throw new Error(
      `Invalid action '${action}'. Expected one of: ${MIGRATION_ACTIONS.join(", ")}`,
    );
  }

  const opts = program.opts();
  const target = loadUpgradeTarget(parsePackageKey(opts.package));
  const rpcUrl = opts.rpcUrl ?? loadRpcUrl();
  const client = new SuiGrpcClient({ network: "localnet", baseUrl: rpcUrl });
  const signer = loadSigner(opts.key);
  const gasBudget = opts.gasBudget ? BigInt(opts.gasBudget) : null;
  const dryRun: boolean = !!opts.dryRun;

  // Migration must target the LATEST (post-upgrade) package version, where
  // current_version() equals the new VERSION. Resolve it from the UpgradeService
  // cap rather than the original deployed id from the manifest — calling
  // migration on the old version aborts EObjectMigrated. This requires the cap
  // to be deposited, which is always true once an upgrade has happened.
  const upgradeServiceClient = await UpgradeServiceClient.buildFromId(
    client,
    target.upgradeServiceId,
  );
  const packageId = await upgradeServiceClient.getUpgradeCapPackageId();
  const migrationClient = new MigrationClient(
    client,
    packageId,
    target.stateId,
  );

  // Owner preflight: migration is owner-gated on-chain; fail early with a clear
  // message rather than a raw Move abort if the signer isn't the owner.
  const owner = await migrationClient.getOwner();
  const signerAddress = signer.toSuiAddress();

  log(`Migration '${action}' for ${target.key}`);
  log(`  Package (latest): ${packageId}`);
  log(`  State:  ${target.stateId}`);
  log(`  Owner:  ${owner}`);
  log(`  Signer: ${signerAddress}${dryRun ? "  (dry-run)" : ""}`);

  if (owner !== signerAddress) {
    throw new Error(
      `Signer ${signerAddress} is not the State owner ${owner}; migration is owner-gated.`,
    );
  }

  if (!dryRun) {
    log(`Proceed with '${action}' migration?`);
    if (!(await waitForUserConfirmation())) {
      log("Aborted.");
      return;
    }
  }

  const output = await migrationClient.migrate(action, signer, {
    gasBudget,
    dryRun,
  });
  log(`Migration '${action}' transaction complete:`);
  console.log(inspectObject(output));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
