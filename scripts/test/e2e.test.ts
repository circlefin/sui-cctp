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

import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

import dotenv from "dotenv";
import * as ethutil from "ethereumjs-util";
import fs from "fs";
import waitForExpect from "wait-for-expect";
import { Contract, EventLog, TransactionReceipt, Web3 } from "web3";

import { executeTransactionHelper, getEd25519KeypairFromPrivateKey } from "../sui-scripts/helpers";

interface SuiContractDefinition {
  messageTransmitterId: string;
  messageTransmitterStateId: string;
  tokenMessengerMinterId: string;
  tokenMessengerMinterStateId: string;
  usdcId: string;
  usdcFundsObjectId: string;
  treasuryId: string;
  signer: Ed25519Keypair;
  client: SuiClient;
}

interface EvmContractDefinition {
  messageTransmitterContract: Contract<any>;
  messageTransmitterContractAddress: string;
  tokenMessengerContract: Contract<any>;
  tokenMessengerContractAddress: string;
  tokenMinterContract: Contract<any>;
  tokenMinterContractAddress: string;
  usdcContract: Contract<any>;
  usdcContractAddress: string;
  web3: Web3;
}

const GAS_BUDGET = 1_000_000_000;
const USDC_AMOUNT = 1;

dotenv.config();
dotenv.config({ path: 'test_config.env'});

