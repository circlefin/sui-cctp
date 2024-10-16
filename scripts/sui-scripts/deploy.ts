/**
 * Copyright (c) 2024, Circle Internet Group, Inc. All rights reserved.
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

import { requestSuiFromFaucetV0 } from "@mysten/sui/faucet";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { bcs } from "@mysten/sui/bcs";

import { execSync } from "child_process";
import { keccak256 } from "ethereumjs-util";
import { writeFile } from "fs";
import dotenv from "dotenv";
// import { DENY_LIST_OBJECT_ID } from '../../stablecoin-sui/typescript/scripts/helpers/index';

const DENY_LIST_OBJECT_ID = "0x403";

import {
  callViewFunction,
  deployHelper,
  executeTransactionHelper,
  getEd25519KeypairFromPrivateKey,
  log,
  recoverChangedObjectId
} from "./helpers";

dotenv.config();

let client: SuiClient;

let stablecoinPackageId: string;
let usdcPackageId: string;
let usdcTreasuryId: string;
let mtPackageId: string;
let mtStateId: string;
let tmmPackageId: string;
let tmmStateId: string;
let usdcTokenId: string;
let usdcFundsObjectId: string;
let suiExtensionsPackageId: string;
let messageTransmitterUpgradeServiceId: string;
let tokenMessengerUpgradeServiceId: string;

/**
 * Deploys and configures all packages for USDC + CCTP. 
 */
