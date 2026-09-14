/*
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

/// Module: message_transmitter_authenticator
/// Authenticator witness passed to `message_transmitter_v2::send_message`
/// so MT can attribute the outbound message to this package.
module token_messenger_minter_v2::message_transmitter_authenticator {
  // === Structs ===
  public struct MessageTransmitterAuthenticator has drop {}

  // === Public-Package Functions ===
  public(package) fun new(): MessageTransmitterAuthenticator {
    MessageTransmitterAuthenticator {}
  }
}