describe("E2E Mint/Burn tests between EVM and Sui chains", () => {
  let evmContractDefinition: EvmContractDefinition;
  let suiContractDefinition: SuiContractDefinition;
  let suiUserAddress: string;

  const evmUserAddress = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";

  beforeAll(async () => {
    // EVM contract setup
    const web3 = new Web3(new Web3.providers.HttpProvider(`${process.env.EVM_RPC_URL}`));
    const evmMessageTransmitterAddress = `${process.env.EVM_MESSAGE_TRANSMITTER_ADDRESS}`;
    const evmTokenMessengerAddress = `${process.env.EVM_TOKEN_MESSENGER_ADDRESS}`;
    const evmTokenMinterAddress = `${process.env.EVM_TOKEN_MINTER_ADDRESS}`;
    const evmUSDCAddress = `${process.env.EVM_USDC_ADDRESS}`;

    const messageTransmitterInterface = JSON.parse(
      fs.readFileSync("../evm-cctp-contracts/cctp-interfaces/MessageTransmitter.sol/MessageTransmitter.json").toString()
    );
  
    const tokenMessengerInterface = JSON.parse(
      fs.readFileSync("../evm-cctp-contracts/cctp-interfaces/TokenMessenger.sol/TokenMessenger.json").toString()
    );
  
    const tokenMinterInterface = JSON.parse(
      fs.readFileSync("../evm-cctp-contracts/cctp-interfaces/TokenMinter.sol/TokenMinter.json").toString()
    );
  
    const usdcInterface = JSON.parse(
      fs.readFileSync("../evm-cctp-contracts/usdc-interfaces/FiatTokenV2_1.sol/FiatTokenV2_1.json").toString()
    );

    const messageTransmitterContract = new web3.eth.Contract(
      messageTransmitterInterface.abi,
      evmMessageTransmitterAddress
    );
    const tokenMessengerContract = new web3.eth.Contract(tokenMessengerInterface.abi, evmTokenMessengerAddress);
    const tokenMinterContract = new web3.eth.Contract(tokenMinterInterface.abi, evmTokenMinterAddress);
    const usdcContract = new web3.eth.Contract(usdcInterface.abi, evmUSDCAddress);

    evmContractDefinition = {
      messageTransmitterContract,
      messageTransmitterContractAddress: evmMessageTransmitterAddress,
      tokenMessengerContract,
      tokenMessengerContractAddress: evmTokenMessengerAddress,
      tokenMinterContract,
      tokenMinterContractAddress: evmTokenMinterAddress,
      usdcContract,
      usdcContractAddress: evmUSDCAddress,
      web3
    };

    // Sui contract setup
    suiContractDefinition = {
      messageTransmitterId: `${process.env.SUI_MESSAGE_TRANSMITTER_ID}`,
      messageTransmitterStateId: `${process.env.SUI_MESSAGE_TRANSMITTER_STATE_ID}`,
      tokenMessengerMinterId: `${process.env.SUI_TOKEN_MESSENGER_MINTER_ID}`,
      tokenMessengerMinterStateId: `${process.env.SUI_TOKEN_MESSENGER_MINTER_STATE_ID}`,
      usdcId: `${process.env.SUI_USDC_ID}`,
      usdcFundsObjectId: `${process.env.SUI_USDC_FUNDS_OBJECT_ID}`,
      treasuryId: `${process.env.SUI_TREASURY_ID}`,
      signer: getEd25519KeypairFromPrivateKey(`${process.env.SUI_DEPLOYER_KEY}`),
      client: new SuiClient({ url: `http://localhost:${process.env.FULLNODE_PORT}`})
    }

    suiUserAddress = suiContractDefinition.signer.toSuiAddress();
  }, 120_000);

  describe("EVM -> Sui", () => {
    test("EVM depositForBurn is received on Sui", async () => {
      const message = await generateEvmBurn(
        evmContractDefinition,
        evmUserAddress,
        suiUserAddress,
        8
      );

      const attestation = attestToMessage(evmContractDefinition.web3, message);
      const messageBytes = Buffer.from(message.replace("0x", ""), "hex");

      await receiveSui(suiContractDefinition, messageBytes, attestation);
    }, 120_000)

    test("EVM depositForBurnWithCaller is received on Sui", async () => {
      const message = await generateEvmBurn(
        evmContractDefinition,
        evmUserAddress,
        suiUserAddress,
        8,
        suiUserAddress
      );

      const attestation = attestToMessage(evmContractDefinition.web3, message);
      const messageBytes = Buffer.from(message.replace("0x", ""), "hex");

      await receiveSui(suiContractDefinition, messageBytes, attestation);
    })
  })

  describe("Sui -> EVM", () => {
    test("Sui depositForBurn is received on EVM", async () => {
      const message = await generateSuiBurn(suiContractDefinition, evmUserAddress);
      const messageHex = `0x${message.toString("hex")}`;
      const attestation = attestToMessage(evmContractDefinition.web3, messageHex);
      await receiveEvm(evmContractDefinition, evmUserAddress, message, attestation);
    })

    test("Sui depositForBurnWithCaller is received on EVM", async () => {
      const message = await generateSuiBurn(suiContractDefinition, evmUserAddress, evmUserAddress);
      const messageHex = `0x${message.toString("hex")}`;
      const attestation = attestToMessage(evmContractDefinition.web3, messageHex);
      await receiveEvm(evmContractDefinition, evmUserAddress, message, attestation);
    })
  })
});

// Generates a depositForBurn tx from the given EVM chain and returns the message as a string.
const generateEvmBurn = async (
  contractDefinition: EvmContractDefinition,
  userAddress: string,
  destAddress: string,
  destDomain: number,
  caller?: string
): Promise<string> => {
  // Set allowance for the userAddress
  const txReceipt1 = await contractDefinition.usdcContract.methods
    .approve(contractDefinition.tokenMessengerContractAddress, USDC_AMOUNT)
    .send({ from: userAddress });
  expect(txReceipt1.status).toBe(BigInt(1));;

  const paddedDestAddress = contractDefinition.web3.utils.padLeft(destAddress, 64);

  let txReceipt2: TransactionReceipt;

  // If a destination caller is provided, call depositForBurnWithCaller.
  if (caller) {
    txReceipt2 = await contractDefinition.tokenMessengerContract.methods
      .depositForBurnWithCaller(USDC_AMOUNT, destDomain, paddedDestAddress, contractDefinition.usdcContractAddress, caller)
      .send({ from: userAddress });
  } else {
    txReceipt2 = await contractDefinition.tokenMessengerContract.methods
      .depositForBurn(USDC_AMOUNT, destDomain, paddedDestAddress, contractDefinition.usdcContractAddress)
      .send({ from: userAddress });
  }
  expect(txReceipt2.status).toBe(BigInt(1));

  return fetchEvmMessage(contractDefinition, txReceipt2);
};

