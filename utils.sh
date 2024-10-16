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
# prohibited without the express written permission of Circle Internet Financial
# Trading Company Limited.
#

# Don't allow users to execute this script, it is only meant to be sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo 'ERROR: This script is not an executable, you must source it!'
    echo "Usage: source $0"
    exit 1
fi


COUNT=10
check_health(){
    CONTAINER=$(docker-compose ps -q $1)
    for (( i=1 ; i <= COUNT; i++ )); do

      RESULT=$(docker ps -q --filter health=healthy --filter id=${CONTAINER} | wc -l)
      if [[ ${RESULT} -eq 1 ]]; then
        echo -e "${1} healthy!!!\n"
        break
      else
        echo "${1} not healthy.  Attempt $i of ${COUNT}. Retrying in 5 seconds."
        if [[ "${i}" != "${COUNT}" ]]; then
            sleep 5
        fi
      fi

      if [[ "$i" == "${COUNT}" ]]; then
        echo -e "ERROR: $1 not healthy after ${COUNT} attempts. Aborting"
        docker-compose logs "$1"
        exit 1
      fi
    done
}
