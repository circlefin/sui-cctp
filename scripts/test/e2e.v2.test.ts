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
import { jest } from "@jest/globals";
import { Transaction } from "@mysten/sui/transactions";

import dotenv from "dotenv";
import { Web3 } from "web3";

import {
  attestToMessage,
  coinTypeMatches,
  eventBytes,
  executeTransactionHelper,
  executeTransactionWithRetry,
  getEd25519KeypairFromPrivateKey,
  normAddr,
  SuiTxResponse,
} from "../sui/helpers";
import {
  messageTransmitterAuthRecipient,
  serializeBurnMessageV2,
  serializeMessageV2,
  toHex,
} from "../sui/messageV2";
import {
  addDepositForBurnV2,
  addReceiveV2,
  buildInboundBurnMessageBytes,
  CctpV2Config,
  InboundMessageOpts,
  loadRemoteEvmConfigFromEnv,
  loadV2ConfigFromEnv,
  RemoteEvmConfig,
  usdcType,
} from "../sui/ptbV2";
import { REMOTE_EVM_DOMAIN, SUI_LOCAL_DOMAIN } from "../sui/constants";
import { expectMoveAbort } from "./helpers";

dotenv.config();
dotenv.config({ path: "test_config.v2.env" });

jest.setTimeout(120_000);

const GAS_BUDGET = 1_000_000_000;
const evmUserAddress = "0xfabb0ac9d68b0b445fb7357272ff202c5651694a";
// A distinct mint recipient (not the deployer/fee recipient) so fee splits are
// observable in balance changes.
const altRecipient = "0x" + "0".repeat(60) + "cafe";

/**
 * V2 Sui <-> EVM bridge E2E, mirroring the Aptos V2 approach: no live EVM node.
 * Inbound (EVM -> Sui) messages are synthesized in TypeScript and signed with
 * the local dummy attester; outbound (Sui -> EVM) burns are real and the emitted
 * message is asserted byte-for-byte against the expected TS serialization.
 *
 * Requires a local Sui node with the V2 contracts deployed (`yarn deploy-local:v2`).
 */
