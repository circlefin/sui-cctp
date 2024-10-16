# sui-cctp

Official repository for Sui smart contracts used by the Cross-Chain Transfer Protocol.

[CCTP Documentation](https://developers.circle.com/stablecoins/cctp-getting-started)

## Getting Started

### Prerequisites

Before you can get started working on the contracts in this repository, make sure you have the following prerequisites installed:

1. [Install Rust.](https://doc.rust-lang.org/book/ch01-01-installation.html#installing-rustup-on-linux-or-macos)

2. Install Sui from source:

    ```bash
    ./setup.sh
    ```

### IDE

- VSCode is recommended for developing Move for Sui.
- [Move (Extension)](https://marketplace.visualstudio.com/items?itemName=mysten.move) is a language server extension for Move. **Note**: additional installation steps required. Please follow the plugin's installation guide.
- [Move Syntax](https://marketplace.visualstudio.com/items?itemName=damirka.move-syntax) a simple syntax highlighting extension for Move.

### Build and Test Contracts

1. Compile Move contracts from project root:

    ```bash
    sui move build --path packages/message_transmitter
    sui move build --path packages/token_messenger_minter
    ```

2. Run tests and see test coverage:

    ```bash
    ./test_and_cov.sh
    ```

3. If test coverage is < 100%, view the coverage line by line:

    ```bash
    sui move coverage source --path packages/{package_path} --module {module_name}
    ```

### Publish Contracts Locally

1. Set up local Sui node and EVM network (optional):

    ```bash
    ./run.sh start_network
    # Optional, only if you want to run E2E tests
    ./setup-evm-contracts.sh
    ```

2. Run the `configure_manifest.sh` script to update to the required localnet manifests:

    ```bash
    ./configure_manifest.sh localnet
    ```

3. Enter the `scripts` folder and rename the provided `.env.example` to `.env`. If the `DEPLOYER_PRIVATE_KEY` field is not set, then the deployment script will automatically generate a new keypair. Then, deploy the contracts.

    ```bash
    cp .env.example .env
    yarn install
    yarn deploy-local
    ```

The local containers and Sui node can be stopped with:

```bash
./run.sh stop_network
./docker-stop-containers.sh
```

### Run Localnet Example Scripts

1. Publish contracts locally, following the steps above.

2. Run the example script for Sui -> EVM:

    ```bash
    cd scripts
    yarn deposit-for-burn-example
    ```

3. Run the example script for EVM -> Sui:

    ```bash
    yarn receive-message-example
    ```

### Run E2E Tests

1. Publish contracts locally, following the steps above.

2. Run the test script:

    ```bash
    yarn test-local
    ```

### Published Bytecode Verification

1. Ensure [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) is installed.

2. And the desired environment configured:

```bash
sui client switch --env {testnet|mainnet}
```

3. Set all published addresses in the move.toml files OR use the
[testnet](https://github.com/circlefin/sui-cctp/tree/testnet)/[mainnet](https://github.com/circlefin/sui-cctp/tree/mainnet) (coming soon) 
branches which contain `Move.lock` files that use Sui's
[Automated Address Management](https://docs.sui.io/concepts/sui-move-concepts/packages/automated-address-management)
for Testnet and Mainnet (coming soon) addresses.

4. Published packages can then be verified with:

```bash
./run.sh verify_on_chain packages/message_transmitter
./run.sh verify_on_chain packages/token_messenger_minter
```

## CCTP as a Dependency

The [testnet](https://github.com/circlefin/sui-cctp/tree/testnet) and [mainnet](https://github.com/circlefin/sui-cctp/tree/mainnet) (coming soon)
branches contain `Move.lock` files that use Sui's
[Automated Address Management](https://docs.sui.io/concepts/sui-move-concepts/packages/automated-address-management)
for Testnet and Mainnet (coming soon) addresses. It also references stablecoin-sui dependencies which uses automated address management as well.

Deployed bytecode can be verified by following the steps in the previous section.
