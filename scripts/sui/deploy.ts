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

import { getFaucetHost, requestSuiFromFaucetV2 } from "@mysten/sui/faucet";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { bcs } from "@mysten/sui/bcs";
import { fromBase58, toHex } from "@mysten/sui/utils";

import { execSync } from "child_process";
import { keccak256 } from "ethereumjs-util";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

import {
  callViewFunction,
  deployHelper,
  executeTransactionHelper,
  getEd25519KeypairFromPrivateKey,
  log,
  recoverChangedObjectId,
  resolveSuiBin,
  setFrozenV1Deploy,
  type DeployNetwork,
} from "./helpers";
import {
  DENY_LIST_ID,
  REMOTE_EVM_DOMAIN,
  SUI_LOCAL_DOMAIN,
  V2_MESSAGE_BODY_VERSION,
  V2_MESSAGE_VERSION,
} from "./constants";

// Load an explicit --config file BEFORE .env. dotenv never overwrites a key
// that is already set, so the first loader wins — which yields the precedence
// we want: real environment variable > --config file > .env.
//
// Order matters concretely: `.env.example` ships `DEPLOYER_PRIVATE_KEY=` (an
// empty *but present* key), and dotenv tests presence rather than truthiness.
// Loading .env first therefore let that empty value silently beat a real key in
// the config file, and the deploy would fall through to the keystore path and
// sign with a different address than the operator specified. This is also why
// `deploy-remote:v2` must not use `--require dotenv/config`, which would preload
// .env before any of our code runs.
const deployConfigFile = loadDeployConfig();
dotenv.config();

// Default local attester (also used by the Anvil EVM setup) so cross-chain
// attestations verify against the same key in local E2E.
const DEFAULT_ATTESTER = "0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f";

// Fixed local values specific to the deploy flow. Shared domains, message
// versions, and system object ids live in ./constants (imported above) so the
// on-chain-registered values and the client-side assumptions can't drift.
const MAX_MESSAGE_BODY_SIZE = 8192;
const BURN_LIMIT_PER_MESSAGE = 100000;
const MINT_ALLOWANCE = 10000000;
const STARTER_MINT_AMOUNT = 10000;

/**
 * Minimum deployer balance, in MIST, required before publishing to a real
 * network. A full four-package V2 publish measured 432,107,480 MIST on testnet
 * (cctp_extensions 13.1M, message_transmitter_v2 148.8M,
 * token_messenger_minter_v2 196.6M, stablecoin_handler 73.6M), so this is that
 * figure with ~1.7x headroom. The point is to fail fast with a clear message
 * rather than die partway through with an opaque gas error, having already
 * published some packages.
 */
const MIN_PUBLISH_BALANCE_MIST = 750_000_000;

/**
 * Chain identifiers for the real networks, used as a guard so a wrong RPC url
 * cannot silently publish to the wrong chain. These are also the keys the
 * `Published.toml` records are written under.
 */
/** A real Sui network — everything except the throwaway localnet. */
type RealNetwork = Exclude<DeployNetwork, "localnet">;

const EXPECTED_CHAIN_IDS: Record<RealNetwork, string> = {
  testnet: "4c78adac",
  mainnet: "35834a8a",
};

/** The stablecoin-sui packages our V2 packages link against on a real network. */
const STABLECOIN_SUI_DEPENDENCIES = [
  "sui_extensions",
  "stablecoin",
  "usdc",
] as const;

// Repo root, relative to this file (scripts/sui). Used to invoke the
// repo-root shell scripts (configure_manifest.sh, run.sh) regardless of cwd.
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "../..");

type DeployVersion = "1" | "2";

let client: SuiGrpcClient;

// Shared USDC / stablecoin stack (deployed on localnet, or read from env).
let stablecoinPackageId: string;
let usdcPackageId: string;
let usdcTreasuryId: string;
let suiExtensionsPackageId: string;

// V1 packages.
let mtPackageId: string;
let mtStateId: string;
let tmmPackageId: string;
let tmmStateId: string;
let usdcTokenId: string;
let usdcFundsObjectId: string;
let mintCapObjectId: string;
let messageTransmitterUpgradeServiceId: string;
let messageTransmitterUpgradeCapId: string;
let tokenMessengerUpgradeServiceId: string;
let tokenMessengerUpgradeCapId: string;

// V2 packages.
let cctpExtensionsPackageId: string;
let mtV2PackageId: string;
let mtV2StateId: string;
let mtV2UpgradeServiceId: string;
let mtV2UpgradeCapId: string;
let tmmV2PackageId: string;
let tmmV2StateId: string;
let tmmV2UpgradeServiceId: string;
let tmmV2UpgradeCapId: string;
let handlerPackageId: string;
let handlerStateId: string;
let handlerUpgradeServiceId: string;
let handlerUpgradeCapId: string;
let usdcTokenIdV2: string;
let usdcFundsV2ObjectId: string;
let mintCapV2ObjectId: string;
let attesterAddress: string;
let feeRecipientAddress: string;

// InitCap object ids recovered from a publish-only (real network) deploy. These
// are owned by the deployer and are consumed later by a separate `init_state`
// step, so they must survive into the artifact.
const publishedInitCapIds: Record<string, string> = {};

/**
 * Resolves an argument from either a CLI flag (`--flag value`) or an env var.
 * The explicit flag takes precedence over the env var.
 */
function resolveArg(flag: string, envVar: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  if (idx !== -1 && idx + 1 < process.argv.length) {
    return process.argv[idx + 1];
  }
  return process.env[envVar];
}

/**
 * Repo-root-relative directory holding the V2 packages to publish. Defaults to
 * `packages`, so every existing invocation is unchanged.
 *
 * Overriding it lets a deploy publish an alternate copy of the sources without
 * disturbing the working tree — for example a gitignored snapshot of
 * already-deployed contract code, so an upgrade can be rehearsed against a
 * stand-in for a live deployment. Precedence: `--packages-root` flag >
 * `PACKAGES_ROOT` env var > `packages`.
 *
 * V1 is deliberately not covered: those packages are frozen, are published from
 * their own pinned toolchain, and have no alternate-source use case.
 */
const PACKAGES_ROOT = (
  resolveArg("--packages-root", "PACKAGES_ROOT") ?? "packages"
).replace(/\/+$/, "");

/**
 * `deployHelper` path (relative to `scripts/sui`) for a V2 package, honouring
 * `PACKAGES_ROOT`.
 */
function v2PackagePath(name: string): string {
  return `../../${PACKAGES_ROOT}/${name}`;
}

/**
 * Whether a real-network deploy should also initialize what it publishes.
 *
 * Default OFF, and deliberately so: a real-network deploy is publish-only
 * because `init_state` is run by separate initialization tooling and the
 * InitCaps are handed to whoever runs it. Turning this on collapses that split,
 * which is only correct when the deployer owns the whole deployment.
 *
 * ON is for standing up a self-contained deployment we control end to end —
 * specifically a stand-in used to rehearse an upgrade + migration, which needs
 * `State` objects to migrate against.
 *
 * This deliberately does NOT run `configureCCTPV2Contracts`. Configuration calls
 * `stablecoin::treasury::configure_new_controller` on the USDC Treasury, which
 * requires treasury admin — true on localnet, where the deploy created that USDC
 * itself, but not on a real network where USDC belongs to someone else.
 *
 * Precedence: `--initialize` flag > `INITIALIZE` env var.
 */
function resolveInitialize(): boolean {
  if (process.argv.includes("--initialize")) return true;
  return (process.env.INITIALIZE ?? "").toLowerCase() === "true";
}

/**
 * Selects which contract version to deploy — required, no default. V1 and V2
 * deploy separately: they need different toolchains (frozen 1.37.3 vs current)
 * for the shared stablecoin-sui dependencies, which a single node/deploy can't
 * satisfy at once. Precedence: `--deploy-version` flag > `DEPLOY_VERSION` env var.
 */
function resolveDeployVersion(): DeployVersion {
  const raw = resolveArg("--deploy-version", "DEPLOY_VERSION");
  if (raw !== "1" && raw !== "2") {
    throw new Error(
      `--deploy-version is required and must be "1" or "2" (got "${raw ?? "<none>"}"). ` +
        `V1 and V2 deploy separately.`,
    );
  }
  return raw;
}

/**
 * Whether to (re)deploy the USDC / stablecoin stack. Defaults to true
 * (localnet); set false on testnet/mainnet where USDC already exists and its
 * ids are supplied via env. Precedence: `--deploy-usdc` flag > `DEPLOY_USDC`
 * env var > default `true`.
 */
