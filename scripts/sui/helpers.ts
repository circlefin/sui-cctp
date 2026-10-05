/**
 * Copyright 2024 Circle Internet Financial, LTD. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { SuiGrpcClient } from "@mysten/sui/grpc";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { BcsType } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { normalizeStructTag, normalizeSuiAddress } from "@mysten/sui/utils";
import { execSync } from "child_process";
import _ from "lodash";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "node:url";
import util from "util";
import Web3, { Contract, EventLog, TransactionReceipt } from "web3";
import * as ethutil from "ethereumjs-util";
import waitForExpect from "wait-for-expect";
import assert from "assert";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function log(...[message, ...args]: Parameters<typeof console.log>) {
  console.log(">>> " + message, ...args);
}

/**
 * Deploy target. `localnet` is the throwaway `--force-regenesis` node used by
 * the E2E suites; `testnet` and `mainnet` are the real Sui networks. Multiple
 * deployments may share a network, distinguished only by RPC and artifact
 * name.
 */
export type DeployNetwork = "localnet" | "testnet" | "mainnet";

/**
 * Normalize a Sui address to `0x` + 64 lowercase hex characters. Handles
 * short-form ids (`0x2`, `0x123`), already-padded forms, and mixed-case
 * hex. Used to compare event-payload addresses against expected values
 * regardless of on-chain encoding.
 */
export function normAddr(addr: string): string {
  return "0x" + addr.replace(/^0x/, "").padStart(64, "0").toLowerCase();
}

/**
 * True if the fully-qualified `coinType` (e.g. `0xabc::usdc::USDC`) belongs to
 * the coin package/id `id`. Normalizes both sides because @mysten/sui 2.x
 * returns short-form (leading-zero-stripped) addresses from getAllCoins /
 * getAllBalances, whereas deploy-artifact ids are full-form — a raw substring
 * match between the two silently fails for any address with a leading zero.
 */
export function coinTypeMatches(coinType: string, id: string): boolean {
  return normalizeStructTag(coinType).includes(normalizeSuiAddress(id));
}

/**
 * Within `tx`, produce a single coin of exactly `amount` of `coinType` owned by
 * `owner`: fetch ALL of the owner's coins of that type (paginating `listCoins`),
 * fail if their combined balance is short, merge them into one, and split off
 * `amount`. Returns the split coin argument. Handles a wallet whose balance is
 * spread across many coin objects and/or pages, which a single-page
 * `listCoins(...).objects.find(...)` would miss.
 */
export async function splitCoinForAmount(args: {
  tx: Transaction;
  client: SuiGrpcClient;
  owner: string;
  coinType: string;
  amount: bigint | number;
}) {
  const coins: { objectId: string; balance: string }[] = [];
  let cursor: string | null = null;
  do {
    const page = await args.client.core.listCoins({
      owner: args.owner,
      coinType: args.coinType,
      cursor,
    });
    coins.push(...page.objects);
    cursor = page.hasNextPage ? page.cursor : null;
  } while (cursor);

  const need = BigInt(args.amount);
  const total = coins.reduce((sum, c) => sum + BigInt(c.balance), BigInt(0));
  if (total < need) {
    throw new Error(
      `Insufficient ${args.coinType}: owner holds ${total}, need ${need}.`,
    );
  }

  const primary = args.tx.object(coins[0].objectId);
  if (coins.length > 1) {
    args.tx.mergeCoins(
      primary,
      coins.slice(1).map((c) => args.tx.object(c.objectId)),
    );
  }
  const [coin] = args.tx.splitCoins(primary, [args.amount]);
  return coin;
}

/**
 * Decode a Move `vector<u8>` field read from a parsed event's JSON. The
 * @mysten/sui gRPC client encodes byte-vectors as base64 strings (the removed
 * JSON-RPC client used number arrays); handle both so event byte payloads
 * (e.g. `MessageSent.message`, `DepositForBurn.hook_data`) decode correctly.
 */