export async function deploySuiContracts(): Promise<void> {
  const suiRpcUrl = `http://localhost:${process.env.FULLNODE_PORT}`;
  const suiFaucetUrl = `http://localhost:${process.env.FAUCET_PORT}`;

  client = new SuiClient({ url: suiRpcUrl });

  // Configure local environment if not already set up
  const existingEnvs = JSON.parse(execSync("sui client envs --json", { encoding: "utf-8" }));
  if (!existingEnvs[0].some((suiEnvConfig: { alias: string; }) => suiEnvConfig.alias === "local")) {
    execSync(`sui client new-env --alias local --rpc ${suiRpcUrl}`);
  };

  // Generate and switch to deployer key if not already set up
  let deployerKeypair: Ed25519Keypair;
  if (process.env.DEPLOYER_PRIVATE_KEY) {
    log(`Using provided deployer key ${process.env.DEPLOYER_PRIVATE_KEY}`);
    deployerKeypair = getEd25519KeypairFromPrivateKey(process.env.DEPLOYER_PRIVATE_KEY);
  } else {
    deployerKeypair = Ed25519Keypair.generate();
    log(`Generating new deployer key ${deployerKeypair.getSecretKey()}`);
    execSync(`sui keytool import ${deployerKeypair.getSecretKey()} ed25519`);
  }
  log(`Using address ${deployerKeypair.toSuiAddress()}`); 

  execSync(`sui client switch --address ${deployerKeypair.toSuiAddress()} --env local`)

  log("Funding address...");
  await requestSuiFromFaucetV0({
    host: suiFaucetUrl,
    recipient: deployerKeypair.toSuiAddress(),
  });
  await requestSuiFromFaucetV0({
    host: suiFaucetUrl,
    recipient: "0xf6152a5005ff4c7bcb25021a12a988073970b9e2f12e68c54957e8baacb9b8b4",
  });

  await deployUSDCContracts();
  log("Deployed USDC packages");

  await deployCCTPContracts(deployerKeypair);
  log("Deployed CCTP packages");

  await configureCCTPContracts(deployerKeypair);
  log("Configured CCTP packages");

  const blocklistAddress = "0xf6152a5005ff4c7bcb25021a12a988073970b9e2f12e68c54957e8baacb9b8b4";
  log("blocklisting address", blocklistAddress);

  const btx = new Transaction();
  btx.moveCall({
    target: `${stablecoinPackageId}::treasury::blocklist`,
    arguments: [
      btx.object(usdcTreasuryId),
      btx.object(DENY_LIST_OBJECT_ID),
      btx.pure.address(blocklistAddress),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  const btxOutput = await executeTransactionHelper({
    client,
    signer: deployerKeypair,
    transaction: btx,
  });
  console.log(btxOutput);

  // Link EVM contracts to Sui. Can be skipped via environment variable if needed.
  if (process.env.LINK_EVM_CONTRACTS === "true") {
    execSync(`~/.foundry/bin/cast send ${process.env.EVM_TOKEN_MINTER_ADDRESS} "function linkTokenPair(address localToken,uint32 remoteDomain,bytes32 remoteToken)" ${process.env.EVM_USDC_ADDRESS} 8 ${usdcTokenId} --rpc-url ${process.env.EVM_RPC_URL} --private-key ${process.env.EVM_TOKEN_MINTER_DEPLOYER_KEY}`);

    // Sui needs to be linked via the MessageTransmitterAuthenticator type as its recipient. 
    const remoteRecipientType = `${tmmPackageId.replace("0x", "")}::message_transmitter_authenticator::MessageTransmitterAuthenticator`;
    const hashedRecipient = keccak256(Buffer.from(remoteRecipientType));
    const recipientAddress = `0x${hashedRecipient.toString('hex')}`
  
    execSync(`~/.foundry/bin/cast send ${process.env.EVM_TOKEN_MESSENGER_ADDRESS} "function addRemoteTokenMessenger(uint32 domain,bytes32 tokenMessenger)" 8 ${recipientAddress} --rpc-url ${process.env.EVM_RPC_URL} --private-key ${process.env.EVM_TOKEN_MESSENGER_DEPLOYER_KEY}`);
  }

  // Export deployment output to sui_deployment.env
  const deploymentConfig = 
    `
    SUI_MESSAGE_TRANSMITTER_ID=${mtPackageId}
    SUI_MESSAGE_TRANSMITTER_STATE_ID=${mtStateId}
    SUI_MESSAGE_TRANSMITTER_UPGRADE_SERVICE_ID=${messageTransmitterUpgradeServiceId}
    SUI_TOKEN_MESSENGER_MINTER_ID=${tmmPackageId}
    SUI_TOKEN_MESSENGER_MINTER_STATE_ID=${tmmStateId}
    SUI_TOKEN_MESSENGER_MINTER_UPGRADE_SERVICE_ID=${tokenMessengerUpgradeServiceId}
    SUI_USDC_ID=${usdcPackageId}
    SUI_USDC_FUNDS_OBJECT_ID=${usdcFundsObjectId}
    SUI_TREASURY_ID=${usdcTreasuryId}
    SUI_EXTENSIONS_ID=${suiExtensionsPackageId}
    SUI_STABLECOIN_ID=${stablecoinPackageId}
    SUI_DEPLOYER_KEY=${deployerKeypair.getSecretKey()}
    `

  writeFile("test_config.env", deploymentConfig, (err) => {
    if (err) throw err;
  });
}

/**
 * Deploy the sui_extensions, stablecoin, and USDC packages.
 */
export async function deployUSDCContracts () {
  // Deploy USDC packages
  const suiExtensionsDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/sui_extensions",
    true
  );
  suiExtensionsPackageId = recoverChangedObjectId(
    suiExtensionsDeploymentOutput,
    "published",
  );
  log(`sui_extensions published at ${suiExtensionsPackageId}`);

  const stablecoinDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/stablecoin",
    true
  );
  stablecoinPackageId = recoverChangedObjectId(
    stablecoinDeploymentOutput,
    "published",
  );
  log(`stablecoin published at ${stablecoinPackageId}`);

  const usdcDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/usdc",
    true
  );
  usdcPackageId = recoverChangedObjectId(
    usdcDeploymentOutput,
    "published",
  );
  log(`usdc published at ${usdcPackageId}`);

  // Recover USDC treasury object
  usdcTreasuryId = recoverChangedObjectId(
    usdcDeploymentOutput,
    "created",
    "treasury::Treasury<",
  );
  log(`USDC treasury object created at ${usdcTreasuryId}`);
}