function resolveDeployUsdc(): boolean {
  const raw = (
    resolveArg("--deploy-usdc", "DEPLOY_USDC") ?? "true"
  ).toLowerCase();
  if (raw !== "true" && raw !== "false") {
    throw new Error(`Invalid deploy-usdc "${raw}". Expected true or false.`);
  }
  return raw === "true";
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} must be set when DEPLOY_USDC=false`);
  }
  return value;
}

/**
 * Loads an optional deploy config file (`--config` flag > `DEPLOY_CONFIG` env),
 * extending the existing dotenv convention rather than adding a new format.
 * Supplies `SUI_NETWORK`, `SUI_RPC_URL`, `DEPLOYER_ADDRESS`,
 * `DEPLOYER_PRIVATE_KEY` and `DEPLOY_OUTPUT`.
 *
 * Called at module scope *before* `dotenv.config()` so the config file takes
 * precedence over `.env` — see the note at the call site. A real environment
 * variable still beats both, since it is already set before either load.
 */
function loadDeployConfig(): string | undefined {
  const file = resolveArg("--config", "DEPLOY_CONFIG");
  if (!file) return undefined;
  if (!existsSync(file)) {
    throw new Error(`Deploy config file not found: ${file}`);
  }
  dotenv.config({ path: file });
  return file;
}

/**
 * The deploy target. `--network` flag > `SUI_NETWORK` env > `localnet`, so
 * every existing localnet invocation keeps working unchanged.
 */
function resolveNetwork(): DeployNetwork {
  const raw = (
    resolveArg("--network", "SUI_NETWORK") ?? "localnet"
  ).toLowerCase();
  if (raw !== "localnet" && raw !== "testnet" && raw !== "mainnet") {
    throw new Error(
      `Invalid --network "${raw}". Expected localnet, testnet, or mainnet.`,
    );
  }
  return raw;
}

/**
 * RPC url for the target. `--rpc-url` flag > `SUI_RPC_URL` env > the localnet
 * default. A real network has no sensible default, so one must be supplied.
 */
function resolveRpcUrl(network: DeployNetwork): string {
  const explicit = resolveArg("--rpc-url", "SUI_RPC_URL");
  if (explicit) return explicit;
  if (network !== "localnet") {
    throw new Error(
      `--rpc-url (or SUI_RPC_URL) is required for a ${network} deploy.`,
    );
  }
  // Use 127.0.0.1 instead of `localhost` so the `sui client` CLI (called via
  // execSync) uses IPv4 directly. CI runners often have IPv6 disabled at the
  // kernel level, and the sui CLI's Rust HTTP client tries AF_INET6 for
  // `localhost` and aborts with "Address family not supported by protocol".
  return `http://127.0.0.1:${process.env.FULLNODE_PORT}`;
}

/**
 * Reads a stablecoin-sui dependency's on-chain package id for `network` from
 * the submodule's `Published.toml`. This is how the >=1.75 package management
 * binds an already-published dependency, so reading the same file keeps the
 * artifact we emit consistent with what the compiler actually linked against —
 * rather than duplicating the ids into config where they could drift.
 */
function readDependencyPublishedAt(pkg: string, network: RealNetwork): string {
  const dir = join(REPO_ROOT, "stablecoin-sui", "packages", pkg);

  // Two layouts have to be accepted, because building a stablecoin-sui package
  // *directly* migrates its legacy `Move.lock` `[env.<network>]` block into a
  // sibling `Published.toml` and removes the block. So:
  //   - a pristine submodule checkout (and CI) has only the Move.lock block;
  //   - a tree where someone ran a build inside the submodule has only
  //     Published.toml, which is untracked and thus absent for everyone else.
  // Both record the same address. Read whichever is present, preferring the
  // migrated file, and never require the untracked one to exist.
  const sources = [
    {
      file: join(dir, "Published.toml"),
      header: `[published.${network}]`,
      idKeys: ["published-at"],
    },
    {
      file: join(dir, "Move.lock"),
      header: `[env.${network}]`,
      // `latest-published-id` is the address to link against; fall back to the
      // original for a package that has never been upgraded.
      idKeys: ["latest-published-id", "original-published-id"],
    },
  ];

  for (const { file, header, idKeys } of sources) {
    if (!existsSync(file)) continue;
    const section = readFileSync(file, "utf-8").split(header)[1];
    if (!section) continue;

    // Guard against a submodule pinned to a different chain than we are
    // deploying to; the ids would otherwise be silently wrong.
    const chainId = section.match(/^\s*chain-id\s*=\s*"([0-9a-f]+)"/m)?.[1];
    const expectedChainId = EXPECTED_CHAIN_IDS[network];
    if (chainId && chainId !== expectedChainId) {
      throw new Error(
        `${file} records ${network} chain-id "${chainId}" but ${network} is ` +
          `"${expectedChainId}".`,
      );
    }

    for (const key of idKeys) {
      const id = section.match(
        new RegExp(`^\\s*${key}\\s*=\\s*"(0x[0-9a-fA-F]+)"`, "m"),
      )?.[1];
      if (id) return id;
    }
  }

  throw new Error(
    `No ${network} publication recorded for stablecoin-sui package "${pkg}". ` +
      `Expected a [published.${network}] block in ${join(dir, "Published.toml")} ` +
      `or an [env.${network}] block in ${join(dir, "Move.lock")}. ` +
      `Re-initialize the submodule with \`./run.sh restore_manifests\`.`,
  );
}

/**
 * The dotenv artifact filename written for a given deploy mode. Localnet keeps
 * the `test_config.*` names the E2E suites already load. A real network gets a
 * per-network default so two deploys targeting the same network cannot
 * overwrite each other's record; `DEPLOY_OUTPUT` lets a config file name them
 * explicitly.
 */
function artifactFilename(
  version: DeployVersion,
  network: DeployNetwork,
): string {
  if (network !== "localnet") {
    return process.env.DEPLOY_OUTPUT ?? `deploy.${network}.env`;
  }
  return version === "1" ? "test_config.v1.env" : "test_config.v2.env";
}

/** Reads a single `KEY=VALUE` from a (possibly indented) dotenv artifact. */
function readArtifactValue(file: string, key: string): string | undefined {
  if (!existsSync(file)) return undefined;
  const match = readFileSync(file, "utf-8").match(
    new RegExp(`^\\s*${key}=(.*)$`, "m"),
  );
  return match ? match[1].trim() : undefined;
}

/**
 * Pre-deploy sanity checks:
 *  1. A Sui node is reachable at the configured RPC url.
 *  2. A previous deployment recorded in this mode's artifact is not still live
 *     on the connected node — re-deploying without a clean node would stack a
 *     second deployment, so fail fast and point at `run.sh start_network`.
 */
async function preflightCheck(
  version: DeployVersion,
  network: DeployNetwork,
  rpcUrl: string,
): Promise<void> {
  try {
    await client.core.getChainIdentifier();
  } catch {
    throw new Error(
      network === "localnet"
        ? `Could not reach a Sui node at ${rpcUrl}. Start one with \`./run.sh start_network\` before deploying.`
        : `Could not reach a Sui node at ${rpcUrl}. Check the ${network} RPC url.`,
    );
  }

  if (network !== "localnet") {
    // gRPC returns the base58 genesis checkpoint digest. Move's chain-id — the
    // value keyed in Published.toml and shown by `sui client envs` — is the
    // first 4 bytes of that digest in hex, so derive it before comparing.
    const { chainIdentifier } = await client.core.getChainIdentifier();
    const chainId = toHex(fromBase58(chainIdentifier).slice(0, 4));
    const expected = EXPECTED_CHAIN_IDS[network];
    if (chainId !== expected) {
      throw new Error(
        `${rpcUrl} reports chain-id "${chainId}" but ${network} is "${expected}". ` +
          `Refusing to publish to the wrong chain.`,
      );
    }
    log(`Connected to ${network} (chain-id ${chainId})`);
  }

  const file = artifactFilename(version, network);
  const keys =
    version === "1"
      ? ["SUI_MESSAGE_TRANSMITTER_ID"]
      : ["SUI_MESSAGE_TRANSMITTER_V2_ID"];

  for (const key of keys) {
    const id = readArtifactValue(file, key);
    if (!id) continue;
    let existingObject: unknown;
    try {
      existingObject = (await client.core.getObject({ objectId: id })).object;
    } catch (e) {
      // gRPC getObject throws a plain Error `Object <id> not found` for a
      // missing object — no typed error / status code is exposed, so the
      // message is the only discriminator. Treat only that as "not live";
      // rethrow anything else (transient RPC / network errors) so a flaky read
      // can't bypass this guard and stack a second deployment on a node with a
      // live prior deploy.
      if (e instanceof Error && /not found/i.test(e.message)) {
        existingObject = undefined;
      } else {
        throw e;
      }
    }
    if (existingObject) {
      throw new Error(
        `A previous deployment recorded in ${file} (${key}=${id}) is still live on this node. ` +
          `Re-running would stack a second deployment. ` +
          (network === "localnet"
            ? `Restart with \`./run.sh start_network\` for a clean node, or delete ${file} if it is stale.`
            : `Move ${file} aside (keep a copy — it is the deployment record) if you really intend to publish again.`),
      );
    }
  }
}

// 1.37.3-compatible Sui framework rev — the one the committed V1 manifests pin
// (override), proven to build the V1 closure under the frozen 1.37.3 compiler.
const FROZEN_V1_SUI_REV = "b023ef895412b22a1db9490d266e96aa5925a890";

// The V1 packages plus the stablecoin-sui packages they build against. For a
// frozen-V1 deploy these all compile with 1.37.3.
const FROZEN_V1_CLOSURE_MANIFESTS = [
  "packages/message_transmitter/Move.toml",
  "packages/token_messenger_minter/Move.toml",
  "stablecoin-sui/packages/sui_extensions/Move.toml",
  "stablecoin-sui/packages/stablecoin/Move.toml",
  "stablecoin-sui/packages/usdc/Move.toml",
];