export function eventBytes(value: unknown): Uint8Array {
  if (typeof value === "string") {
    return new Uint8Array(Buffer.from(value, "base64"));
  }
  return Uint8Array.from((value ?? []) as number[]);
}

/**
 * Minimal, legacy-shaped view of an executed transaction. The @mysten/sui gRPC
 * client (`SuiGrpcClient`) returns a different response shape than the removed
 * JSON-RPC client; `toSuiTxResponse` below rebuilds just the fields the tooling
 * reads so downstream consumers (`recoverChangedObjectId`, `findEvent`, the
 * balance/event/object-change reads in the deploy flow and tests) keep the same
 * field access. `deployHelper` produces the same shape from the CLI publish JSON.
 */
export interface TxObjectChange {
  type: "created" | "mutated" | "deleted" | "published" | string;
  objectId?: string;
  objectType?: string;
  packageId?: string;
  version?: string;
  digest?: string;
}
export interface TxBalanceChange {
  owner: { AddressOwner?: string };
  coinType: string;
  amount: string;
}
export interface TxEvent {
  type: string;
  parsedJson: unknown;
  sender?: string;
}
export interface SuiTxResponse {
  digest: string;
  effects: { status: { status: "success" | "failure"; error?: string } };
  balanceChanges: TxBalanceChange[];
  objectChanges: TxObjectChange[];
  events: TxEvent[];
}

/**
 * The subset of the `SuiGrpcClient` transaction/simulation result shape that
 * {@link toSuiTxResponse} consumes. Declared explicitly (rather than `any`) so
 * field access is type-checked. The runtime shape is pinned by the fixture test
 * in `test/txAdapter.test.ts`, so an @mysten/sui gRPC shape change surfaces
 * there (locally) rather than only in the CI-only e2e bridge.
 */
interface GrpcChangedObject {
  objectId?: string;
  idOperation?: string;
  outputVersion?: string;
  outputDigest?: string;
}
interface GrpcBalanceChange {
  coinType?: string;
  address?: string;
  amount?: string;
}
interface GrpcEvent {
  eventType?: string;
  type?: string;
  json?: unknown;
  parsedJson?: unknown;
  contents?: unknown;
  sender?: string;
}
interface GrpcTxBody {
  digest?: string;
  status?: { success?: boolean; error?: string | null };
  effects?: {
    status?: { success?: boolean; error?: string | null };
    changedObjects?: GrpcChangedObject[];
  };
  objectTypes?: Record<string, string>;
  balanceChanges?: GrpcBalanceChange[];
  events?: GrpcEvent[];
}
export interface GrpcTxResult {
  Transaction?: GrpcTxBody;
  FailedTransaction?: GrpcTxBody;
}

/**
 * Map a gRPC `changedObjects[].idOperation` to the legacy `objectChanges` type.
 * `recoverChangedObjectId` depends on `created` being detected, so an
 * unrecognized value is logged rather than silently bucketed as `mutated`.
 */
function changedObjectType(idOperation: string | undefined): string {
  switch ((idOperation ?? "").toLowerCase()) {
    case "created":
      return "created";
    case "deleted":
      return "deleted";
    case "none":
    case "unknown":
    case "id_operation_unknown":
    case "":
      return "mutated";
    default:
      log(
        `Warning: unrecognized changedObject idOperation "${idOperation}"; ` +
          `treating as "mutated". The @mysten/sui gRPC enum encoding may have ` +
          `changed — verify object-id recovery.`,
      );
      return "mutated";
  }
}

/**
 * Rebuild a legacy-shaped {@link SuiTxResponse} from a `SuiGrpcClient`
 * transaction/simulation result. gRPC returns `{ Transaction | FailedTransaction }`
 * with `effects.changedObjects` (+ a separate `objectTypes` map), `balanceChanges`
 * keyed by `address`, and boolean `status.success` — mapped here back to the
 * `objectChanges` / `owner.AddressOwner` / `status.status` fields the tooling uses.
 * A missing wrapper/status defaults to a failure, so a mis-shaped result never
 * reads as a successful transaction.
 */
