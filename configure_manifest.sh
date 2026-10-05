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

# Swaps the frozen-V1 packages onto their localnet manifests (self = 0x0, local
# path deps) for a localnet deploy. Only V1 needs a per-environment manifest: it
# is frozen at 1.37.3 (old package management), which resolves a package's
# address and deps from the manifest. V2 (1.76.1) uses a single `Move.toml`
# (self = 0x0) and needs no swap: its dependency graph is pinned per environment
# in `Move.lock` (`[pinned.<env>.*]`), and its published address — when it has
# one — lives in `Published.toml`.
#
# `run.sh restore_manifests` (git checkout) reverts the swap after a deploy.

environment="${1:-localnet}"
if [[ "$environment" != "localnet" ]]; then
    echo "Usage: $0 localnet   (only the localnet swap remains; V2 uses a single Move.toml)" >&2
    exit 1
fi

cp "packages/message_transmitter/Move.localnet.toml" "./packages/message_transmitter/Move.toml"
cp "packages/token_messenger_minter/Move.localnet.toml" "./packages/token_messenger_minter/Move.toml"