/**
 * Injects the 1.37.3-compatible Sui framework pin into every manifest in the V1
 * build closure. The frozen 1.37.3 compiler does not auto-inject the framework
 * (unlike 1.76.1), and both the V2 unpin patch (stablecoin-sui) and the V1
 * localnet manifests omit an explicit `[dependencies.Sui]` for the 1.76.1 path —
 * so a frozen-V1 deploy must add it back. `override = true` forces this rev
 * across the closure. Reverted by `run.sh restore_manifests` (git checkout +
 * submodule reset/re-patch) in the deploy's finally.
 */
function pinFrozenV1Framework(): void {
  const block =
    `\n[dependencies.Sui]\n` +
    `git = "https://github.com/MystenLabs/sui.git"\n` +
    `subdir = "crates/sui-framework/packages/sui-framework"\n` +
    `rev = "${FROZEN_V1_SUI_REV}"\n` +
    `override = true\n`;
  for (const rel of FROZEN_V1_CLOSURE_MANIFESTS) {
    const abs = join(REPO_ROOT, rel);
    const src = readFileSync(abs, "utf-8");
    if (/^\s*\[dependencies\.Sui\]/m.test(src)) continue; // already pinned
    if (!src.includes("[addresses]")) {
      throw new Error(`Cannot pin framework: no [addresses] section in ${rel}`);
    }
    writeFileSync(abs, src.replace("[addresses]", `${block}\n[addresses]`));
  }
}

/**
 * Deploys and configures the selected packages for USDC + CCTP.
 */
export async function deploySuiContracts(): Promise<void> {
  const network = resolveNetwork();
  const version = resolveDeployVersion();
  const suiRpcUrl = resolveRpcUrl(network);
  if (deployConfigFile) log(`Loaded deploy config ${deployConfigFile}`);
  // Loud, because publishing from an alternate source tree is never what you
  // want by accident — the packages are indistinguishable once on chain.
  if (PACKAGES_ROOT !== "packages") {
    log(`Publishing V2 packages from alternate root: ${PACKAGES_ROOT}/`);
  }

  client = new SuiGrpcClient({ network, baseUrl: suiRpcUrl });

  await preflightCheck(version, network, suiRpcUrl);

  // A real-network deploy is publish-only. Contract initialization and admin
  // configuration are handled by separate initialization tooling, whose
  // deployer is not assumed to hold the USDC master-minter or any other admin
  // role. Localnet keeps the full publish + init + configure
  // flow because the E2E suites depend on the state objects, MintCap and
  // minted USDC it produces.
  if (network !== "localnet") {
    if (version !== "2") {
      throw new Error(
        `Only --deploy-version 2 is supported for a ${network} deploy; ` +
          `V1 is already deployed to testnet and mainnet.`,
      );
    }
    const initialize = resolveInitialize();
    log(
      `Deploying version=2 to ${network} ` +
        `(${initialize ? "publish + initialize" : "publish only"}) via ${suiRpcUrl}`,
    );
    const deployerAddress = await setupRemoteDeployer(network, suiRpcUrl);

    // The publish is signed by the `sui` CLI's active address, so publish-only
    // is happy with a key that lives solely in the keystore. `init_state` is
    // signed in-process, so --initialize additionally needs the key here.
    let deployerKeypair: Ed25519Keypair | null = null;
    if (initialize) {
      if (!process.env.DEPLOYER_PRIVATE_KEY) {
        throw new Error(
          `--initialize requires DEPLOYER_PRIVATE_KEY. The publish is signed by ` +
            `the sui CLI, but init_state is signed in-process, so a deployer that ` +
            `exists only in the keystore cannot complete initialization.`,
        );
      }
      deployerKeypair = getEd25519KeypairFromPrivateKey(
        process.env.DEPLOYER_PRIVATE_KEY,
      );
      // `setupRemoteDeployer` derives the publishing address from
      // DEPLOYER_PRIVATE_KEY when it is set, and switches the CLI to it — so the
      // key always signs the publish, and DEPLOYER_ADDRESS is silently ignored.
      // That is the mistake worth catching: a config copied from another
      // environment, where the address was updated and the key was not, would
      // publish from whoever owns the key rather than the named deployer.
      const configuredAddress = process.env.DEPLOYER_ADDRESS;
      if (configuredAddress && configuredAddress !== deployerAddress) {
        throw new Error(
          `Config mismatch: DEPLOYER_ADDRESS is ${configuredAddress} but ` +
            `DEPLOYER_PRIVATE_KEY resolves to ${deployerAddress}, which is what ` +
            `would actually publish and own the InitCaps. Fix one or the other.`,
        );
      }
    }

    publishV2Packages(network);
    if (deployerKeypair) {
      await initializeV2Packages(deployerKeypair, network);
    }
    writePublishArtifact(
      network,
      deployerAddress,
      suiRpcUrl,
      deployerKeypair ? { deployerKey: deployerKeypair } : null,
    );
    return;
  }

  const deployUsdc = resolveDeployUsdc();
  log(`Deploying version=${version}, deployUsdc=${deployUsdc}`);

  const suiFaucetUrl = `http://127.0.0.1:${process.env.FAUCET_PORT}`;

  try {
    // A V1 deploy compiles + publishes its whole closure with the frozen 1.37.3
    // toolchain (matching mainnet). V1 is frozen at 1.37.3 (old package
    // management), so it resolves a package's address + deps from the manifest:
    // swap in the localnet manifests (self = 0x0, local-path deps) and pin the
    // 1.37.3-compatible framework so the 1.37.3 compiler can build them. V2
    // (1.76.1) uses a single 0x0 `Move.toml` + `Move.lock` `[env]` sections, so
    // it needs no manifest swap. Reverted in the `finally` below (git checkout),
    // so a local deploy leaves no uncommitted changes.
    const frozenV1 = version === "1";
    setFrozenV1Deploy(frozenV1);
    if (frozenV1) {
      log("Configuring localnet manifests (V1)...");
      execSync("bash configure_manifest.sh localnet", {
        cwd: REPO_ROOT,
        stdio: "inherit",
      });
      pinFrozenV1Framework();
    }

    const deployerKeypair = await setupDeployer(suiRpcUrl, suiFaucetUrl);

    await acquireUsdcStack(deployUsdc);

    if (version === "1") {
      await deployCCTPContracts(deployerKeypair);
      log("Deployed V1 CCTP packages");

      await configureCCTPContracts(deployerKeypair);
      log("Configured V1 CCTP packages");

      linkEvmContractsV1();
    }

    if (version === "2") {
      await deployCCTPV2Contracts(deployerKeypair);
      log("Deployed V2 CCTP packages");

      await configureCCTPV2Contracts(deployerKeypair);
      log("Configured V2 CCTP packages");
    }

    writeArtifact(version, network, deployerKeypair);
  } finally {
    // Restore the Move.toml / Move.lock churn from configure_manifest + publish
    // so a local deploy never leaves uncommitted changes. A cleanup failure must
    // not mask a deploy failure, so swallow (and surface) any error here.
    //
    // LOCALNET ONLY, and guarded explicitly rather than relying on the early
    // return above: `restore_manifests` is a git checkout over every package's
    // Move.toml/Move.lock, so on a real network it would discard whatever that
    // build wrote — including the [pinned.<env>.*] blocks — for any env whose
    // pins are not committed.
    if (network === "localnet") {
      try {
        log("Restoring manifests...");
        execSync("bash run.sh restore_manifests", {
          cwd: REPO_ROOT,
          stdio: "inherit",
        });
      } catch {
        log(
          "Warning: failed to restore manifests; run `./run.sh restore_manifests` manually.",
        );
      }
    }
  }
}

/** True if a `local` client env is already registered. */
function localEnvExists(): boolean {
  const envs = JSON.parse(
    execSync("sui client envs --json", { encoding: "utf-8" }),
  );
  return envs[0].some((e: { alias: string }) => e.alias === "local");
}

/**
 * Ensures a `local` client env pointing at the localnet RPC exists, tolerating
 * `sui client new-env`'s behavior against a freshly-started node. new-env
 * probes the RPC for a chain-id, which can transiently fail right after node
 * bring-up / at an epoch boundary ("The service is currently unavailable") —
 * yet it still records the env, so a naive retry then aborts with "already
 * exists". We therefore treat the env actually existing as success (both before
 * and after the call) and only retry a genuine transient failure that left no
 * env behind. Non-transient failures rethrow immediately.
 */