export function toSuiTxResponse(res: unknown): SuiTxResponse {
  // Single boundary cast: the SDK's generic gRPC result types don't structurally
  // match GrpcTxResult, but the fields we read are covered by it; everything
  // downstream of here is type-checked against GrpcTxResult.
  const result = res as GrpcTxResult;
  const T: GrpcTxBody = result?.Transaction ?? result?.FailedTransaction ?? {};
  const status = T.status ?? T.effects?.status ?? {};
  const objectTypes = T.objectTypes ?? {};
  const objectChanges: TxObjectChange[] = (T.effects?.changedObjects ?? []).map(
    (co) => ({
      type: changedObjectType(co.idOperation),
      objectId: co.objectId,
      objectType: co.objectId ? objectTypes[co.objectId] : undefined,
      version: co.outputVersion,
      digest: co.outputDigest,
    }),
  );
  const balanceChanges: TxBalanceChange[] = (T.balanceChanges ?? []).map(
    (b) => ({
      owner: { AddressOwner: b.address },
      coinType: b.coinType ?? "",
      amount: b.amount ?? "",
    }),
  );
  const events: TxEvent[] = (T.events ?? []).map((e) => ({
    type: e.eventType ?? e.type ?? "",
    parsedJson: e.json ?? e.parsedJson ?? e.contents,
    sender: e.sender,
  }));
  return {
    digest: T.digest ?? "",
    effects: {
      status: {
        status: status.success ? "success" : "failure",
        error: status.error ?? undefined,
      },
    },
    balanceChanges,
    objectChanges,
    events,
  };
}

export function inspectObject(object: any) {
  return util.inspect(
    object,
    false /* showHidden */,
    8 /* depth */,
    true /* color */,
  );
}

export function writeJsonOutput(filePrefix: string, output: Record<any, any>) {
  if (process.env.NODE_ENV !== "TESTING") {
    const randomString = new Date().getTime().toString();
    const outputDirectory = path.join(__dirname, "../logs/");
    const outputFilepath = path.join(
      outputDirectory,
      `${filePrefix}-${randomString}.json`,
    );
    fs.mkdirSync(outputDirectory, { recursive: true });
    fs.writeFileSync(outputFilepath, JSON.stringify(output, null, 2));

    log(`Logs written to ${outputFilepath}`);
  }
}

// Turn private key into keypair format
// cuts off 1st byte as it signifies which signature type is used.
export function getEd25519KeypairFromPrivateKey(privateKey: string) {
  return Ed25519Keypair.fromSecretKey(
    decodeSuiPrivateKey(privateKey).secretKey,
  );
}

export async function executeTransactionHelper(args: {
  client: SuiGrpcClient;
  signer: Ed25519Keypair;
  transaction: Transaction;
}): Promise<SuiTxResponse> {
  // gRPC `signAndExecuteTransaction` returns the full result inline when the
  // relevant data is `include`d — no separate `waitForTransaction` fetch needed
  // for the payload; we still wait on the digest so dependent reads see the
  // transaction's effects applied.
  const res = await args.client.signAndExecuteTransaction({
    signer: args.signer,
    transaction: args.transaction,
    include: {
      effects: true,
      balanceChanges: true,
      events: true,
      objectTypes: true,
    },
  });

  const txOutput = toSuiTxResponse(res);
  await args.client.waitForTransaction({ digest: txOutput.digest });

  if (txOutput.effects.status.status === "failure") {
    console.log(inspectObject(res));
    throw new Error(
      `Transaction failed! ${txOutput.effects.status.error ?? ""}`,
    );
  }

  return txOutput;
}

/**
 * Defaults for `executeTransactionWithRetry`. Deliberately small: the bridge
 * E2E suite runs under a 120s per-test ceiling and `waitForTransaction` carries
 * its own 60s internal timeout, so a generous attempt count could convert an
 * intermittent flake into a hard timeout. 4 attempts at 250ms exponential
 * backoff is ~1.75s of added latency in the worst case.
 */
