# Copyright 2024 Circle Internet Group, Inc.  All rights reserved.
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
#
# SPDX-License-Identifier: Apache-2.0

# Sui toolchains this repo builds with.
#
# V1 packages are frozen artifacts already deployed to mainnet: they must keep
# building with the compiler they were released under, in perpetuity. Pinning
# them to the current compiler would accrue deprecation warnings (and eventually
# hard errors) as the toolchain advances. V2 (and anything new) tracks current.
#
# NOTE (bash 3.2 on macOS has no associative arrays) — the mapping is expressed
# as echo-functions, consistent with run.sh's _get_packages().

# Default / current toolchain: used by V2 packages and the ./bin/sui symlink.
export DEFAULT_SUI_VERSION=mainnet-v1.76.1

# Build environment for current-toolchain packages. Sui >= ~1.75 requires
# `-e <env>` to resolve dependencies. For a localnet build the graph is all local
# source deps, so the choice is immaterial to the compiled output — but it is NOT
# immaterial once a dependency resolves to a package already published on a real
# network (each dependency's Published.toml is keyed by env), which is exactly
# what `verify_bytecode` against testnet/mainnet relies on.
#
# Assigned with :- so a caller-supplied value survives this file being sourced;
# a bare assignment would silently clobber `DEFAULT_BUILD_ENV=testnet ./run.sh ...`
# and build against mainnet instead.
#
# The frozen V1 toolchain predates the flag and must NOT receive it (see
# sui_build_env_args).
export DEFAULT_BUILD_ENV="${DEFAULT_BUILD_ENV:-mainnet}"

# Every distinct toolchain to install (deduped). setup.sh iterates this.
sui_all_versions() {
  printf '%s\n' \
    mainnet-v1.37.3 \
    "$DEFAULT_SUI_VERSION" \
    | sort -u
}

# Map a package path to the toolchain it must be built/tested with.
# Defaults to the current toolchain; V1 packages pin their frozen release.
sui_version_for() {
  case "$1" in
    packages/message_transmitter)    echo mainnet-v1.37.3 ;;   # OSS rev b023ef8 (frozen)
    packages/token_messenger_minter) echo mainnet-v1.37.3 ;;   # OSS rev b023ef8 (frozen)
    *)                               echo "$DEFAULT_SUI_VERSION" ;;
  esac
}

# Echo the `-e <env>` build-env args a package's toolchain needs (word-split by
# the caller), or nothing for the frozen V1 toolchain, which predates the flag.
# Usage: <sui> move build --path <pkg> $(sui_build_env_args <pkg>)
sui_build_env_args() {
  [[ "$(sui_version_for "$1")" == mainnet-v1.37.3 ]] && return 0
  echo "-e $DEFAULT_BUILD_ENV"
}

# CCTP package paths, optionally filtered by CCTP contract version.
#   cctp_packages     -> all packages, canonical build order (V1 then V2)
#   cctp_packages 1   -> V1 only (original mainnet contracts, frozen toolchain)
#   cctp_packages 2   -> V2 only (the V2 stack: cctp_extensions + *_v2 +
#                        stablecoin_handler, all on the current toolchain)
# Shared by run.sh (_get_packages) and test_and_cov.sh so the split lives in one
# place. Any argument other than 1/2 (including none) yields the full set.
cctp_packages() {
  local v1 v2
  v1="packages/message_transmitter
packages/token_messenger_minter"
  v2="packages/cctp_extensions
packages/message_transmitter_v2
packages/token_messenger_minter_v2
packages/stablecoin_handler"
  case "$1" in
    1) printf '%s\n' "$v1" ;;
    2) printf '%s\n' "$v2" ;;
    *) printf '%s\n%s\n' "$v1" "$v2" ;;
  esac
}

# Directory containing this repo's ./bin (derived from this file's location).
_VERSIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Absolute path to the sui binary a package must build/test with. Falls back to
# `sui` on PATH (with a warning) if that pinned toolchain isn't installed yet.
# The v1.37.3 release `sui` can't do `move test --coverage` (debug-build-only),
# but the release tarball's bundled `sui-debug` build can — so the frozen V1
# toolchain uses `sui-debug` (same version, so the Move.lock stamp is unchanged).
sui_bin_for() {
  local ver binname bin
  ver="$(sui_version_for "$1")"
  if [[ "$ver" == mainnet-v1.37.3 ]]; then binname="sui-debug"; else binname="sui"; fi
  bin="$_VERSIONS_DIR/bin/$ver/$binname"
  if [[ -x "$bin" ]]; then
    echo "$bin"
  else
    echo "warning: $binname for $ver ('$1') not installed; falling back to 'sui' on PATH" >&2
    echo sui
  fi
}

# Resolve the pinned sui binary for a package, echoing its absolute path on
# stdout. Hard-fails (returns 1) if the package's pinned toolchain isn't
# installed — i.e. sui_bin_for fell back to a bare `sui` on PATH. Intended for
# CI, where silently running the wrong compiler should be a loud failure rather
# than an accidental pass. Usage: SUI="$(resolve_sui_or_fail <pkg>)" || exit 1
resolve_sui_or_fail() {
  local bin
  bin="$(sui_bin_for "$1")"
  if [[ "$bin" == "sui" ]]; then
    echo "ERROR: pinned toolchain for '$1' not found in ./bin (sui_bin_for fell back to PATH 'sui'). Did setup.sh install it?" >&2
    return 1
  fi
  echo "$bin"
}
