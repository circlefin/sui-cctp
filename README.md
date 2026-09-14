# sui-cctp

Official repository for Sui smart contracts used by the Cross-Chain Transfer Protocol.

[CCTP Documentation](https://developers.circle.com/stablecoins/cctp-getting-started)

## Getting Started

### Prerequisites

Before you can get started working on the contracts in this repository, make sure you have the following prerequisites installed:

1. [Install Rust.](https://doc.rust-lang.org/book/ch01-01-installation.html#installing-rustup-on-linux-or-macos)

2. Install the pinned Sui toolchains:

    ```bash
    ./setup.sh
    ```

    `setup.sh` performs the full one-time setup:

    - **Toolchains** — downloads the pinned Sui release binaries into `./bin/<version>/`. Two are installed: v1.37.3 for the V1 packages and v1.76.1 for the V2 packages. The V1 packages are frozen, already-deployed artifacts, so they build under their original Sui release; V2 (and anything new) tracks the current release. See `versions.sh` for the package → toolchain mapping (the source of truth for the pinned versions).
    - **`stablecoin-sui` submodule** — initializes and clones it (`git submodule update --init --recursive`), so a plain `git clone` without `--recurse-submodules` still works.
    - **Unpin patch** — applies `patches/stablecoin-sui-unpin-dependencies.patch` to that submodule, stripping its divergent framework pin so the V2 tree resolves the compiler-injected 1.76.1 framework. The submodule stays at its pinned commit; the patch only modifies its working tree, which `.gitmodules` marks `ignore = dirty` so `git status` stays quiet. Re-running `setup.sh` is safe — the patch is skipped if already applied.

    If you cloned without submodules, or need to (re)apply the submodule + patch by hand — e.g. after a `git submodule update` reset it — the manual equivalent of the last two steps is:

    ```bash
    git submodule update --init --recursive
    (cd stablecoin-sui && git apply ../patches/stablecoin-sui-unpin-dependencies.patch)
    ```

    To install just one toolchain, pass a version, e.g. `./setup.sh v1.37.3`.

### IDE

- VSCode is recommended for developing Move for Sui.
- [Move (Extension)](https://marketplace.visualstudio.com/items?itemName=mysten.move) is a language server extension for Move. **Note**: additional installation steps required. Please follow the plugin's installation guide.
- [Move Syntax](https://marketplace.visualstudio.com/items?itemName=damirka.move-syntax) a simple syntax highlighting extension for Move.

### Build and Test Contracts

1. Compile all Move contracts from project root:

    ```bash
    ./run.sh build
    ```

    `run.sh` builds every package with its pinned toolchain (V1 → v1.37.3, V2 → v1.76.1). Building a V1 package with a bare `sui move build` will fail, because V1 is pinned to the v1.37.3 framework and requires the matching compiler, unless you have the legacy compiler version in your path. The V2 packages track the current release and can be built individually — the current toolchain requires a build-environment flag (`-e mainnet` or `-e testnet`; for a plain local build the choice is immaterial, since the dependency graph is then all local source — but it is *not* immaterial when a dependency resolves to a package already published on that network, which is what `verify_bytecode` relies on):

    ```bash
    sui move build --path packages/message_transmitter_v2 -e mainnet
    sui move build --path packages/token_messenger_minter_v2 -e mainnet
    sui move build --path packages/cctp_extensions -e mainnet
    sui move build --path packages/stablecoin_handler -e mainnet
    ```

2. Run tests and see test coverage:

    ```bash
    ./test_and_cov.sh
    ```

3. If test coverage is < 100%, view the coverage line by line. Like `build`/`test`, the V2 (current-toolchain) packages need the build-environment flag (`-e mainnet`); the frozen V1 packages omit it:

    ```bash
    # V2 (current toolchain)
    sui move coverage source --path packages/{package_path} --module {module_name} -e mainnet
    # V1 (frozen mainnet-v1.37.3)
    sui move coverage source --path packages/{package_path} --module {module_name}
    ```

### Publish Contracts Locally

The `deploy` script publishes and configures the CCTP packages against a local Sui node and writes a `test_config.*.env` artifact — every package ID, `State` ID, `MintCap` ID, and `UpgradeService` ID — consumed by the example scripts and E2E tests. Each deploy is self-contained: for a V1 deploy it swaps in the frozen-V1 localnet manifests before publishing (V2 uses a single `Move.toml`, no swap) and restores everything (`Move.toml` / `Move.lock`, including the `stablecoin-sui` submodule) afterward, so a local deploy leaves no uncommitted changes — you never need to run `configure_manifest.sh` yourself.

1. Start a local Sui node. An Anvil EVM network is also required for EVM linking (`deploy-local:v1`) and the E2E tests:

    ```bash
    ./run.sh start_network
    # Only needed for EVM linking / E2E tests:
    ./setup-evm-contracts.sh
    ```

2. In `scripts/`, create your `.env` and install dependencies. If `DEPLOYER_PRIVATE_KEY` is unset, the script generates a new keypair.

    ```bash
    cd scripts
    cp .env.example .env
    yarn install
    ```

3. Deploy the version you want (`--deploy-version` is required — V1 and V2 deploy separately):

    ```bash
    yarn deploy-local:v1     # V1 -> test_config.v1.env; also links the EVM contracts (needs Anvil)
    yarn deploy-local:v2     # V2 -> test_config.v2.env
    ```

    `deploy-local:v1` links the V1 EVM contracts (Anvil required); the `deploy-skip-linking-local:v1` variant is identical but skips that linking. V2 never links EVM contracts — the V2 E2E synthesizes EVM messages in TypeScript rather than running a live EVM node (mirroring the Aptos V2 suite), so `deploy-local:v2` needs no Anvil. Under the hood the mode comes from the required `--deploy-version <1|2>` flag (or the `DEPLOY_VERSION` env var; the flag wins). V1 and V2 must deploy separately — they need different toolchains (frozen 1.37.3 vs current) for the shared stablecoin-sui dependencies, which a single node/deploy can't satisfy at once.

    On localnet the USDC / stablecoin stack is deployed fresh. Real networks use the existing on-chain packages instead — see [Publish Contracts to Testnet / Mainnet](#publish-contracts-to-testnet--mainnet).

Stop the local node and containers when done:

```bash
./run.sh stop_network
./docker-delete-containers.sh
```

If a **localnet** deploy is interrupted and leaves modified `Move.toml` / `Move.lock` files, restore them with `./run.sh restore_manifests`.

#### Troubleshooting

**A deploy fails with `fetch failed` / a closed-socket error (often at `init_state`) on a fresh checkout.** The deploy git-clones the pinned Sui framework (~19k files) on first use. With a cold `~/.move` cache that clone runs *during* the deploy's publish phase and can leave the deploy's reused RPC connection idle long enough for the node to close it.

Both versions are affected, and they pin **different** framework revs, so warming one does not warm the other:

- **V1** compiles with the 1.37.3 toolchain against rev `b023ef8`.
- **V2** compiles with 1.76.1, whose `Move.lock` pins the framework as a git source at rev `d50b7888` (`[pinned.<env>.Sui]`). The compiler injects the dependency implicitly, but it still resolves to a clone.

Warm the framework once before deploying — `./run.sh build --version 1` and `./run.sh build --version 2` (or any build/test of that version) fetch the same clones up front — then re-run the deploy. CI warms both automatically.

### Publish Contracts to Testnet / Mainnet

Real-network deploys are **publish only by default**: they publish the four V2 packages and nothing else. Contract initialization (`init_state`) and admin configuration are separate steps, and V1 is already deployed to testnet and mainnet, so only `--deploy-version 2` is accepted.

Copy `scripts/deploy.env.example` to `deploy.<name>.env`, fill it in, then:

```bash
yarn deploy-remote:v2 --config deploy.<name>.env
```

Config precedence is **real environment variable > `--config` file > `scripts/.env`**. The config file is loaded before `.env` for this reason: `.env.example` ships an empty `DEPLOYER_PRIVATE_KEY=`, and dotenv treats a present-but-empty key as already set, so loading `.env` first would silently discard a key supplied in the config file.

The opt-in `--initialize` flag additionally runs `init_state`, producing the `State` objects the migration commands operate on, and records the `*_STATE_ID` values in the deployment record. It requires `DEPLOYER_PRIVATE_KEY`, because `init_state` is signed in-process rather than by the Sui CLI. It is for standing up a deployment you own end to end.

The stablecoin-sui dependencies (`sui_extensions`, `stablecoin`, `usdc`) are not configured by hand. Under Move >= 1.75 package management they resolve to the packages already published on the target chain, and the deploy reads the same record, so the artifact reports exactly what was linked against.

#### Outputs

Each publish writes a `Published.toml` beside the package's `Move.toml`, and the deploy writes one summary record (`DEPLOY_OUTPUT`) with the network, RPC url, package ids, the three shared UpgradeService objects, the UpgradeCaps and the InitCaps. Neither is committed.

On the default path the summary record omits the deployer private key and the State object ids — nothing is initialized, so neither exists.

#### Things to know

- The publish is signed by `sui client publish` using the CLI's active address, so the deploy never signs in-process and needs no private key in config. Set `DEPLOYER_ADDRESS` and keep the key in the Sui keystore; `DEPLOYER_PRIVATE_KEY` stays supported for automation that must supply one.
- The `InitCap` objects are owned by the deploying address and are consumed by `init_state`. Whoever runs initialization needs them, so either deploy with that key or transfer them.
- The publish builds against the **active `sui` client env** (`sui client publish` rejects `--build-env`), so the deploy selects the env matching `SUI_NETWORK` and refuses to run if its RPC disagrees with `SUI_RPC_URL`. It also verifies the chain id, so a wrong RPC cannot silently publish to the wrong chain.
- A real-network publish requires the pinned toolchain in `bin/`. The `sui` on `PATH` may be older than the >= 1.75 package management this depends on, so the deploy fails rather than falling back to it.
- The deployer must already be funded — a full four-package publish measures ~0.44 SUI, and the deploy refuses to start below 0.75 SUI. There is no faucet on mainnet.
- **Do not run `restore_manifests` after a real-network deploy.** It is a `git checkout` over every package's `Move.toml` and `Move.lock`, so it discards anything a real-network build wrote that has not been committed. The deploy itself only invokes it on localnet.

### Published Bytecode Verification

1. Ensure [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) is installed.

2. Switch the CLI to the environment you're verifying against:

```bash
sui client switch --env {testnet|mainnet}
```

3. Make sure each package's on-chain published address is recorded where its toolchain reads it. This differs by version, because `verify_bytecode` rebuilds each package with its pinned toolchain and build-env (just like `build`/`test`):
   - **V1** (`message_transmitter`, `token_messenger_minter`, frozen at `mainnet-v1.37.3`): the published address lives in the package's `Move.toml`.
   - **V2** (`cctp_extensions`, `message_transmitter_v2`, `token_messenger_minter_v2`, `stablecoin_handler`, current toolchain): the published address lives in the package's `Published.toml` under `[published.<network>]`, written by `sui client publish` (see [Publish Contracts to Testnet / Mainnet](#publish-contracts-to-testnet--mainnet)).

4. Published packages can then be verified with:

```bash
# V1
./run.sh verify_bytecode packages/message_transmitter
./run.sh verify_bytecode packages/token_messenger_minter

# V2
./run.sh verify_bytecode packages/cctp_extensions
./run.sh verify_bytecode packages/message_transmitter_v2
./run.sh verify_bytecode packages/token_messenger_minter_v2
./run.sh verify_bytecode packages/stablecoin_handler
```

V2 verification builds against `$DEFAULT_BUILD_ENV` (defaults to `mainnet`), and the build-env selects which network's publication is compared against. To verify V2 packages on testnet, switch the CLI env (step 2) and set `DEFAULT_BUILD_ENV=testnet`:

```bash
DEFAULT_BUILD_ENV=testnet ./run.sh verify_bytecode packages/message_transmitter_v2
```

### Run Example Scripts

The V1 examples exercise the bridge against the EVM chain, so publish V1 with EVM linking (`yarn deploy-local:v1`, with the Anvil network running) following the steps above.

1. Run the example script for Sui -> EVM:

    ```bash
    cd scripts
    yarn deposit-for-burn-example:v1
    ```

2. Run the example script for EVM -> Sui:

    ```bash
    yarn receive-message-example:v1
    ```

The V2 example scripts are Sui-only (no Anvil needed) — on localnet they synthesize the counterpart EVM message in TypeScript. Publish V2 first (`yarn deploy-local:v2`), then:

3. Run the V2 example script for Sui -> EVM:

    ```bash
    yarn deposit-for-burn-example:v2
    ```

4. Run the V2 example script for EVM -> Sui:

    ```bash
    yarn receive-message-example:v2
    ```

#### Running the V2 examples against a public network

The **V2** example scripts also run against testnet and mainnet, targeting a deployment you did not
make yourself. The V1 examples remain localnet-only.

Object ids come from a dotenv record passed with `--config`; any filename works. Copy
`test_config.v2.env.example` and fill in the ids for the target deployment — do not reuse
`test_config.v2.env`, since `yarn deploy-local:v2` overwrites that file. Only these keys are read:

| Key | |
| --- | --- |
| `SUI_MESSAGE_TRANSMITTER_V2_ID` | package id |
| `SUI_MESSAGE_TRANSMITTER_V2_STATE_ID` | `MessageTransmitter` State |
| `SUI_TOKEN_MESSENGER_MINTER_V2_ID` | package id |
| `SUI_TOKEN_MESSENGER_MINTER_V2_STATE_ID` | `TokenMessengerMinter` State |
| `SUI_STABLECOIN_HANDLER_ID` | package id |
| `SUI_STABLECOIN_HANDLER_STATE_ID` | `StablecoinHandler` State |
| `SUI_USDC_ID` | USDC package (the coin type) |
| `SUI_TREASURY_ID` | `Treasury<USDC>` |
| `SUI_NETWORK`, `SUI_RPC_URL` | target network and its **gRPC** fullnode url |
| `SUI_SIGNER_KEY` | signer, in `suiprivkey1...` form |

If the target package has been upgraded, use its current `published-at` id, not its `original-id`:
the pre-upgrade package aborts `EIncompatibleVersion` on every version-gated entrypoint. An object's
type keeps the original id through upgrades, so it is not evidence of the callable address; check
`compatible_versions` on the State object.

`SUI_RPC_URL` must serve the Sui **gRPC** API, since the scripts use `SuiGrpcClient`. JSON-RPC has
been deprecated on Sui's public fullnodes.

The signer is whichever key you supply via `SUI_SIGNER_KEY` (or `--key`) — your own funded address,
not the deployer of the target contracts.

**Prerequisites**

- a funded Sui address you control, with SUI for gas
- for the burn, USDC on that address. On localnet `deploy-local:v2` mints it; on a public network
  nothing does, and the script fails with `Insufficient <coinType>`
- for the receive, a real message and attestation (see below)

**Sui -> remote chain (burn)**

```bash
yarn deposit-for-burn-example:v2 \
  --network testnet --config test_config.<name>.env \
  --destination-domain 0 --mint-recipient 0x<address-on-destination-chain>
```

`--mint-recipient` is the address on the **destination** chain, not your Sui address. Other flags:
`--amount` (base units; USDC has 6 decimals, so `1` = 0.000001 USDC), `--max-fee`,
`--min-finality-threshold` (1000 fast, 2000 standard), `--gas-budget`, `--rpc-url`, `--key`,
`--iris-host` (override the attestation-service host printed in the poll url).

No attestation is printed on a public network — only Circle's attestation service can produce one
the destination will accept. The script prints the emitted message, its hash, and the url to poll.

**Remote chain -> Sui (receive)**

The receive needs a message from a burn that actually happened, attested by Circle. Fetch both from
the attestation service, using the source chain's CCTP domain and the burn's transaction hash:

```bash
curl "<attestation-service-host>/v2/messages/<sourceDomain>?transactionHash=0x<burn-tx>"
```

See the [CCTP documentation](https://developers.circle.com/stablecoins/cctp-getting-started) for
the attestation-service host to use. **It must be the one that indexes the deployment you burned
from.** Separate deployments can share a chain, each with its own EVM contracts, its own attester
and its own api host — a burn through one deployment's TokenMessenger is not visible to another's.
The burn script's `--iris-host` flag overrides the url it prints for this reason. Getting this wrong
fails late: the receive aborts in `validate_remote_token_messenger` because the message's `sender`
is not the TokenMessenger the destination has registered for that domain.

Poll until `status` is `complete`: while it is
`pending_confirmations` the response returns `attestation: "PENDING"` and `message: "0x"`, and the
scripts reject both by name rather than failing later on-chain. Then:

```bash
yarn receive-message-example:v2 \
  --network testnet --config test_config.<name>.env \
  --message 0x<message> --attestation 0x<attestation>
```

Two things to check in the response's `decodedMessage` before submitting:

- `decodedMessageBody.mintRecipient` is fixed by the upstream burn. If it is not a Sui address you
  control, the receive still succeeds and the USDC mints to someone else.
- a non-zero `destinationCaller` restricts who may submit the receive.

Mainnet runs additionally require `--confirm-mainnet` on both scripts, since they move real USDC.

### Run E2E Tests

The V1 E2E suite bridges V1 between Sui and the EVM chain, so it needs both a running Sui node and an Anvil EVM network. Start them, deploy V1 with EVM linking, then run the suite:

```bash
./run.sh start_network        # local Sui node
./setup-evm-contracts.sh      # local Anvil EVM network
cd scripts
yarn deploy-local:v1
yarn test-local:v1
```

The V2 E2E suite (`scripts/test/e2e.v2.test.ts`) is Sui-only: it synthesizes inbound EVM messages in TypeScript and signs them with the local attester, and asserts outbound (Sui -> EVM) messages byte-for-byte. No Anvil network is required, only a running Sui node:

```bash
./run.sh start_network        # local Sui node (no Anvil needed)
cd scripts
yarn deploy-local:v2
yarn test-local:v2
```

The upgrade/migration E2E lives in `test/upgrade.e2e.v2.test.ts` (V2 only — V1 is frozen and superseded by V2 rather than upgraded, so it has no upgrade spec) and is included in `test-local:v2`. Because it publishes a real on-chain package upgrade and completes a migration (which sets `State.compatible_versions` to `{2}` and version-locks the originally-deployed package), any suite that ran against the same deployment afterward would abort in `version_control`. A custom jest sequencer (`scripts/testSequencer.cjs`) therefore forces every `upgrade.e2e*` spec to run last, regardless of CLI order (jest's default sequencer ignores argument order). New destructive, deployment-mutating suites should follow the same `upgrade.e2e*` naming — or extend the sequencer — so they too run after the read-only suites.

### Upgrade & Migration Tooling

Tooling to drive the on-chain upgrade/migration primitives for the stateful packages: deposit each package's `UpgradeCap` into its `UpgradeService`, publish a package upgrade through that service, and drive the `State.compatible_versions` migration.

The per-step commands take a `--package` selector naming the package — `message_transmitter_v2`, `token_messenger_minter_v2`, `stablecoin_handler` (V2) and `message_transmitter`, `token_messenger_minter` (V1). Short aliases are accepted for the V2 packages only: `mt`, `tmm`, `handler`. Note that an unsuffixed *package name* is V1 (`token_messenger_minter`), whereas an unsuffixed *alias* is V2 (`tmm`), so prefer full names anywhere the target matters.

`cctp_extensions` cannot be targeted: it is a pure library published with no `UpgradeService` and no `State`, so it has neither an upgrade path through this tooling nor anything to migrate.

Every command resolves object ids from the deployment manifest written by `yarn deploy*` — `test_config.{v1,v2}.env` for a localnet deploy, or the `DEPLOY_OUTPUT` record for a real-network one. Point `dotenv` at the relevant manifest with `DOTENV_CONFIG_PATH`. All commands accept `--dry-run` (simulate without submitting), `--rpc-url` and `--gas-budget`.

The end-to-end sequence for upgrading a package to a new version:

1. Deposit the package's `UpgradeCap` into its `UpgradeService` (once per package):

    ```bash
    cd scripts
    DOTENV_CONFIG_PATH=test_config.v2.env yarn upgrade:deposit-cap --package message_transmitter_v2
    ```

2. Publish the upgraded package. Provide the built bytecode either as a pre-built artifact (`--build-artifact-filepath`, produced by `sui move build --dump-bytecode-as-base64 -e mainnet`) or build it inline from a package directory (`--package-path`). The new package must bump `version_control::VERSION`:

    ```bash
    DOTENV_CONFIG_PATH=test_config.v2.env yarn upgrade:package --package message_transmitter_v2 \
      --build-artifact-filepath ./message_transmitter_v2.upgrade.json
    ```

3. Drive the migration (`start` opens the compatibility window; `complete` closes out the old version; `abort` reverts a pending migration):

    ```bash
    DOTENV_CONFIG_PATH=test_config.v2.env yarn upgrade:migrate start --package message_transmitter_v2
    DOTENV_CONFIG_PATH=test_config.v2.env yarn upgrade:migrate complete --package message_transmitter_v2
    ```

Deposit is owner-agnostic; `upgrade:package` is gated by the `UpgradeService` admin and `upgrade:migrate` by the `State` owner (both the deployer at init). The commands preflight these roles and abort early on a mismatch.

#### One-shot upgrade + migrate (`yarn upgrade:v2`)

`yarn upgrade:v2` does steps 2 and 3 in a single preflighted run: it builds the upgrade from the working tree, publishes it through the `UpgradeService`, then drives `start_migration` and `complete_migration`. It is V2-only. Use it when you want the whole version bump to land as one operation; use the per-step commands when you need to do one piece at a time, including to recover.

```bash
cd scripts
yarn upgrade:v2 --package token_messenger_minter_v2 \
  --package-path packages/token_messenger_minter_v2 \
  --config deploy.<name>.out.env \
  --dry-run          # always dry-run first
```

`--dry-run` **simulates the upgrade transaction**, which is what makes it useful: package upgrade compatibility is enforced while executing the `Upgrade` command, so simulating it returns a real verdict. An incompatible upgrade fails the dry run with `PackageUpgradeError { IncompatibleUpgrade }` and a non-zero exit. The migration is not simulated — it targets the post-upgrade package, which does not exist until the upgrade is committed.

`yarn upgrade:v2` does not resume. If a run fails partway it reports the phase it detects and names the per-step command to run; recovery is by composition with the per-step commands above, which handle every intermediate state.

#### `VERSION` must be ahead of the deployed `State`, and must not be committed that way

`start_migration` asserts `active_version < current_version()`, so publishing an upgrade without a raised `VERSION` leaves the package upgraded but unmigrated. The command preflights this and refuses before touching the chain.

Committing a raised `VERSION` breaks the next fresh deployment instead: `init_state` writes `compatible_versions = {VERSION-at-deploy-time}`, so a deployment made from a tree carrying a bump meant for elsewhere gets a `State` whose set does not contain the package's own version, and every version-gated entrypoint aborts `EIncompatibleVersion` from the moment it is deployed.

Apply the bump only for the duration of a migration run and revert it afterwards. The command never edits source — it builds the tree as it finds it — so reverting is the operator's responsibility, and `git status` is the check.