const DEFAULT_TX_MAX_ATTEMPTS = 4;
const DEFAULT_TX_BASE_DELAY_MS = 250;

/**
 * Render an unknown thrown value for logging. The gRPC transport throws
 * `RpcError` (from `@protobuf-ts/runtime-rpc`, a transitive dep) whose `code`
 * is a gRPC status name like `UNAVAILABLE` or `ABORTED` — the only structured
 * discriminator available on this path — but plain `Error`s also reach here
 * from `@mysten/sui` internals. Duck-type rather than importing the class.
 */
function describeThrownError(e: unknown): string {
  const err = e as { code?: unknown; name?: unknown; message?: unknown };
  const code = typeof err?.code === "string" ? `[${err.code}] ` : "";
  const name = typeof err?.name === "string" ? `${err.name}: ` : "";
  const message =
    typeof err?.message === "string" ? err.message : String(e ?? "");
  return `${code}${name}${message}`;
}

/**
 * Transient-tolerant sibling of `executeTransactionHelper`.
 *
 * WHY A BUILDER CALLBACK RATHER THAN A `Transaction`:
 * `Transaction` memoizes the object references it resolves during its first
 * build, so re-signing the same instance replays the *same* object versions. A
 * burn that failed because its USDC coin ref went stale would therefore fail
 * identically on every retry. `buildTransaction` is invoked fresh on each
 * attempt so the caller re-runs its own `listCoins` / ref lookups and picks up
 * current versions. The re-read is the actual fix; the retry merely gives it a
 * chance to happen. A retry that does not rebuild is not a fix.
 *
 * WHICH FAILURES ARE RETRIED — by channel, not by error text:
 * A deterministic on-chain failure (a Move abort) *executes*, and comes back
 * with `effects.status.status === "failure"`. A transient owned-object/version
 * race is rejected at build/submit time and *throws* out of
 * `signAndExecuteTransaction`. Only the throwing channel is retried. Keying
 * on the channel rather than on error text means callers used inside
 * `expectMoveAbort` still fail fast on their expected abort instead of paying
 * N x the latency.
 *
 * A failure from `waitForTransaction` is deliberately NOT retried: submit
 * already succeeded at that point, so rebuilding would risk executing the
 * transaction twice.
 *
 * The full error is logged on every retry and on final give-up, so the next
 * occurrence names the real error class instead of vanishing.
 */
export async function executeTransactionWithRetry(args: {
  client: SuiGrpcClient;
  signer: Ed25519Keypair;
  buildTransaction: () => Transaction | Promise<Transaction>;
  maxAttempts?: number;
  baseDelayMs?: number;
}): Promise<SuiTxResponse> {
  const maxAttempts = args.maxAttempts ?? DEFAULT_TX_MAX_ATTEMPTS;
  const baseDelayMs = args.baseDelayMs ?? DEFAULT_TX_BASE_DELAY_MS;

  // `for (;;)` rather than a bounded loop: every path returns or throws, which
  // keeps `noImplicitReturns` satisfied. `while (true)` would trip
  // `no-constant-condition`. Mirrors `ensureLocalEnv` in sui/deploy.ts.
  for (let attempt = 1; ; attempt++) {
    // Rebuilt per attempt — this re-reads owned-object references.
    const transaction = await args.buildTransaction();

    let res: unknown;
    try {
      res = await args.client.signAndExecuteTransaction({
        signer: args.signer,
        transaction,
        include: {
          effects: true,
          balanceChanges: true,
          events: true,
          objectTypes: true,
        },
      });
    } catch (e) {
      const details = describeThrownError(e);
      if (attempt >= maxAttempts) {
        throw new Error(
          `Transaction submit failed after ${attempt} attempt(s): ${details}`,
          { cause: e },
        );
      }
      // Deterministic backoff (no jitter): jest runs this suite with
      // `maxWorkers: 1` against a single signer, so there are no competing
      // clients to de-synchronize, and determinism keeps the unit test honest.
      const delayMs = baseDelayMs * 2 ** (attempt - 1);
      log(
        `Transaction submit attempt ${attempt}/${maxAttempts} failed, ` +
          `retrying in ${delayMs}ms: ${details}`,
      );
      await new Promise((resolve) => setTimeout(resolve, delayMs));
      continue;
    }

    const txOutput = toSuiTxResponse(res);
    await args.client.waitForTransaction({ digest: txOutput.digest });

    if (txOutput.effects.status.status === "failure") {
      console.log(inspectObject(res));
      throw new Error(
        `Transaction failed! ${txOutput.effects.status.error ?? ""}`,
      );
    }

    return txOutput;
  }
}