async function ensureLocalEnv(suiRpcUrl: string): Promise<void> {
  const TRANSIENT_RPC_ERRORS = [
    "service is currently unavailable",
    "service unavailable",
    "connection refused",
    "error sending request",
    "transport error",
  ];
  const maxAttempts = 6;
  const delayMs = 3000;
  for (let attempt = 1; ; attempt++) {
    if (localEnvExists()) return;
    try {
      execSync(`sui client new-env --alias local --rpc ${suiRpcUrl}`);
      return;
    } catch (err) {
      // new-env records the env even when its RPC probe fails, so a written
      // env means we're done regardless of the exit code.
      if (localEnvExists()) return;
      const details = err as {
        stdout?: Buffer | string;
        stderr?: Buffer | string;
        message?: string;
      };
      const haystack =
        `${details.stdout ?? ""}${details.stderr ?? ""}${details.message ?? ""}`.toLowerCase();
      const isTransient = TRANSIENT_RPC_ERRORS.some((sig) =>
        haystack.includes(sig),
      );
      if (!isTransient || attempt >= maxAttempts) {
        throw err;
      }
      log(
        `Transient error creating \`local\` env (attempt ${attempt}/${maxAttempts}), retrying in ${delayMs / 1000}s.`,
      );
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

/**
 * Sets up the local sui env, resolves the deployer keypair, and ensures it
 * is funded. Returns the deployer keypair.
 */
async function setupDeployer(
  suiRpcUrl: string,
  suiFaucetUrl: string,
): Promise<Ed25519Keypair> {
  // Configure the local environment if not already set up (idempotent and
  // tolerant of a still-warming node — see ensureLocalEnv).
  await ensureLocalEnv(suiRpcUrl);

  // Generate and switch to deployer key if not already set up
  let deployerKeypair: Ed25519Keypair;
  if (process.env.DEPLOYER_PRIVATE_KEY) {
    log(`Using provided deployer key ${process.env.DEPLOYER_PRIVATE_KEY}`);
    deployerKeypair = getEd25519KeypairFromPrivateKey(
      process.env.DEPLOYER_PRIVATE_KEY,
    );
  } else {
    deployerKeypair = Ed25519Keypair.generate();
    log(`Generating new deployer key ${deployerKeypair.getSecretKey()}`);
  }
  // Add account to wallet if missing
  execSync(
    `sui keytool list | grep '${deployerKeypair.toSuiAddress()}' || sui keytool import ${deployerKeypair.getSecretKey()} ed25519`,
  );
  log(`Using address ${deployerKeypair.toSuiAddress()}`);

  // Set default SUI account
  execSync(
    `sui client switch --address ${deployerKeypair.toSuiAddress()} --env local`,
  );

  const balance = readSuiBalance("sui", deployerKeypair.toSuiAddress());

  if (balance < 10) {
    log("Address balance is too low, funding...", {
      address: deployerKeypair.toSuiAddress(),
      balance,
      expected: 10,
    });
    await requestSuiFromFaucetV2({
      host: suiFaucetUrl,
      recipient: deployerKeypair.toSuiAddress(),
    });
  } else {
    log("Address already has sufficient balance", {
      address: deployerKeypair.toSuiAddress(),
      balance,
    });
  }

  return deployerKeypair;
}

/**
 * Deploys the USDC/stablecoin stack (localnet), or reads the existing ids
 * from env when `DEPLOY_USDC=false` (testnet/mainnet, where USDC already
 * exists on-chain).
 */
async function acquireUsdcStack(deployUsdc: boolean): Promise<void> {
  if (deployUsdc) {
    await deployUSDCContracts();
    log("Deployed USDC packages");
  } else {
    suiExtensionsPackageId = requireEnv("SUI_EXTENSIONS_ID");
    stablecoinPackageId = requireEnv("SUI_STABLECOIN_ID");
    usdcPackageId = requireEnv("SUI_USDC_ID");
    usdcTreasuryId = requireEnv("SUI_TREASURY_ID");
    log("Using existing USDC packages from env", {
      suiExtensionsPackageId,
      stablecoinPackageId,
      usdcPackageId,
      usdcTreasuryId,
    });
  }
}

/**
 * Deploy the sui_extensions, stablecoin, and USDC packages.
 */
export async function deployUSDCContracts() {
  // Deploy USDC packages
  const suiExtensionsDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/sui_extensions",
  );
  suiExtensionsPackageId = recoverChangedObjectId(
    suiExtensionsDeploymentOutput,
    "published",
  );
  log(`sui_extensions published at ${suiExtensionsPackageId}`);

  const stablecoinDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/stablecoin",
  );
  stablecoinPackageId = recoverChangedObjectId(
    stablecoinDeploymentOutput,
    "published",
  );
  log(`stablecoin published at ${stablecoinPackageId}`);

  const usdcDeploymentOutput = deployHelper(
    "../../stablecoin-sui/packages/usdc",
  );
  usdcPackageId = recoverChangedObjectId(usdcDeploymentOutput, "published");
  log(`usdc published at ${usdcPackageId}`);

  // Recover USDC treasury object
  usdcTreasuryId = recoverChangedObjectId(
    usdcDeploymentOutput,
    "created",
    "treasury::Treasury<",
  );
  log(`USDC treasury object created at ${usdcTreasuryId}`);
}

/**
 * Deploys and initializes the message_transmitter and token_messenger_minter packages.
 */
export async function deployCCTPContracts(deployerKey: Ed25519Keypair) {
  const mtDeploymentOutput = deployHelper("../../packages/message_transmitter");
  mtPackageId = recoverChangedObjectId(mtDeploymentOutput, "published");
  messageTransmitterUpgradeServiceId = recoverChangedObjectId(
    mtDeploymentOutput,
    "created",
    "UpgradeService",
  );
  log(`message_transmitter published at ${mtPackageId}`);
  log(
    `message_transmitter upgrade service object created at ${messageTransmitterUpgradeServiceId}`,
  );
  messageTransmitterUpgradeCapId = recoverChangedObjectId(
    mtDeploymentOutput,
    "created",
    "package::UpgradeCap",
  );
  log(
    `message_transmitter UpgradeCap created at ${messageTransmitterUpgradeCapId}`,
  );

  // Obtain message_transmitter InitCap
  const mtInitCapId = recoverChangedObjectId(
    mtDeploymentOutput,
    "created",
    "initialize::InitCap",
  );
  log(`message_transmitter InitCap found at ${mtInitCapId}`);

  // Initialize message_transmitter state
  const mtInitializeTx = new Transaction();
  mtInitializeTx.moveCall({
    target: `${mtPackageId}::initialize::init_state`,
    arguments: [
      mtInitializeTx.object(mtInitCapId),
      mtInitializeTx.pure.u32(8), // localDomain
      mtInitializeTx.pure.u32(0), // messageVersion
      mtInitializeTx.pure.u64(8192), // maxMessageSize
      mtInitializeTx.pure.address("0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f"), // attester
    ],
  });

  const mtInitTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mtInitializeTx,
  });

  // Obtain message_transmitter state object id
  mtStateId = recoverChangedObjectId(mtInitTxOutput, "created", "state::State");
  log(`message_transmitter state found at ${mtStateId}`);

  // Skip dependency verification for TokenMessengerMinter for now
  const tmmDeploymentOutput = deployHelper(
    "../../packages/token_messenger_minter",
  );
  tmmPackageId = recoverChangedObjectId(tmmDeploymentOutput, "published");
  tokenMessengerUpgradeServiceId = recoverChangedObjectId(
    tmmDeploymentOutput,
    "created",
    "UpgradeService",
  );
  log(`token_messenger_minter deployed at ${tmmPackageId}`);
  log(
    `token_messenger_minter upgrade service object created at ${tokenMessengerUpgradeServiceId}`,
  );
  tokenMessengerUpgradeCapId = recoverChangedObjectId(
    tmmDeploymentOutput,
    "created",
    "package::UpgradeCap",
  );
  log(
    `token_messenger_minter UpgradeCap created at ${tokenMessengerUpgradeCapId}`,
  );

  // Obtain token_messenger_minter InitCap
  const tmmInitCapId = recoverChangedObjectId(
    tmmDeploymentOutput,
    "created",
    "initialize::InitCap",
  );
  log(`token_messenger_minter InitCap found at ${tmmInitCapId}`);

  // Initialize token_messenger_minter state
  const tmmInitializeTx = new Transaction();
  tmmInitializeTx.moveCall({
    target: `${tmmPackageId}::initialize::init_state`,
    arguments: [
      tmmInitializeTx.object(tmmInitCapId),
      tmmInitializeTx.pure.u32(0), // messageBodyVersion
    ],
  });

  const tmmInitTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: tmmInitializeTx,
  });

  // Obtain token_messenger_minter state object id
  tmmStateId = recoverChangedObjectId(
    tmmInitTxOutput,
    "created",
    "state::State",
  );
  log(`token_messenger_minter state found at ${tmmStateId}`);

  // Fetch token id
  const tokenIdTx = new Transaction();
  tokenIdTx.moveCall({
    target: `${tmmPackageId}::token_utils::calculate_token_id`,
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  const tokenIdTxOutput = await callViewFunction({
    client,
    transaction: tokenIdTx,
    returnTypes: [bcs.Address],
  });

  usdcTokenId = tokenIdTxOutput.toString();

  log(`Token ID is ${usdcTokenId}`);
}

/**
 * Configure the CCTP contracts.
 * This adds a remote token messenger, remote token pair, and mint cap.
 */
export async function configureCCTPContracts(deployerKey: Ed25519Keypair) {
  // Add remote resources
  const addRemoteTmTx = new Transaction();
  addRemoteTmTx.moveCall({
    target: `${tmmPackageId}::remote_token_messenger::add_remote_token_messenger`,
    arguments: [
      addRemoteTmTx.pure.u32(0), // remoteDomain
      addRemoteTmTx.pure.address(`${process.env.EVM_TOKEN_MESSENGER_ADDRESS}`), // remote tokenMessenger address
      addRemoteTmTx.object(tmmStateId), // tokenMessenger state
    ],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addRemoteTmTx,
  });

  const setBurnLimitTx = new Transaction();
  setBurnLimitTx.moveCall({
    target: `${tmmPackageId}::token_controller::set_max_burn_amount_per_message`,
    arguments: [
      setBurnLimitTx.pure.u64(100000), // burn limit
      setBurnLimitTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: setBurnLimitTx,
  });

  // Configure a new controller, configure TMM as a minter, & add the mint cap
  const configureNewControllerTx = new Transaction();

  configureNewControllerTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_new_controller`,
    arguments: [
      configureNewControllerTx.object(usdcTreasuryId),
      configureNewControllerTx.pure.address(deployerKey.toSuiAddress()),
      configureNewControllerTx.pure.address(deployerKey.toSuiAddress()),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  const configureNewControllerTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: configureNewControllerTx,
  });

  // Configure the mintCap with a minter allowance
  const configureMinterTx = new Transaction();

  configureMinterTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_minter`,
    arguments: [
      configureMinterTx.object(usdcTreasuryId),
      configureMinterTx.object(DENY_LIST_ID), // fixed denyList address
      configureMinterTx.pure.u64(10000000), // mint allowance
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: configureMinterTx,
  });

  // Mint starter funds to the deployer address
  mintCapObjectId = recoverChangedObjectId(
    configureNewControllerTxOutput,
    "created",
    "treasury::MintCap",
  );
  log("mint cap object id:", mintCapObjectId);

  const mintFundsTx = new Transaction();

  mintFundsTx.moveCall({
    target: `${stablecoinPackageId}::treasury::mint`,
    arguments: [
      mintFundsTx.object(usdcTreasuryId), // USDC treasury object
      mintFundsTx.object(mintCapObjectId), // mint cap
      mintFundsTx.object(DENY_LIST_ID), // fixed denyList address
      mintFundsTx.pure.u64(10000), // amount
      mintFundsTx.pure.address(deployerKey.toSuiAddress()), // recipient
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  const mintFundsTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mintFundsTx,
  });

  usdcFundsObjectId = recoverChangedObjectId(
    mintFundsTxOutput,
    "created",
    "coin::Coin",
  );

  log(
    `Funded deployer address with 10000 USDC, stored at ${usdcFundsObjectId}`,
  );

  // Add mint cap to the token_messenger_minter
  const addMintCapTx = new Transaction();
  addMintCapTx.moveCall({
    target: `${tmmPackageId}::token_controller::add_stablecoin_mint_cap`,
    arguments: [
      addMintCapTx.object(mintCapObjectId),
      addMintCapTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addMintCapTx,
  });

  // Link evm token
  const linkTokenPairTx = new Transaction();
  linkTokenPairTx.moveCall({
    target: `${tmmPackageId}::token_controller::link_token_pair`,
    arguments: [
      linkTokenPairTx.pure.u32(0), // remote domain
      linkTokenPairTx.pure.address(`${process.env.EVM_USDC_ADDRESS}`), // remote token address
      linkTokenPairTx.object(tmmStateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });

  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: linkTokenPairTx,
  });
}

/**
 * Links the V1 EVM contracts to Sui. Skipped unless LINK_EVM_CONTRACTS=true.
 */
function linkEvmContractsV1(): void {
  if (process.env.LINK_EVM_CONTRACTS !== "true") {
    return;
  }

  execSync(
    `~/.foundry/bin/cast send ${process.env.EVM_TOKEN_MINTER_ADDRESS} "function linkTokenPair(address localToken,uint32 remoteDomain,bytes32 remoteToken)" ${process.env.EVM_USDC_ADDRESS} 8 ${usdcTokenId} --rpc-url ${process.env.EVM_RPC_URL} --private-key ${process.env.EVM_TOKEN_MINTER_DEPLOYER_KEY}`,
  );

  // Sui needs to be linked via the MessageTransmitterAuthenticator type as its recipient.
  const remoteRecipientType = `${tmmPackageId.replace("0x", "")}::message_transmitter_authenticator::MessageTransmitterAuthenticator`;
  const hashedRecipient = keccak256(Buffer.from(remoteRecipientType));
  const recipientAddress = `0x${hashedRecipient.toString("hex")}`;

  execSync(
    `~/.foundry/bin/cast send ${process.env.EVM_TOKEN_MESSENGER_ADDRESS} "function addRemoteTokenMessenger(uint32 domain,bytes32 tokenMessenger)" 8 ${recipientAddress} --rpc-url ${process.env.EVM_RPC_URL} --private-key ${process.env.EVM_TOKEN_MESSENGER_DEPLOYER_KEY}`,
  );
  log("Linked V1 EVM contracts to Sui");
}

/**
 * Total SUI balance of `address`, in MIST, via the `sui client balance` CLI.
 * The positional indexing mirrors that command's `--json` shape.
 */
function readSuiBalance(suiBin: string, address: string): number {
  const output: unknown = JSON.parse(
    execSync(
      `${suiBin} client balance ${address} --coin-type 0x2::sui::SUI --json`,
      {
        encoding: "utf-8",
      },
    ),
  );

  // The shape of `sui client balance --json` has changed across CLI versions
  // (1.76.1 nests `{ metadata, balance: { balance: "..." } }`; older releases
  // used positional `[coinType, [coins]]` tuples). Rather than index into one
  // layout — which silently reads 0 against the other, making a balance check
  // useless — sum every string `balance` field found anywhere in the tree.
  let total = 0;
  const visit = (node: unknown): void => {
    if (Array.isArray(node)) {
      node.forEach(visit);
      return;
    }
    if (node && typeof node === "object") {
      const record = node as Record<string, unknown>;
      if (typeof record.balance === "string") {
        total += Number(record.balance);
        return;
      }
      Object.values(record).forEach(visit);
    }
  };
  visit(output);
  return total;
}

/**
 * Prepares the deployer for a real-network publish: resolves the key (never
 * generates one), points the `sui` CLI at the target network, and verifies the
 * balance up front.
 *
 * The CLI env matters: `sui client publish` builds for the *active client env*
 * and rejects `--build-env`, so the env is selected here and its RPC must match
 * the one we preflighted — otherwise we would publish to a different node than
 * the one we checked.
 */
async function setupRemoteDeployer(
  network: DeployNetwork,
  rpcUrl: string,
): Promise<string> {
  const suiBin = resolveSuiBin(network);

  // The publish is performed by `sui client publish`, which signs with the
  // CLI's active address — this process never signs anything on the
  // publish-only path. So a private key is optional: the preferred flow leaves
  // the key in the Sui keystore and never puts it in a config
  // file at all. DEPLOYER_PRIVATE_KEY remains supported for automation that has
  // to supply one. A key is never *generated* for a real network, which would
  // strand the published packages' UpgradeCaps at an address nobody controls.
  let address: string;
  if (process.env.DEPLOYER_PRIVATE_KEY) {
    address = getEd25519KeypairFromPrivateKey(
      process.env.DEPLOYER_PRIVATE_KEY,
    ).toSuiAddress();
  } else {
    const active = execSync(`${suiBin} client active-address`, {
      encoding: "utf-8",
    }).trim();
    address = process.env.DEPLOYER_ADDRESS ?? active;
    if (!address) {
      throw new Error(
        `No deployer for a ${network} deploy. Set DEPLOYER_ADDRESS (with the key ` +
          `already in the sui keystore) or DEPLOYER_PRIVATE_KEY.`,
      );
    }
  }
  // Log the address, never the key.
  log(`Deploying from ${address}`);
  const stripTrailingSlash = (u: string) => u.replace(/\/+$/, "");

  const envs = JSON.parse(
    execSync(`${suiBin} client envs --json`, { encoding: "utf-8" }),
  );
  const existingEnv = envs[0].find(
    (e: { alias: string }) => e.alias === network,
  );
  if (!existingEnv) {
    execSync(`${suiBin} client new-env --alias ${network} --rpc ${rpcUrl}`);
    log(`Created \`${network}\` client env at ${rpcUrl}`);
  } else if (
    stripTrailingSlash(existingEnv.rpc) !== stripTrailingSlash(rpcUrl)
  ) {
    throw new Error(
      `The \`${network}\` sui client env points at ${existingEnv.rpc} but this deploy ` +
        `targets ${rpcUrl}. The publish builds against the active client env, so they must agree.`,
    );
  }

  // Import only when a key was supplied. It is passed by shell expansion rather
  // than interpolated into the command string: it still reaches `sui keytool`'s
  // argv, but stays out of this process's command line and out of any log.
  const known = execSync(`${suiBin} keytool list`, {
    encoding: "utf-8",
  }).includes(address);
  if (!known) {
    if (!process.env.DEPLOYER_PRIVATE_KEY) {
      throw new Error(
        `${address} is not in the sui keystore and no DEPLOYER_PRIVATE_KEY was ` +
          `supplied, so the publish could not be signed.`,
      );
    }
    execSync(`${suiBin} keytool import "$DEPLOYER_PRIVATE_KEY" ed25519`);
  }
  execSync(`${suiBin} client switch --address ${address} --env ${network}`);

  let balance = readSuiBalance(suiBin, address);
  if (balance < MIN_PUBLISH_BALANCE_MIST && network === "testnet") {
    log("Balance below publish threshold, requesting testnet faucet funds...", {
      address,
      balance,
      required: MIN_PUBLISH_BALANCE_MIST,
    });
    await requestSuiFromFaucetV2({
      host: getFaucetHost("testnet"),
      recipient: address,
    });
    balance = readSuiBalance(suiBin, address);
  }
  if (balance < MIN_PUBLISH_BALANCE_MIST) {
    throw new Error(
      `Deployer ${address} holds ${balance} MIST but a V2 publish needs at least ` +
        `${MIN_PUBLISH_BALANCE_MIST} MIST (~${MIN_PUBLISH_BALANCE_MIST / 1e9} SUI). ` +
        (network === "mainnet"
          ? `Fund it before deploying — there is no mainnet faucet.`
          : `Fund it and retry.`),
    );
  }
  log(`Deployer balance ${balance} MIST`);

  return address;
}

/**
 * Publishes the four V2 packages to a real network in dependency order, with
 * no initialization or admin configuration — those belong to separate
 * initialization tooling. Records the package ids plus the UpgradeService,
 * UpgradeCap and InitCap objects created by each publish.
 */
function publishV2Packages(network: RealNetwork): void {
  // The compiler binds these from stablecoin-sui's own Published.toml; we read
  // the same file so the artifact reports exactly what was linked against.
  [suiExtensionsPackageId, stablecoinPackageId, usdcPackageId] =
    STABLECOIN_SUI_DEPENDENCIES.map((pkg) =>
      readDependencyPublishedAt(pkg, network),
    );
  log("Resolved stablecoin-sui dependencies", {
    suiExtensionsPackageId,
    stablecoinPackageId,
    usdcPackageId,
  });

  // 1. cctp_extensions — a pure library: no init_state, no InitCap, no
  //    UpgradeService. Only the package id and its UpgradeCap exist.
  const extOutput = deployHelper(v2PackagePath("cctp_extensions"), network);
  cctpExtensionsPackageId = recoverChangedObjectId(extOutput, "published");
  log(`cctp_extensions published at ${cctpExtensionsPackageId}`);

  // 2. message_transmitter_v2
  const mtV2Output = deployHelper(
    v2PackagePath("message_transmitter_v2"),
    network,
  );
  mtV2PackageId = recoverChangedObjectId(mtV2Output, "published");
  mtV2UpgradeServiceId = recoverChangedObjectId(
    mtV2Output,
    "created",
    "UpgradeService",
  );
  mtV2UpgradeCapId = recoverChangedObjectId(
    mtV2Output,
    "created",
    "package::UpgradeCap",
  );
  publishedInitCapIds.messageTransmitterV2 = recoverChangedObjectId(
    mtV2Output,
    "created",
    "initialize::InitCap",
  );
  log(`message_transmitter_v2 published at ${mtV2PackageId}`);

  // 3. token_messenger_minter_v2
  const tmmV2Output = deployHelper(
    v2PackagePath("token_messenger_minter_v2"),
    network,
  );
  tmmV2PackageId = recoverChangedObjectId(tmmV2Output, "published");
  tmmV2UpgradeServiceId = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "UpgradeService",
  );
  tmmV2UpgradeCapId = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "package::UpgradeCap",
  );
  publishedInitCapIds.tokenMessengerMinterV2 = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "initialize::InitCap",
  );
  log(`token_messenger_minter_v2 published at ${tmmV2PackageId}`);

  // 4. stablecoin_handler
  const handlerOutput = deployHelper(
    v2PackagePath("stablecoin_handler"),
    network,
  );
  handlerPackageId = recoverChangedObjectId(handlerOutput, "published");
  handlerUpgradeServiceId = recoverChangedObjectId(
    handlerOutput,
    "created",
    "UpgradeService",
  );
  handlerUpgradeCapId = recoverChangedObjectId(
    handlerOutput,
    "created",
    "package::UpgradeCap",
  );
  publishedInitCapIds.stablecoinHandler = recoverChangedObjectId(
    handlerOutput,
    "created",
    "initialize::InitCap",
  );
  log(`stablecoin_handler published at ${handlerPackageId}`);
}

