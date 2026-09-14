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
 * CCTP V2 PTB builders for the Sui side of the bridge E2E.
 *
 * Burn (Sui -> EVM) — 3-call PTB:
 *   1. TMM `deposit_for_burn` -> `BurnReceipt<USDC>` + coin.
 *   2. `stablecoin_handler::handler::burn` burns the coin and returns a
 *      `CompleteBurnTicket<USDC, Auth>`.
 *   3. TMM `complete_burn` consumes the ticket, sends the MT
 *      message, emits `DepositForBurn`.
 *
 * Receive (EVM -> Sui) — 3-call PTB:
 *   1. MT `receive_message` -> `Receipt`.
 *   2. TMM `prepare_mint<USDC>` -> `MintReceipt<USDC>`.
 *   3. `handler::mint` mints via the handler's MintCap and returns a
 *      `CompleteMintTicket<USDC, Auth>`, which is fed into TMM
 *      `complete_mint`.
 */

import {
  Transaction,
  TransactionObjectArgument,
} from "@mysten/sui/transactions";

import {
  messageTransmitterAuthRecipient,
  serializeBurnMessageV2,
  serializeMessageV2,
} from "./messageV2";
import {
  CLOCK_ID,
  DENY_LIST_ID,
  REMOTE_EVM_DOMAIN,
  SUI_LOCAL_DOMAIN,
  V2_MESSAGE_BODY_VERSION,
  V2_MESSAGE_VERSION,
} from "./constants";

// Object ids + package ids for the deployed V2 contracts, from test_config.v2.env.
export interface CctpV2Config {
  mtV2PackageId: string;
  mtV2StateId: string;
  tmmV2PackageId: string;
  tmmV2StateId: string;
  handlerPackageId: string;
  handlerStateId: string;
  usdcPackageId: string;
  treasuryId: string;
}