/**
 * Deploys and initializes the message_transmitter and token_messenger_minter packages.
 */
export async function deployCCTPContracts(
  deployerKey: Ed25519Keypair
) {
  const mtDeploymentOutput = deployHelper("../../packages/message_transmitter", true);
  mtPackageId = recoverChangedObjectId(mtDeploymentOutput, "published");
  messageTransmitterUpgradeServiceId = recoverChangedObjectId(mtDeploymentOutput, "created", "UpgradeService");
  log(`message_transmitter published at ${mtPackageId}`);
  log(`message_transmitter upgrade service object created at ${messageTransmitterUpgradeServiceId}`);

  // Obtain message_transmitter InitCap
  const mtInitCapId = recoverChangedObjectId(
    mtDeploymentOutput,
    "created",
    "initialize::InitCap",
  );
  log(`message_transmitter InitCap found at ${mtInitCapId}`);

  // Initialize message_transmitter state
  const mtInitializeTx = new Transaction();
  mtInitializeTx.moveCall({
    target: `${mtPackageId}::initialize::init_state`,
    arguments: [
      mtInitializeTx.object(mtInitCapId),
      mtInitializeTx.pure.u32(8), // localDomain
      mtInitializeTx.pure.u32(0), // messageVersion
      mtInitializeTx.pure.u64(8192), // maxMessageSize
      mtInitializeTx.pure.address("0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f"), // attester
    ],
  });

  const mtInitTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mtInitializeTx,
  });

  // Obtain message_transmitter state object id
  mtStateId = recoverChangedObjectId(
    mtInitTxOutput,
    "created",
    "state::State",
  );
  log(`message_transmitter state found at ${mtStateId}`);

  // Skip dependency verification for TokenMessengerMinter for now
  const tmmDeploymentOutput = deployHelper(
    "../../packages/token_messenger_minter",
    true
  );
  tmmPackageId = recoverChangedObjectId(tmmDeploymentOutput, "published");
  tokenMessengerUpgradeServiceId = recoverChangedObjectId(tmmDeploymentOutput, "created", "UpgradeService");
  log(`token_messenger_minter deployed at ${tmmPackageId}`);
  log(`token_messenger_minter upgrade service object created at ${tokenMessengerUpgradeServiceId}`);

  // Obtain token_messenger_minter InitCap
  const tmmInitCapId = recoverChangedObjectId(
    tmmDeploymentOutput,
    "created",
    "initialize::InitCap",
  );
  log(`token_messenger_minter InitCap found at ${tmmInitCapId}`);

  // Initialize token_messenger_minter state
  const tmmInitializeTx = new Transaction();
  tmmInitializeTx.moveCall({
    target: `${tmmPackageId}::initialize::init_state`,
    arguments: [
      tmmInitializeTx.object(tmmInitCapId),
      tmmInitializeTx.pure.u32(0), // messageBodyVersion
    ],
  });

  const tmmInitTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: tmmInitializeTx,
  });

  // Obtain token_messenger_minter state object id
  tmmStateId = recoverChangedObjectId(
    tmmInitTxOutput,
    "created",
    "state::State",
  );
  log(`token_messenger_minter state found at ${tmmStateId}`);

  // Fetch token id
  const tokenIdTx = new Transaction();
  tokenIdTx.moveCall({
    target: `${tmmPackageId}::token_utils::calculate_token_id`,
    typeArguments: [`${usdcPackageId}::usdc::USDC`]
  });

  const tokenIdTxOutput = await callViewFunction({
    client,
    transaction: tokenIdTx,
    returnTypes: [bcs.Address]
  });

  usdcTokenId = tokenIdTxOutput.toString();
  
  log(`Token ID is ${usdcTokenId}`);
}

/**
 * Configure the CCTP contracts.
 * This adds a remote token messenger, remote token pair, and mint cap.
 */