/**
 * Publishes and initializes the four V2 packages in dependency order:
 * cctp_extensions -> message_transmitter_v2 -> token_messenger_minter_v2 ->
 * stablecoin_handler.
 */
export async function deployCCTPV2Contracts(deployerKey: Ed25519Keypair) {
  attesterAddress = process.env.ATTESTER_ADDRESS ?? DEFAULT_ATTESTER;

  // 1. cctp_extensions (pure library; no init, no state)
  const cctpExtensionsOutput = deployHelper(v2PackagePath("cctp_extensions"));
  cctpExtensionsPackageId = recoverChangedObjectId(
    cctpExtensionsOutput,
    "published",
  );
  log(`cctp_extensions published at ${cctpExtensionsPackageId}`);

  // 2. message_transmitter_v2
  const mtV2Output = deployHelper(v2PackagePath("message_transmitter_v2"));
  mtV2PackageId = recoverChangedObjectId(mtV2Output, "published");
  mtV2UpgradeServiceId = recoverChangedObjectId(
    mtV2Output,
    "created",
    "UpgradeService",
  );
  mtV2UpgradeCapId = recoverChangedObjectId(
    mtV2Output,
    "created",
    "package::UpgradeCap",
  );
  const mtV2InitCapId = recoverChangedObjectId(
    mtV2Output,
    "created",
    "initialize::InitCap",
  );
  log(`message_transmitter_v2 published at ${mtV2PackageId}`);
  log(
    `message_transmitter_v2 upgrade service object created at ${mtV2UpgradeServiceId}`,
  );

  const mtV2InitTx = new Transaction();
  mtV2InitTx.moveCall({
    target: `${mtV2PackageId}::initialize::init_state`,
    arguments: [
      mtV2InitTx.object(mtV2InitCapId),
      mtV2InitTx.pure.u32(SUI_LOCAL_DOMAIN), // localDomain
      mtV2InitTx.pure.u32(V2_MESSAGE_VERSION), // messageVersion
      mtV2InitTx.pure.u64(MAX_MESSAGE_BODY_SIZE), // maxMessageBodySize
      mtV2InitTx.pure.address(attesterAddress), // attester (enabled at init)
    ],
  });
  const mtV2InitOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mtV2InitTx,
  });
  mtV2StateId = recoverChangedObjectId(
    mtV2InitOutput,
    "created",
    "state::State",
  );
  log(`message_transmitter_v2 state found at ${mtV2StateId}`);

  // 3. token_messenger_minter_v2
  const tmmV2Output = deployHelper(v2PackagePath("token_messenger_minter_v2"));
  tmmV2PackageId = recoverChangedObjectId(tmmV2Output, "published");
  tmmV2UpgradeServiceId = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "UpgradeService",
  );
  tmmV2UpgradeCapId = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "package::UpgradeCap",
  );
  const tmmV2InitCapId = recoverChangedObjectId(
    tmmV2Output,
    "created",
    "initialize::InitCap",
  );
  log(`token_messenger_minter_v2 published at ${tmmV2PackageId}`);
  log(
    `token_messenger_minter_v2 upgrade service object created at ${tmmV2UpgradeServiceId}`,
  );

  const tmmV2InitTx = new Transaction();
  tmmV2InitTx.moveCall({
    target: `${tmmV2PackageId}::initialize::init_state`,
    arguments: [
      tmmV2InitTx.object(tmmV2InitCapId),
      tmmV2InitTx.pure.u32(V2_MESSAGE_BODY_VERSION), // messageBodyVersion
    ],
  });
  const tmmV2InitOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: tmmV2InitTx,
  });
  tmmV2StateId = recoverChangedObjectId(
    tmmV2InitOutput,
    "created",
    "state::State",
  );
  log(`token_messenger_minter_v2 state found at ${tmmV2StateId}`);

  // 4. stablecoin_handler
  const handlerOutput = deployHelper(v2PackagePath("stablecoin_handler"));
  handlerPackageId = recoverChangedObjectId(handlerOutput, "published");
  handlerUpgradeServiceId = recoverChangedObjectId(
    handlerOutput,
    "created",
    "UpgradeService",
  );
  handlerUpgradeCapId = recoverChangedObjectId(
    handlerOutput,
    "created",
    "package::UpgradeCap",
  );
  const handlerInitCapId = recoverChangedObjectId(
    handlerOutput,
    "created",
    "initialize::InitCap",
  );
  log(`stablecoin_handler published at ${handlerPackageId}`);
  log(
    `stablecoin_handler upgrade service object created at ${handlerUpgradeServiceId}`,
  );

  const handlerInitTx = new Transaction();
  handlerInitTx.moveCall({
    target: `${handlerPackageId}::initialize::init_state`,
    arguments: [handlerInitTx.object(handlerInitCapId)],
  });
  const handlerInitOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: handlerInitTx,
  });
  handlerStateId = recoverChangedObjectId(
    handlerInitOutput,
    "created",
    "state::State",
  );
  log(`stablecoin_handler state found at ${handlerStateId}`);

  // Compute the local USDC token id (feeds register_handler + set_min_fee).
  const tokenIdTx = new Transaction();
  tokenIdTx.moveCall({
    target: `${tmmV2PackageId}::token_utils::calculate_token_id`,
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  const tokenIdTxOutput = await callViewFunction({
    client,
    transaction: tokenIdTx,
    returnTypes: [bcs.Address],
  });
  usdcTokenIdV2 = tokenIdTxOutput.toString();
  log(`V2 token ID is ${usdcTokenIdV2}`);
}

/**
 * Configures the V2 contracts: installs the handler's MintCap, wires remote
 * domain / token pair / burn limit, registers the handler, and sets the min
 * fee. `controllerKey` is the USDC treasury controller (defaults to the
 * deployer).
 */
export async function configureCCTPV2Contracts(
  deployerKey: Ed25519Keypair,
  controllerKey: Ed25519Keypair = deployerKey,
) {
  feeRecipientAddress =
    process.env.FEE_RECIPIENT_ADDRESS ?? deployerKey.toSuiAddress();

  // Configure a controller + mint cap on the USDC treasury. The MintCap is
  // transferred to the deployer (minter) so it can be installed into the
  // handler below.
  const configureNewControllerTx = new Transaction();
  configureNewControllerTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_new_controller`,
    arguments: [
      configureNewControllerTx.object(usdcTreasuryId),
      configureNewControllerTx.pure.address(controllerKey.toSuiAddress()), // controller
      configureNewControllerTx.pure.address(deployerKey.toSuiAddress()), // minter (receives MintCap)
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  const configureNewControllerTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey, // master minter
    transaction: configureNewControllerTx,
  });
  mintCapV2ObjectId = recoverChangedObjectId(
    configureNewControllerTxOutput,
    "created",
    "treasury::MintCap",
  );
  log("V2 mint cap object id:", mintCapV2ObjectId);

  // Configure the mint cap allowance (must be signed by the controller).
  const configureMinterTx = new Transaction();
  configureMinterTx.moveCall({
    target: `${stablecoinPackageId}::treasury::configure_minter`,
    arguments: [
      configureMinterTx.object(usdcTreasuryId),
      configureMinterTx.object(DENY_LIST_ID),
      configureMinterTx.pure.u64(MINT_ALLOWANCE),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  await executeTransactionHelper({
    client,
    signer: controllerKey,
    transaction: configureMinterTx,
  });

  // Mint starter funds to the deployer (before the MintCap moves into the
  // handler) so downstream burn tests have USDC to work with.
  const mintFundsTx = new Transaction();
  mintFundsTx.moveCall({
    target: `${stablecoinPackageId}::treasury::mint`,
    arguments: [
      mintFundsTx.object(usdcTreasuryId),
      mintFundsTx.object(mintCapV2ObjectId),
      mintFundsTx.object(DENY_LIST_ID),
      mintFundsTx.pure.u64(STARTER_MINT_AMOUNT),
      mintFundsTx.pure.address(deployerKey.toSuiAddress()),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  const mintFundsTxOutput = await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: mintFundsTx,
  });
  usdcFundsV2ObjectId = recoverChangedObjectId(
    mintFundsTxOutput,
    "created",
    "coin::Coin",
  );
  log(
    `Funded deployer with ${STARTER_MINT_AMOUNT} USDC (V2), stored at ${usdcFundsV2ObjectId}`,
  );

  // Install the MintCap into the handler's State (mint_controller = deployer).
  const addMintCapTx = new Transaction();
  addMintCapTx.moveCall({
    target: `${handlerPackageId}::mint_controller::add_mint_cap`,
    arguments: [
      addMintCapTx.object(mintCapV2ObjectId),
      addMintCapTx.object(handlerStateId),
    ],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addMintCapTx,
  });

  // Link the remote (EVM) token messenger. Prefer the V2-specific var,
  // falling back to the shared var when it isn't set.
  const evmRemoteTokenMessenger =
    process.env.EVM_TOKEN_MESSENGER_V2_ADDRESS ??
    process.env.EVM_TOKEN_MESSENGER_ADDRESS;
  const addRemoteTmTx = new Transaction();
  addRemoteTmTx.moveCall({
    target: `${tmmV2PackageId}::remote_token_messenger::add_remote_token_messenger`,
    arguments: [
      addRemoteTmTx.pure.u32(REMOTE_EVM_DOMAIN),
      addRemoteTmTx.pure.address(`${evmRemoteTokenMessenger}`),
      addRemoteTmTx.object(tmmV2StateId),
    ],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: addRemoteTmTx,
  });

  // Set the per-message burn limit.
  const setBurnLimitTx = new Transaction();
  setBurnLimitTx.moveCall({
    target: `${tmmV2PackageId}::token_controller::set_max_burn_amount_per_message`,
    arguments: [
      setBurnLimitTx.pure.u64(BURN_LIMIT_PER_MESSAGE),
      setBurnLimitTx.object(tmmV2StateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: setBurnLimitTx,
  });

  // Link the local <-> remote token pair.
  const linkTokenPairTx = new Transaction();
  linkTokenPairTx.moveCall({
    target: `${tmmV2PackageId}::token_controller::link_token_pair`,
    arguments: [
      linkTokenPairTx.pure.u32(REMOTE_EVM_DOMAIN),
      linkTokenPairTx.pure.address(`${process.env.EVM_USDC_ADDRESS}`),
      linkTokenPairTx.object(tmmV2StateId),
    ],
    typeArguments: [`${usdcPackageId}::usdc::USDC`],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: linkTokenPairTx,
  });

  // Register the handler as the authorized handler for USDC. Authorization is
  // bound to the handler's witness type (`handler::Auth`), passed as a type
  // argument; the contract stores the keccak256 of its fully-qualified name.
  const registerHandlerTx = new Transaction();
  registerHandlerTx.moveCall({
    target: `${tmmV2PackageId}::handler_registry::register_handler`,
    typeArguments: [`${handlerPackageId}::handler::Auth`],
    arguments: [
      registerHandlerTx.object(tmmV2StateId),
      registerHandlerTx.pure.address(usdcTokenIdV2), // token address (local token id)
    ],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: registerHandlerTx,
  });

  // Set the min fee for USDC to 0 (smoke default; populates the min_fees entry).
  const setMinFeeTx = new Transaction();
  setMinFeeTx.moveCall({
    target: `${tmmV2PackageId}::fee_controller::set_min_fee`,
    arguments: [
      setMinFeeTx.object(tmmV2StateId),
      setMinFeeTx.pure.address(usdcTokenIdV2), // burn token (local token id)
      setMinFeeTx.pure.u256(0), // min fee
    ],
  });
  await executeTransactionHelper({
    client,
    signer: deployerKey,
    transaction: setMinFeeTx,
  });

  // Optionally rotate the fee recipient away from the deployer default.
  if (process.env.FEE_RECIPIENT_ADDRESS) {
    const setFeeRecipientTx = new Transaction();
    setFeeRecipientTx.moveCall({
      target: `${tmmV2PackageId}::fee_controller::set_fee_recipient`,
      arguments: [
        setFeeRecipientTx.object(tmmV2StateId),
        setFeeRecipientTx.pure.address(feeRecipientAddress),
      ],
    });
    await executeTransactionHelper({
      client,
      signer: deployerKey,
      transaction: setFeeRecipientTx,
    });
    log(`Set V2 fee recipient to ${feeRecipientAddress}`);
  }
}

/**
 * Writes the per-mode deployment summary artifact consumed by downstream
 * test scripts.
 */
function writeArtifact(
  version: DeployVersion,
  network: DeployNetwork,
  deployerKeypair: Ed25519Keypair,
): void {
  const sharedLines = [
    `SUI_USDC_ID=${usdcPackageId}`,
    `SUI_TREASURY_ID=${usdcTreasuryId}`,
    `SUI_EXTENSIONS_ID=${suiExtensionsPackageId}`,
    `SUI_STABLECOIN_ID=${stablecoinPackageId}`,
    `SUI_DEPLOYER_KEY=${deployerKeypair.getSecretKey()}`,
  ];

  const v1Lines = [
    `SUI_MESSAGE_TRANSMITTER_ID=${mtPackageId}`,
    `SUI_MESSAGE_TRANSMITTER_STATE_ID=${mtStateId}`,
    `SUI_MESSAGE_TRANSMITTER_UPGRADE_SERVICE_ID=${messageTransmitterUpgradeServiceId}`,
    `SUI_MESSAGE_TRANSMITTER_UPGRADE_CAP_ID=${messageTransmitterUpgradeCapId}`,
    `SUI_TOKEN_MESSENGER_MINTER_ID=${tmmPackageId}`,
    `SUI_TOKEN_MESSENGER_MINTER_STATE_ID=${tmmStateId}`,
    `SUI_TOKEN_MESSENGER_MINTER_UPGRADE_SERVICE_ID=${tokenMessengerUpgradeServiceId}`,
    `SUI_TOKEN_MESSENGER_MINTER_UPGRADE_CAP_ID=${tokenMessengerUpgradeCapId}`,
    `SUI_USDC_FUNDS_OBJECT_ID=${usdcFundsObjectId}`,
    `SUI_MINT_CAP_ID=${mintCapObjectId}`,
    `SUI_USDC_CCTP_ID=${usdcTokenId}`,
  ];

  const v2Lines = [
    `SUI_CCTP_EXTENSIONS_ID=${cctpExtensionsPackageId}`,
    `SUI_MESSAGE_TRANSMITTER_V2_ID=${mtV2PackageId}`,
    `SUI_MESSAGE_TRANSMITTER_V2_STATE_ID=${mtV2StateId}`,
    `SUI_MESSAGE_TRANSMITTER_V2_UPGRADE_SERVICE_ID=${mtV2UpgradeServiceId}`,
    `SUI_MESSAGE_TRANSMITTER_V2_UPGRADE_CAP_ID=${mtV2UpgradeCapId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_ID=${tmmV2PackageId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_STATE_ID=${tmmV2StateId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_UPGRADE_SERVICE_ID=${tmmV2UpgradeServiceId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_UPGRADE_CAP_ID=${tmmV2UpgradeCapId}`,
    `SUI_STABLECOIN_HANDLER_ID=${handlerPackageId}`,
    `SUI_STABLECOIN_HANDLER_STATE_ID=${handlerStateId}`,
    `SUI_STABLECOIN_HANDLER_UPGRADE_SERVICE_ID=${handlerUpgradeServiceId}`,
    `SUI_STABLECOIN_HANDLER_UPGRADE_CAP_ID=${handlerUpgradeCapId}`,
    `SUI_MINT_CAP_V2_ID=${mintCapV2ObjectId}`,
    `SUI_USDC_TOKEN_ID_V2=${usdcTokenIdV2}`,
    `SUI_USDC_FUNDS_V2_OBJECT_ID=${usdcFundsV2ObjectId}`,
    `SUI_ATTESTER_ADDRESS=${attesterAddress}`,
    `SUI_FEE_RECIPIENT_ADDRESS=${feeRecipientAddress}`,
  ];

  const lines =
    version === "1"
      ? [...v1Lines, ...sharedLines]
      : [...v2Lines, ...sharedLines];

  const filename = artifactFilename(version, network);
  const deploymentConfig = lines.map((line) => `    ${line}`).join("\n") + "\n";

  writeFileSync(filename, deploymentConfig);
  log(`Wrote deployment artifact ${filename}`);
}

/**
 * Writes the deployment record for a real-network publish.
 *
 * Deliberately excludes the deployer private key and the State object ids
 * (nothing is initialized here — separate initialization tooling creates
 * those). UpgradeCap ids are also recorded in each package's `Published.toml`,
 * but repeated here so this one file is enough to hand off.
 */
/**
 * Runs `init_state` for the three stateful V2 packages after a real-network
 * publish, producing the `State` objects that `migration::*` operates on.
 *
 * Mirrors the localnet flow's initialization exactly — same calls, same
 * arguments — so there is one definition of what "initialized" means. It stops
 * there: configuration is not performed (see `resolveInitialize`).
 *
 * `cctp_extensions` is absent by design: a pure library with no InitCap and no
 * state.
 */
async function initializeV2Packages(
  deployerKey: Ed25519Keypair,
  network: DeployNetwork,
): Promise<void> {
  attesterAddress = process.env.ATTESTER_ADDRESS ?? DEFAULT_ATTESTER;
  log(`Initializing V2 packages on ${network} (attester ${attesterAddress})`);

  // 1. message_transmitter_v2
  const mtV2InitTx = new Transaction();
  mtV2InitTx.moveCall({
    target: `${mtV2PackageId}::initialize::init_state`,
    arguments: [
      mtV2InitTx.object(publishedInitCapIds.messageTransmitterV2),
      mtV2InitTx.pure.u32(SUI_LOCAL_DOMAIN), // localDomain
      mtV2InitTx.pure.u32(V2_MESSAGE_VERSION), // messageVersion
      mtV2InitTx.pure.u64(MAX_MESSAGE_BODY_SIZE), // maxMessageBodySize
      mtV2InitTx.pure.address(attesterAddress), // attester (enabled at init)
    ],
  });
  mtV2StateId = recoverChangedObjectId(
    await executeTransactionHelper({
      client,
      signer: deployerKey,
      transaction: mtV2InitTx,
    }),
    "created",
    "state::State",
  );
  log(`message_transmitter_v2 state created at ${mtV2StateId}`);

  // 2. token_messenger_minter_v2
  const tmmV2InitTx = new Transaction();
  tmmV2InitTx.moveCall({
    target: `${tmmV2PackageId}::initialize::init_state`,
    arguments: [
      tmmV2InitTx.object(publishedInitCapIds.tokenMessengerMinterV2),
      tmmV2InitTx.pure.u32(V2_MESSAGE_BODY_VERSION), // messageBodyVersion
    ],
  });
  tmmV2StateId = recoverChangedObjectId(
    await executeTransactionHelper({
      client,
      signer: deployerKey,
      transaction: tmmV2InitTx,
    }),
    "created",
    "state::State",
  );
  log(`token_messenger_minter_v2 state created at ${tmmV2StateId}`);

  // 3. stablecoin_handler
  const handlerInitTx = new Transaction();
  handlerInitTx.moveCall({
    target: `${handlerPackageId}::initialize::init_state`,
    arguments: [handlerInitTx.object(publishedInitCapIds.stablecoinHandler)],
  });
  handlerStateId = recoverChangedObjectId(
    await executeTransactionHelper({
      client,
      signer: deployerKey,
      transaction: handlerInitTx,
    }),
    "created",
    "state::State",
  );
  log(`stablecoin_handler state created at ${handlerStateId}`);
}

function writePublishArtifact(
  network: DeployNetwork,
  deployerAddress: string,
  rpcUrl: string,
  initialized: { deployerKey: Ed25519Keypair } | null = null,
): void {
  const lines = [
    `# CCTP V2 deployment record — ${network}`,
    `# Generated by \`yarn deploy\`.`,
    ``,
    `SUI_NETWORK=${network}`,
    // Without this, anything consuming the record falls back to a localnet URL
    // (see upgradeConfig::loadRpcUrl) — a record that says "testnet" while
    // pointing the tooling at localhost:9001.
    `SUI_RPC_URL=${rpcUrl}`,
    `SUI_DEPLOYER_ADDRESS=${deployerAddress}`,
    ``,
    `# Published CCTP V2 packages`,
    `SUI_CCTP_EXTENSIONS_ID=${cctpExtensionsPackageId}`,
    `SUI_MESSAGE_TRANSMITTER_V2_ID=${mtV2PackageId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_ID=${tmmV2PackageId}`,
    `SUI_STABLECOIN_HANDLER_ID=${handlerPackageId}`,
    ``,
    `# Shared UpgradeService objects, created at publish time`,
    `SUI_MESSAGE_TRANSMITTER_V2_UPGRADE_SERVICE_ID=${mtV2UpgradeServiceId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_UPGRADE_SERVICE_ID=${tmmV2UpgradeServiceId}`,
    `SUI_STABLECOIN_HANDLER_UPGRADE_SERVICE_ID=${handlerUpgradeServiceId}`,
    ``,
    `# UpgradeCaps, owned by the deployer (also in each Published.toml)`,
    `SUI_MESSAGE_TRANSMITTER_V2_UPGRADE_CAP_ID=${mtV2UpgradeCapId}`,
    `SUI_TOKEN_MESSENGER_MINTER_V2_UPGRADE_CAP_ID=${tmmV2UpgradeCapId}`,
    `SUI_STABLECOIN_HANDLER_UPGRADE_CAP_ID=${handlerUpgradeCapId}`,
    ``,
    ...(initialized
      ? [
          `# State objects, created by init_state at deploy time (--initialize).`,
          `# These are what the upgrade/migration tooling operates on.`,
          `SUI_MESSAGE_TRANSMITTER_V2_STATE_ID=${mtV2StateId}`,
          `SUI_TOKEN_MESSENGER_MINTER_V2_STATE_ID=${tmmV2StateId}`,
          `SUI_STABLECOIN_HANDLER_STATE_ID=${handlerStateId}`,
          ``,
          `# Signing key for the migration tooling, which signs in-process rather`,
          `# than through the CLI keystore. Present only because --initialize`,
          `# required a key here; a publish-only deploy never records one.`,
          `SUI_DEPLOYER_KEY=${initialized.deployerKey.getSecretKey()}`,
          ``,
          `# InitCaps were CONSUMED by init_state above and no longer exist.`,
        ]
      : [
          `# InitCaps, owned by the deployer and consumed by init_state. The`,
          `# deploying key must therefore run initialization, or these`,
          `# must be transferred to whoever does.`,
          `SUI_MESSAGE_TRANSMITTER_V2_INIT_CAP_ID=${publishedInitCapIds.messageTransmitterV2}`,
          `SUI_TOKEN_MESSENGER_MINTER_V2_INIT_CAP_ID=${publishedInitCapIds.tokenMessengerMinterV2}`,
          `SUI_STABLECOIN_HANDLER_INIT_CAP_ID=${publishedInitCapIds.stablecoinHandler}`,
        ]),
    ``,
    `# Pre-existing stablecoin-sui packages these were linked against`,
    `SUI_EXTENSIONS_ID=${suiExtensionsPackageId}`,
    `SUI_STABLECOIN_ID=${stablecoinPackageId}`,
    `SUI_USDC_ID=${usdcPackageId}`,
  ];

  const filename = artifactFilename("2", network);
  writeFileSync(filename, lines.join("\n") + "\n");
  log(`Wrote deployment record ${filename}`);
}

deploySuiContracts().catch((err) => {
  console.error(err);
  process.exit(1);
});
