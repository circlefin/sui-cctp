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
 * V2 upgrade/migration E2E. Split into its own file because it publishes a
 * real on-chain package upgrade and completes a migration, which version-locks
 * the shared deployment's original package. The jest testSequencer forces
 * `upgrade.e2e*` specs to run last so no other suite (e.g. the admin-events or
 * bridge suites) runs against the migrated deployment. Requires a local node
 * with V2 deployed (`yarn deploy-local:v2`).
 */

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { requestSuiFromFaucetV2 } from "@mysten/sui/faucet";

import dotenv from "dotenv";

import { getEd25519KeypairFromPrivateKey } from "../sui/helpers";
import { expectMoveAbort } from "./helpers";
import UpgradeServiceClient from "../sui/upgrade/upgradeServiceClient";
import MigrationClient from "../sui/upgrade/migrationClient";
import { loadUpgradeTarget } from "../sui/upgrade/upgradeConfig";
import {
  buildUpgradeArtifact,
  BuildArtifact,
  revertUpgradeBuild,
} from "./upgradeBuildHelper";

dotenv.config();
dotenv.config({ path: "test_config.v2.env" });

describe("Upgrade & migration tests (message_transmitter_v2)", () => {
  const target = loadUpgradeTarget("message_transmitter_v2");
  let client: SuiGrpcClient;
  let signer: Ed25519Keypair;

  beforeAll(() => {
    client = new SuiGrpcClient({
      network: "localnet",
      baseUrl:
        process.env.SUI_RPC_URL ??
        `http://localhost:${process.env.FULLNODE_PORT ?? "9001"}`,
    });
    signer = getEd25519KeypairFromPrivateKey(
      process.env.SUI_DEPLOYER_KEY as string,
    );
  });

  // Safety net: buildUpgradeArtifact mutates manifests/locks/version files. We
  // also revert immediately after building, but this guarantees a clean tree
  // even if the test throws mid-flow.
  afterAll(() => {
    revertUpgradeBuild();
  });

  const readCompatibleVersions = async (): Promise<number[]> => {
    const obj = await client.core.getObject({
      objectId: target.stateId,
      include: { json: true },
    });
    const json = obj.object?.json as
      | { compatible_versions?: { contents?: string[] } | string[] }
      | undefined;
    const cv = json?.compatible_versions;
    const contents = Array.isArray(cv) ? cv : (cv?.contents ?? []);
    return contents.map((v) => Number(v)).sort((a, b) => a - b);
  };

  test("deposit, upgrade, and drive start/abort/start/complete migration", async () => {
    const usClient = await UpgradeServiceClient.buildFromId(
      client,
      target.upgradeServiceId,
    );

    // Precondition: freshly deployed at uv1.
    expect(await readCompatibleVersions()).toEqual([1]);

    // Deposit the UpgradeCap into the UpgradeService (one-time).
    await usClient.depositUpgradeCap(signer, target.upgradeCapId, {
      gasBudget: null,
    });

    // Build the uv2 artifact at test time, reverting the tree immediately.
    const artifact: BuildArtifact = (() => {
      try {
        return buildUpgradeArtifact("message_transmitter_v2");
      } finally {
        revertUpgradeBuild();
      }
    })();

    const latestPackageId = await usClient.getUpgradeCapPackageId();

    // Auth negative: a non-admin cannot authorize the upgrade (two_step_role).
    const stranger = Ed25519Keypair.generate();
    await requestSuiFromFaucetV2({
      host: `http://127.0.0.1:${process.env.FAUCET_PORT ?? "9123"}`,
      recipient: stranger.toSuiAddress(),
    });
    await expectMoveAbort(
      usClient.upgrade(
        stranger,
        latestPackageId,
        artifact.modules,
        artifact.dependencies,
        artifact.digest,
        { gasBudget: null },
      ),
      "two_step_role",
      0,
    );

    // Publish the upgrade as admin -> new package id (uv2).
    await usClient.upgrade(
      signer,
      latestPackageId,
      artifact.modules,
      artifact.dependencies,
      artifact.digest,
      { gasBudget: null },
    );
    const newPackageId = await usClient.getUpgradeCapPackageId();
    expect(newPackageId).not.toBe(latestPackageId);

    // Migration targets the new (uv2) package version.
    const migClient = new MigrationClient(client, newPackageId, target.stateId);

    // start -> {1,2}, abort -> {1}, start -> {1,2}, complete -> {2}.
    await migClient.migrate("start", signer, { gasBudget: null });
    expect(await readCompatibleVersions()).toEqual([1, 2]);

    await migClient.migrate("abort", signer, { gasBudget: null });
    expect(await readCompatibleVersions()).toEqual([1]);

    await migClient.migrate("start", signer, { gasBudget: null });
    expect(await readCompatibleVersions()).toEqual([1, 2]);

    await migClient.migrate("complete", signer, { gasBudget: null });
    expect(await readCompatibleVersions()).toEqual([2]);
  }, 300_000);
});
