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

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";

import assert from "assert";
import fs from "fs";
import path from "path";
import dotenv from "dotenv";
import { Command } from "commander";
import { Web3 } from "web3";

import {
  attestToMessage,
  coinTypeMatches,
  executeTransactionHelper,
  getEd25519KeypairFromPrivateKey,
} from "./helpers";
import {
  addReceiveV2,
  buildInboundBurnMessageBytes,
  loadRemoteEvmConfigFromEnv,
  loadV2ConfigFromEnv,
} from "./ptbV2";
import {
  assertMainnetAllowed,
  NETWORKS,
  Network,
  parseNetwork,
  resolveRpcUrl,
} from "./network";
import { parseBigIntFlag, parseHexFlag, resolveSigner } from "./exampleCli";

const DEFAULT_CONFIG = "test_config.v2.env";
const DEFAULT_GAS_BUDGET = "1000000000";
const USDC_AMOUNT = BigInt(1000);

/**
 * Example: receiving/minting a USDC transfer on Sui (V2).
 *
 * The receive/mint PTB itself is network-agnostic — it takes raw message and
 * attestation bytes. What differs by network is where those bytes come from:
 *
 * - **localnet**: there is no source chain, so the inbound message is
 *   synthesized in TypeScript and signed with the dev attester key.
 * - **testnet/mainnet**: the caller supplies `--message` and `--attestation`
 *   from a real burn, fetched from Circle's attestation service. Nothing is
 *   forged; the dev key is not a valid attester on any real network, and a
 *   deployment may require more than one signature.
 *
 *   yarn receive-message-example:v2                        # localnet, as before
 *   yarn receive-message-example:v2 --network testnet \
 *     --config test_config.<name>.env \
 *     --message 0x... --attestation 0x...
 *
 * ## Two things that surprise callers on a real network
 *
 * - `mintRecipient` is fixed by the upstream burn, not by this script. If it is
 *   not a Sui address you control, this still succeeds — and the USDC lands in
 *   someone else's account.
 * - A non-zero `destinationCaller` in the message restricts who may submit the
 *   receive. If it is set and is not your address, the transaction aborts.
 *
 * Both are visible in the `decodedMessage` of the Iris response before you
 * submit anything.
 */
