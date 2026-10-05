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
 * Module: network
 *
 * Network resolution shared by the V2 example scripts.
 *
 * `deploy.ts` and `upgrade/migrate.ts` keep their own copies of this logic, so
 * this module is purely additive and does not touch either file. `migrate.ts`
 * could not be imported from in any case: it exports nothing and calls `main()`
 * at module scope, so importing it would run the migration CLI.
 */

/**
 * Networks the example scripts accept. Narrower than `migrate.ts`'s list, which
 * also carries `devnet`: CCTP is not deployed there, so an example run against
 * it could only fail later and more confusingly.
 */
export const NETWORKS = ["localnet", "testnet", "mainnet"] as const;

export type Network = (typeof NETWORKS)[number];

export function parseNetwork(value: string): Network {
  if (!(NETWORKS as readonly string[]).includes(value)) {
    throw new Error(
      `Invalid --network '${value}'. Expected one of: ${NETWORKS.join(", ")}.`,
    );
  }
  return value as Network;
}

/**
 * Fullnode RPC url. `--rpc-url` flag > `SUI_RPC_URL` (from the loaded config or
 * the environment) > the localnet default.
 *
 * Adopts the STRICT semantics of `deploy.ts:resolveRpcUrl` rather than the
 * silent localhost fallback in `upgradeConfig.ts:loadRpcUrl`: a real network has
 * no sensible default, and silently falling back makes a typo'd or missing
 * config surface as a connection failure against a local port that was never
 * started, rather than as the configuration error it is.
 *
 * NOTE the url must serve the Sui **gRPC** API, since the scripts construct
 * `SuiGrpcClient`. JSON-RPC has been deprecated on Sui's public fullnodes.
 */
export function resolveRpcUrl(network: Network, explicit?: string): string {
  const url = explicit ?? process.env.SUI_RPC_URL;
  if (url) return url;
  if (network !== "localnet") {
    throw new Error(
      `--rpc-url (or SUI_RPC_URL) is required for a ${network} run.`,
    );
  }
  return `http://localhost:${process.env.FULLNODE_PORT ?? "9001"}`;
}

/**
 * Mainnet guard. The burn example spends real USDC and the receive example mints
 * it, so neither should be reachable by a stray `--network mainnet`.
 */
export function assertMainnetAllowed(network: Network, confirmed: boolean) {
  if (network === "mainnet" && !confirmed) {
    throw new Error(
      "Refusing to run against mainnet without --confirm-mainnet. " +
        "This spends real USDC.",
    );
  }
}
