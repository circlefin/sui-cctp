#!/bin/bash
#
# Copyright (c) 2024, Circle Internet Group, Inc. All rights reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -e
source versions.sh

# Optional first arg installs a SINGLE toolchain instead of all pinned ones.
# Accepts "1.37.3", "v1.37.3", or "mainnet-v1.37.3". No allow-list — any version
# is attempted as given; a non-existent release simply fails on download (404).
# With no arg, all pinned toolchains from versions.sh are installed.
if [[ -n "${1:-}" ]]; then
  VER_TAG="$1"
  [[ "$VER_TAG" == mainnet-v* ]] || VER_TAG="mainnet-v${VER_TAG#v}"
  VERSIONS_TO_INSTALL="$VER_TAG"
else
  VERSIONS_TO_INSTALL="$(sui_all_versions)"
fi

# Fetch submodules if needed
echo "Fetching submodules..."
git submodule update --init --recursive

# Strip stablecoin-sui's pinned framework dependency so the
# V2 tree resolves the compiler-injected framework instead of a divergent rev. The
# submodule stays at its pinned commit; this patch modifies only its working tree
# (see patches/ and `ignore = dirty` in .gitmodules). Idempotent: a reverse --check
# succeeds only when the patch is already applied, so re-running setup.sh is safe.
STABLECOIN_UNPIN_PATCH="$PWD/patches/stablecoin-sui-unpin-dependencies.patch"
if git -C stablecoin-sui apply --reverse --check "$STABLECOIN_UNPIN_PATCH" >/dev/null 2>&1; then
  echo ">> stablecoin-sui unpin patch already applied; skipping."
else
  git -C stablecoin-sui apply "$STABLECOIN_UNPIN_PATCH"
  echo ">> Applied stablecoin-sui unpin patch."
fi

# Determine OS for downloading correct binary
if [[ "$CI" == true ]]; then
  OS="ubuntu-x86_64"
else
  # Detect macOS architecture
  if [[ "$(uname -m)" == "arm64" ]]; then
    OS="macos-arm64"
  else
    OS="macos-x86_64"
  fi
fi

mkdir -p ./bin

# Install each selected toolchain into its own versioned dir: ./bin/<tag>/sui.
# V1 packages build with a frozen older release; V2 with the current one — see
# versions.sh. Each version lives in its own dir so they don't collide on `sui`.
for VER in $VERSIONS_TO_INSTALL; do
  NUM="${VER#mainnet-v}"
  DEST="./bin/$VER"

  if [[ -x "$DEST/sui" ]] && "$DEST/sui" -V 2>/dev/null | grep -q "sui $NUM-"; then
    echo ">> $VER already installed, skipping"
    continue
  fi

  echo "Downloading Sui binary from Github..."
  echo ">> Version: '$VER'"
  echo ">> OS: '$OS'"

  mkdir -p "$DEST"
  curl -fL -o "/tmp/sui-$VER.tgz" "https://github.com/MystenLabs/sui/releases/download/$VER/sui-$VER-$OS.tgz"
  tar -xzf "/tmp/sui-$VER.tgz" -C "$DEST"
  rm -f "/tmp/sui-$VER.tgz"

  # Sanity check that this toolchain installed correctly.
  if ! "$DEST/sui" -V | grep -q "sui $NUM-"; then
    echo "Sui binary '$VER' was not installed correctly"
    exit 1
  fi
  echo ">> Installed $VER -> $DEST/sui"
done

# Back-compat: ./bin/sui -> default toolchain, so a bare `sui` (and the sui-cctp
# alias, which targets ./bin/sui) resolves to the current version. Only (re)link
# when the default toolchain is present (a single-version install of just V1
# leaves it untouched).
if [[ -x "./bin/$DEFAULT_SUI_VERSION/sui" ]]; then
  ln -sf "$DEFAULT_SUI_VERSION/sui" ./bin/sui
fi

# Add ./bin to PATH for the current shell.
export PATH="$PWD/bin:$PATH"
echo "Added ./bin to PATH for this session."

# Add ./bin to PATH for all other steps in the CI workflow.
if [[ "$CI" == true ]]; then
  echo "$PWD/bin" >> "$GITHUB_PATH"
fi

if [[ -x ./bin/sui ]]; then
  echo "Default sui: $(./bin/sui -V)"
fi
echo "Installed this run: $(echo $VERSIONS_TO_INSTALL | tr '\n' ' ')"
