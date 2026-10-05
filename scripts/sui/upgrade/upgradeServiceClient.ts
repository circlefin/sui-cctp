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
 * Client for the shared `sui_extensions::upgrade_service` module: deposit an
 * UpgradeCap into a package's UpgradeService, authorize/commit a package upgrade,
 * and manage the service admin. Ported from the stablecoin-sui submodule
 * (typescript/scripts/helpers/upgradeServiceClient.ts) — the CCTP V1/V2 packages
 * use the same `sui_extensions` UpgradeService, so this is coin-agnostic. The
 * package id and `UpgradeService<T>` type argument are derived from the on-chain
 * object type, so the same client serves all five stateful CCTP packages.
 */

import { bcs, BcsType } from "@mysten/sui/bcs";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { callViewFunction } from "../helpers";
import { executeTransactionHelper } from "./upgradeHelpers";

export default class UpgradeServiceClient {
  suiClient: SuiGrpcClient;
  upgradeServiceObjectId: string;
  suiExtensionsPackageId: string;
  upgradeServiceOtwType: string;

  public constructor(
    suiClient: SuiGrpcClient,
    upgradeServiceObjectId: string,
    suiExtensionsPackageId: string,
    upgradeServiceOtwType: string,
  ) {
    this.suiClient = suiClient;
    this.upgradeServiceObjectId = upgradeServiceObjectId;
    this.suiExtensionsPackageId = suiExtensionsPackageId;
    this.upgradeServiceOtwType = upgradeServiceOtwType;
  }

  public static async buildFromId(
    suiClient: SuiGrpcClient,
    upgradeServiceObjectId: string,
  ) {
    const upgradeServiceObject = await suiClient.core.getObject({
      objectId: upgradeServiceObjectId,
    });
    if (!upgradeServiceObject.object?.type) {
      throw new Error("Failed to retrieve upgrade service object type");
    }
    const upgradeServiceType = upgradeServiceObject.object.type;

    return this.buildHelper(
      suiClient,
      upgradeServiceObjectId,
      upgradeServiceType,
    );
  }

  private static buildHelper(
    suiClient: SuiGrpcClient,
    upgradeServiceObjectId: string,
    upgradeServiceType: string,
  ) {
    const suiExtensionsPackageId = upgradeServiceType.split("::")[0];
    const upgradeServiceOtwType = upgradeServiceType.match(
      /(?<=upgrade_service::UpgradeService<)\w{66}::\w*::\w*(?=>)/,
    )?.[0];
    if (!upgradeServiceOtwType) {
      throw new Error("Failed to parse upgrade service OTW type");
    }
    return new UpgradeServiceClient(
      suiClient,
      upgradeServiceObjectId,
      suiExtensionsPackageId,
      upgradeServiceOtwType,
    );
  }

  public async depositUpgradeCap(
    upgradeCapOwner: Ed25519Keypair,
    upgradeCapObjectId: string,
    options: {
      gasBudget: bigint | null;
      dryRun?: boolean;
    },
  ) {
    const transaction = new Transaction();
    transaction.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::deposit`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [
        transaction.object(this.upgradeServiceObjectId),
        transaction.object(upgradeCapObjectId),
      ],
    });

    return executeTransactionHelper({
      dryRun: !!options.dryRun,
      client: this.suiClient,
      signer: upgradeCapOwner,
      transaction,
      gasBudget: options.gasBudget != null ? BigInt(options.gasBudget) : null,
    });
  }

  public async changeAdmin(
    admin: Ed25519Keypair,
    newAdmin: string,
    options: {
      gasBudget: bigint | null;
      dryRun?: boolean;
    },
  ) {
    const changeUpgradeServiceAdminTx = new Transaction();
    changeUpgradeServiceAdminTx.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::change_admin`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [
        changeUpgradeServiceAdminTx.object(this.upgradeServiceObjectId),
        changeUpgradeServiceAdminTx.pure.address(newAdmin),
      ],
    });

    return executeTransactionHelper({
      dryRun: !!options.dryRun,
      client: this.suiClient,
      signer: admin,
      transaction: changeUpgradeServiceAdminTx,
      gasBudget: options.gasBudget != null ? BigInt(options.gasBudget) : null,
    });
  }

  public async upgrade(
    admin: Ed25519Keypair,
    latestPackageId: string,
    modules: string[],
    dependencies: string[],
    digest: number[],
    options: {
      gasBudget: bigint | null;
      dryRun?: boolean;
    },
  ) {
    const upgradeTx = new Transaction();

    const [compatiblePolicyRef] = upgradeTx.moveCall({
      target: "0x2::package::compatible_policy",
    });

    const [upgradeTicket] = upgradeTx.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::authorize_upgrade`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [
        upgradeTx.object(this.upgradeServiceObjectId),
        compatiblePolicyRef,
        upgradeTx.makeMoveVec({
          type: "u8",
          elements: digest.map((byte) => upgradeTx.pure.u8(byte)),
        }),
      ],
    });

    const [upgradeReceipt] = upgradeTx.upgrade({
      modules,
      dependencies,
      package: latestPackageId,
      ticket: upgradeTicket,
    });

    upgradeTx.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::commit_upgrade`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [
        upgradeTx.object(this.upgradeServiceObjectId),
        upgradeReceipt,
      ],
    });

    return executeTransactionHelper({
      dryRun: !!options.dryRun,
      client: this.suiClient,
      signer: admin,
      transaction: upgradeTx,
      gasBudget: options.gasBudget != null ? BigInt(options.gasBudget) : null,
    });
  }

  public async getAdmin(): Promise<string> {
    return this.callSimpleViewFunction("admin", bcs.Address);
  }

  public async getPendingAdmin(): Promise<string | null | undefined> {
    return this.callSimpleViewFunction(
      "pending_admin",
      bcs.option(bcs.Address),
    );
  }

  public async acceptPendingAdmin(
    pendingAdmin: Ed25519Keypair,
    options: {
      gasBudget: bigint | null;
      dryRun?: boolean;
    },
  ) {
    const acceptUpgradeServiceAdminTx = new Transaction();
    acceptUpgradeServiceAdminTx.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::accept_admin`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [
        acceptUpgradeServiceAdminTx.object(this.upgradeServiceObjectId),
      ],
    });

    return executeTransactionHelper({
      dryRun: !!options.dryRun,
      client: this.suiClient,
      signer: pendingAdmin,
      transaction: acceptUpgradeServiceAdminTx,
      gasBudget: options.gasBudget != null ? BigInt(options.gasBudget) : null,
    });
  }

  public async getUpgradeCapPackageId(): Promise<string> {
    return this.callSimpleViewFunction("upgrade_cap_package", bcs.Address);
  }

  public async getUpgradeCapVersion(): Promise<string> {
    return this.callSimpleViewFunction("upgrade_cap_version", bcs.U64);
  }

  public async getUpgradeCapPolicy(): Promise<number> {
    return this.callSimpleViewFunction("upgrade_cap_policy", bcs.U8);
  }

  /**
   * Calls a view function on the upgrade_service module that takes no arguments
   * and returns a single value.
   */
  private async callSimpleViewFunction<T, Input = T>(
    functionName: string,
    returnType: BcsType<T, Input>,
  ): Promise<T> {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.suiExtensionsPackageId}::upgrade_service::${functionName}`,
      typeArguments: [this.upgradeServiceOtwType],
      arguments: [tx.object(this.upgradeServiceObjectId)],
    });
    const [value] = await callViewFunction({
      client: this.suiClient,
      transaction: tx,
      returnTypes: [returnType],
    });
    return value;
  }
}
