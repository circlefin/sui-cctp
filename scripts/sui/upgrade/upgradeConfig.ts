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
 * Shared config for the upgrade/migration tooling. Resolves the object ids for a
 * given `--package` selection from the dotenv deployment manifest
 * (test_config.{v1,v2}.env), plus the signer and RPC url. Covers all
 * five stateful CCTP packages (three V2 + two V1).
 */

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getEd25519KeypairFromPrivateKey } from "../helpers";

/**
 * Canonical `--package` values: the full package (folder) names under /packages.
 * Short aliases (see ALIASES) are also accepted and normalized to these.
 */
export type PackageKey =
  | "message_transmitter"
  | "token_messenger_minter"
  | "message_transmitter_v2"
  | "token_messenger_minter_v2"
  | "stablecoin_handler";

export const PACKAGE_KEYS: readonly PackageKey[] = [
  "message_transmitter_v2",
  "token_messenger_minter_v2",
  "stablecoin_handler",
  "message_transmitter",
  "token_messenger_minter",
];

/**
 * The V2 subset. The frozen V1 packages build with the 1.37.3 toolchain, which
 * predates both the `-e <env>` build-environment flag and `--pubfile-path`, and
 * they resolve published addresses through `Move.toml` rather than
 * `Published.toml`. Tooling that depends on either mechanism is V2-only and
 * should validate against this list rather than `PACKAGE_KEYS`.
 */
export const V2_PACKAGE_KEYS: readonly PackageKey[] = [
  "message_transmitter_v2",
  "token_messenger_minter_v2",
  "stablecoin_handler",
];

export function isV2PackageKey(key: PackageKey): boolean {
  return V2_PACKAGE_KEYS.includes(key);
}

/**
 * Short aliases accepted by `--package`, normalized to the canonical name.
 *
 * V2 only, deliberately. The V1 packages remain addressable by their full
 * names, but are frozen, superseded by V2 and scheduled for retirement, so
 * there is no reason to offer shorthand that makes reaching for them easier.
 *
 * Note an unsuffixed alias means V2 (`tmm`), which is the inverse of the
 * package names, where an unsuffixed name means V1
 * (`token_messenger_minter`). Prefer full names wherever the target matters.
 */
const ALIASES: Record<string, PackageKey> = {
  mt: "message_transmitter_v2",
  tmm: "token_messenger_minter_v2",
  handler: "stablecoin_handler",
};

/** Manifest env-key prefix for each package. */
const ENV_PREFIX: Record<PackageKey, string> = {
  message_transmitter_v2: "SUI_MESSAGE_TRANSMITTER_V2",
  token_messenger_minter_v2: "SUI_TOKEN_MESSENGER_MINTER_V2",
  stablecoin_handler: "SUI_STABLECOIN_HANDLER",
  message_transmitter: "SUI_MESSAGE_TRANSMITTER",
  token_messenger_minter: "SUI_TOKEN_MESSENGER_MINTER",
};

export interface UpgradeTarget {
  key: PackageKey;
  packageId: string;
  stateId: string;
  upgradeServiceId: string;
  upgradeCapId: string;
}

export function isPackageKey(value: string): value is PackageKey {
  return (PACKAGE_KEYS as readonly string[]).includes(value);
}

/** Accepts a full package name or a short alias; returns the canonical name. */
export function parsePackageKey(value: string): PackageKey {
  if (isPackageKey(value)) return value;
  const aliased = ALIASES[value];
  if (aliased) return aliased;
  throw new Error(
    `Invalid --package '${value}'. Expected a package name ` +
      `(${PACKAGE_KEYS.join(", ")}) or an alias (${Object.keys(ALIASES).join(", ")}).`,
  );
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `Missing required env var '${name}'. Ensure the deployment manifest ` +
        `(test_config.{v1,v2}.env) is loaded via 'dotenv/config'.`,
    );
  }
  return value;
}

/** Resolves the object ids for a package from the loaded manifest. */
export function loadUpgradeTarget(key: PackageKey): UpgradeTarget {
  const prefix = ENV_PREFIX[key];
  return {
    key,
    packageId: requireEnv(`${prefix}_ID`),
    stateId: requireEnv(`${prefix}_STATE_ID`),
    upgradeServiceId: requireEnv(`${prefix}_UPGRADE_SERVICE_ID`),
    upgradeCapId: requireEnv(`${prefix}_UPGRADE_CAP_ID`),
  };
}

/** Fullnode RPC url — SUI_RPC_URL, else the local node on FULLNODE_PORT. */
export function loadRpcUrl(): string {
  return (
    process.env.SUI_RPC_URL ??
    `http://localhost:${process.env.FULLNODE_PORT ?? 9001}`
  );
}

/**
 * Signer for a tx. Defaults to the deployer key (owner/admin at init); pass an
 * override for cases where the owner/admin role has been transferred.
 */
export function loadSigner(privateKeyOverride?: string): Ed25519Keypair {
  return getEd25519KeypairFromPrivateKey(
    privateKeyOverride ?? requireEnv("SUI_DEPLOYER_KEY"),
  );
}
