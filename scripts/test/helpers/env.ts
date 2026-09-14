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
 * Env resolvers shared by every E2E test file. Uses the same
 * `FULLNODE_PORT` / `FAUCET_PORT` conventions as `yarn deploy-local:v2` and
 * `yarn test-local:v2` so tests point at the same localnet the deploy set
 * up. Falls through to `SUI_RPC_URL` / `SUI_FAUCET_URL` overrides for
 * against-remote-env test runs.
 */

/** Full-node RPC URL. Prefers `SUI_RPC_URL`, else `localhost:$FULLNODE_PORT`. */
export const rpcUrl = (): string =>
  process.env.SUI_RPC_URL ??
  `http://localhost:${process.env.FULLNODE_PORT ?? "9001"}`;

/** Faucet URL. Prefers `SUI_FAUCET_URL`, else `localhost:$FAUCET_PORT`. */
export const faucetUrl = (): string =>
  process.env.SUI_FAUCET_URL ??
  `http://localhost:${process.env.FAUCET_PORT ?? "9123"}`;

/**
 * Reads a deploy-artifact env var that only some suites need, so it stays out
 * of `loadV2ConfigFromEnv` (whose vars every V2 script requires).
 */
export const requireTestEnv = (name: string): string => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
};
