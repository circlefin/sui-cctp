/**
 * Copyright 2024 Circle Internet Financial, LTD. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { SuiClient, SuiTransactionBlockResponse } from "@mysten/sui/client";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { BcsType } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { execSync } from "child_process";
import _ from "lodash";
import fs from "fs";
import path from "path";
import util from "util";
import Web3, { Contract, EventLog, TransactionReceipt } from "web3";
import * as ethutil from 'ethereumjs-util';
import waitForExpect from "wait-for-expect";
import assert from "assert";

export function log(...[message, ...args]: Parameters<typeof console.log>) {
  console.log(">>> " + message, ...args);
}

export function inspectObject(object: any) {
  return util.inspect(
    object,
    false /* showHidden */,
    8 /* depth */,
    true /* color */,
  );
}

export function writeJsonOutput(filePrefix: string, output: Record<any, any>) {
  if (process.env.NODE_ENV !== "TESTING") {
    const randomString = new Date().getTime().toString();
    const outputDirectory = path.join(__dirname, "../logs/");
    const outputFilepath = path.join(
      outputDirectory,
      `${filePrefix}-${randomString}.json`,
    );
    fs.mkdirSync(outputDirectory, { recursive: true });
    fs.writeFileSync(outputFilepath, JSON.stringify(output, null, 2));

    log(`Logs written to ${outputFilepath}`);
  }
}

// Turn private key into keypair format
// cuts off 1st byte as it signifies which signature type is used.
export function getEd25519KeypairFromPrivateKey(privateKey: string) {
  return Ed25519Keypair.fromSecretKey(
    decodeSuiPrivateKey(privateKey).secretKey,
  );
}

export async function executeTransactionHelper(args: {
  client: SuiClient;
  signer: Ed25519Keypair;
  transaction: Transaction;
}): Promise<SuiTransactionBlockResponse> {
  const initialTxOutput = await args.client.signAndExecuteTransaction({
    signer: args.signer,
    transaction: args.transaction,
  });

  // Wait for the transaction to be available over API
  const txOutput = await args.client.waitForTransaction({
    digest: initialTxOutput.digest,
    options: {
      showBalanceChanges: true,
      showEffects: true,
      showEvents: true,
      showInput: true,
      showObjectChanges: true,
      showRawInput: false, // too verbose
    },
  });

  if (txOutput.effects?.status.status === "failure") {
    console.log(inspectObject(txOutput));
    throw new Error("Transaction failed!");
  }

  return txOutput;
}

export async function callViewFunction<T, Input = T>(args: {
  client: SuiClient;
  transaction: Transaction;
  returnTypes: BcsType<T, Input>[];
  sender?: string;
}) {
  const { results } = await args.client.devInspectTransactionBlock({
    sender:
      args.sender ||
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    transactionBlock: args.transaction
  });

  const returnValues = results?.[0]?.returnValues;
  if (!returnValues) {
    throw new Error("Missing return values!");
  }

  if (returnValues.length != args.returnTypes.length) {
    throw new Error("Mismatched return values and return types!");
  }

  // returnValues has the shape of [Byte[], Type][]
  const returnValueBytes = returnValues.map((v) => new Uint8Array(v[0]));
  const decodedResults = _.zip(args.returnTypes, returnValueBytes).map(
    ([type, bytes]) => type!.parse(bytes!)
  );

  return decodedResults;
}

/**
 * Deploys a Sui package using the command line.
 * @param packagePath Relative path from the calling directory
 * @param skipDependencyVerification Flag to optionally skip verifying package dependencies on-chain.
 * @returns parsed transaction output for deployment
 */
export function deployHelper(
  packagePath: string,
  skipDependencyVerification: boolean = false,
): SuiTransactionBlockResponse {
  const fullPackagePath = path.join(__dirname, packagePath);

  const skipDependencyVerificationFlag = skipDependencyVerification
    ? "--skip-dependency-verification"
    : "";
  const rawDeploymentOutput = execSync(
    `sui client publish ${fullPackagePath} ${skipDependencyVerificationFlag} --json`,
    { encoding: "utf-8" },
  );

  const deploymentOutput: SuiTransactionBlockResponse =
    JSON.parse(rawDeploymentOutput);
  return deploymentOutput;
}

