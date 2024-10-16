#!/usr/bin/env bash
# Copyright (c) 2023, Circle Internet Financial Trading Company Limited.
# All rights reserved.
#
# Circle Internet Financial Trading Company Limited CONFIDENTIAL
#
# This file includes unpublished proprietary source code of Circle Internet
# Financial Trading Company Limited, Inc. The copyright notice above does not
# evidence any actual or intended publication of such source code. Disclosure
# of this source code or any related proprietary information is strictly
# prohibited without the express written permission of Circle Internet Financial
# Trading Company Limited.

echo "Deploying evm-cctp-contracts contracts"

# Check if foundry is installed
if ! ~/.foundry/bin/forge -V; then
 curl -L https://foundry.paradigm.xyz | bash
 # 07-14-2023 - The version following this version breaks our build, so setting to this version for now.
 ~/.foundry/bin/foundryup --version nightly-d369d2486f85576eec4ca41d277391dfdae21ba7
fi

cd evm-cctp-contracts

# Update submodules
git submodule update --init --recursive

# Install any needed dependency
yarn install

# Build the anvil image
docker build --no-cache -f Dockerfile -t foundry .

# Create the anvil container
docker rm -f anvil || true
docker run -d -p 8500:8545 --platform linux/amd64 --name anvil --rm foundry "anvil --host 0.0.0.0 -a 13 --code-size-limit 250000"

# Define the contract parameters
RPC_URL_ETH=http://localhost:8500
SENDER='0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc'

export MESSAGE_TRANSMITTER_DEPLOYER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export TOKEN_MESSENGER_DEPLOYER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
export TOKEN_MINTER_DEPLOYER_KEY=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
export TOKEN_CONTROLLER_DEPLOYER_KEY=0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82
export ATTESTER_ADDRESS=0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f
export USDC_CONTRACT_ADDRESS=0x700b6a60ce7eaaea56f065753d8dcb9653dbad35
export TOKEN_CONTROLLER_ADDRESS=0x71be63f3384f5fb98995898a86b02fb2426c5788

export BURN_LIMIT_PER_MESSAGE=100000
export REMOTE_TOKEN_MESSENGER_ADDRESS=0x057ef64E23666F000b34aE31332854aCBd1c8544
export REMOTE_USDC_CONTRACT_ADDRESS=0x700b6a60ce7eaaea56f065753d8dcb9653dbad35

# Arbitrary addresses
export MESSAGE_TRANSMITTER_PAUSER_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
export TOKEN_MINTER_PAUSER_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
export MESSAGE_TRANSMITTER_RESCUER_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
export TOKEN_MESSENGER_RESCUER_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
export TOKEN_MINTER_RESCUER_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266

export MASTER_MINTER_ADDRESS=0xa0ee7a142d267c1f36714e4a8f75612f20a79720
export TOKEN_MINTER_ADDRESS=0xbdEd0D2bf404bdcBa897a74E6657f1f12e5C6fb6
export DUMMY_ADDRESS=0xfabb0ac9d68b0b445fb7357272ff202c5651694a
export MASTER_MINTER_KEY=0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6

export UPGRADEABLE_KEY=0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6
export UPGRADEABLE_ADDRESS=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266

sleep 10;

# Deploy the contracts
export DOMAIN=0
~/.foundry/bin/forge script ../scripts/evm-scripts/cctp_deploy.s.sol:DeployScript --rpc-url $RPC_URL_ETH --sender $SENDER --broadcast
mkdir cctp-interfaces
cp -R ./out/* ./cctp-interfaces
~/.foundry/bin/forge script ../scripts/evm-scripts/usdc_deploy.s.sol:USDCDeployScript --rpc-url $RPC_URL_ETH --sender $SENDER --broadcast --force --use 0.6.12
mkdir usdc-interfaces
cp -R ./out/* ./usdc-interfaces

cd ..