const main = async () => {
  const program = new Command();
  program
    .name("receive-message-example:v2")
    .description("Receive and mint an inbound CCTP V2 USDC transfer on Sui")
    .option(
      "--network <name>",
      `target network: ${NETWORKS.join("|")} (default: SUI_NETWORK, else localnet)`,
    )
    .option("--rpc-url <url>", "fullnode gRPC url")
    .option(
      "--config <path>",
      `dotenv record holding the deployment's object ids (default: ${DEFAULT_CONFIG})`,
    )
    .option(
      "--key <suiprivkey>",
      "signer private key (default: SUI_SIGNER_KEY, else SUI_DEPLOYER_KEY)",
    )
    .option("--confirm-mainnet", "required to run against mainnet", false)
    .option(
      "--message <hex>",
      "message bytes from Circle's attestation service (required off localnet)",
    )
    .option(
      "--attestation <hex>",
      "attestation bytes from Circle's attestation service (required off localnet)",
    )
    .option(
      "--gas-budget <mist>",
      `gas budget in MIST (default: ${DEFAULT_GAS_BUDGET})`,
    )
    .parse(process.argv);

  const opts = program.opts();

  const configPath = path.resolve(opts.config ?? DEFAULT_CONFIG);
  if (opts.config && !fs.existsSync(configPath)) {
    throw new Error(`--config file not found: ${configPath}`);
  }
  if (fs.existsSync(configPath)) {
    dotenv.config({ path: configPath, override: true });
  }

  // Truthiness rather than `??`: a blank `SUI_NETWORK=` line in the config is
  // the empty string, which `??` would accept and pass on to parseNetwork.
  const configuredNetwork = process.env.SUI_NETWORK
    ? process.env.SUI_NETWORK
    : "localnet";
  const network: Network = parseNetwork(
    opts.network ? opts.network : configuredNetwork,
  );
  assertMainnetAllowed(network, !!opts.confirmMainnet);
  const rpcUrl = resolveRpcUrl(network, opts.rpcUrl);

  // The two halves of the input are useless apart, so require them together
  // rather than silently synthesizing over a half-supplied pair.
  if (!!opts.message !== !!opts.attestation) {
    throw new Error("--message and --attestation must be supplied together.");
  }

  const cfg = loadV2ConfigFromEnv();
  const signer = getEd25519KeypairFromPrivateKey(resolveSigner(opts.key));
  const client = new SuiGrpcClient({ network, baseUrl: rpcUrl });
  const gasBudget = parseBigIntFlag(
    opts.gasBudget ?? DEFAULT_GAS_BUDGET,
    "--gas-budget",
  );

  let message: Uint8Array;
  let attestation: Uint8Array;

  if (opts.message) {
    message = parseHexFlag(opts.message, "--message");
    attestation = parseHexFlag(opts.attestation, "--attestation");
  } else {
    if (network !== "localnet") {
      throw new Error(
        `--message and --attestation are required for a ${network} run.\n` +
          "A real network needs a message from a burn that actually happened, " +
          "attested by Circle. Fetch both from:\n" +
          "  GET https://iris-api-sandbox.circle.com/v2/messages/" +
          "{sourceDomainId}?transactionHash=0x<burn tx hash>\n" +
          "(https://iris-api.circle.com for mainnet), and pass the " +
          "response's `message` and `attestation` fields.\n" +
          "The host must be the attestation service for the SAME deployment " +
          "the burn went through — a burn through one environment's " +
          "TokenMessenger is not indexed by another's, and receiving it here " +
          "would abort in validate_remote_token_messenger.\n" +
          "This script will not forge one: the dev attester key is not valid " +
          "on any real network.",
      );
    }
    // Localnet only: no source chain exists, so synthesize the inbound message
    // and sign it with the dev attester key. `loadRemoteEvmConfigFromEnv` is
    // called HERE rather than at module scope so that a public-network run does
    // not require EVM_* env vars it has no use for.
    const remote = loadRemoteEvmConfigFromEnv();
    // A unique nonce per receive (opaque 32-byte value in CCTP V2).
    const nonce =
      BigInt(Date.now()) * BigInt(1_000_000) +
      BigInt(Math.floor(Math.random() * 1_000_000));
    message = buildInboundBurnMessageBytes(cfg, remote, {
      nonce,
      mintRecipient: signer.toSuiAddress(),
      amount: USDC_AMOUNT,
    });
    const messageHex = `0x${Buffer.from(message).toString("hex")}`;
    const attestationHex = attestToMessage(new Web3(), messageHex);
    attestation = Uint8Array.from(
      Buffer.from(attestationHex.replace("0x", ""), "hex"),
    );
  }

  console.log(
    `Network: ${network} (${rpcUrl})\n` +
      `Submitting as ${signer.toSuiAddress()}\n`,
  );

  const tx = new Transaction();
  addReceiveV2(tx, cfg, message, attestation);
  tx.setGasBudget(gasBudget);

  console.log("Broadcasting sui V2 receive_message tx...");
  const output = await executeTransactionHelper({
    client,
    signer,
    transaction: tx,
  });
  assert(output.effects.status.status === "success");
  console.log(`receive_message transaction successful: 0x${output.digest} \n`);

  const usdcBalanceChange = output.balanceChanges?.find((b) =>
    coinTypeMatches(b.coinType, cfg.usdcPackageId),
  );
  console.log("USDC mint on Sui (V2) successful:");
  console.log(
    `Sui recipient: ${signer.toSuiAddress()}, change: +${usdcBalanceChange?.amount}`,
  );
};

main();
