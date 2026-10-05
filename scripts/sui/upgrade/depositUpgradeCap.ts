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
 * Deposits a stateful package's UpgradeCap into its shared UpgradeService, so
 * future upgrades are gated by the service admin. Run once per package after
 * deployment.
 *
 *   yarn upgrade:deposit-cap \
 *     --package <message_transmitter_v2|token_messenger_minter_v2|stablecoin_handler|message_transmitter|token_messenger_minter> \
 *     [--dry-run]
 */

import { Command } from "commander";
import { SuiGrpcClient } from "@mysten/sui/grpc";
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

  const opts = program.opts();
  const target = loadUpgradeTarget(parsePackageKey(opts.package));
  const rpcUrl = opts.rpcUrl ?? loadRpcUrl();
  const client = new SuiGrpcClient({ network: "localnet", baseUrl: rpcUrl });
  const signer = loadSigner(opts.key);
  const gasBudget = opts.gasBudget ? BigInt(opts.gasBudget) : null;
  const dryRun: boolean = !!opts.dryRun;

  log(`Depositing UpgradeCap for ${target.key}`);
  log(`  UpgradeService: ${target.upgradeServiceId}`);
  log(`  UpgradeCap:     ${target.upgradeCapId}`);
  log(`  Signer:         ${signer.toSuiAddress()}`);
  log(`  RPC:            ${rpcUrl}${dryRun ? "  (dry-run)" : ""}`);

  const upgradeServiceClient = await UpgradeServiceClient.buildFromId(
    client,
    target.upgradeServiceId,
  );

  if (!dryRun) {
    log("Proceed with deposit?");
    if (!(await waitForUserConfirmation())) {
      log("Aborted.");
      return;
    }
  }

  const output = await upgradeServiceClient.depositUpgradeCap(
    signer,
    target.upgradeCapId,
    { gasBudget, dryRun },
  );
  log("Deposit transaction complete:");
  console.log(inspectObject(output));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