export async function configureCCTPContracts(
  deployerKey: Ed25519Keypair
) {
  // Add remote resources
  const addRemoteTmTx = new Transaction();
  addRemoteTmTx.moveCall({
    target: `${tmmPackageId}::remote_token_messenger::add_remote_token_messenger`,
    arguments: [
      addRemoteTmTx.pure.u32(0), // remoteDomain
      addRemoteTmTx.pure.address(`${process.env.EVM_TOKEN_MESSENGER_ADDRESS}`), // remote tokenMessenger address
      addRemoteTmTx.object(tmmStateId), // tokenMessenger state
    ],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addRemoteTmTx,
  });

  const setBurnLimitTx = new Transaction();
  setBurnLimitTx.moveCall({
    target: `${tmmPackageId}::token_controller::set_max_burn_amount_per_message`,
    arguments: [
      setBurnLimitTx.pure.u64(100000), // burn limit
      setBurnLimitTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: setBurnLimitTx,
  });

  // Configure a new controller, configure TMM as a minter, & add the mint cap
  const configureNewControllerTx = new Transaction();

  configureNewControllerTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_new_controller`,
    arguments: [
      configureNewControllerTx.object(usdcTreasuryId),
      configureNewControllerTx.pure.address(deployerKey.toSuiAddress()),
      configureNewControllerTx.pure.address(deployerKey.toSuiAddress())
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  const configureNewControllerTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: configureNewControllerTx,
  });

  // Configure the mintCap with a minter allowance
  const configureMinterTx = new Transaction();

  configureMinterTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_minter`,
    arguments: [
      configureMinterTx.object(usdcTreasuryId),
      configureMinterTx.object("0x403"), // fixed denyList address
      configureMinterTx.pure.u64(10000000), // mint allowance
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  })

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: configureMinterTx
  });

  // Mint starter funds to the deployer address
  const mintCapObjectId = recoverChangedObjectId(
    configureNewControllerTxOutput,
    "created",
    "treasury::MintCap",
  );
  log("mint cap object id:", mintCapObjectId);

  const mintFundsTx = new Transaction();

  mintFundsTx.moveCall({
    target: `${stablecoinPackageId}::treasury::mint`,
    arguments: [
      mintFundsTx.object(usdcTreasuryId), // USDC treasury object
      mintFundsTx.object(mintCapObjectId), // mint cap
      mintFundsTx.object("0x403"), // fixed denyList address
      mintFundsTx.pure.u64(10000), // amount
      mintFundsTx.pure.address(deployerKey.toSuiAddress()) // recipient
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  })

  mintFundsTx.moveCall({
    target: `${stablecoinPackageId}::treasury::mint`,
    arguments: [
      mintFundsTx.object(usdcTreasuryId), // USDC treasury object
      mintFundsTx.object(mintCapObjectId), // mint cap
      mintFundsTx.object("0x403"), // fixed denyList address
      mintFundsTx.pure.u64(10000), // amount
      mintFundsTx.pure.address("0xf6152a5005ff4c7bcb25021a12a988073970b9e2f12e68c54957e8baacb9b8b4") // recipient
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  })

  const mintFundsTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mintFundsTx
  });

  usdcFundsObjectId = recoverChangedObjectId(
    mintFundsTxOutput,
    "created",
    "coin::Coin"
  );

  log(`Funded deployer address with 10000 USDC, stored at ${usdcFundsObjectId}`);

  // Add mint cap to the token_messenger_minter
  const addMintCapTx = new Transaction();
  addMintCapTx.moveCall({
    target: `${tmmPackageId}::token_controller::add_stablecoin_mint_cap`,
    arguments: [
      addMintCapTx.object(mintCapObjectId),
      addMintCapTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addMintCapTx,
  });

  // Link evm token
  const linkTokenPairTx = new Transaction();
  linkTokenPairTx.moveCall({
    target: `${tmmPackageId}::token_controller::link_token_pair`,
    arguments: [
      linkTokenPairTx.pure.u32(0), // remote domain
      linkTokenPairTx.pure.address(`${process.env.EVM_USDC_ADDRESS}`), // remote token address
      linkTokenPairTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: linkTokenPairTx,
  });
}

deploySuiContracts();
