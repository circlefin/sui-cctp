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

# clean build
rm -rf packages/**/build

sui move test --path packages/message_transmitter --coverage --statistics 
sui move test --path packages/token_messenger_minter --coverage --statistics

sui move coverage summary --path packages/message_transmitter
sui move coverage summary --path packages/token_messenger_minter