describe("V2 E2E bridge tests between EVM and Sui chains", () => {
  let client: SuiGrpcClient;
  let web3: Web3;
  let cfg: CctpV2Config;
  let remote: RemoteEvmConfig;
  let signer: ReturnType<typeof getEd25519KeypairFromPrivateKey>;
  let signerAddress: string;
  let usdcTokenIdV2: string;
  let feeRecipient: string;
  let nonceCounter: bigint;

  beforeAll(() => {
    const rpcUrl =
      process.env.SUI_RPC_URL ??
      `http://localhost:${process.env.FULLNODE_PORT ?? "9001"}`;
    client = new SuiGrpcClient({ network: "localnet", baseUrl: rpcUrl });
    web3 = new Web3();
    cfg = loadV2ConfigFromEnv();
    remote = loadRemoteEvmConfigFromEnv();
    signer = getEd25519KeypairFromPrivateKey(
      process.env.SUI_DEPLOYER_KEY as string,
    );
    signerAddress = signer.toSuiAddress();
    usdcTokenIdV2 = process.env.SUI_USDC_TOKEN_ID_V2 as string;
    feeRecipient = process.env.SUI_FEE_RECIPIENT_ADDRESS as string;
    // Distinct per-message nonces; the replay test intentionally reuses one.
    nonceCounter = BigInt(Date.now()) * BigInt(1_000_000);
  });

  const nextNonce = (): bigint => nonceCounter++;

  // --- helpers ---

  const usdcChangeFor = (output: SuiTxResponse, owner: string): bigint => {
    const change = output.balanceChanges?.find(
      (b) =>
        coinTypeMatches(b.coinType, cfg.usdcPackageId) &&
        (b.owner as { AddressOwner?: string }).AddressOwner === owner,
    );
    return change ? BigInt(change.amount) : BigInt(0);
  };

  // Synthesize + locally attest an inbound message; returns the raw bytes so
  // callers can resubmit the exact same message (e.g. nonce-replay).
  const buildInbound = (
    opts: Omit<InboundMessageOpts, "nonce"> & { nonce?: bigint },
  ): { message: Uint8Array; attestation: Uint8Array } => {
    const message = buildInboundBurnMessageBytes(cfg, remote, {
      nonce: opts.nonce ?? nextNonce(),
      ...opts,
    });
    const attestationHex = attestToMessage(
      web3,
      `0x${Buffer.from(message).toString("hex")}`,
    );
    const attestation = Buffer.from(attestationHex.replace("0x", ""), "hex");
    return { message, attestation };
  };

  const submitReceive = async (
    message: Uint8Array,
    attestation: Uint8Array,
  ): Promise<SuiTxResponse> => {
    const tx = new Transaction();
    addReceiveV2(tx, cfg, message, attestation);
    tx.setGasBudget(GAS_BUDGET);
    return executeTransactionHelper({ client, signer, transaction: tx });
  };

  const burnOutbound = async (params: {
    amount: bigint;
    maxFee?: bigint;
    minFinalityThreshold?: number;
    destinationDomain?: number;
    destinationCaller?: string;
    mintRecipient?: string;
    hookData?: Uint8Array;
  }): Promise<SuiTxResponse> => {
    // Both the coin read and the tx build live INSIDE the builder so that a
    // retry re-reads them. Every burn advances the version of the USDC coin it
    // splits from (and of the auto-selected gas coin), and `waitForTransaction`
    // only guarantees the digest is queryable — not that the fullnode's coin
    // index has caught up. Consecutive burns can therefore pick up a stale ref.
    return executeTransactionWithRetry({
      client,
      signer,
      buildTransaction: async () => {
        // listCoins returns the first page only; sufficient here because the
        // deployer holds a small number of USDC coin objects on localnet.
        const coins = await client.core.listCoins({
          owner: signerAddress,
          coinType: `${cfg.usdcPackageId}::usdc::USDC`,
        });
        const usdc = coins.objects.find(
          (c) =>
            coinTypeMatches(c.type, cfg.usdcPackageId) &&
            BigInt(c.balance) >= params.amount,
        );
        if (!usdc) {
          throw new Error("Insufficient USDC to burn.");
        }
        const tx = new Transaction();
        const [coin] = tx.splitCoins(usdc.objectId, [
          tx.pure.u64(params.amount),
        ]);
        addDepositForBurnV2(tx, cfg, coin, {
          destinationDomain: params.destinationDomain ?? REMOTE_EVM_DOMAIN,
          mintRecipient: params.mintRecipient ?? evmUserAddress,
          destinationCaller: params.destinationCaller,
          maxFee: params.maxFee ?? BigInt(0),
          minFinalityThreshold: params.minFinalityThreshold ?? 2000,
          hookData: params.hookData,
        });
        tx.setGasBudget(GAS_BUDGET);
        return tx;
      },
    });
  };

  const emittedMessageHex = (output: SuiTxResponse): string => {
    const event = output.events?.find((e) =>
      e.type.includes("send_message::MessageSent"),
    );
    const raw = (event?.parsedJson as { message: unknown }).message;
    return toHex(eventBytes(raw));
  };

  // Expected outbound wire bytes: sender = the local MessageTransmitterAuthenticator
  // auth id, recipient = the registered remote token messenger, nonce = 0
  // (assigned off-chain in V2), finalityThresholdExecuted = 0, burnToken = local
  // token id, messageSender = the depositor.
  const expectedOutboundHex = (params: {
    amount: bigint;
    maxFee: bigint;
    minFinalityThreshold: number;
    destinationCaller?: string;
    mintRecipient?: string;
    hookData?: Uint8Array;
  }): string => {
    return toHex(
      serializeMessageV2({
        version: 1,
        sourceDomain: SUI_LOCAL_DOMAIN,
        destinationDomain: REMOTE_EVM_DOMAIN,
        nonce: BigInt(0),
        sender: messageTransmitterAuthRecipient(cfg.tmmV2PackageId),
        recipient: remote.remoteTokenMessenger,
        destinationCaller: params.destinationCaller ?? "0x0",
        minFinalityThreshold: params.minFinalityThreshold,
        finalityThresholdExecuted: 0,
        messageBody: serializeBurnMessageV2({
          version: 1,
          burnToken: usdcTokenIdV2,
          mintRecipient: params.mintRecipient ?? evmUserAddress,
          amount: params.amount,
          messageSender: signerAddress,
          maxFee: params.maxFee,
          feeExecuted: BigInt(0),
          expirationBlock: BigInt(0),
          hookData: params.hookData,
        }),
      }),
    );
  };

  interface DepositForBurnJson {
    burn_token: string;
    amount: string;
    depositor: string;
    mint_recipient: string;
    destination_domain: number;
    destination_token_messenger: string;
    destination_caller: string;
    max_fee: string;
    min_finality_threshold: number;
    hook_data: number[];
  }

  const depositForBurnEvent = (output: SuiTxResponse): DepositForBurnJson => {
    const event = output.events?.find((e) =>
      e.type.includes("deposit_for_burn::DepositForBurn"),
    );
    if (!event) {
      throw new Error("DepositForBurn event not found");
    }
    return event.parsedJson as DepositForBurnJson;
  };

  // Verify an outbound burn end to end: the emitted MessageSent bytes
  // (byte-for-byte, i.e. every field), the depositor's USDC balance decrease,
  // and the DepositForBurn event fields.
  const expectOutbound = (
    output: SuiTxResponse,
    params: {
      amount: bigint;
      maxFee: bigint;
      minFinalityThreshold: number;
      destinationDomain?: number;
      destinationCaller?: string;
      mintRecipient?: string;
      hookData?: Uint8Array;
    },
  ): void => {
    expect(emittedMessageHex(output)).toBe(expectedOutboundHex(params));
    expect(usdcChangeFor(output, signerAddress)).toBe(-params.amount);

    const dfb = depositForBurnEvent(output);
    expect(BigInt(dfb.amount)).toBe(params.amount);
    expect(BigInt(dfb.max_fee)).toBe(params.maxFee);
    expect(Number(dfb.destination_domain)).toBe(
      params.destinationDomain ?? REMOTE_EVM_DOMAIN,
    );
    expect(Number(dfb.min_finality_threshold)).toBe(
      params.minFinalityThreshold,
    );
    expect(normAddr(dfb.depositor)).toBe(normAddr(signerAddress));
    expect(normAddr(dfb.burn_token)).toBe(normAddr(usdcTokenIdV2));
    expect(normAddr(dfb.mint_recipient)).toBe(
      normAddr(params.mintRecipient ?? evmUserAddress),
    );
    expect(normAddr(dfb.destination_caller)).toBe(
      normAddr(params.destinationCaller ?? "0x0"),
    );
    expect(normAddr(dfb.destination_token_messenger)).toBe(
      normAddr(remote.remoteTokenMessenger),
    );
    expect(Buffer.from(eventBytes(dfb.hook_data)).toString("hex")).toBe(
      Buffer.from(params.hookData ?? new Uint8Array()).toString("hex"),
    );
  };

  interface MintAndWithdrawJson {
    mint_recipient: string;
    amount: string;
    mint_token: string;
    fee_collected: string;
  }

  // Verify the inbound mint's MintAndWithdraw event: net amount to the recipient,
  // fee to the fee recipient, and the local mint token.
  const expectMintAndWithdraw = (
    output: SuiTxResponse,
    expected: { mintRecipient: string; amount: bigint; feeCollected: bigint },
  ): void => {
    const event = output.events?.find((e) =>
      e.type.includes("handle_receive_message::MintAndWithdraw"),
    );
    if (!event) {
      throw new Error("MintAndWithdraw event not found");
    }
    const maw = event.parsedJson as MintAndWithdrawJson;
    expect(normAddr(maw.mint_recipient)).toBe(normAddr(expected.mintRecipient));
    expect(BigInt(maw.amount)).toBe(expected.amount);
    expect(BigInt(maw.fee_collected)).toBe(expected.feeCollected);
    expect(normAddr(maw.mint_token)).toBe(normAddr(usdcTokenIdV2));
  };

  const setDenylisted = async (
    addr: string,
    denylisted: boolean,
  ): Promise<void> => {
    const tx = new Transaction();
    tx.moveCall({
      target: `${cfg.tmmV2PackageId}::denylistable::${denylisted ? "denylist" : "un_denylist"}`,
      arguments: [tx.object(cfg.tmmV2StateId), tx.pure.address(addr)],
    });
    await executeTransactionHelper({ client, signer, transaction: tx });
  };

  const setHandlerRegistered = async (registered: boolean): Promise<void> => {
    const tx = new Transaction();
    if (registered) {
      tx.moveCall({
        target: `${cfg.tmmV2PackageId}::handler_registry::register_handler`,
        typeArguments: [`${cfg.handlerPackageId}::handler::Auth`],
        arguments: [
          tx.object(cfg.tmmV2StateId),
          tx.pure.address(usdcTokenIdV2),
        ],
      });
    } else {
      tx.moveCall({
        target: `${cfg.tmmV2PackageId}::handler_registry::deregister_handler`,
        arguments: [
          tx.object(cfg.tmmV2StateId),
          tx.pure.address(usdcTokenIdV2),
        ],
      });
    }
    await executeTransactionHelper({ client, signer, transaction: tx });
  };

  // --- EVM -> Sui (inbound, synthesized messages) ---

  describe("EVM -> Sui", () => {
    test("standard mint (no fee)", async () => {
      const amount = BigInt(1000);
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount,
      });
      const output = await submitReceive(message, attestation);
      expect(usdcChangeFor(output, signerAddress)).toBe(amount);
      expectMintAndWithdraw(output, {
        mintRecipient: signerAddress,
        amount,
        feeCollected: BigInt(0),
      });
    });

    test("mint with fee splits net to recipient and fee to fee_recipient", async () => {
      const amount = BigInt(1000);
      const feeExecuted = BigInt(10);
      const { message, attestation } = buildInbound({
        mintRecipient: altRecipient,
        amount,
        maxFee: BigInt(100),
        feeExecuted,
      });
      const output = await submitReceive(message, attestation);
      expect(usdcChangeFor(output, altRecipient)).toBe(amount - feeExecuted);
      expect(usdcChangeFor(output, feeRecipient)).toBe(feeExecuted);
      expectMintAndWithdraw(output, {
        mintRecipient: altRecipient,
        amount: amount - feeExecuted,
        feeCollected: feeExecuted,
      });
    });

    test("mint with a future expiration succeeds", async () => {
      const amount = BigInt(500);
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount,
        expirationBlock: BigInt(Date.now() + 3_600_000),
      });
      const output = await submitReceive(message, attestation);
      expect(usdcChangeFor(output, signerAddress)).toBe(amount);
    });

    test("mint with an expired message is rejected", async () => {
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount: BigInt(500),
        expirationBlock: BigInt(1),
      });
      await expectMoveAbort(
        submitReceive(message, attestation),
        "handle_receive_message",
        8, // EExpiredMessage
      );
    });

    test("fast-finality (finality_threshold_executed = 500) succeeds", async () => {
      const amount = BigInt(500);
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount,
        finalityThresholdExecuted: 500,
      });
      const output = await submitReceive(message, attestation);
      expect(usdcChangeFor(output, signerAddress)).toBe(amount);
    });

    test("finality_threshold_executed below 500 is rejected", async () => {
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount: BigInt(500),
        finalityThresholdExecuted: 499,
      });
      await expectMoveAbort(
        submitReceive(message, attestation),
        "handle_receive_message",
        11, // EUnsupportedFinalityThreshold
      );
    });

    test("replaying a used nonce is rejected", async () => {
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount: BigInt(250),
      });
      await submitReceive(message, attestation);
      await expectMoveAbort(
        submitReceive(message, attestation),
        "receive_message",
        4, // ENonceAlreadyUsed
      );
    });

    test("an unknown burn token is rejected", async () => {
      const { message, attestation } = buildInbound({
        mintRecipient: signerAddress,
        amount: BigInt(500),
        burnTokenOverride: "0x000000000000000000000000000000000000dead",
      });
      await expectMoveAbort(
        submitReceive(message, attestation),
        "handle_receive_message",
        3, // EUnknownBurnToken
      );
    });

    test("a deregistered handler cannot mint (registry auth)", async () => {
      await setHandlerRegistered(false);
      try {
        const { message, attestation } = buildInbound({
          mintRecipient: signerAddress,
          amount: BigInt(500),
        });
        await expectMoveAbort(
          submitReceive(message, attestation),
          "handler_registry",
          0, // ENoHandlerRegistered (deregistered => no handler for the token)
        );
      } finally {
        await setHandlerRegistered(true);
      }
    });
  });

  // --- Sui -> EVM (outbound, real burn + byte-equality) ---

  describe("Sui -> EVM", () => {
    test("standard burn emits the expected message", async () => {
      const params = {
        amount: BigInt(1),
        maxFee: BigInt(0),
        minFinalityThreshold: 2000,
      };
      const output = await burnOutbound(params);
      expectOutbound(output, params);
    });

    test("burn with hookData carries the hook in the message", async () => {
      const params = {
        amount: BigInt(1),
        maxFee: BigInt(0),
        minFinalityThreshold: 2000,
        hookData: Buffer.from("cctpe3230hook", "utf8"),
      };
      const output = await burnOutbound(params);
      expectOutbound(output, params);
    });

    test("burn with an explicit destination caller carries it", async () => {
      const params = {
        amount: BigInt(1),
        maxFee: BigInt(0),
        minFinalityThreshold: 2000,
        destinationCaller: "0x000000000000000000000000000000000000beef",
      };
      const output = await burnOutbound(params);
      expectOutbound(output, params);
    });

    test("a denylisted depositor cannot burn", async () => {
      await setDenylisted(signerAddress, true);
      try {
        await expectMoveAbort(
          burnOutbound({ amount: BigInt(1) }),
          "denylistable",
          3, // EDenylistedAddress
        );
      } finally {
        await setDenylisted(signerAddress, false);
      }
    });
  });

  // --- Multi-token (lite): the same USDC linked to a second remote domain ---

  describe("Multi-token", () => {
    test("USDC can be linked to a second remote domain", async () => {
      const SECOND_DOMAIN = 5;
      const remoteToken = "0x000000000000000000000000000000000000feed";
      const link = new Transaction();
      link.moveCall({
        target: `${cfg.tmmV2PackageId}::token_controller::link_token_pair`,
        arguments: [
          link.pure.u32(SECOND_DOMAIN),
          link.pure.address(remoteToken),
          link.object(cfg.tmmV2StateId),
        ],
        typeArguments: [usdcType(cfg)],
      });
      const output = await executeTransactionHelper({
        client,
        signer,
        transaction: link,
      });
      try {
        expect(output.effects?.status.status).toBe("success");
      } finally {
        // Unlink so the test is idempotent across re-runs on a live node
        // (link_token_pair aborts ETokenPairAlreadyLinked on a duplicate).
        const unlink = new Transaction();
        unlink.moveCall({
          target: `${cfg.tmmV2PackageId}::token_controller::unlink_token_pair`,
          arguments: [
            unlink.pure.u32(SECOND_DOMAIN),
            unlink.pure.address(remoteToken),
            unlink.object(cfg.tmmV2StateId),
          ],
          typeArguments: [usdcType(cfg)],
        });
        await executeTransactionHelper({
          client,
          signer,
          transaction: unlink,
        });
      }
    });
  });
});
