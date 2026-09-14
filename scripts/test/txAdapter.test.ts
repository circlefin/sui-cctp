/*
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
 * Pure unit tests (no node) for the gRPC response adapter. The fixtures below
 * are real @mysten/sui `SuiGrpcClient` result shapes captured from a live
 * localnet node. They pin the shape `toSuiTxResponse` / `eventBytes` depend on,
 * so an SDK gRPC shape change (e.g. `eventType`/`json`/`changedObjects`
 * renamed, or `vector<u8>` no longer base64) fails here locally rather than
 * only in the CI-only EVM bridge suite.
 */

import { toSuiTxResponse, eventBytes } from "../sui/helpers";

// A real gRPC `signAndExecuteTransaction` result (trimmed to the consumed fields):
// one created Coin<USDC>, one balance change, one emitted event.
const grpcTxResult = {
  $kind: "Transaction",
  Transaction: {
    digest: "2nYvKrugD46JvL7DxsA1hU2sAyADVy33CDDUyCzXWqv9",
    status: { success: true, error: null },
    effects: {
      status: { success: true, error: null },
      changedObjects: [
        {
          objectId: "0x0abc",
          idOperation: "Created",
          outputVersion: "3",
          outputDigest: "58D4e4xmHNxV7rmneNPhDbB6zstWtZySKhnECpVTUGS8",
        },
        {
          objectId: "0x0def",
          idOperation: "None",
          outputVersion: "3",
          outputDigest: "CXzCsaC4NhvLq8p8cx5x5dChzpMRXpXBE6wMZGyDqo13",
        },
      ],
    },
    objectTypes: {
      "0x0abc":
        "0x2::coin::Coin<0x075e2e1974743b57bcce822ecdbbb5aa33fba1fd7cbf73aca1abbb224fdf1f29::usdc::USDC>",
    },
    balanceChanges: [
      {
        coinType:
          "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
        address:
          "0x25cf064398a64be2a4aa70053f13df6f22d368c329ad257cb71c70b048da1170",
        amount: "-1976000",
      },
    ],
    events: [
      {
        packageId: "0x7aad",
        module: "pausable",
        sender: "0xbac7",
        eventType: "0x7aad::pausable::Pause",
        json: { dummy_field: false },
      },
    ],
  },
};

describe("toSuiTxResponse (gRPC → legacy shape adapter)", () => {
  it("maps a successful tx result's status, objectChanges, balances, events", () => {
    const out = toSuiTxResponse(grpcTxResult);

    expect(out.digest).toBe("2nYvKrugD46JvL7DxsA1hU2sAyADVy33CDDUyCzXWqv9");
    expect(out.effects.status.status).toBe("success");

    // changedObjects → objectChanges, with type from idOperation and the type
    // string looked up from the separate objectTypes map.
    const created = out.objectChanges.find((c) => c.type === "created");
    expect(created?.objectId).toBe("0x0abc");
    expect(created?.objectType).toContain("::usdc::USDC");
    expect(created?.version).toBe("3");
    expect(created?.digest).toBe(
      "58D4e4xmHNxV7rmneNPhDbB6zstWtZySKhnECpVTUGS8",
    );
    // idOperation "None" → "mutated"
    expect(out.objectChanges.find((c) => c.objectId === "0x0def")?.type).toBe(
      "mutated",
    );

    // balanceChanges keyed by `address` → owner.AddressOwner
    expect(out.balanceChanges[0].owner.AddressOwner).toBe(
      "0x25cf064398a64be2a4aa70053f13df6f22d368c329ad257cb71c70b048da1170",
    );
    expect(out.balanceChanges[0].amount).toBe("-1976000");

    // events: type from `eventType`, parsedJson from `json`
    expect(out.events[0].type).toBe("0x7aad::pausable::Pause");
    expect(out.events[0].parsedJson).toEqual({ dummy_field: false });
    expect(out.events[0].sender).toBe("0xbac7");
  });

  it("maps idOperation case-insensitively and buckets unknown ops as mutated", () => {
    const out = toSuiTxResponse({
      Transaction: {
        status: { success: true },
        effects: {
          changedObjects: [
            { objectId: "0x01", idOperation: "CREATED" }, // UPPER_SNAKE
            { objectId: "0x02", idOperation: "DELETED" },
            { objectId: "0x03", idOperation: "NONE" },
            { objectId: "0x04", idOperation: "SOMETHING_NEW" }, // unrecognized
          ],
        },
      },
    });
    const byId = Object.fromEntries(
      out.objectChanges.map((c) => [c.objectId, c.type]),
    );
    expect(byId["0x01"]).toBe("created");
    expect(byId["0x02"]).toBe("deleted");
    expect(byId["0x03"]).toBe("mutated");
    // An unrecognized op never reads as created/deleted (which would corrupt
    // object-id recovery); it falls back to mutated.
    expect(byId["0x04"]).toBe("mutated");
  });

  it("reads a failing tx as failure with its error", () => {
    const out = toSuiTxResponse({
      Transaction: {
        digest: "d",
        status: { success: false, error: "MoveAbort ... abort code: 5," },
        effects: { changedObjects: [] },
      },
    });
    expect(out.effects.status.status).toBe("failure");
    expect(out.effects.status.error).toContain("abort code: 5");
  });

  it("fails closed on a missing/mis-shaped wrapper (never reads as success)", () => {
    const out = toSuiTxResponse({});
    expect(out.effects.status.status).toBe("failure");
    expect(out.objectChanges).toEqual([]);
    expect(out.balanceChanges).toEqual([]);
    expect(out.events).toEqual([]);
  });
});

describe("eventBytes (Move vector<u8> decode)", () => {
  it("decodes a base64 string (the gRPC encoding)", () => {
    // base64 of [0,1,2,3,255]
    expect(Array.from(eventBytes("AAECA/8="))).toEqual([0, 1, 2, 3, 255]);
  });

  it("accepts a number array (legacy JSON-RPC encoding)", () => {
    expect(Array.from(eventBytes([0, 1, 2, 3]))).toEqual([0, 1, 2, 3]);
  });

  it("treats null/undefined as empty", () => {
    expect(Array.from(eventBytes(undefined))).toEqual([]);
    expect(Array.from(eventBytes(null))).toEqual([]);
  });
});