export async function callViewFunction<T, Input = T>(args: {
  client: SuiGrpcClient;
  transaction: Transaction;
  returnTypes: BcsType<T, Input>[];
  sender?: string;
}) {
  // `simulateTransaction` replaces `devInspectTransactionBlock`; disabling
  // checks (`checksEnabled: false`) is the devInspect-equivalent that lets a
  // view PTB run without gas/ownership validation. Return values live under
  // `commandResults[i].returnValues[j].bcs` (raw BCS bytes).
  args.transaction.setSender(
    args.sender ||
      "0x0000000000000000000000000000000000000000000000000000000000000000",
  );
  const sim = await args.client.simulateTransaction({
    transaction: args.transaction,
    checksEnabled: false,
    include: { commandResults: true },
  });

  const commandResults = (sim as any).commandResults;
  const returnValues = commandResults?.[0]?.returnValues;
  if (!returnValues) {
    throw new Error("Missing return values!");
  }

  if (returnValues.length != args.returnTypes.length) {
    throw new Error("Mismatched return values and return types!");
  }

  const returnValueBytes: Uint8Array[] = returnValues.map((v: any) =>
    v.bcs instanceof Uint8Array ? v.bcs : new Uint8Array(v.bcs),
  );
  const decodedResults = _.zip(args.returnTypes, returnValueBytes).map(
    ([type, bytes]) => type!.parse(bytes as Uint8Array),
  );

  return decodedResults;
}

// When true, deployHelper publishes with the frozen V1 toolchain (1.37.3) rather
// than the current one. Set by the deploy per its --deploy-version (see
// deploy.ts): a V1 deploy compiles + publishes its entire closure with 1.37.3 so
// the published V1 bytecode matches mainnet and the dependency linkage is
// self-consistent (a mixed 1.37.3/1.76.1 closure aborts VMVerification on
// publish). The 1.76.1 localnet node accepts the older 1.37.3 bytecode.
let frozenV1Deploy = false;
export function setFrozenV1Deploy(frozen: boolean): void {
  frozenV1Deploy = frozen;
}

/**
 * Resolves the `sui` binary to use for CLI calls against `network`.
 *
 * A real-network operation MUST use the pinned toolchain: the `sui` on PATH can
 * be far older (1.62.1 at time of writing) and predates the >=1.75 package
 * management that on-chain dependency resolution and `Published.toml` depend
 * on. Localnet keeps the lenient PATH fallback so a contributor without ./bin
 * can still run a local deploy.
 */
export function resolveSuiBin(network: DeployNetwork = "localnet"): string {
  const repoRoot = path.join(__dirname, "../..");
  const version = frozenV1Deploy
    ? "mainnet-v1.37.3"
    : execSync(`bash -c 'source versions.sh && echo "$DEFAULT_SUI_VERSION"'`, {
        cwd: repoRoot,
        encoding: "utf-8",
      }).trim();
  const pinnedSui = path.join(repoRoot, "bin", version, "sui");
  if (fs.existsSync(pinnedSui)) return pinnedSui;
  if (network !== "localnet") {
    throw new Error(
      `Pinned Sui binary not found at ${pinnedSui}. A ${network} deploy requires ` +
        `the pinned ${version} toolchain; refusing to fall back to the \`sui\` on PATH.`,
    );
  }
  return "sui";
}

