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
 * Upgrades a deployed package to the working tree's code and migrates its State,
 * in one preflighted run.
 *
 *   yarn upgrade:v2 --package tmm \
 *     --package-path packages/token_messenger_minter_v2 \
 *     --config deploy.<name>.out.env [--dry-run]
 *
 * ## What it does
 *
 * Preflight (all read-only, before anything irreversible) -> build the artifact
 * from the working tree -> publish the upgrade through the UpgradeService ->
 * `start_migration` -> `complete_migration`.
 *
 * ## What it deliberately does NOT do
 *
 * - **It never edits source.** Migrating requires the target package to report a
 *   higher `VERSION` than the State's active one, but that bump is applied by the
 *   operator and reverted afterwards, because the same tree gets deployed fresh
 *   elsewhere at `VERSION = 1`. A tool that edits and reverts source
 *   can leave a dirty tree if it dies mid-run, and obscures what is being
 *   deployed. Preflight verifies the bump is present; it does not make it.
 *
 * - **It does not resume.** If a run dies partway, recovery is by composition
 *   with the per-step CLIs (`upgrade:deposit-cap`, `upgrade:package`,
 *   `upgrade:migrate <start|abort|complete>`), which already handle every
 *   intermediate state. This command detects the phase and refuses with the
 *   specific command to run, rather than guessing what you meant. Each refusal
 *   message names the exact next step.
 *
 * `cctp_extensions` cannot be targeted here: it is a pure library published with
 * no UpgradeService and no State, so it has neither an upgrade path through this
 * tooling nor anything to migrate.
 */

import fs from "fs";
import path from "path";
import dotenv from "dotenv";
import { Command } from "commander";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import UpgradeServiceClient from "./upgradeServiceClient";
import MigrationClient from "./migrationClient";
import {
  buildArtifactFromPackage,
  pinnedSuiBin,
  repoRoot,
} from "./buildArtifact";
import { waitForUserConfirmation } from "./upgradeHelpers";
import {
  isV2PackageKey,
  loadRpcUrl,
  loadSigner,
  loadUpgradeTarget,
  parsePackageKey,
  V2_PACKAGE_KEYS,
} from "./upgradeConfig";
import { inspectObject, log } from "../helpers";

const NETWORKS = ["localnet", "devnet", "testnet", "mainnet"] as const;
type Network = (typeof NETWORKS)[number];

function parseNetwork(value: string): Network {
  if (!(NETWORKS as readonly string[]).includes(value)) {
    throw new Error(
      `Invalid --network '${value}'. Expected one of: ${NETWORKS.join(", ")}.`,
    );
  }
  return value as Network;
}

/** Reads `State.compatible_versions`, ascending. */
async function readCompatibleVersions(
  client: SuiGrpcClient,
  stateId: string,
): Promise<number[]> {
  const obj = await client.core.getObject({
    objectId: stateId,
    include: { json: true },
  });
  const json = obj.object?.json as
    | { compatible_versions?: { contents?: string[] } | string[] }
    | undefined;
  const cv = json?.compatible_versions;
  const contents = Array.isArray(cv) ? cv : (cv?.contents ?? []);
  return contents.map((v) => Number(v)).sort((a, b) => a - b);
}

/**
 * The `VERSION` the working tree declares for this package, or null if the
 * package has no `version_control.move` (in which case there is nothing to
 * migrate). All five packages reachable via `--package` currently have one.
 */
function readSourceVersion(packagePath: string): number | null {
  const versionFile = path.join(
    packagePath,
    "sources",
    "admin",
    "version_control.move",
  );
  if (!fs.existsSync(versionFile)) return null;
  const match = fs
    .readFileSync(versionFile, "utf-8")
    .match(/const\s+VERSION\s*:\s*u64\s*=\s*(\d+)\s*;/);
  if (!match) {
    throw new Error(`Could not parse a VERSION constant from ${versionFile}.`);
  }
  return Number(match[1]);
}

