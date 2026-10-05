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
 * CCTP V2 message serialization helpers.
 *
 * The Sui V2 E2E suite mirrors the Aptos V2 approach: rather than running a live
 * EVM node, inbound (EVM -> Sui) messages are hand-serialized in TypeScript,
 * signed locally with the dummy attester key, and submitted to the Sui V2
 * receive/mint path. This module produces the CCTP V2 wire bytes.
 *
 * The layout below is confirmed identical across three independent sources:
 *   - EVM V2 Solidity: evm-cctp-contracts/src/messages/v2/{MessageV2,BurnMessageV2}.sol
 *   - Sui Move: message_transmitter_v2/sources/message/message.move,
 *               token_messenger_minter_v2/sources/burn_message.move
 *   - Aptos: aptos-cctp-private/e2e/test_v2/e2e.test.ts
 *
 * All fields are big-endian; addresses / bytes32 are left-padded to 32 bytes;
 * uints are left-padded to their field width.
 *
 * Outer message (148-byte header + body):
 *   version(u32,4) | sourceDomain(u32,4) | destinationDomain(u32,4) |
 *   nonce(u256,32) | sender(32) | recipient(32) | destinationCaller(32) |
 *   minFinalityThreshold(u32,4) | finalityThresholdExecuted(u32,4) | messageBody(dynamic)
 *
 * Inner burn body (228-byte header + hook):
 *   version(u32,4) | burnToken(32) | mintRecipient(32) | amount(u256,32) |
 *   messageSender(32) | maxFee(u256,32) | feeExecuted(u256,32) |
 *   expirationBlock(u256,32) | hookData(dynamic, no length prefix)
 */

import { keccak256 } from "ethereumjs-util";

// Serialize a u32 value to big-endian bytes (4 bytes).
export function serializeU32(value: number): Uint8Array {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new Error(`serializeU32: value out of u32 range: ${value}`);
  }
  const buffer = new ArrayBuffer(4);
  new DataView(buffer).setUint32(0, value, false /* big-endian */);
  return new Uint8Array(buffer);
}

const U256_MAX = (BigInt(1) << BigInt(256)) - BigInt(1);

// Serialize a u256 value to big-endian bytes (32 bytes).
export function serializeU256(value: bigint): Uint8Array {
  if (value < BigInt(0) || value > U256_MAX) {
    throw new Error(`serializeU256: value out of u256 range: ${value}`);
  }
  const hex = value.toString(16).padStart(64, "0");
  const bytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

// Serialize an address to bytes (32 bytes, left-padded). Accepts either a
// 20-byte EVM address or a 32-byte Sui address; both become a 32-byte word with
// the address in the least-significant (rightmost) bytes.
export function serializeAddress(address: string): Uint8Array {
  const normalized = address.replace(/^0x/, "").toLowerCase();
  if (!/^[0-9a-f]*$/.test(normalized) || normalized.length > 64) {
    throw new Error(`serializeAddress: invalid address: ${address}`);
  }
  const padded = normalized.padStart(64, "0");
  const bytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    bytes[i] = parseInt(padded.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

// Concatenate byte arrays into a single Uint8Array.
function concat(parts: Uint8Array[]): Uint8Array {
  const totalLength = parts.reduce((sum, arr) => sum + arr.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export interface BurnMessageV2Params {
  version: number;
  burnToken: string;
  mintRecipient: string;
  amount: bigint;
  messageSender: string;
  maxFee: bigint;
  feeExecuted?: bigint;
  expirationBlock?: bigint;
  hookData?: Uint8Array;
}

// Serialize a CCTP V2 burn message body (the inner `messageBody`).
export function serializeBurnMessageV2(
  params: BurnMessageV2Params,
): Uint8Array {
  const parts: Uint8Array[] = [
    serializeU32(params.version),
    serializeAddress(params.burnToken),
    serializeAddress(params.mintRecipient),
    serializeU256(params.amount),
    serializeAddress(params.messageSender),
    serializeU256(params.maxFee),
    serializeU256(params.feeExecuted ?? BigInt(0)),
    serializeU256(params.expirationBlock ?? BigInt(0)),
  ];

  // hookData is appended raw with no length prefix; its length is implied by
  // the total message length.
  if (params.hookData && params.hookData.length > 0) {
    parts.push(params.hookData);
  }

  return concat(parts);
}

export interface MessageV2Params {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  nonce: bigint;
  sender: string;
  recipient: string;
  destinationCaller: string;
  minFinalityThreshold: number;
  finalityThresholdExecuted?: number;
  messageBody: Uint8Array;
}

// Serialize a CCTP V2 outer message (envelope + body).
export function serializeMessageV2(params: MessageV2Params): Uint8Array {
  return concat([
    serializeU32(params.version),
    serializeU32(params.sourceDomain),
    serializeU32(params.destinationDomain),
    serializeU256(params.nonce),
    serializeAddress(params.sender),
    serializeAddress(params.recipient),
    serializeAddress(params.destinationCaller),
    serializeU32(params.minFinalityThreshold),
    serializeU32(params.finalityThresholdExecuted ?? 0),
    params.messageBody,
  ]);
}

// Convenience: hex-encode bytes (no 0x prefix).
export function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

/**
 * Compute the auth-caller identifier of a Move `Auth` struct, mirroring
 * `message_transmitter_v2::auth::auth_caller_identifier` — the keccak256 hash of
 * the full type name `<32-byte-package-id>::<module>::<struct>` (address as 64
 * lowercase hex chars, no 0x prefix). This is what an inbound message's
 * `recipient` field must equal for the mint path (the MessageTransmitterAuthenticator).
 */
export function authCallerIdentifier(
  packageId: string,
  moduleName: string,
  structName: string,
): string {
  const paddedPackageId = packageId.replace(/^0x/, "").padStart(64, "0");
  const typeName = `${paddedPackageId}::${moduleName}::${structName}`;
  return "0x" + keccak256(Buffer.from(typeName, "ascii")).toString("hex");
}

// The recipient an inbound CCTP V2 message must target for the USDC mint path:
// the auth-caller identifier of the TMM's MessageTransmitterAuthenticator.
export function messageTransmitterAuthRecipient(
  tmmV2PackageId: string,
): string {
  return authCallerIdentifier(
    tmmV2PackageId,
    "message_transmitter_authenticator",
    "MessageTransmitterAuthenticator",
  );
}