/**
 * Deploys a Sui package using the command line.
 * @param packagePath Relative path from the calling directory
 * @returns parsed transaction output for deployment
 */
export function deployHelper(
  packagePath: string,
  network: DeployNetwork = "localnet",
): SuiTxResponse {
  const fullPackagePath = path.join(__dirname, packagePath);
  const repoRoot = path.join(__dirname, "../..");

  // Toolchain for the localnet deploy:
  //  - Frozen V1 deploy: the pinned 1.37.3 compiler, so the whole V1 closure is
  //    compiled + published as frozen mainnet bytecode (the deploy also pins the
  //    1.37.3-compatible framework across the closure — see deploy.ts).
  //  - V2 deploy: the current toolchain (DEFAULT_SUI_VERSION).
  const version = frozenV1Deploy
    ? "mainnet-v1.37.3"
    : execSync(`bash -c 'source versions.sh && echo "$DEFAULT_SUI_VERSION"'`, {
        cwd: repoRoot,
        encoding: "utf-8",
      }).trim();
  const pinnedSui = path.join(repoRoot, "bin", version, "sui");
  // (see resolveSuiBin for the shared PATH-fallback policy)
  // A real-network publish MUST use the pinned toolchain. The `sui` on PATH can
  // be far older (1.62.1 at time of writing) and predates the >=1.75 package
  // management this publish path depends on, which would silently produce a
  // wrong or failed publish against testnet/mainnet. Localnet keeps the lenient
  // fallback so a contributor without ./bin can still run a local deploy.
  if (network !== "localnet" && !fs.existsSync(pinnedSui)) {
    throw new Error(
      `Pinned Sui binary not found at ${pinnedSui}. A ${network} publish requires ` +
        `the pinned ${version} toolchain; refusing to fall back to the \`sui\` on PATH.`,
    );
  }
  const suiBin = fs.existsSync(pinnedSui) ? pinnedSui : "sui";

  // Publish path by package-management generation:
  //  - 1.37.3 (frozen V1, old package management): plain `client publish`. It
  //    records each package's published id into its Move.lock, which dependents
  //    published later in the same deploy resolve automatically.
  //  - Current toolchain (1.76.1 new package management): `client publish`
  //    requires an env-defined publication localnet packages lack, so use
  //    `test-publish --build-env mainnet` — an ephemeral publication tracked in a
  //    `Pub.<env>.toml` that also lets dependents resolve their local deps.
  // --skip-dependency-verification avoids dep source verification against the
  // localnet deps; the published bytecode is unaffected.
  //  - Real network (testnet/mainnet): plain `client publish`. The dependency
  //    graph resolves to the stablecoin-sui packages already published on that
  //    chain via their `Published.toml`, and the publish writes our own
  //    `Published.toml` beside each `Move.toml`. Note `--build-env` is REJECTED
  //    by `client publish` ("when publishing you must build for the environment
  //    that you are publishing for") — the env comes from the active CLI env,
  //    which deploy.ts selects before calling this.
  const localnetPublish = network === "localnet";
  const publishSubcmd =
    version === "mainnet-v1.37.3" || !localnetPublish
      ? `client publish ${fullPackagePath}`
      : `client test-publish --build-env mainnet ${fullPackagePath}`;
  // Dependency verification is skipped only for localnet, where deps are
  // freshly published local sources with nothing meaningful to verify against.
  // On a real network we want the check to run.
  const skipDepVerification = localnetPublish
    ? " --skip-dependency-verification"
    : "";
  const rawDeploymentOutput = execSync(
    `${suiBin} ${publishSubcmd} --json${skipDepVerification}`,
    { encoding: "utf-8" },
  );

  const deploymentOutput: SuiTxResponse = JSON.parse(rawDeploymentOutput);
  return deploymentOutput;
}

/**
 * Obtains the id for an object changed in a provided Sui transaction.
 * @param transactionResponse transaction response object obtained from a deployment
 * @param objectChangeType the type of change an object underwent, e.g. "published" or "created"
 * @param identifier an identifying label for the object, e.g. the package::module
 * @returns the ID of the object, or an empty string if not found
 */
