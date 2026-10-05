#!/usr/bin/env bash
# Copyright (c) 2024, Circle Internet Financial Trading Company Limited.
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

# Bring up the local E2E network: a host-mode Sui fullnode (via the `sui`
# binary installed by setup.sh) plus an anvil container for the EVM side.
# Sui used to run as a docker-compose service backed by a mirrored
# image; that's been replaced with the same `sui start --force-regenesis`
# flow that local dev (and stablecoin-sui's CI) already use, removing the
# dependency on an image registry.
#
# The legacy `-i` (pull images) and `-r` (restart) flags are accepted for
# backwards compatibility but no longer pull any images — only anvil's
# image is built locally inside setup-evm-contracts.sh.

export DOCROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

while getopts ":ir" OPTION
do
    case ${OPTION} in
    r) ;;
    i) ;;
    ?) ;;
    esac
done

# Ensure the `sui` binary is installed. The reusable CI workflow runs
# this step (`start_containers_command`) BEFORE `install_dependencies_command`
# (which is where setup.sh normally runs), so we can't rely on the
# binary already being downloaded. setup.sh is idempotent — it overwrites
# `./bin/sui` on each call — so this is safe to run unconditionally for
# the not-on-PATH case.
export PATH="${DOCROOT}/bin:$PATH"
if ! command -v sui &> /dev/null; then
    echo ">> sui not found on PATH; running setup.sh to install it..."
    bash "${DOCROOT}/setup.sh"
fi

# Stop any previously-running local network so we start from a clean slate.
bash "${DOCROOT}/docker-delete-containers.sh"

# Start the local Sui fullnode + faucet on default ports (9001 / 9123).
# `run.sh start_network` invokes `exit 0` from a subshell on success, so
# control returns here once Sui is healthy.
bash "${DOCROOT}/run.sh" start_network

# Build the anvil image and bring up the EVM container, then deploy the
# EVM-side CCTP contracts.
source "${DOCROOT}/setup-evm-contracts.sh"

echo "Successfully started local network: sui (host) + anvil (docker)"
