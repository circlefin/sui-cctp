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
 * Unit tests for `executeTransactionWithRetry`. No localnet and no
 * deployment required — the gRPC client is stubbed, so these run anywhere.
 *
 * The two properties worth protecting are:
 *  1. the transaction is REBUILT on every attempt (a retry that reuses the same
 *     `Transaction` replays the same stale object refs and fixes nothing), and
 *  2. only submit-time throws are retried — a Move abort arrives via
 *     `effects.status.failure` and must fail fast, because ~55 `expectMoveAbort`
 *     assertions depend on that channel staying synchronous.
 */

import { afterEach, describe, expect, jest, test } from "@jest/globals";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

import { executeTransactionWithRetry } from "../sui/helpers";

/** A gRPC success envelope in the shape `toSuiTxResponse` consumes. */
const successResult = (digest = "0xdeadbeef") => ({
  Transaction: { digest, status: { success: true } },
});

/** A gRPC envelope for a transaction that executed and aborted on-chain. */
const abortResult = (error: string, digest = "0xfeedface") => ({
  FailedTransaction: { digest, status: { success: false, error } },
});

/**
 * Stub client recording how many times submit was attempted. `submit` receives
 * the 1-based attempt number and may return an envelope or throw.
 */
const makeStubClient = (submit: (attempt: number) => unknown) => {
  const state = { submitAttempts: 0, waitedDigests: [] as string[] };
  const client = {
    signAndExecuteTransaction: async () => {
      state.submitAttempts += 1;
      return submit(state.submitAttempts);
    },
    waitForTransaction: async (a: { digest: string }) => {
      state.waitedDigests.push(a.digest);
      return undefined;
    },
  } as unknown as SuiGrpcClient;
  return { client, state };
};

const signer = {} as Ed25519Keypair;

/** Counts builder invocations; each call returns a distinct dummy Transaction. */
const makeBuilder = () => {
  const built: Transaction[] = [];
  return {
    built,
    buildTransaction: () => {
      const tx = {} as Transaction;
      built.push(tx);
      return tx;
    },
  };
};

// `baseDelayMs: 1` keeps the whole file well inside jest's 5s default timeout
// (jest.config.cjs sets no global testTimeout).
const FAST = { maxAttempts: 4, baseDelayMs: 1 };

describe("executeTransactionWithRetry", () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  test("returns the parsed response and waits on the digest when submit succeeds first try", async () => {
    const { client, state } = makeStubClient(() => successResult("0xaaa"));
    const builder = makeBuilder();

    const out = await executeTransactionWithRetry({
      client,
      signer,
      ...builder,
      ...FAST,
    });

    expect(out.digest).toBe("0xaaa");
    expect(out.effects.status.status).toBe("success");
    expect(state.submitAttempts).toBe(1);
    expect(builder.built).toHaveLength(1);
    expect(state.waitedDigests).toEqual(["0xaaa"]);
  });

  test("rebuilds the transaction on every attempt and recovers from a transient submit failure", async () => {
    jest.spyOn(console, "log").mockImplementation(() => undefined);
    const { client, state } = makeStubClient((attempt) => {
      if (attempt === 1) {
        throw Object.assign(
          new Error("object is not available for consumption"),
          {
            code: "ABORTED",
          },
        );
      }
      return successResult("0xbbb");
    });
    const builder = makeBuilder();

    const out = await executeTransactionWithRetry({
      client,
      signer,
      ...builder,
      ...FAST,
    });

    expect(out.digest).toBe("0xbbb");
    expect(state.submitAttempts).toBe(2);
    // The whole point: one fresh build per attempt, and they are distinct
    // objects rather than the same memoized instance re-signed.
    expect(builder.built).toHaveLength(2);
    expect(builder.built[0]).not.toBe(builder.built[1]);
  });

  test("logs the gRPC code and full error text on each retry", async () => {
    const logSpy = jest
      .spyOn(console, "log")
      .mockImplementation(() => undefined);
    const { client } = makeStubClient((attempt) => {
      if (attempt < 3) {
        throw Object.assign(new Error("ObjectVersionUnavailable"), {
          code: "UNAVAILABLE",
        });
      }
      return successResult();
    });

    await executeTransactionWithRetry({
      client,
      signer,
      ...makeBuilder(),
      ...FAST,
    });

    const lines = logSpy.mock.calls.map((c) => String(c[0]));
    const retryLines = lines.filter((l) =>
      l.includes("Transaction submit attempt"),
    );
    expect(retryLines).toHaveLength(2);
    expect(retryLines[0]).toContain("attempt 1/4");
    expect(retryLines[0]).toContain("[UNAVAILABLE]");
    expect(retryLines[0]).toContain("ObjectVersionUnavailable");
    expect(retryLines[1]).toContain("attempt 2/4");
  });

  test("does NOT retry an on-chain failure and preserves the abort message shape", async () => {
    jest.spyOn(console, "log").mockImplementation(() => undefined);
    const { client, state } = makeStubClient(() =>
      abortResult("MoveAbort(denylistable, 3), abort code: 3,"),
    );
    const builder = makeBuilder();

    await expect(
      executeTransactionWithRetry({
        client,
        signer,
        ...builder,
        ...FAST,
      }),
    ).rejects.toThrow(/^Transaction failed! /);

    // Executed once. `expectMoveAbort` depends on this staying synchronous.
    expect(state.submitAttempts).toBe(1);
    expect(builder.built).toHaveLength(1);
  });

  test("gives up after maxAttempts, preserving the raw error text and cause", async () => {
    jest.spyOn(console, "log").mockImplementation(() => undefined);
    const boom = Object.assign(new Error("equivocation detected"), {
      code: "ABORTED",
    });
    const { client, state } = makeStubClient(() => {
      throw boom;
    });
    const builder = makeBuilder();

    let err: Error | undefined;
    try {
      await executeTransactionWithRetry({
        client,
        signer,
        ...builder,
        maxAttempts: 3,
        baseDelayMs: 1,
      });
    } catch (e) {
      err = e as Error;
    }

    expect(err).toBeDefined();
    expect(err?.message).toContain("after 3 attempt(s)");
    expect(err?.message).toContain("[ABORTED]");
    expect(err?.message).toContain("equivocation detected");
    expect(err?.cause).toBe(boom);
    expect(state.submitAttempts).toBe(3);
    expect(builder.built).toHaveLength(3);
  });

  test("does NOT retry a deterministic failure thrown while building", async () => {
    jest.spyOn(console, "log").mockImplementation(() => undefined);
    const { client, state } = makeStubClient(() => successResult());
    let buildCalls = 0;

    await expect(
      executeTransactionWithRetry({
        client,
        signer,
        buildTransaction: () => {
          buildCalls += 1;
          throw new Error("Insufficient USDC to burn.");
        },
        ...FAST,
      }),
    ).rejects.toThrow("Insufficient USDC to burn.");

    expect(buildCalls).toBe(1);
    expect(state.submitAttempts).toBe(0);
  });
});
