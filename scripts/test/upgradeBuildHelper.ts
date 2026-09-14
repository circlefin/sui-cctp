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
 * Test-only helper: builds a "uv2" (VERSION bumped 1 -> 2) upgrade artifact for a
 * deployed V2 package, at test time, so the upgrade/migration e2e can exercise a
 * real on-chain upgrade. (Only V2 is upgradable — V1 is frozen and superseded by
 * V2 rather than upgraded, so it has no upgrade e2e.)
 *
 * Configures the localnet manifests (self = 0x0, which tx.upgrade requires),
 * patches VERSION, and dumps the bytecode with the current toolchain, resolving
 * the localnet-published deps via the deploy's ephemeral pub file.
 * `revertUpgradeBuild()` undoes every mutation and MUST run in a finally.
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "node:url";
import { PackageKey } from "../sui/upgrade/upgradeConfig";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.join(__dirname, "../..");

export interface BuildArtifact {
  modules: string[];
  dependencies: string[];
  digest: number[];
}

interface BuildConfig {
  /** repo-relative package dir */
  packagePath: string;
  /** repo-relative version_control.move to patch */
  versionFile: string;
}

// Only the representative package the e2e drives is configured.
const CONFIGS: Partial<Record<PackageKey, BuildConfig>> = {
  message_transmitter_v2: {
    packagePath: "packages/message_transmitter_v2",
    versionFile:
      "packages/message_transmitter_v2/sources/admin/version_control.move",
  },
};

/** Resolves the package's pinned sui binary (versions.sh), falling back to PATH. */
function pinnedSuiBin(repoRelPkg: string): string {
  const version = execSync(
    `bash -c 'source versions.sh && sui_version_for "${repoRelPkg}"'`,
    { cwd: REPO_ROOT, encoding: "utf-8" },
  ).trim();
  const bin = path.join(REPO_ROOT, "bin", version, "sui");
  return fs.existsSync(bin) ? bin : "sui";
}

// Sui mainnet chain-id. `move build -e mainnet --pubfile-path` requires the pub
// file's chain-id to equal the build-env's chain-id, so the localnet ephemeral
// pub file is relabeled to this before it's consumed (see prepUpgradePubfile).
const MAINNET_CHAIN_ID = "35834a8a";

/**
 * Produces a build-env-compatible copy of the deploy's ephemeral pub file for the
 * current-toolchain upgrade build. The deploy publishes localnet packages via
 * `test-publish`, recording their addresses in `scripts/Pub.local.toml`. `move
 * build -e mainnet --pubfile-path` needs that pub file's chain-id to match
 * mainnet's, so we relabel a copy (the recorded ephemeral dep addresses are what
 * matter, not the chain-id label). Returns the repo-relative relabeled path.
 */
function prepUpgradePubfile(): string {
  const srcPath = path.join(REPO_ROOT, "scripts", "Pub.local.toml");
  if (!fs.existsSync(srcPath)) {
    throw new Error(
      `Ephemeral pub file ${srcPath} not found — deploy the packages first.`,
    );
  }
  const relabeled = fs
    .readFileSync(srcPath, "utf-8")
    .replace(/chain-id = "[0-9a-f]+"/g, `chain-id = "${MAINNET_CHAIN_ID}"`);
  const dstPath = path.join(REPO_ROOT, "scripts", "Pub.upgrade.toml");
  fs.writeFileSync(dstPath, relabeled);
  return dstPath;
}

/**
 * Builds the uv2 upgrade artifact for `key`. Mutates manifests/locks/version file
 * — always pair with revertUpgradeBuild() in a finally.
 */
export function buildUpgradeArtifact(key: PackageKey): BuildArtifact {
  const cfg = CONFIGS[key];
  if (!cfg) {
    throw new Error(`No upgrade-build config for package '${key}'`);
  }

  const suiBin = pinnedSuiBin(cfg.packagePath);

  // The V2 `Move.toml` already keeps the package's own address at 0x0, so the
  // built modules are 0x0-self, which tx.upgrade requires (a non-zero self aborts
  // PublishErrorNonZeroAddress).

  // uv1 -> uv2.
  const versionAbs = path.join(REPO_ROOT, cfg.versionFile);
  const src = fs.readFileSync(versionAbs, "utf-8");
  fs.writeFileSync(
    versionAbs,
    src.replace("const VERSION: u64 = 1;", "const VERSION: u64 = 2;"),
  );

  // The deps are published on localnet via `test-publish`, recorded in the
  // ephemeral pub file. `move build` resolves them with `--pubfile-path`, but
  // requires the pub file's chain-id to equal the `-e` env's — so we build against
  // a mainnet-relabeled copy of the pub file (only the recorded ephemeral dep
  // addresses matter).
  const depFlags = `-e mainnet --pubfile-path ${prepUpgradePubfile()}`;

  const stdout = execSync(
    `${suiBin} move build --dump-bytecode-as-base64 --path ${cfg.packagePath} ${depFlags}`,
    { cwd: REPO_ROOT, encoding: "utf-8" },
  );
  const jsonStart = stdout.indexOf("{");
  if (jsonStart < 0) {
    throw new Error(`No build artifact JSON in output:\n${stdout}`);
  }
  return JSON.parse(stdout.slice(jsonStart));
}

/** Reverts all mutations from buildUpgradeArtifact (safe to call unconditionally). */
export function revertUpgradeBuild(): void {
  // Revert version_control.move patches.
  const versionFiles = Object.values(CONFIGS).map((c) => c!.versionFile);
  execSync(`git checkout -- ${versionFiles.join(" ")}`, { cwd: REPO_ROOT });
  // Revert Move.toml / Move.lock churn + submodule lock edits.
  execSync("bash run.sh restore_manifests", { cwd: REPO_ROOT });
}
