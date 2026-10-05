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
 * Publishes an upgraded package version through its UpgradeService (admin-gated).
 *
 *   yarn upgrade:package \
 *     --package <message_transmitter_v2|token_messenger_minter_v2|stablecoin_handler|message_transmitter|token_messenger_minter> \
 *     ( --build-artifact-filepath <json> | --package-path <dir> ) [--dry-run]
 *
 * The build artifact is `{ modules, dependencies, digest }` as produced by
 * `sui move build --dump-bytecode-as-base64`. Provide it either as a pre-built
 * JSON file (--build-artifact-filepath, e.g. from a release branch) or let this
 * script build it inline from a package directory (--package-path). For the
 * frozen V1 toolchain, pass --sui-bin (or a pre-built artifact).
 */

import { Command } from "commander";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import UpgradeServiceClient from "./upgradeServiceClient";
import {
  BuildArtifact,
  buildArtifactFromPackage,
  readArtifactFile,
  pinnedSuiBin,
} from "./buildArtifact";
import { waitForUserConfirmation } from "./upgradeHelpers";
import {
  loadRpcUrl,
  loadSigner,
  loadUpgradeTarget,
  parsePackageKey,
  PACKAGE_KEYS,
} from "./upgradeConfig";
import { inspectObject, log } from "../helpers";

async function main() {
  const program = new Command();
  program
    .requiredOption(
      "--package <name>",
      `package to upgrade (full name or short alias): ${PACKAGE_KEYS.join(", ")}`,
    )
    .option(
      "--build-artifact-filepath <json>",
      "pre-built { modules, dependencies, digest } JSON",
    )
    .option(
      "--package-path <dir>",
      "package dir to build inline via the Sui CLI",
    )
    .option(
      "--sui-bin <path>",
      "sui binary for inline builds (default: the package's pinned toolchain)",
    )
    .option(
      "--pubfile-path <path>",
      "ephemeral pub file for dependency addresses (localnet only)",
    )
    .option(
      "--key <suiprivkey>",
      "admin private key (default: SUI_DEPLOYER_KEY)",
    )
    .option("--rpc-url <url>", "fullnode RPC url")
    .option("--gas-budget <mist>", "gas budget in MIST")
    .option("--dry-run", "simulate without submitting", false)
    .parse(process.argv);

  const opts = program.opts();

  if (!opts.buildArtifactFilepath && !opts.packagePath) {
    throw new Error(
      "Provide either --build-artifact-filepath or --package-path.",
    );
  }
  if (opts.buildArtifactFilepath && opts.packagePath) {
    throw new Error(
      "Provide only one of --build-artifact-filepath or --package-path.",
    );
  }

  const target = loadUpgradeTarget(parsePackageKey(opts.package));
  const rpcUrl = opts.rpcUrl ?? loadRpcUrl();
  const client = new SuiGrpcClient({ network: "localnet", baseUrl: rpcUrl });
  const signer = loadSigner(opts.key);
  const gasBudget = opts.gasBudget ? BigInt(opts.gasBudget) : null;
  const dryRun: boolean = !!opts.dryRun;

  const artifact: BuildArtifact = opts.buildArtifactFilepath
    ? readArtifactFile(opts.buildArtifactFilepath)
    : buildArtifactFromPackage(
        opts.packagePath,
        opts.suiBin ?? pinnedSuiBin(opts.packagePath),
        undefined,
        opts.pubfilePath,
      );

  const upgradeServiceClient = await UpgradeServiceClient.buildFromId(
    client,
    target.upgradeServiceId,
  );

  // Admin preflight: upgrade is admin-gated on-chain.
  const admin = await upgradeServiceClient.getAdmin();
  const signerAddress = signer.toSuiAddress();
  const latestPackageId = await upgradeServiceClient.getUpgradeCapPackageId();

  log(`Upgrading ${target.key}`);
  log(`  UpgradeService: ${target.upgradeServiceId}`);
  log(`  Latest package: ${latestPackageId}`);
  log(`  Admin:          ${admin}`);
  log(`  Signer:         ${signerAddress}${dryRun ? "  (dry-run)" : ""}`);
  log(`  Modules:        ${artifact.modules.length}`);

  if (admin !== signerAddress) {
    throw new Error(
      `Signer ${signerAddress} is not the UpgradeService admin ${admin}; upgrade is admin-gated.`,
    );
  }

  if (!dryRun) {
    log("Proceed with upgrade?");
    if (!(await waitForUserConfirmation())) {
      log("Aborted.");
      return;
    }
  }

  const output = await upgradeServiceClient.upgrade(
    signer,
    latestPackageId,
    artifact.modules,
    artifact.dependencies,
    artifact.digest,
    { gasBudget, dryRun },
  );

  if (!dryRun) {
    // Read the new package id from the UpgradeCap (via the on-chain view),
    // the same gRPC-proven path used to read `latestPackageId` above. The
    // published-package object-change is not surfaced by the gRPC client's
    // response the way the old JSON-RPC `objectChanges` were.
    const newPackageId = await upgradeServiceClient.getUpgradeCapPackageId();
    log(`Upgrade complete. New package id: ${newPackageId}`);
  }
  console.log(inspectObject(output));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
