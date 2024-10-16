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
import { Transaction } from "@mysten/sui/transactions";

import dotenv from "dotenv";
import fs from "fs";
import { EventLog, Web3 } from "web3";

import { attestToMessage, executeTransactionHelper, fetchUsdcBalance, generateEvmBurn, getEd25519KeypairFromPrivateKey } from "../sui-scripts/helpers";

dotenv.config();
dotenv.config({ path: 'test_config.env'});

const USDC_AMOUNT = 1;
const GAS_BUDGET = 1_000_000_000;
const evmUserAddress = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";

// Ids taken from test_config.env from local deployment
const messageTransmitterId = process.env.SUI_MESSAGE_TRANSMITTER_ID as string;
const messageTransmitterStateId = process.env.SUI_MESSAGE_TRANSMITTER_STATE_ID as string;
const tokenMessengerMinterId = process.env.SUI_TOKEN_MESSENGER_MINTER_ID as string;
const tokenMessengerMinterStateId = process.env.SUI_TOKEN_MESSENGER_MINTER_STATE_ID as string;
const usdcId = process.env.SUI_USDC_ID as string;
const treasuryId = process.env.SUI_TREASURY_ID as string;
const suiPrivateKey = process.env.SUI_DEPLOYER_KEY as string;
const signer = getEd25519KeypairFromPrivateKey(suiPrivateKey);

const FULLNODE_PORT = process.env.FULLNODE_PORT ?? "7000";
const SUI_RPC_URL = process.env.SUI_RPC_URL ?? `http://localhost:${FULLNODE_PORT}`;
const EVM_RPC_URL = process.env.EVM_RPC_URL ?? "http://localhost:8500";

/**
 * This script shows an example of transferring USDC from EVM to Sui using the receive_message call on localnet.
 * The same example can be followed on testnet/mainnet with appropriate addresses, RPC URLs, and calling out 
 * to Circle's attestation service for the message attestation.
 * 
 * Local addresses are fetched from env vars from .env and test_config.env files after contract deployment using `yarn deploy-local`.
 */
