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
  eventBytes,
  executeTransactionWithRetry,
  getEd25519KeypairFromPrivateKey,
  splitCoinForAmount,
} from "./helpers";
import { addDepositForBurnV2, loadV2ConfigFromEnv } from "./ptbV2";
import { REMOTE_EVM_DOMAIN } from "./constants";
import {
  assertMainnetAllowed,
  NETWORKS,
  Network,
  parseNetwork,
  resolveRpcUrl,
} from "./network";
import {
  irisMessagesUrl,
  parseBigIntFlag,
  parseIntegerFlag,
  resolveSigner,
  sourceDomainOf,
} from "./exampleCli";

const DEFAULT_CONFIG = "test_config.v2.env";

// Defaults preserve the previous localnet behaviour exactly, so an unflagged
// `yarn deposit-for-burn-example:v2` burns and prints what it always did.
const DEFAULT_AMOUNT = "1";
const DEFAULT_MINT_RECIPIENT = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";
const DEFAULT_MAX_FEE = "0";
const DEFAULT_MIN_FINALITY_THRESHOLD = "2000";

/**
 * Example: burning USDC on Sui (V2) to bridge to a remote domain.
 *
 * Runs against localnet, testnet or mainnet. Object ids come from the dotenv
 * record named by `--config`, so a caller who did not deploy the contracts can
 * point this at an existing deployment's record with their own key.
 *
 * On localnet the emitted message is attested locally with the dev attester key,
 * exactly as before. On a real network no attestation is forged: the message and
 * its hash are printed along with the Iris url to poll, because only Circle's
 * attestation service can produce a signature the destination will accept.
 *
 *   yarn deposit-for-burn-example:v2                       # localnet, as before
 *   yarn deposit-for-burn-example:v2 --network testnet \
 *     --config test_config.<name>.env \
 *     --destination-domain 0 --mint-recipient 0x<evm-addr>
 */
const main = async () => {
  const program = new Command();
  program
    .name("deposit-for-burn-example:v2")
    .description("Burn USDC on Sui (CCTP V2) to bridge it to a remote domain")
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
      "--amount <baseUnits>",
      `USDC to burn, in base units — USDC has 6 decimals, so 1 = 0.000001 USDC (default: ${DEFAULT_AMOUNT})`,
    )
    .option(
      "--destination-domain <n>",
      `CCTP domain to mint on (default: ${REMOTE_EVM_DOMAIN})`,
    )
    .option(
      "--mint-recipient <addr>",
      "address to mint to ON THE DESTINATION CHAIN — not your Sui address",
    )
    .option("--max-fee <baseUnits>", `(default: ${DEFAULT_MAX_FEE})`)
    .option(
      "--min-finality-threshold <n>",
      `1000 = fast, 2000 = standard (default: ${DEFAULT_MIN_FINALITY_THRESHOLD})`,
    )
    .option("--gas-budget <mist>", "gas budget in MIST")
    .option(
      "--iris-host <url>",
      "attestation-service host to print in the poll url (default: per network)",
    )
    .parse(process.argv);

  const opts = program.opts();

  // Load the deployment record BEFORE anything reads process.env, so the record
  // wins over a stale shell environment. An explicitly-passed --config must
  // exist; the default is loaded only if present, which keeps a pre-deploy
  // localnet run behaving as it did (the values simply come from env instead).
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

  const cfg = loadV2ConfigFromEnv();
  const signer = getEd25519KeypairFromPrivateKey(resolveSigner(opts.key));
  const client = new SuiGrpcClient({ network, baseUrl: rpcUrl });
  // web3 is only used for keccak256 over the message bytes (no network calls).
  const web3 = new Web3();

  const amount = parseIntegerFlag(opts.amount ?? DEFAULT_AMOUNT, "--amount");
  const destinationDomain = parseIntegerFlag(
    opts.destinationDomain ?? String(REMOTE_EVM_DOMAIN),
    "--destination-domain",
  );
  const mintRecipient = opts.mintRecipient ?? DEFAULT_MINT_RECIPIENT;
  const maxFee = parseBigIntFlag(opts.maxFee ?? DEFAULT_MAX_FEE, "--max-fee");
  const minFinalityThreshold = parseIntegerFlag(
    opts.minFinalityThreshold ?? DEFAULT_MIN_FINALITY_THRESHOLD,
    "--min-finality-threshold",
  );
  const gasBudget = opts.gasBudget
    ? parseBigIntFlag(opts.gasBudget, "--gas-budget")
    : null;

  console.log(
    `Network: ${network} (${rpcUrl})\n` +
      `Burning ${amount} base units of USDC from ${signer.toSuiAddress()}\n` +
      `to ${mintRecipient} on domain ${destinationDomain}\n`,
  );

  // The coin selection and the tx build both live inside `buildTransaction` so
  // that a retry re-reads them: splitting from an owned USDC coin advances its
  // version, and a stale ref is rejected at submit time.
  console.log("Broadcasting sui V2 deposit_for_burn tx...");
  const output = await executeTransactionWithRetry({
    client,
    signer,
    buildTransaction: async () => {
      const tx = new Transaction();

      // Merge the owner's USDC coins and split off the burn amount.
      const coin = await splitCoinForAmount({
        tx,
        client,
        owner: signer.toSuiAddress(),
        coinType: `${cfg.usdcPackageId}::usdc::USDC`,
        amount,
      });

      addDepositForBurnV2(tx, cfg, coin, {
        destinationDomain,
        mintRecipient,
        maxFee,
        minFinalityThreshold,
      });

      // Neither transaction helper accepts a gas budget, so set it on the
      // transaction itself.
      if (gasBudget !== null) tx.setGasBudget(gasBudget);

      return tx;
    },
  });
  assert(output.effects.status.status === "success");
  console.log(`deposit_for_burn transaction successful: 0x${output.digest} \n`);

  const messageRaw = eventBytes(
    (
      output.events?.find((event) =>
        event.type.includes("send_message::MessageSent"),
      )?.parsedJson as { message: unknown }
    ).message,
  );
  const messageHex = `0x${Buffer.from(messageRaw).toString("hex")}`;

  console.log("USDC burn on Sui (V2) successful:");
  console.log(`Emitted message: ${messageHex}`);

  if (network === "localnet") {
    // The dev attester key is only a valid attester on localnet; see
    // `attestToMessage` in helpers.ts.
    console.log(`Local attestation: ${attestToMessage(web3, messageHex)}`);
    return;
  }

  console.log(`Message hash: ${web3.utils.keccak256(messageHex)}`);
  console.log(
    "\nNo attestation is produced on a real network. Poll Circle's " +
      "attestation service for it:\n" +
      `  ${irisMessagesUrl(
        network,
        sourceDomainOf(messageRaw),
        output.digest,
        opts.irisHost,
      )}`,
  );
};

main();