/**
 * Obtains the id for an object changed in a provided Sui transaction.
 * @param transactionResponse transaction response object obtained from a deployment
 * @param objectChangeType the type of change an object underwent, e.g. "published" or "created"
 * @param identifier an identifying label for the object, e.g. the package::module
 * @returns the ID of the object, or an empty string if not found
 */
export function recoverChangedObjectId(
  transactionResponse: SuiTransactionBlockResponse,
  objectChangeType: "created" | "published",
  identifier: string = "",
): string {
  if (objectChangeType === "created") {
    const object = transactionResponse.objectChanges?.find((objectChange) => {
      return (
        objectChange.type === objectChangeType &&
        objectChange.objectType.includes(identifier)
      );
    });
    return object && object.type === "created" ? object.objectId : "";
  } else if (objectChangeType === "published") {
    const object = transactionResponse.objectChanges?.find((objectChange) => {
      return objectChange.type === objectChangeType;
    });
    return object && object.type === "published" ? object.packageId : "";
  }
  return "";
}

// Receives a message on the given EVM chain.
export const receiveEvm = async (
  messageTransmitterContract: Contract<any>,
  userAddress: string,
  message: Buffer,
  attestation: string
) => 
  messageTransmitterContract.methods
    .receiveMessage(message, attestation)
    .send({ from: userAddress });

// Fetches USDC balance
export const fetchUsdcBalance = async (
  web3: Web3,
  address: string
) => {
  const evmUSDCAddress = `${process.env.EVM_USDC_ADDRESS}`;
  const usdcInterface = JSON.parse(
    fs.readFileSync("../evm-cctp-contracts/usdc-interfaces/FiatTokenV2_1.sol/FiatTokenV2_1.json").toString()
  );
  const usdcContract = new web3.eth.Contract(usdcInterface.abi, evmUSDCAddress);

  return usdcContract.methods
    .balanceOf(address)
    .call();
}

// Given a hex-encoded message, produces an attestation.
export const attestToMessage = (
  web3: Web3,
  messageHex: string,
): string => {
  // Create an attestation using the initialized Anvil keypair
  // This is not a valid attester key in any testnet or mainnet environment. 
  const attesterPrivateKey = "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97";

  const messageHash = web3.utils.keccak256(messageHex);
  const signedMessage = ethutil.ecsign(ethutil.toBuffer(messageHash), ethutil.toBuffer(attesterPrivateKey));
  const attestation = ethutil.toRpcSig(signedMessage.v, signedMessage.r, signedMessage.s);
  
  return attestation;
}

// Generates a depositForBurn tx from the given EVM chain and returns the message as a string.
export const generateEvmBurn = async (
  web3: Web3,
  messageTransmitterContract: Contract<any>,
  tokenMessengerContract: Contract<any>,
  usdcContract: Contract<any>,
  tokenMessengerContractAddress: string,
  usdcContractAddress: string,
  userAddress: string,
  destAddress: string,
  destDomain: number,
  amount: number
) => {
  // Set allowance for the userAddress
  const txReceipt1 = await usdcContract.methods
    .approve(tokenMessengerContractAddress, amount)
    .send({ from: userAddress });
  assert(txReceipt1.status === BigInt(1));

  const paddedDestAddress = web3.utils.padLeft(destAddress, 64);

  const txReceipt2 = await tokenMessengerContract.methods
    .depositForBurn(amount, destDomain, paddedDestAddress, usdcContractAddress)
    .send({ from: userAddress });
  assert(txReceipt2.status === BigInt(1));

  return fetchEvmMessage(messageTransmitterContract, txReceipt2);
};


// Fetches an EVM message body from event logs.
const fetchEvmMessage = async (
  messageTransmitterContract: Contract<any>,
  txReceipt: TransactionReceipt
) => {
  let logs: any = [];

  await waitForExpect(async () => {
    logs = await messageTransmitterContract.getPastEvents("MessageSent", {
      fromBlock: txReceipt.blockNumber,
      toBlock: txReceipt.blockNumber
    });
    assert(logs.length > 0);
  }, 90_000);

  return {message: String((logs[0] as EventLog).returnValues.message), tx: txReceipt};
}