const main = async () => {
  // EVM setup
  const web3 = new Web3(new Web3.providers.HttpProvider(EVM_RPC_URL));
  const evmMessageTransmitterAddress = `${process.env.EVM_MESSAGE_TRANSMITTER_ADDRESS}`;
  const evmTokenMessengerAddress = `${process.env.EVM_TOKEN_MESSENGER_ADDRESS}`;
  const evmUsdcAddress = `${process.env.EVM_USDC_ADDRESS}`;
  const messageTransmitterInterface = JSON.parse(
    fs.readFileSync("../evm-cctp-contracts/cctp-interfaces/MessageTransmitter.sol/MessageTransmitter.json").toString()
  );
  const tokenMessengerInterface = JSON.parse(
    fs.readFileSync("../evm-cctp-contracts/cctp-interfaces/TokenMessenger.sol/TokenMessenger.json").toString()
  );
  const usdcInterface = JSON.parse(
    fs.readFileSync("../evm-cctp-contracts/usdc-interfaces/FiatTokenV2_1.sol/FiatTokenV2_1.json").toString()
  );
  const messageTransmitterContract = new web3.eth.Contract(
    messageTransmitterInterface.abi,
    evmMessageTransmitterAddress
  );
  const tokenMessengerContract = new web3.eth.Contract(
    tokenMessengerInterface.abi,
    evmTokenMessengerAddress
  );
  const usdcContract = new web3.eth.Contract(
    usdcInterface.abi,
    evmUsdcAddress
  )

  // Sui setup 
  const client = new SuiClient({ url: SUI_RPC_URL});

  // 1. Start the transfer with depositForBurn on the EVM chain.
  console.log("Broadcasting evm depositForBurn tx...");
  const evmBurnTx = await generateEvmBurn(
    web3,
    messageTransmitterContract,
    tokenMessengerContract,
    usdcContract,
    evmTokenMessengerAddress,
    evmUsdcAddress,
    evmUserAddress,
    "0xf6152a5005ff4c7bcb25021a12a988073970b9e2f12e68c54957e8baacb9b8b4",
    8,
    USDC_AMOUNT
  )
  console.log(`depositForBurn transaction successful: ${evmBurnTx.tx.transactionHash} \n`);

  const logs = await tokenMessengerContract.getPastEvents("DepositForBurn", {
    fromBlock: evmBurnTx.tx.blockNumber,
    toBlock: evmBurnTx.tx.blockNumber
  });
  const evmBalanceChangeAddress = (logs[0] as EventLog).returnValues.depositor as string;
  const evmBalanceAmount = (logs[0] as EventLog).returnValues.amount;
  const evmUsdcBalance = await fetchUsdcBalance(web3, evmBalanceChangeAddress);
  const messageHash = web3.utils.keccak256(evmBurnTx.message);

  console.log(`Message hash: ${messageHash}`);

  // 2. Attest to the message
  // On testnet/mainnet this would fetch the message from the attestation service.
  // Since this is on localnet, sign it locally with a dummy attester address.
  const attestation = attestToMessage(web3, evmBurnTx.message);
  console.log(`Signed attestation locally: ${attestation} \n`);

  // 3. Receive the message on the destination chain
  // Create receiveMessage PTB
  const receiveMessageTx = new Transaction();

  // Add receive_message call
  const [receipt] = receiveMessageTx.moveCall({
    target: `${messageTransmitterId}::receive_message::receive_message`,
    arguments: [
      receiveMessageTx.pure.vector("u8", Buffer.from(evmBurnTx.message.replace("0x", ""), "hex")), // message as byte array
      receiveMessageTx.pure.vector("u8", Buffer.from(attestation.replace("0x", ""), "hex")), // attestation as byte array
      receiveMessageTx.object(messageTransmitterStateId) // message_transmitter state
    ]
  });

  // Add handle_receive_message call
  const [stampedReceipt] = receiveMessageTx.moveCall({
    target: `${tokenMessengerMinterId}::handle_receive_message::handle_receive_message`,
    arguments: [
      receipt, // Receipt object returned from receive_message call
      receiveMessageTx.object(tokenMessengerMinterStateId), // token_messenger_minter state
      receiveMessageTx.object(messageTransmitterStateId), // message_transmitter state
      receiveMessageTx.object("0x403"), // deny list, fixed address
      receiveMessageTx.object(treasuryId), // usdc treasury object Treasury<T>
    ],
    typeArguments: [`${usdcId}::usdc::USDC`],
  })

  // Add complete_receive_message call
  receiveMessageTx.moveCall({
    target: `${messageTransmitterId}::receive_message::complete_receive_message`,
    arguments: [
      stampedReceipt, // Stamped receipt object returned from handle_receive_message call
      receiveMessageTx.object(messageTransmitterStateId) // message_transmitter state
    ]
  })

  // Manually set the gas budget. This is sometimes required
  // for PTBs that pass objects between transaction calls.
  receiveMessageTx.setGasBudget(GAS_BUDGET);
  
  console.log("Broadcasting Sui receive_message tx...");
  const receiveMessageOutput = await executeTransactionHelper({
    client: client,
    signer: signer,
    transaction: receiveMessageTx,
  });

  console.log(`receive_message transaction successful: 0x${receiveMessageOutput.digest} \n`);

  const suiUsdcBalanceChange = receiveMessageOutput.balanceChanges?.find(b => b.coinType.includes(usdcId))
  const balances = await client.getAllBalances({ owner: signer.toSuiAddress() });
  const usdcBalance = balances.find(b => b.coinType.includes(usdcId))?.totalBalance;

  console.log("USDC Transfer from Sui -> EVM successful:");
  console.log(`EVM address: ${evmBalanceChangeAddress}, change: -${evmBalanceAmount}, current balance: ${evmUsdcBalance}`);
  console.log(`Sui address: ${(suiUsdcBalanceChange?.owner as any).AddressOwner}, change: +${suiUsdcBalanceChange?.amount}, current balance: ${usdcBalance}`);
}


main();
