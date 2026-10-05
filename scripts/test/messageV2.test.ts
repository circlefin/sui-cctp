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

import {
  ecrecover,
  ecsign,
  keccak256,
  privateToAddress,
  pubToAddress,
  toRpcSig,
} from "ethereumjs-util";

import {
  authCallerIdentifier,
  serializeBurnMessageV2,
  serializeMessageV2,
  toHex,
} from "../sui/messageV2";

/**
 * Offline validation of the CCTP V2 serializers against golden byte-vectors
 * taken verbatim from the on-chain Move test fixtures and the EVM V2 Solidity
 * integration test. This runs without any node and proves the serialization
 * layer produces spec-correct wire bytes before the live E2E is ever run.
 */
describe("CCTP V2 message serialization (golden vectors)", () => {
  // token_messenger_minter_v2/sources/burn_message.move :: get_raw_test_message()
  // (canonical 228-byte body, empty hookData, feeExecuted = 0, expirationBlock = 0)
  const BURN_MESSAGE_FIXTURE =
    "000000010000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

  // message_transmitter_v2/sources/message/message.move :: MESSAGE_BODY const
  // (opaque 132-byte body used by the outer-envelope fixture)
  const OUTER_MESSAGE_BODY =
    "000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1";

  // message_transmitter_v2/sources/message/message.move :: get_raw_test_message()
  const OUTER_MESSAGE_FIXTURE =
    "00000001000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000009f3b8679c73c2fef8b59b4f3444d4e156fb70aa5000000000000000000000000eb08f243e5d3fcff26a9e38ae5520a669f4019d00000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c9605000003e800000000000000000000000000000000000000001c7d4b196cb0c7b01d743fbc6116a902379c72380000000000000000000000001f26414439c8d03fc4b9ca912cefd5cb508c960500000000000000000000000000000000000000000000000000000000000004be0000000000000000000000003b61abee91852714e4e99b09a1af3e9c13893ef1";

  // evm-cctp-contracts/test/v2/TokenMessengerV2IT.t.sol :: _localMessageSent()
  // 376-byte message: 148-byte MessageV2 header + 228-byte BurnMessageV2 body (empty hook).
  const EVM_FULL_MESSAGE_FIXTURE =
    // MessageV2 header (148 bytes)
    "00000001" + // version (u32)
    "00000000" + // sourceDomain (u32)
    "00000001" + // destinationDomain (u32)
    "09ac09a5866905247c049066d77ced39929878c828a4198405db6608023c54fb" + // nonce (bytes32)
    "00000000000000000000000093c7a6d00849c44ef3e92e95dceffccd447909ae" + // sender (bytes32)
    "000000000000000000000000ca8b49076d1a8039599e24979abf819af784c27a" + // recipient (bytes32)
    "00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906" + // destinationCaller (bytes32)
    "000003e8" + // minFinalityThreshold (u32, 1000)
    "000003e8" + // finalityThresholdExecuted (u32, 1000)
    // BurnMessageV2 body (228 bytes)
    "00000001" + // body version (u32)
    "00000000000000000000000024fa1f38ffe8be6711872c6e0d662d83e524f0ce" + // burnToken (bytes32)
    "00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906" + // mintRecipient (bytes32)
    "0000000000000000000000000000000000000000000000000000000ba43b7400" + // amount (u256, 50_000_000_000)
    "000000000000000000000000bcd4042de499d14e55001ccbb24a551f3b954096" + // messageSender (bytes32)
    "0000000000000000000000000000000000000000000000000000000002faf080" + // maxFee (u256, 50_000_000)
    "0000000000000000000000000000000000000000000000000000000002faf080" + // feeExecuted (u256, 50_000_000)
    "0000000000000000000000000000000000000000000000000000000000000000"; // expirationBlock (u256, 0)

  test("serializeBurnMessageV2 reproduces the Move burn_message fixture", () => {
    const bytes = serializeBurnMessageV2({
      version: 1,
      burnToken: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
      mintRecipient: "0x1f26414439c8d03fc4b9ca912cefd5cb508c9605",
      amount: BigInt(1214),
      messageSender: "0x3b61abee91852714e4e99b09a1af3e9c13893ef1",
      maxFee: BigInt(0),
      feeExecuted: BigInt(0),
      expirationBlock: BigInt(0),
    });
    expect(bytes.length).toBe(228);
    expect(toHex(bytes)).toBe(BURN_MESSAGE_FIXTURE);
  });

  test("serializeMessageV2 reproduces the Move outer-message fixture", () => {
    const bytes = serializeMessageV2({
      version: 1,
      sourceDomain: 0,
      destinationDomain: 1,
      nonce: BigInt(0),
      sender: "0x9f3b8679c73c2fef8b59b4f3444d4e156fb70aa5",
      recipient: "0xeb08f243e5d3fcff26a9e38ae5520a669f4019d0",
      destinationCaller: "0x1f26414439c8d03fc4b9ca912cefd5cb508c9605",
      minFinalityThreshold: 1000,
      finalityThresholdExecuted: 0,
      messageBody: Buffer.from(OUTER_MESSAGE_BODY, "hex"),
    });
    expect(toHex(bytes)).toBe(OUTER_MESSAGE_FIXTURE);
  });

  test("serializeMessageV2 + serializeBurnMessageV2 reproduce the EVM V2 full-message vector", () => {
    const burnBody = serializeBurnMessageV2({
      version: 1,
      burnToken: "0x24fa1f38ffe8be6711872c6e0d662d83e524f0ce",
      mintRecipient: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
      amount: BigInt("50000000000"),
      messageSender: "0xbcd4042de499d14e55001ccbb24a551f3b954096",
      maxFee: BigInt("50000000"),
      feeExecuted: BigInt("50000000"),
      expirationBlock: BigInt(0),
    });
    const message = serializeMessageV2({
      version: 1,
      sourceDomain: 0,
      destinationDomain: 1,
      nonce: BigInt(
        "0x09ac09a5866905247c049066d77ced39929878c828a4198405db6608023c54fb",
      ),
      sender: "0x93c7a6d00849c44ef3e92e95dceffccd447909ae",
      recipient: "0xca8b49076d1a8039599e24979abf819af784c27a",
      destinationCaller: "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
      minFinalityThreshold: 1000,
      finalityThresholdExecuted: 1000,
      messageBody: burnBody,
    });
    expect(message.length).toBe(376);
    expect(toHex(message)).toBe(EVM_FULL_MESSAGE_FIXTURE);
  });

  // attestation.move HALF_CURVE_ORDER (EIP-2 low-S bound)
  const HALF_CURVE_ORDER = BigInt(
    "0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0",
  );

  // The Sui receive_message.move unit tests sign with the EVM CCTP test attester
  // vm.addr(1) (private key = the integer 1; enrolled as 0x7e5f4552...395bdf). We
  // prove our attestation encoding/recovery matches attestation.move by recovering
  // the signer from their golden (message, attestation) pair: message digest =
  // keccak256(rawBytes), signature = r(32) || s(32) || v(1) with v in {27,28}.
  test("attestation encoding recovers the Move fixture signer (mirrors attestation.move)", () => {
    // receive_message.move :: VALID_MESSAGE
    const validMessage = Buffer.from(
      "0000000100000000000000011a2b3c4d5e6f708192a3b4c5d6e7f80011223344556677889900aabbccddeeff0000000000000000000000000000000000000000000000000000000000000001adfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a0000000000000000000000000000000000000000000000000000000000000000000003e8000007d01234",
      "hex",
    );
    // receive_message.move :: VALID_MESSAGE_ATTESTATION (65-byte r||s||v)
    const attestation = Buffer.from(
      "686e88c3b374aa6ad3e2b1e7a1addd813cf982b814a49c3944e4a8267fa9434d78a83d7274fce1f92d319b70d80a57d188fc4207ed5b6799ce5e32377bffcb611c",
      "hex",
    );
    expect(attestation.length).toBe(65);
    const r = attestation.subarray(0, 32);
    const s = attestation.subarray(32, 64);
    const v = attestation[64];

    const pubKey = ecrecover(keccak256(validMessage), v, r, s);
    const recovered = "0x" + pubToAddress(pubKey).toString("hex");
    expect(recovered).toBe("0x7e5f4552091a69125d5dfcb7b8c2659029395bdf");
  });

  // The E2E suite signs locally with the dummy attester key (helpers.ts
  // attestToMessage). Confirm its address (which the V2 deploy must enable) and
  // that it produces a well-formed, low-S, v in {27,28} 65-byte attestation over
  // a synthesized V2 message.
  test("dummy attester produces a well-formed low-S attestation over a V2 message", () => {
    const dummyPrivateKey = Buffer.from(
      "dbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
      "hex",
    );
    const dummyAddress =
      "0x" + privateToAddress(dummyPrivateKey).toString("hex");
    expect(dummyAddress).toBe("0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f");

    const message = serializeMessageV2({
      version: 1,
      sourceDomain: 0,
      destinationDomain: 8,
      nonce: BigInt(12345),
      sender: "0x1234567890123456789012345678901234567890",
      recipient: "0x9f3b8679c73c2fef8b59b4f3444d4e156fb70aa5",
      destinationCaller: "0x0",
      minFinalityThreshold: 500,
      finalityThresholdExecuted: 2000,
      messageBody: serializeBurnMessageV2({
        version: 1,
        burnToken: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
        mintRecipient: "0x9f3b8679c73c2fef8b59b4f3444d4e156fb70aa5",
        amount: BigInt(1000),
        messageSender: "0x1234567890123456789012345678901234567890",
        maxFee: BigInt(100),
        feeExecuted: BigInt(10),
      }),
    });

    const sig = ecsign(keccak256(Buffer.from(message)), dummyPrivateKey);
    expect([27, 28]).toContain(Number(sig.v));
    expect(BigInt("0x" + sig.s.toString("hex")) <= HALF_CURVE_ORDER).toBe(true);
    const attestationHex = toRpcSig(sig.v, sig.r, sig.s);
    expect(Buffer.from(attestationHex.slice(2), "hex").length).toBe(65);
  });

  // Mirrors message_transmitter_v2::auth_tests::test_auth_caller_identifier_successful:
  // auth_caller_identifier<SendMessageTestAuth>() where the auth type is defined at
  // package 0x…0000. Confirms the inbound `recipient` derivation matches on-chain.
  test("authCallerIdentifier reproduces the Move auth_caller_identifier fixture", () => {
    const identifier = authCallerIdentifier(
      "0x0",
      "message_transmitter_authenticator",
      "SendMessageTestAuth",
    );
    expect(identifier).toBe(
      "0xadfb200041e521016062e20dc613c317681c216d0174606c3243cea2117e5b1a",
    );
  });

  test("hookData is appended raw with no length prefix", () => {
    const hook = Buffer.from("deadbeef", "hex");
    const bytes = serializeBurnMessageV2({
      version: 1,
      burnToken: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
      mintRecipient: "0x1f26414439c8d03fc4b9ca912cefd5cb508c9605",
      amount: BigInt(1214),
      messageSender: "0x3b61abee91852714e4e99b09a1af3e9c13893ef1",
      maxFee: BigInt(1),
      hookData: hook,
    });
    expect(bytes.length).toBe(228 + 4);
    expect(toHex(bytes).endsWith("deadbeef")).toBe(true);
  });
});
