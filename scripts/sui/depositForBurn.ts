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

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";

import dotenv from "dotenv";
import fs from "fs";
import { EventLog, Web3 } from "web3";

import {
  attestToMessage,
  coinTypeMatches,
  eventBytes,
  executeTransactionWithRetry,
  fetchUsdcBalance,
  getEd25519KeypairFromPrivateKey,
  receiveEvm,
  splitCoinForAmount,
} from "./helpers";
import assert from "assert";

dotenv.config();
dotenv.config({ path: "test_config.v1.env" });

const USDC_AMOUNT = 1;
const DESTINATION_DOMAIN = 0;
const evmUserAddress = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";

// Ids taken from test_config.v1.env from local deployment
const messageTransmitterStateId = process.env
  .SUI_MESSAGE_TRANSMITTER_STATE_ID as string;
const tokenMessengerMinterId = process.env
  .SUI_TOKEN_MESSENGER_MINTER_ID as string;
const tokenMessengerMinterStateId = process.env
  .SUI_TOKEN_MESSENGER_MINTER_STATE_ID as string;
const usdcId = process.env.SUI_USDC_ID as string;
const treasuryId = process.env.SUI_TREASURY_ID as string;
const suiPrivateKey = process.env.SUI_DEPLOYER_KEY as string;
const signer = getEd25519KeypairFromPrivateKey(suiPrivateKey);

const FULLNODE_PORT = process.env.FULLNODE_PORT ?? "9001";
const SUI_RPC_URL =
  process.env.SUI_RPC_URL ?? `http://localhost:${FULLNODE_PORT}`;
const EVM_RPC_URL = process.env.EVM_RPC_URL ?? "http://localhost:8500";

/**
 * This script shows an example of transferring USDC from Sui to EVM using the deposit_for_burn call on localnet.
 * The same example can be followed on testnet/mainnet with appropriate addresses, RPC URLs, and calling out
 * to Circle's attestation service for the message attestation.
 *
 * Local addresses are fetched from env vars from .env and test_config.v1.env files after contract deployment using `yarn deploy-local:v1`.
 */
const main = async () => {
  // EVM setup
  const web3 = new Web3(new Web3.providers.HttpProvider(EVM_RPC_URL));
  const evmMessageTransmitterAddress = `${process.env.EVM_MESSAGE_TRANSMITTER_ADDRESS}`;
  const evmTokenMessengerAddress = `${process.env.EVM_TOKEN_MESSENGER_ADDRESS}`;
  const messageTransmitterInterface = JSON.parse(
    fs
      .readFileSync(
        "../evm-cctp-contracts/cctp-interfaces/MessageTransmitter.sol/MessageTransmitter.json",
      )
      .toString(),
  );
  const tokenMessengerInterface = JSON.parse(
    fs
      .readFileSync(
        "../evm-cctp-contracts/cctp-interfaces/TokenMessenger.sol/TokenMessenger.json",
      )
      .toString(),
  );
  const messageTransmitterContract = new web3.eth.Contract(
    messageTransmitterInterface.abi,
    evmMessageTransmitterAddress,
  );
  const tokenMessengerContract = new web3.eth.Contract(
    tokenMessengerInterface.abi,
    evmTokenMessengerAddress,
  );

  // Sui setup
  const client = new SuiGrpcClient({
    network: "localnet",
    baseUrl: SUI_RPC_URL,
  });

  // 1. Call deposit_for_burn on Sui to begin the transfer.
  // The coin selection and the tx build both live inside `buildTransaction` so
  // that a retry re-reads them: splitting from an owned USDC coin advances its
  // version, and a stale ref is rejected at submit time.
  console.log("Broadcasting sui deposit_for_burn tx...");
  const depositForBurnOutput = await executeTransactionWithRetry({
    client,
    signer,
    buildTransaction: async () => {
      const depositForBurnTx = new Transaction();

      // Merge the owner's USDC coins and split 1 USDC for the depositForBurn call.
      const coin = await splitCoinForAmount({
        tx: depositForBurnTx,
        client,
        owner: signer.toSuiAddress(),
        coinType: `${usdcId}::usdc::USDC`,
        amount: USDC_AMOUNT,
      });

      depositForBurnTx.moveCall({
        target: `${tokenMessengerMinterId}::deposit_for_burn::deposit_for_burn`,
        arguments: [
          depositForBurnTx.object(coin), // Coin<USDC>
          depositForBurnTx.pure.u32(DESTINATION_DOMAIN), // destination_domain
          depositForBurnTx.pure.address(evmUserAddress), // mint_recipient
          depositForBurnTx.object(tokenMessengerMinterStateId), // token_messenger_minter state
          depositForBurnTx.object(messageTransmitterStateId), // message_transmitter state
          depositForBurnTx.object("0x403"), // deny_list id, fixed address
          depositForBurnTx.object(treasuryId), // treasury object Treasury<USDC>
        ],
        typeArguments: [`${usdcId}::usdc::USDC`],
      });

      return depositForBurnTx;
    },
  });
  assert(depositForBurnOutput.effects.status.status === "success");
  console.log(
    `deposit_for_burn transaction successful: 0x${depositForBurnOutput.digest} \n`,
  );

  const suiUsdcBalanceChange = depositForBurnOutput.balanceChanges?.find((b) =>
    coinTypeMatches(b.coinType, usdcId),
  );
  // First page of balances; sufficient for the localnet deployer.
  const balances = await client.core.listBalances({
    owner: signer.toSuiAddress(),
  });
  const usdcBalance = balances.balances.find((b) =>
    coinTypeMatches(b.coinType, usdcId),
  )?.balance;

  // Get the message emitted from the tx
  const messageRaw = eventBytes(
    (
      depositForBurnOutput.events?.find((event) =>
        event.type.includes("send_message::MessageSent"),
      )?.parsedJson as { message: unknown }
    ).message,
  );
  const messageBuffer = Buffer.from(messageRaw);
  const messageHex = `0x${messageBuffer.toString("hex")}`;
  console.log(`Message hash: ${web3.utils.keccak256(messageHex)}`);

  // 2. Attest to the message
  // On testnet/mainnet this would fetch the message from the attestation service.
  // Since this is on localnet, sign it locally with a dummy attester address.
  const attestation = attestToMessage(web3, messageHex);
  console.log(`Signed attestation locally: ${attestation} \n`);

  // 3. Receive the message on the destination chain
  console.log("Broadcasting EVM receiveMessage tx...");
  const receiveMessageTx = await receiveEvm(
    messageTransmitterContract,
    evmUserAddress,
    messageBuffer,
    attestation,
  );
  console.log(
    `receiveMessage transaction successful: ${receiveMessageTx.transactionHash} \n`,
  );
  const logs = await tokenMessengerContract.getPastEvents("MintAndWithdraw", {
    fromBlock: receiveMessageTx.blockNumber,
    toBlock: receiveMessageTx.blockNumber,
  });
  const evmBalanceChangeAddress = (logs[0] as EventLog).returnValues
    .mintRecipient as string;
  const evmBalanceAmount = (logs[0] as EventLog).returnValues.amount;
  const evmUsdcBalance = await fetchUsdcBalance(web3, evmBalanceChangeAddress);

  console.log("USDC Transfer from Sui -> EVM successful:");
  console.log(
    `Sui address: ${(suiUsdcBalanceChange?.owner as any).AddressOwner}, change: ${suiUsdcBalanceChange?.amount}, current balance: ${usdcBalance}`,
  );
  console.log(
    `EVM address: ${evmBalanceChangeAddress}, change: +${evmBalanceAmount}, current balance: ${evmUsdcBalance}`,
  );
};

main();
