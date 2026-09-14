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
 * Builds the `{ modules, dependencies, digest }` artifact that `tx.upgrade`
 * consumes. Shared by `upgrade.ts` and `migrate.ts` so there is one definition
 * of how an upgrade artifact is produced.
 *
 * Nothing here mutates source. The artifact reflects the working tree exactly as
 * it stands — including, deliberately, an uncommitted `VERSION` bump that the
 * operator applied before running a migration.
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

// ESM has no `__dirname` global; derive it from this module's URL (same pattern
// as helpers.ts / deploy.ts) so the repo-relative package path resolves.
const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface BuildArtifact {
  modules: string[];
  dependencies: string[];
  digest: number[];
}

export function readArtifactFile(filepath: string): BuildArtifact {
  return JSON.parse(fs.readFileSync(filepath, "utf-8"));
}

/** Repo root, resolved from this module's location. */
export function repoRoot(): string {
  return path.join(__dirname, "../../..");
}

/**
 * The toolchain a package is pinned to (`versions.sh::sui_version_for`), falling
 * back to whatever `sui` is on PATH if that release is not installed.
 *
 * Worth resolving rather than defaulting to PATH: the flags differ between
 * releases — the frozen V1 toolchain predates `-e`, and a stale PATH `sui`
 * rejects it outright — so building with the wrong binary fails confusingly or,
 * worse, silently builds something different from what CI builds.
 */
export function pinnedSuiBin(packagePath: string): string {
  const root = repoRoot();
  const repoRelPkg = path.relative(root, path.resolve(packagePath));
  const version = execSync(
    `bash -c 'source versions.sh && sui_version_for "${repoRelPkg}"'`,
    { cwd: root, encoding: "utf-8" },
  ).trim();
  const bin = path.join(root, "bin", version, "sui");
  return fs.existsSync(bin) ? bin : "sui";
}

/**
 * The `-e <env>` args a package's pinned toolchain needs, from
 * `versions.sh::sui_build_env_args` (empty for the frozen V1 toolchain, which
 * predates the flag).
 */
function defaultBuildEnvArgs(packagePath: string): string {
  const root = repoRoot();
  const repoRelPkg = path.relative(root, path.resolve(packagePath));
  return execSync(
    `bash -c 'source versions.sh && sui_build_env_args "${repoRelPkg}"'`,
    { cwd: root, encoding: "utf-8" },
  ).trim();
}

/**
 * Builds `{ modules, dependencies, digest }` from a package dir via the Sui CLI.
 *
 * `buildEnv` matters more than it looks. The build env selects which
 * `[published.<env>]` block is read from each dependency's `Published.toml`, and
 * those addresses are baked into the emitted bytecode. Building for the wrong env
 * either fails outright ("unpublished dependencies") or links against a different
 * deployment — so a real-network upgrade must build for that network, not for
 * whatever `versions.sh` defaults to. Omit it to accept the pinned default, which
 * is what the localnet flow wants.
 */
export function buildArtifactFromPackage(
  packagePath: string,
  suiBin: string,
  buildEnv?: string,
  pubfilePath?: string,
): BuildArtifact {
  const buildEnvArgs = buildEnv
    ? `-e ${buildEnv}`
    : defaultBuildEnvArgs(packagePath);

  // `--pubfile-path` exists for localnet, where packages are published with
  // `client test-publish` and their addresses land in an ephemeral pub file
  // rather than in each dependency's `Published.toml`. Without it a localnet
  // upgrade build fails with "unpublished dependencies". A real network needs
  // nothing here: `client publish` writes the `Published.toml` the build reads.
  const pubfileArgs = pubfilePath ? ` --pubfile-path ${pubfilePath}` : "";

  const stdout = execSync(
    `${suiBin} move build --dump-bytecode-as-base64 --path ${packagePath} ${buildEnvArgs}${pubfileArgs}`,
    { encoding: "utf-8" },
  );
  // Build logs go to stderr; the JSON object is on stdout. Slice from the first
  // '{' to be resilient to any leading output.
  const jsonStart = stdout.indexOf("{");
  if (jsonStart < 0) {
    throw new Error(`No build artifact JSON in output:\n${stdout}`);
  }
  return JSON.parse(stdout.slice(jsonStart));
}