export function recoverChangedObjectId(
  transactionResponse: SuiTxResponse,
  objectChangeType: "created" | "published",
  identifier: string = "",
): string {
  if (objectChangeType === "created") {
    const object = transactionResponse.objectChanges?.find((objectChange) => {
      return (
        objectChange.type === objectChangeType &&
        (objectChange.objectType?.includes(identifier) ?? false)
      );
    });
    return object?.objectId ?? "";
  } else if (objectChangeType === "published") {
    const object = transactionResponse.objectChanges?.find((objectChange) => {
      return objectChange.type === objectChangeType;
    });
    return object?.packageId ?? "";
  }
  return "";
}

// Receives a message on the given EVM chain.
export const receiveEvm = async (
  messageTransmitterContract: Contract<any>,
  userAddress: string,
  message: Buffer,
  attestation: string,
) =>
  messageTransmitterContract.methods
    .receiveMessage(message, attestation)
    .send({ from: userAddress });

// Fetches USDC balance
export const fetchUsdcBalance = async (web3: Web3, address: string) => {
  const evmUSDCAddress = `${process.env.EVM_USDC_ADDRESS}`;
  const usdcInterface = JSON.parse(
    fs
      .readFileSync(
        "../evm-cctp-contracts/usdc-interfaces/FiatTokenV2_1.sol/FiatTokenV2_1.json",
      )
      .toString(),
  );
  const usdcContract = new web3.eth.Contract(usdcInterface.abi, evmUSDCAddress);

  return usdcContract.methods.balanceOf(address).call();
};

// Given a hex-encoded message, produces an attestation.
export const attestToMessage = (web3: Web3, messageHex: string): string => {
  // Create an attestation using the initialized Anvil keypair
  // This is not a valid attester key in any testnet or mainnet environment.
  const attesterPrivateKey =
    "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97";

  const messageHash = web3.utils.keccak256(messageHex);
  const signedMessage = ethutil.ecsign(
    ethutil.toBuffer(messageHash),
    ethutil.toBuffer(attesterPrivateKey),
  );
  const attestation = ethutil.toRpcSig(
    signedMessage.v,
    signedMessage.r,
    signedMessage.s,
  );

  return attestation;
};

// Generates a depositForBurn tx from the given EVM chain and returns the message as a string.
export const generateEvmBurn = async (
  web3: Web3,
  messageTransmitterContract: Contract<any>,
  tokenMessengerContract: Contract<any>,
  usdcContract: Contract<any>,
  tokenMessengerContractAddress: string,
  usdcContractAddress: string,
  userAddress: string,
  destAddress: string,
  destDomain: number,
  amount: number,
) => {
  // Set allowance for the userAddress
  const txReceipt1 = await usdcContract.methods
    .approve(tokenMessengerContractAddress, amount)
    .send({ from: userAddress });
  assert(txReceipt1.status === BigInt(1));

  const paddedDestAddress = web3.utils.padLeft(destAddress, 64);

  const txReceipt2 = await tokenMessengerContract.methods
    .depositForBurn(amount, destDomain, paddedDestAddress, usdcContractAddress)
    .send({ from: userAddress });
  assert(txReceipt2.status === BigInt(1));

  return fetchEvmMessage(messageTransmitterContract, txReceipt2);
};

// Fetches an EVM message body from event logs.
const fetchEvmMessage = async (
  messageTransmitterContract: Contract<any>,
  txReceipt: TransactionReceipt,
) => {
  let logs: any = [];

  await waitForExpect(async () => {
    logs = await messageTransmitterContract.getPastEvents("MessageSent", {
      fromBlock: txReceipt.blockNumber,
      toBlock: txReceipt.blockNumber,
    });
    assert(logs.length > 0);
  }, 90_000);

  return {
    message: String((logs[0] as EventLog).returnValues.message),
    tx: txReceipt,
  };
};