// The remote (EVM) identifiers the deploy registered on the Sui side. Under the
// Aptos-mirror model there is no live EVM node; these are the values that
// `configureCCTPV2Contracts` registered as the remote token messenger / token,
// which a synthesized inbound message must match to be accepted.
export interface RemoteEvmConfig {
  sourceDomain: number;
  remoteTokenMessenger: string;
  remoteUsdc: string;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

export function loadV2ConfigFromEnv(): CctpV2Config {
  return {
    mtV2PackageId: requireEnv("SUI_MESSAGE_TRANSMITTER_V2_ID"),
    mtV2StateId: requireEnv("SUI_MESSAGE_TRANSMITTER_V2_STATE_ID"),
    tmmV2PackageId: requireEnv("SUI_TOKEN_MESSENGER_MINTER_V2_ID"),
    tmmV2StateId: requireEnv("SUI_TOKEN_MESSENGER_MINTER_V2_STATE_ID"),
    handlerPackageId: requireEnv("SUI_STABLECOIN_HANDLER_ID"),
    handlerStateId: requireEnv("SUI_STABLECOIN_HANDLER_STATE_ID"),
    usdcPackageId: requireEnv("SUI_USDC_ID"),
    treasuryId: requireEnv("SUI_TREASURY_ID"),
  };
}

export function loadRemoteEvmConfigFromEnv(): RemoteEvmConfig {
  return {
    sourceDomain: REMOTE_EVM_DOMAIN,
    remoteTokenMessenger: requireEnv("EVM_TOKEN_MESSENGER_ADDRESS"),
    remoteUsdc: requireEnv("EVM_USDC_ADDRESS"),
  };
}

export function usdcType(cfg: CctpV2Config): string {
  return `${cfg.usdcPackageId}::usdc::USDC`;
}

export interface DepositForBurnV2Params {
  destinationDomain: number;
  mintRecipient: string;
  destinationCaller?: string;
  maxFee: bigint;
  minFinalityThreshold: number;
  hookData?: Uint8Array;
}

/**
 * Add the 3-call V2 burn to a transaction. `coin` is a `Coin<USDC>` argument
 * (e.g. the result of `tx.splitCoins`).
 */
export function addDepositForBurnV2(
  tx: Transaction,
  cfg: CctpV2Config,
  coin: TransactionObjectArgument,
  params: DepositForBurnV2Params,
): void {
  const [burnReceipt, returnedCoin] = tx.moveCall({
    target: `${cfg.tmmV2PackageId}::deposit_for_burn::deposit_for_burn`,
    arguments: [
      coin,
      tx.pure.u32(params.destinationDomain),
      tx.pure.address(params.mintRecipient),
      tx.pure.address(params.destinationCaller ?? "0x0"),
      tx.pure.u256(params.maxFee),
      tx.pure.u32(params.minFinalityThreshold),
      tx.pure.vector("u8", Array.from(params.hookData ?? new Uint8Array())),
      tx.object(cfg.tmmV2StateId),
    ],
    typeArguments: [usdcType(cfg)],
  });

  const [completeBurnTicket] = tx.moveCall({
    target: `${cfg.handlerPackageId}::handler::burn`,
    arguments: [
      tx.object(cfg.handlerStateId),
      burnReceipt,
      returnedCoin,
      tx.object(DENY_LIST_ID),
      tx.object(cfg.treasuryId),
    ],
  });

  tx.moveCall({
    target: `${cfg.tmmV2PackageId}::deposit_for_burn::complete_burn`,
    arguments: [
      completeBurnTicket,
      tx.object(cfg.tmmV2StateId),
      tx.object(cfg.mtV2StateId),
    ],
    typeArguments: [usdcType(cfg), `${cfg.handlerPackageId}::handler::Auth`],
  });
}

/**
 * Add the 3-call V2 receive/mint to a transaction, given the raw message and
 * attestation bytes.
 */
export function addReceiveV2(
  tx: Transaction,
  cfg: CctpV2Config,
  message: Uint8Array,
  attestation: Uint8Array,
): void {
  const [receipt] = tx.moveCall({
    target: `${cfg.mtV2PackageId}::receive_message::receive_message`,
    arguments: [
      tx.pure.vector("u8", Array.from(message)),
      tx.pure.vector("u8", Array.from(attestation)),
      tx.object(cfg.mtV2StateId),
    ],
  });

  const [mintReceipt] = tx.moveCall({
    target: `${cfg.tmmV2PackageId}::handle_receive_message::prepare_mint`,
    arguments: [receipt, tx.object(cfg.tmmV2StateId), tx.object(CLOCK_ID)],
    typeArguments: [usdcType(cfg)],
  });

  const [completeMintTicket] = tx.moveCall({
    target: `${cfg.handlerPackageId}::handler::mint`,
    arguments: [
      tx.object(cfg.handlerStateId),
      mintReceipt,
      tx.object(cfg.tmmV2StateId),
      tx.object(cfg.treasuryId),
      tx.object(DENY_LIST_ID),
    ],
  });

  tx.moveCall({
    target: `${cfg.tmmV2PackageId}::handle_receive_message::complete_mint`,
    arguments: [
      completeMintTicket,
      tx.object(cfg.tmmV2StateId),
      tx.object(cfg.mtV2StateId),
    ],
    typeArguments: [usdcType(cfg), `${cfg.handlerPackageId}::handler::Auth`],
  });
}

export interface InboundMessageOpts {
  nonce: bigint;
  mintRecipient: string;
  amount: bigint;
  // Acceptance-critical fields default to the deploy-registered / valid values.
  sourceDomain?: number;
  destinationDomain?: number;
  destinationCaller?: string;
  minFinalityThreshold?: number;
  finalityThresholdExecuted?: number;
  messageSender?: string;
  maxFee?: bigint;
  feeExecuted?: bigint;
  expirationBlock?: bigint;
  hookData?: Uint8Array;
  // Overrides for negative tests (e.g. wrong burn token / recipient).
  burnTokenOverride?: string;
  recipientOverride?: string;
  senderOverride?: string;
}

/**
 * Build the wire bytes for a synthesized inbound (EVM -> Sui) burn message that
 * satisfies the V2 receive/mint acceptance rules by default:
 *  - sender == the deploy-registered remote token messenger
 *  - recipient == the MessageTransmitterAuthenticator auth-caller identifier
 *  - burnToken == the deploy-registered remote USDC
 *  - destinationDomain == the Sui local domain
 *  - finalityThresholdExecuted >= 500
 * Individual fields can be overridden for negative / edge-case scenarios.
 */
export function buildInboundBurnMessageBytes(
  cfg: CctpV2Config,
  remote: RemoteEvmConfig,
  opts: InboundMessageOpts,
): Uint8Array {
  const messageSender =
    opts.messageSender ?? "0x1234567890123456789012345678901234567890";

  const body = serializeBurnMessageV2({
    version: V2_MESSAGE_BODY_VERSION,
    burnToken: opts.burnTokenOverride ?? remote.remoteUsdc,
    mintRecipient: opts.mintRecipient,
    amount: opts.amount,
    messageSender,
    maxFee: opts.maxFee ?? BigInt(0),
    feeExecuted: opts.feeExecuted ?? BigInt(0),
    expirationBlock: opts.expirationBlock ?? BigInt(0),
    hookData: opts.hookData,
  });

  return serializeMessageV2({
    version: V2_MESSAGE_VERSION,
    sourceDomain: opts.sourceDomain ?? remote.sourceDomain,
    destinationDomain: opts.destinationDomain ?? SUI_LOCAL_DOMAIN,
    nonce: opts.nonce,
    sender: opts.senderOverride ?? remote.remoteTokenMessenger,
    recipient:
      opts.recipientOverride ??
      messageTransmitterAuthRecipient(cfg.tmmV2PackageId),
    destinationCaller: opts.destinationCaller ?? "0x0",
    minFinalityThreshold: opts.minFinalityThreshold ?? 500,
    finalityThresholdExecuted: opts.finalityThresholdExecuted ?? 2000,
    messageBody: body,
  });
}
