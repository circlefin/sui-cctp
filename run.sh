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

FULLNODE_PORT="${FULLNODE_PORT:-9001}"
FAUCET_PORT="${FAUCET_PORT:-9123}"
FULLNODE_EPOCH_DURATION_MS="${FULLNODE_EPOCH_DURATION_MS:-10000}"
FULLNODE_URL=http://localhost:$FULLNODE_PORT
FAUCET_URL=http://localhost:$FAUCET_PORT

# Ensure the `./bin` directory next to this script is on PATH so the
# `sui` binary installed by setup.sh is discoverable regardless of how
# this script is invoked. In CI, setup.sh writes `./bin` to
# $GITHUB_PATH so the env is available in later steps, but an earlier
# step may not have re-materialized $GITHUB_PATH before invoking us,
# leading to `sui: command not found` here. Prepending unconditionally
# is safe for local dev too (just a no-op if `sui` is already on PATH).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR/bin:$PATH"

# Per-package toolchain resolution (sui_bin_for): V1 packages are frozen to an
# older Sui release, V2 tracks current. The `./bin/sui` on PATH above (the
# default toolchain) still serves package-agnostic commands (deploy, network).
source "$SCRIPT_DIR/versions.sh"

function clean() {
  for path in $(_get_packages); do
    echo ">> Cleaning $path..."
    rm -rf $path/build
    rm -f $path/.coverage_map.mvcov
    rm -f $path/.trace
  done
}

# Restores the git-tracked manifest/lock files that a local deploy mutates, so
# stale localnet data isn't accidentally committed:
#   - the frozen-V1 Move.toml is swapped in place by configure_manifest.sh localnet
#     (and gets a framework pin injected); V2 uses a single Move.toml, no swap
#   - Move.lock gets per-environment [pinned.<env>.*] dependency-graph blocks and
#     the local compiler version written during build/publish. (Published ids
#     themselves live in each package's Published.toml, not Move.lock.)
# Uses `git checkout` because the committed Move.toml is not reproducible via
# configure_manifest for every package — the V1 packages pin remote git
# dependencies in their committed manifest.
# LOCALNET ONLY. This is a `git checkout` over every package's Move.toml and
# Move.lock, so it discards anything an uncommitted build wrote. It exists to
# undo the localnet manifest swap (configure_manifest.sh localnet + the frozen-V1
# framework pin); a real-network deploy must never run it. The [pinned.<env>.*]
# dependency-graph blocks are committed so a checkout restores them instead of
# wiping them.
function restore_manifests() {
  echo ">> Restoring Move.toml / Move.lock to their committed state (localnet)..."
  for path in $(_get_packages); do
    git checkout -- "$path/Move.toml" "$path/Move.lock" 2>/dev/null || true
  done
  # stablecoin-sui is a pinned submodule with our unpin patch applied on top (see
  # setup.sh). A local publish churns its Move.lock / Published.toml; reset it to
  # the pinned rev, then re-apply the patch so the tree still builds.
  git submodule update --init --force stablecoin-sui >/dev/null 2>&1 || true
  git -C stablecoin-sui apply "$PWD/patches/stablecoin-sui-unpin-dependencies.patch" >/dev/null 2>&1 || true
  echo ">> Done."
}

function build() {
  _parse_version_filter "$@" || exit 1
  for path in $(_get_packages "$VERSION_FILTER"); do
    echo ">> Building $path..."
    if ! "$(sui_bin_for "$path")" move build --path $path --lint $(sui_build_env_args "$path"); then
      exit 1
    fi
  done
}

function test() {
  _parse_version_filter "$@" || exit 1
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

function verify_bytecode() {
  if [ -z "$1" ]; then
    echo "Usage: [DEFAULT_BUILD_ENV=<env>] ./run.sh verify_bytecode package_path/package" >&2
    exit 1
  fi
  # Rebuilds the package locally and compares the result against the bytecode
  # published on chain (`sui client verify-source`). This is *bytecode*
  # verification; verifying on-chain contract *state* is a separate step.
  #
  # Builds with the package's pinned toolchain + build-env, like build/test — so
  # V1 reproduces its frozen 1.37.3 bytecode (no build-env) and V2 builds with the
  # current toolchain (-e $DEFAULT_BUILD_ENV). The build-env selects which
  # network's publication is compared against, so target testnet with
  # `DEFAULT_BUILD_ENV=testnet ./run.sh verify_bytecode <pkg>`; the sui CLI's
  # active env must point at the same network.
  #
  # The published address must already be recorded where that toolchain reads it:
  # V1 in the package's Move.toml, V2 in its Published.toml (written by
  # `sui client publish`).
  echo ">> Ensure $1's published address is recorded (V1: Move.toml, V2: Published.toml)."
  "$(sui_bin_for "$1")" client verify-source "$1" $(sui_build_env_args "$1")
}

# Optional single-arg version filter (1 | 2) forwarded to cctp_packages
# (defined in versions.sh). No/other arg => all packages.
function _get_packages() {
  cctp_packages "$1"
}

# Parse an optional `--version {1|2}` filter shared by build/test. Sets the
# global VERSION_FILTER to "1", "2", or "" (all). Returns 1 (caller should
# exit) when --version is passed an unsupported value, so the script stops
# before doing any work.
function _parse_version_filter() {
  VERSION_FILTER=""
  if [[ "$1" == "--version" ]]; then
    case "$2" in
      1|2) VERSION_FILTER="$2" ;;
      *) echo "Error: unsupported version '${2:-}'. Supported versions: 1, 2." >&2; return 1 ;;
    esac
  fi
  return 0
}

function start_network() {
  LOG_FILE="$PWD/sui-node.log"

  stop_network

  # Ephemeral `test-publish` pub files (Pub.<env>.toml) are only valid for the
  # node that created them: `--force-regenesis` mints a fresh chain-id each start,
  # so a stale pub file makes the next `test-publish` reject as "already
  # published". Clear them alongside the node restart they're bound to.
  rm -f "$PWD/scripts/"Pub.*.toml

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
  # Detach the background sui process from this shell's job table so it
  # survives the `exit 0` below (otherwise bash sends SIGHUP on exit and
  # the node dies right after the health check passes).
  disown

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

  # Loop fell through without ever seeing a 200 — sui failed to start.
  # Dump the log so the cause is visible in CI output, then fail loudly
  # instead of pretending success and letting downstream steps connect
  # to a dead node.
  echo ">> Sui node did not become healthy within $WAIT_TIME seconds. Log:"
  echo "----------------------------------------------------------------"
  cat "$LOG_FILE" 2>/dev/null || echo "(log file not found)"
  echo "----------------------------------------------------------------"
  exit 1
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
