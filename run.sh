#!/bin/bash
#
# Copyright 2024 Circle Internet Financial, LTD. All rights reserved.
# 
# SPDX-License-Identifier: Apache-2.0
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FULLNODE_PORT="7000"
FAUCET_PORT="7123"
FULLNODE_EPOCH_DURATION_MS="10000"
FULLNODE_URL=http://localhost:$FULLNODE_PORT
FAUCET_URL=http://localhost:$FAUCET_PORT

function clean() {
  for path in $(_get_packages); do
    echo ">> Cleaning $path..."
    rm -rf $path/build
    rm -f $path/.coverage_map.mvcov
    rm -f $path/.trace
  done
}

function build() {
  for path in $(_get_packages); do
    echo ">> Building $path..."
    if ! sui move build --path $path --lint; then
      exit 1
    fi
  done
}

function test() {
  source test_and_cov.sh
}

function static_checks() {
  # Fails if any files (eg Move.lock) was updated.
  build
  if ! git diff --quiet --exit-code "**/Move.lock"; then
    echo ">> Did you forget to commit the Move.lock files?"
    echo ""
    git --no-pager diff "**/Move.lock"
    exit 1
  fi
  
  current_dir="$PWD"
  cd typescript
  yarn format:check && yarn type-check && yarn lint
  cd $current_dir
}

function deploy_dry_run() {
  build
  if [ -z $1 ]; then
    echo "Usage: ./run.sh deploy_dry_run package_path/package";
    exit 1;
  fi

  sui client publish --dry-run $1
}

function deploy() {
  build
  if [ -z $1 ]; then
    echo "Usage: ./run.sh deploy package_path/package";
    exit 1;
  fi
  
  sui client publish $1
}

function verify_on_chain() {
  echo "Please ensure Move.toml or Move.lock files contain the correct published address"
  if [ -z $1 ]; then
    echo "Usage: ./run.sh verify_on_chain package_path/package";
    exit 1;
  fi
  
  sui client verify-source $1
}

function _get_packages() {
  find "packages" -type d -mindepth 1 -maxdepth 1
}

function start_network() {
  LOG_FILE="$PWD/sui-node.log"

  stop_network

  echo "Starting network in the background..."
  echo ">> Fullnode: $FULLNODE_URL"
  echo ">> Faucet: $FAUCET_URL"
  echo ">> Epoch duration: $FULLNODE_EPOCH_DURATION_MS ms"
  echo ">> Logs written to $LOG_FILE"

  # Starts an in-memory node by using the `--force-regenesis` flag.
  sui start \
    --fullnode-rpc-port=$FULLNODE_PORT \
    --with-faucet=$FAUCET_PORT \
    --epoch-duration-ms=$FULLNODE_EPOCH_DURATION_MS \
    --force-regenesis &> $LOG_FILE &

  WAIT_TIME=30

  echo ">> Waiting for Sui node to come online within $WAIT_TIME seconds..."
  ELAPSED=0
  SECONDS=0
  while [[ "$ELAPSED" -lt "$WAIT_TIME" ]]
  do
    FULLNODE_HEALTHCHECK_STATUS_CODE="$(curl -k -s -o /dev/null -w %{http_code} -X POST -H 'Content-Type: application/json' -d "{\"jsonrpc\": \"2.0\", \"method\": \"suix_getLatestSuiSystemState\", \"params\": [], \"id\": 1}" $FULLNODE_URL)"
    FAUCET_HEALTHCHECK_STATUS_CODE="$(curl -k -s -o /dev/null -w %{http_code} $FAUCET_URL)"

    if [[ "$FULLNODE_HEALTHCHECK_STATUS_CODE" -eq 200 ]] && [[ "$FAUCET_HEALTHCHECK_STATUS_CODE" -eq 200 ]]; then
      echo ">> Sui node is started after $ELAPSED seconds!"
      exit 0
    fi

    # Add a heartbeat every 5 seconds and show status
    if [[ $(( ELAPSED % 5 )) == 0 && "$ELAPSED" > 0 ]]; then
      echo ">> Waiting for Sui node for $ELAPSED seconds.."
      echo ">> Fullnode status: $FULLNODE_HEALTHCHECK_STATUS_CODE, Faucet status: $FAUCET_HEALTHCHECK_STATUS_CODE"
    fi

    # Ping every second
    sleep 1
    ELAPSED=$SECONDS
  done
}

function stop_network() {
  # Find the PID of the node using the lsof command
  # -t = only return port number
  # -c sui = where command name is 'sui'
  # -a = <AND>
  # -i:$FULLNODE_PORT = where the port is '$FULLNODE_PORT'
  PID=$(lsof -t -c sui -a -i:$FULLNODE_PORT || true)

  if [ ! -z "$PID" ]; then
    echo "Stopping network at pid: $PID..."
    kill "$PID" &>/dev/null
    rm "$PWD/sui-node.log"
  else 
    echo "No local sui node running"
  fi
}

# This script takes in a function name as the first argument, 
# and runs it in the context of the script.
if [ -z $1 ]; then
  echo "Usage: bash run.sh <function>";
  exit 1;
elif declare -f "$1" > /dev/null; then
  "$@";
else
  echo "Function '$1' does not exist";
  exit 1;
fi
