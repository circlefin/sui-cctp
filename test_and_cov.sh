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

# Each package is built/tested with its own pinned toolchain (V1 is frozen to an
# older Sui release, V2 tracks current) — see versions.sh :: sui_bin_for. V1
# resolves to that release's bundled `sui-debug` binary so `--coverage` works
# there too (the release `sui` supports coverage only in debug builds).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/versions.sh"

# Package set, optionally narrowed by `./run.sh test --version {1|2}` (which
# exports VERSION_FILTER). Unset (e.g. when this script is run directly) => all.
PACKAGES="$(cctp_packages "${VERSION_FILTER:-}")"

# clean build
rm -rf packages/**/build

for pkg in $PACKAGES; do
  "$(sui_bin_for "$pkg")" move test --path "$pkg" --coverage --statistics $(sui_build_env_args "$pkg")
done

for pkg in $PACKAGES; do
  "$(sui_bin_for "$pkg")" move coverage summary --path "$pkg" $(sui_build_env_args "$pkg")
done