// Receives a message on the given EVM chain.
const receiveEvm = async (
  contractDefinition: EvmContractDefinition,
  userAddress: string,
  message: Buffer,
  attestation: string
): Promise<void> => {
  const destinationTxReceipt: TransactionReceipt = await contractDefinition.messageTransmitterContract.methods
    .receiveMessage(message, attestation)
    .send({ from: userAddress });

  const destinationLogs = await contractDefinition.messageTransmitterContract.getPastEvents("MessageReceived", {
    fromBlock: destinationTxReceipt.blockNumber,
    toBlock: destinationTxReceipt.blockNumber,
  });
  expect(destinationLogs.length).toBeGreaterThan(0);
};

// Executes a depositForBurn tx from Sui. Returns the message as a buffer.
const generateSuiBurn = async (
  contractDefinition: SuiContractDefinition,
  mintRecipient: string,
  caller?: string
): Promise<Buffer> => {
  // Create DepositForBurn tx
  const depositForBurnTx = new Transaction();

  // Split 1 unit of USDC to send in depositForBurn call
  const [coin] = depositForBurnTx.splitCoins(
    contractDefinition.usdcFundsObjectId,
    [USDC_AMOUNT]
  );

  // If destination caller is provided, call deposit_for_burn_with_caller
  if (caller) {
    depositForBurnTx.moveCall({
      target: `${contractDefinition.tokenMessengerMinterId}::deposit_for_burn::deposit_for_burn_with_caller`,
      arguments: [
        depositForBurnTx.object(coin), // Coin<USDC>
        depositForBurnTx.pure.u32(0), // destination_domain
        depositForBurnTx.pure.address(mintRecipient), // mint_recipient
        depositForBurnTx.pure.address(caller), // destination_caller
        depositForBurnTx.object(contractDefinition.tokenMessengerMinterStateId), // token_messenger_minter state
        depositForBurnTx.object(contractDefinition.messageTransmitterStateId), // message_transmitter state
        depositForBurnTx.object("0x403"), // deny_list id, fixed address
        depositForBurnTx.object(contractDefinition.treasuryId) // treasury object Treasury<USDC>
      ],
      typeArguments: [`${contractDefinition.usdcId}::usdc::USDC`],
    });
  } else {
    depositForBurnTx.moveCall({
      target: `${contractDefinition.tokenMessengerMinterId}::deposit_for_burn::deposit_for_burn`,
      arguments: [
        depositForBurnTx.object(coin), // Coin<USDC>
        depositForBurnTx.pure.u32(0), // destination_domain
        depositForBurnTx.pure.address(mintRecipient), // mint_recipient
        depositForBurnTx.object(contractDefinition.tokenMessengerMinterStateId), // token_messenger_minter state
        depositForBurnTx.object(contractDefinition.messageTransmitterStateId), // message_transmitter state
        depositForBurnTx.object("0x403"), // deny_list id, fixed address
        depositForBurnTx.object(contractDefinition.treasuryId) // treasury object Treasury<USDC>
      ],
      typeArguments: [`${contractDefinition.usdcId}::usdc::USDC`],
    });
  }

  const depositForBurnOutput = await executeTransactionHelper({
    client: contractDefinition.client,
    signer: contractDefinition.signer,
    transaction: depositForBurnTx,
  });

  // Validate that the expected balance change occurred.
  // Requires recasting the change owner as `any` due to lack of type compatiblity.
  expect(depositForBurnOutput.balanceChanges?.filter((balanceChange) => {
    return (
      balanceChange.coinType == `${contractDefinition.usdcId}::usdc::USDC`
      && Number(balanceChange.amount) == -1
      && Object.prototype.hasOwnProperty.call(balanceChange.owner, "AddressOwner")
      && (balanceChange.owner as any).AddressOwner == contractDefinition.signer.toSuiAddress()
    );
  }).length).toBe(1);

  const message: Uint8Array = (depositForBurnOutput.events?.find((event) => 
    event.type.includes("send_message::MessageSent")
  )?.parsedJson as any).message;

  return Buffer.from(message);
}

