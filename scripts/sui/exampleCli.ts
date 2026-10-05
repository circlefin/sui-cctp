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
 * Module: exampleCli
 *
 * Helpers shared by the two V2 example scripts. Kept out of
 * `helpers.ts` because the test suites depend on that file and this is
 * example-script-only surface.
 */

import { Network } from "./network";

/**
 * Signing key: `--key` > `SUI_SIGNER_KEY` > `SUI_DEPLOYER_KEY`.
 *
 * The `SUI_DEPLOYER_KEY` fallback is what keeps the localnet flow working
 * unchanged: `deploy.ts` is frozen and writes only that key into
 * `test_config.v2.env`. On a public network the caller is not the deployer, so
 * `SUI_SIGNER_KEY` is the one to set; deploy/migrate continue to read only
 * `SUI_DEPLOYER_KEY`, keeping the two roles distinct in those paths.
 */
export function resolveSigner(keyFlag?: string): string {
  const accounts = {
    signer: process.env.SUI_SIGNER_KEY,
    deployer: process.env.SUI_DEPLOYER_KEY,
  };
  const signingAccount = accounts.signer ? accounts.signer : accounts.deployer;
  const key = keyFlag ? keyFlag : signingAccount;
  if (!key) {
    throw new Error(
      "No signing key. Provide one of: --key <suiprivkey>, SUI_SIGNER_KEY, " +
        "or SUI_DEPLOYER_KEY (in the --config record or the environment).",
    );
  }
  return key;
}

/**
 * Default attestation-service hosts. The network does not fully determine the
 * host: separate deployments can share a network, each with its own attester
 * and its own api, so a run may need `--iris-host` to point at the one that
 * indexes the burn it is following.
 */
const IRIS_HOSTS: Record<Exclude<Network, "localnet">, string> = {
  testnet: "https://iris-api-sandbox.circle.com",
  mainnet: "https://iris-api.circle.com",
};

/**
 * Iris url for the message(s) emitted by a burn transaction. Poll until
 * `status` is `complete` and `attestation` is no longer the literal `PENDING`.
 */
export function irisMessagesUrl(
  network: Exclude<Network, "localnet">,
  sourceDomain: number,
  txHash: string,
  hostOverride?: string,
): string {
  // `txHash` is passed through verbatim. Do NOT normalise it to an 0x-prefixed
  // hex string: a Sui transaction digest is base58, and prefixing it produces a
  // url that looks plausible and matches nothing.
  const host = hostOverride ?? IRIS_HOSTS[network];
  return `${host}/v2/messages/${sourceDomain}?transactionHash=${txHash}`;
}

/**
 * Source domain of a serialized CCTP V2 message: the second big-endian u32, at
 * bytes 4..8 (the first is `version`). See `serializeMessageV2` in messageV2.ts.
 * Read from the message rather than assumed, since the local domain is a
 * deploy-time value that differs per deployment.
 */
export function sourceDomainOf(message: Uint8Array): number {
  if (message.length < 8) {
    throw new Error(
      `Message too short to contain a source domain: ${message.length} bytes.`,
    );
  }
  return new DataView(
    message.buffer,
    message.byteOffset,
    message.byteLength,
  ).getUint32(4, false /* big-endian */);
}

/**
 * Decode an 0x-prefixed hex flag.
 *
 * Rejects the two sentinel values the Iris API returns when an attestation is
 * not yet available, by name: `attestation` comes back as the literal string
 * `PENDING`, and `message` as a bare `0x`. A caller copying out of the JSON
 * response will hit these, and without this the failure surfaces much later as
 * an opaque on-chain signature error.
 */
export function parseHexFlag(value: string, flag: string): Uint8Array {
  if (value.trim().toUpperCase() === "PENDING") {
    throw new Error(
      `${flag} is "PENDING" — Circle's attestation service has not signed this ` +
        "message yet. Re-poll until the response's `status` is `complete`.",
    );
  }
  const body =
    value.startsWith("0x") || value.startsWith("0X") ? value.slice(2) : value;
  if (body.length === 0) {
    throw new Error(
      `${flag} is empty ("0x") — Iris returns this when the attestation is not ` +
        "yet available. Re-poll until the response's `status` is `complete`.",
    );
  }
  if (body.length % 2 !== 0) {
    throw new Error(`${flag} has an odd number of hex digits: ${body.length}.`);
  }
  if (!/^[0-9a-fA-F]+$/.test(body)) {
    throw new Error(`${flag} is not valid hex.`);
  }
  return Uint8Array.from(Buffer.from(body, "hex"));
}

/**
 * Decode a non-negative integer flag. Without this a typo'd numeric flag
 * becomes `NaN` and surfaces much later as an opaque
 * "The number NaN cannot be converted to a BigInt".
 */
export function parseIntegerFlag(value: string, flag: string): number {
  const trimmed = value.trim();
  if (!/^\d+$/.test(trimmed)) {
    throw new Error(`${flag} must be a non-negative integer (got "${value}").`);
  }
  return Number(trimmed);
}

/** As `parseIntegerFlag`, for values that exceed Number.MAX_SAFE_INTEGER. */
export function parseBigIntFlag(value: string, flag: string): bigint {
  const trimmed = value.trim();
  if (!/^\d+$/.test(trimmed)) {
    throw new Error(`${flag} must be a non-negative integer (got "${value}").`);
  }
  return BigInt(trimmed);
}
