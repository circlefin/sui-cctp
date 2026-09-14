/**
 * Copyright (c) 2026, Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Shared CCTP V2 constants used by both the deploy flow (deploy.ts) and the
 * client-side PTB builders / E2E (ptbV2.ts). Kept in one place so the values
 * written into on-chain state at deploy time and the values assumed when
 * building / synthesizing messages can never drift apart.
 */

// Domains — must match what deploy.ts writes into on-chain state at init.
export const SUI_LOCAL_DOMAIN = 8;
export const REMOTE_EVM_DOMAIN = 0;

// CCTP V2 message versions (V1 used 0).
export const V2_MESSAGE_VERSION = 1;
export const V2_MESSAGE_BODY_VERSION = 1;

// Fixed system object ids.
export const DENY_LIST_ID = "0x403";
export const CLOCK_ID = "0x6";