// Executes a receiveMessage tx on Sui.
const receiveSui = async (
  contractDefinition: SuiContractDefinition,
  message: Buffer,
  attestation: string,
): Promise<void> => {
  // Create receiveMessage PTB
  const receiveMessageTx = new Transaction();

  // Add receive_message call
  const [receipt] = receiveMessageTx.moveCall({
    target: `${contractDefinition.messageTransmitterId}::receive_message::receive_message`,
    arguments: [
      receiveMessageTx.pure.vector("u8", message), // message
      receiveMessageTx.pure.vector("u8", Buffer.from(attestation.replace("0x", ""), "hex")), // attestation as byte array
      receiveMessageTx.object(contractDefinition.messageTransmitterStateId) // message_transmitter state
    ]
  });

  // Add handle_receive_message call
  const [stampedReceipt] = receiveMessageTx.moveCall({
    target: `${contractDefinition.tokenMessengerMinterId}::handle_receive_message::handle_receive_message`,
    arguments: [
      receipt, // Receipt object returned from receive_message call
      receiveMessageTx.object(contractDefinition.tokenMessengerMinterStateId), // token_messenger_minter state
      receiveMessageTx.object(contractDefinition.messageTransmitterStateId), // message_transmitter state
      receiveMessageTx.object("0x403"), // deny list, fixed address
      receiveMessageTx.object(contractDefinition.treasuryId), // usdc treasury object Treasury<T>
    ],
    typeArguments: [`${contractDefinition.usdcId}::usdc::USDC`],
  })

  // Add complete_receive_message call
  receiveMessageTx.moveCall({
    target: `${contractDefinition.messageTransmitterId}::receive_message::complete_receive_message`,
    arguments: [
      stampedReceipt, // Stamped receipt object returned from handle_receive_message call
      receiveMessageTx.object(contractDefinition.messageTransmitterStateId) // message_transmitter state
    ]
  })

  // Manually set the gas budget. This is sometimes required
  // for PTBs that pass objects between transaction calls.
  receiveMessageTx.setGasBudget(GAS_BUDGET);

  const receiveMessageOutput = await executeTransactionHelper({
    client: contractDefinition.client,
    signer: contractDefinition.signer,
    transaction: receiveMessageTx,
  });

  // Validate that the expected balance change occurred.
  // Requires recasting the change owner as `any` due to lack of type compatiblity.
  expect(receiveMessageOutput.balanceChanges?.filter((balanceChange) => {
    return (
      balanceChange.coinType == `${contractDefinition.usdcId}::usdc::USDC`
      && Number(balanceChange.amount) == 1
      && Object.prototype.hasOwnProperty.call(balanceChange.owner, "AddressOwner")
      && (balanceChange.owner as any).AddressOwner == contractDefinition.signer.toSuiAddress()
    );
  }).length).toBe(1);
}

// Given a hex-encoded message, produces an attestation.
const attestToMessage = (
  web3: Web3,
  messageHex: string,
): string => {
  // Create an attestation using the initialized Anvil keypair
  const attesterPrivateKey = "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97";

  const messageHash = web3.utils.keccak256(messageHex);
  const signedMessage = ethutil.ecsign(ethutil.toBuffer(messageHash), ethutil.toBuffer(attesterPrivateKey));
  const attestation = ethutil.toRpcSig(signedMessage.v, signedMessage.r, signedMessage.s);
  
  return attestation;
}

// Fetches an EVM message body from event logs.
const fetchEvmMessage = async (
  contractDefinition: EvmContractDefinition,
  txReceipt: TransactionReceipt
): Promise<string> => {
  let logs: any = [];

  await waitForExpect(async () => {
    logs = await contractDefinition.messageTransmitterContract.getPastEvents("MessageSent", {
      fromBlock: txReceipt.blockNumber,
      toBlock: txReceipt.blockNumber
    });
    expect(logs.length).toBeGreaterThan(0);
  }, 90_000);

  return String((logs[0] as EventLog).returnValues.message);
}