/**
 * `original-id` recorded for `env` in a package's `Published.toml`, if any.
 *
 * Deliberately `original-id` and not `published-at`. Upgrades performed through
 * the `UpgradeService` PTB never write back to `Published.toml` (only
 * `sui client upgrade` does), so `published-at` stays pinned to the first
 * publish while the on-chain package id advances with every upgrade. Comparing
 * those two would therefore report a mismatch on any deployment that has been
 * upgraded once — blocking exactly the legitimate case this tooling exists for.
 * `original-id` is stable across upgrades and identifies the deployment.
 */
function readOriginalId(tomlPath: string, env: string): string | null {
  if (!fs.existsSync(tomlPath)) return null;
  const section = fs
    .readFileSync(tomlPath, "utf-8")
    .split(`[published.${env}]`)[1];
  if (!section) return null;
  return (
    section.match(/^\s*original-id\s*=\s*"(0x[0-9a-fA-F]+)"/m)?.[1] ?? null
  );
}

async function main() {
  const program = new Command();
  program
    .requiredOption(
      "--package <name>",
      `V2 package to upgrade and migrate (full name or alias): ${V2_PACKAGE_KEYS.join(", ")}`,
    )
    .requiredOption(
      "--package-path <dir>",
      "package dir to build the upgrade from (repo-relative)",
    )
    .option(
      "--config <path>",
      "dotenv deployment record holding the target's object ids",
    )
    .option(
      "--network <name>",
      `target network: ${NETWORKS.join("|")} (default: SUI_NETWORK, else localnet)`,
    )
    .option("--rpc-url <url>", "fullnode RPC url")
    .option(
      "--published-toml <path>",
      "Published.toml to verify the target against (default: <package-path>/Published.toml)",
    )
    .option(
      "--sui-bin <path>",
      "sui binary for the build (default: the package's pinned toolchain)",
    )
    .option(
      "--pubfile-path <path>",
      "ephemeral pub file for dependency addresses (localnet only)",
    )
    .option(
      "--key <suiprivkey>",
      "signer private key (default: SUI_DEPLOYER_KEY)",
    )
    .option("--gas-budget <mist>", "gas budget in MIST")
    .option("--dry-run", "simulate the upgrade without submitting", false)
    .parse(process.argv);

  const opts = program.opts();
  const dryRun: boolean = !!opts.dryRun;

  // Load the deployment record before resolving anything from env. On a real
  // network the object ids live in the record written by the deploy, not in
  // test_config.v2.env which the localnet-oriented `upgrade:*` targets assume.
  if (opts.config) {
    const configPath = path.resolve(opts.config);
    if (!fs.existsSync(configPath)) {
      throw new Error(`--config file not found: ${configPath}`);
    }
    dotenv.config({ path: configPath, override: true });
    log(`Loaded deployment record ${opts.config}`);
  }

  const network: Network = parseNetwork(
    opts.network ?? process.env.SUI_NETWORK ?? "localnet",
  );
  const rpcUrl = opts.rpcUrl ?? loadRpcUrl();
  const client = new SuiGrpcClient({ network, baseUrl: rpcUrl });
  const signer = loadSigner(opts.key);
  const signerAddress = signer.toSuiAddress();
  const gasBudget = opts.gasBudget ? BigInt(opts.gasBudget) : null;

  const packageKey = parsePackageKey(opts.package);
  // V2-only, as the command name says. The frozen V1 toolchain (1.37.3) rejects
  // the `-e <env>` flag this passes for a real-network build, and V1 resolves
  // published addresses through `Move.toml` rather than the `Published.toml`
  // that the build and the --published-toml preflight both read. Refuse up front
  // rather than fail later inside the Sui CLI with an opaque flag error.
  if (!isV2PackageKey(packageKey)) {
    throw new Error(
      `'${packageKey}' is a V1 package; this command is V2-only (${V2_PACKAGE_KEYS.join(", ")}).\n` +
        `V1 builds with the frozen 1.37.3 toolchain, which predates the build-env ` +
        `flag used here, and records its published address in Move.toml rather ` +
        `than Published.toml.\n` +
        `Use the per-step commands instead: yarn upgrade:deposit-cap, ` +
        `yarn upgrade:package, yarn upgrade:migrate.`,
    );
  }

  const target = loadUpgradeTarget(packageKey);
  const packagePath = path.resolve(repoRoot(), opts.packagePath);
  if (!fs.existsSync(packagePath)) {
    throw new Error(`--package-path does not exist: ${packagePath}`);
  }

  log(`Upgrade + migrate ${target.key} on ${network}`);
  log(`  Source:   ${packagePath}`);
  log(`  State:    ${target.stateId}`);
  log(`  Signer:   ${signerAddress}${dryRun ? "   (dry-run)" : ""}`);
  log(`  RPC:      ${rpcUrl}`);

  // ---- Preflight. Everything here is read-only. --------------------------

  const usClient = await UpgradeServiceClient.buildFromId(
    client,
    target.upgradeServiceId,
  );

  // The UpgradeCap must already be deposited: the package id we upgrade from is
  // read off the cap, and authorize_upgrade needs it held by the service.
  let latestPackageId: string;
  try {
    latestPackageId = await usClient.getUpgradeCapPackageId();
  } catch (err) {
    throw new Error(
      `Could not read the UpgradeCap from UpgradeService ${target.upgradeServiceId}. ` +
        `It is most likely not deposited yet — run:\n` +
        `  yarn upgrade:deposit-cap --package ${target.key}\n` +
        `Underlying error: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  log(`  Package:  ${latestPackageId}`);

  const admin = await usClient.getAdmin();
  if (admin !== signerAddress) {
    throw new Error(
      `Signer is not the UpgradeService admin.\n` +
        `  role:     UpgradeService admin (required to publish the upgrade)\n` +
        `  expected: ${admin}\n` +
        `  signer:   ${signerAddress}\n` +
        `Pass the admin key with --key, or use an account that holds the role.`,
    );
  }

  // Checked up front even though it is only needed after the upgrade: finding
  // out the signer cannot migrate *after* publishing leaves the deployment
  // upgraded but unmigrated, which is the state we least want to be in.
  const migrationOwnerProbe = new MigrationClient(
    client,
    latestPackageId,
    target.stateId,
  );
  const owner = await migrationOwnerProbe.getOwner();
  if (owner !== signerAddress) {
    throw new Error(
      `Signer is not the State owner.\n` +
        `  role:     State owner (required for start/complete migration)\n` +
        `  expected: ${owner}\n` +
        `  signer:   ${signerAddress}\n` +
        `The upgrade would succeed and the migration would then abort, leaving the ` +
        `package upgraded but the State on the old version. Refusing up front.`,
    );
  }

  // Guard against a stale local publish record naming a different deployment.
  // Published.toml is gitignored, so whatever sits in the tree is whoever last
  // deployed from it — on a shared chain-id that may not be this deployment.
  if (network !== "localnet") {
    const tomlPath = opts.publishedToml
      ? path.resolve(opts.publishedToml)
      : path.join(packagePath, "Published.toml");
    const originalId = readOriginalId(tomlPath, network);
    if (originalId && originalId !== target.packageId) {
      throw new Error(
        `Publish record does not match the deployment being upgraded.\n` +
          `  file:        ${tomlPath}\n` +
          `  original-id: ${originalId}\n` +
          `  deployment:  ${target.packageId}\n` +
          `These files are untracked, so this usually means the tree holds a record ` +
          `from a different deployment on the same chain. Copy the right record in, ` +
          `or point at it with --published-toml.`,
      );
    }
  }

  const sourceVersion = readSourceVersion(packagePath);
  const compatibleVersions = await readCompatibleVersions(
    client,
    target.stateId,
  );
  log(
    `  Versions: state=${JSON.stringify(compatibleVersions)} source=${sourceVersion}`,
  );

  if (sourceVersion === null) {
    throw new Error(
      `${packagePath} has no sources/admin/version_control.move, so it has no ` +
        `migration to perform. Use 'yarn upgrade:package' to upgrade it instead.`,
    );
  }

  // Phase detection: report and refuse, never resume. The per-step CLIs already
  // cover every intermediate state; guessing here risks skipping an upgrade the
  // operator wanted or repeating one they did not.
  if (compatibleVersions.length === 2) {
    throw new Error(
      `A migration is already in progress: compatible_versions = ` +
        `${JSON.stringify(compatibleVersions)}.\n` +
        `This command does not resume. Finish or unwind it with:\n` +
        `  yarn upgrade:migrate complete --package ${target.key}\n` +
        `  yarn upgrade:migrate abort    --package ${target.key}`,
    );
  }
  if (compatibleVersions.length !== 1) {
    throw new Error(
      `Unexpected compatible_versions ${JSON.stringify(compatibleVersions)} on ` +
        `State ${target.stateId}; expected exactly one version. Inspect the State ` +
        `before proceeding.`,
    );
  }

  const activeVersion = compatibleVersions[0];
  if (sourceVersion <= activeVersion) {
    throw new Error(
      `Nothing to migrate to: the State is on version ${activeVersion} and the ` +
        `source declares VERSION ${sourceVersion}.\n` +
        `Either the migration has already completed, or the temporary VERSION bump ` +
        `has not been applied. start_migration requires ` +
        `active_version < current_version(), so it would abort EObjectMigrated.\n` +
        `  bump: ${path.join(opts.packagePath, "sources/admin/version_control.move")}\n` +
        `Remember the bump is intentionally uncommitted — revert it after the run.`,
    );
  }

  // ---- Build. Reflects the working tree exactly, bump included. ----------

  // The build env selects which [published.<env>] block each dependency resolves
  // through, and those addresses are baked into the bytecode. A real-network
  // upgrade must build for that network; localnet keeps the pinned default.
  const buildEnv = network === "localnet" ? undefined : network;
  log(`Building upgrade artifact${buildEnv ? ` for -e ${buildEnv}` : ""}...`);
  const suiBin = opts.suiBin ?? pinnedSuiBin(packagePath);
  const artifact = buildArtifactFromPackage(
    packagePath,
    suiBin,
    buildEnv,
    opts.pubfilePath,
  );
  log(
    `  modules=${artifact.modules.length} deps=${artifact.dependencies.length}`,
  );

  if (!dryRun) {
    log(
      `Proceed: upgrade ${target.key} ${activeVersion} -> ${sourceVersion} and migrate?`,
    );
    if (!(await waitForUserConfirmation())) {
      log("Aborted.");
      return;
    }
  }

  // ---- Upgrade. ----------------------------------------------------------

  const upgradeOutput = await usClient.upgrade(
    signer,
    latestPackageId,
    artifact.modules,
    artifact.dependencies,
    artifact.digest,
    { gasBudget, dryRun },
  );

  if (dryRun) {
    // Simulation runs the on-chain compatibility check, so reaching this point
    // means the upgrade is compatible. (executeTransactionHelper throws on a
    // failed simulation, so a rejected upgrade never gets here.)
    log(`Dry run OK — upgrade simulated successfully and is compatible.`);
    log(
      `Migration not simulated: it targets the post-upgrade package, which does ` +
        `not exist until the upgrade is actually committed.`,
    );
    console.log(inspectObject(upgradeOutput));
    return;
  }

  const newPackageId = await usClient.getUpgradeCapPackageId();
  if (newPackageId === latestPackageId) {
    throw new Error(
      `Upgrade did not produce a new package id (still ${newPackageId}). ` +
        `Refusing to migrate against an unchanged package.`,
    );
  }
  log(`Upgraded: ${latestPackageId} -> ${newPackageId}`);

  // ---- Migrate. Targets the NEW package; the old one aborts EObjectMigrated.

  const migrationClient = new MigrationClient(
    client,
    newPackageId,
    target.stateId,
  );

  await migrationClient.migrate("start", signer, { gasBudget, dryRun: false });
  log(
    `start_migration:    ${JSON.stringify(await readCompatibleVersions(client, target.stateId))}`,
  );

  await migrationClient.migrate("complete", signer, {
    gasBudget,
    dryRun: false,
  });
  const finalVersions = await readCompatibleVersions(client, target.stateId);
  log(`complete_migration: ${JSON.stringify(finalVersions)}`);

  if (finalVersions.length !== 1 || finalVersions[0] !== sourceVersion) {
    throw new Error(
      `Migration finished in an unexpected state: expected [${sourceVersion}], ` +
        `got ${JSON.stringify(finalVersions)}.`,
    );
  }

  log(
    `Done. ${target.key} is upgraded to ${newPackageId} and on version ${sourceVersion}.`,
  );
  log(`Remember to revert the temporary VERSION bump before committing.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
