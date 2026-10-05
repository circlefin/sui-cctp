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

import { requestSuiFromFaucetV2 } from "@mysten/sui/faucet";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

import { faucetUrl } from "./env";

/**
 * Generate a fresh ed25519 keypair and fund it from the local Sui faucet.
 * Used as a non-role-holder for negative auth assertions.
 *
 * A small `setTimeout` follows the faucet request because the faucet
 * transfer is best-effort — occasionally the SUI hasn't been indexed by
 * the time we try to sign, and signing without gas produces a confusing
 * `InsufficientGas` error.
 */
export const fundedFreshSigner = async (): Promise<{
  signer: Ed25519Keypair;
  address: string;
}> => {
  const signer = Ed25519Keypair.generate();
  const address = signer.toSuiAddress();
  await requestSuiFromFaucetV2({ host: faucetUrl(), recipient: address });
  await new Promise((r) => setTimeout(r, 500));
  return { signer, address };
};
