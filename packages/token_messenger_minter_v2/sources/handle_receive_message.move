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

/// Module: handle_receive_message
/// V2 destination-side flow, decoupled from any specific stablecoin
/// implementation (TMM never touches `Coin<T>`):
///
///   1. `prepare_mint<T>`: validates the MT `Receipt` + decoded
///      `BurnMessage` and returns a `MintReceipt<T>` hot potato
///      carrying `(local_token, mint_recipient, amount_net, fee)`.
///      Callable by anyone.
///   2. `complete_mint<T, W: drop>`: called by the registered handler
///      package (proven via witness `W`). The handler mints the coin
///      itself between the two phases; `complete_mint` only stamps +
///      completes the MT receipt and emits `MintAndWithdraw`.
///
/// Trust boundary: `complete_mint` cannot observe whether the handler
/// actually minted. Correctness is enforced by (a) the witness `W`
/// (proves the caller is the registered handler for `local_token`) and
/// (b) the phantom `T` on `MintReceipt<T>` (prevents consuming a
/// receipt for the wrong token).
module token_messenger_minter_v2::handle_receive_message {
  // === Imports ===
  use sui::{
    clock::Clock,
    event::emit,
  };
  use message_transmitter_v2::{
    receive_message::{
      StampReceiptTicket,
      Receipt,
      create_stamp_receipt_ticket,
      stamp_receipt,
      complete_receive_message,
    },
    state::State as MessageTransmitterState,
  };
  use token_messenger_minter_v2::{
    burn_message,
    handler_registry,
    message_transmitter_authenticator::{Self, MessageTransmitterAuthenticator},
    state::State,
    token_utils::calculate_token_id,
    version_control::{Self, assert_object_version_is_compatible_with_package},
  };

  // === Errors ===
  // Numbering gaps at 5 (`EMissingMintCap`) and 12
  // (`ERecipientNotTokenMessenger`) retired; do not reuse.
  const EUnknownRemoteDomain: u64 = 0;
  const EInvalidRemoteTokenMessenger: u64 = 1;
  const EInvalidBurnMessageVersion: u64 = 2;
  const EUnknownBurnToken: u64 = 3;
  const EInvalidTokenType: u64 = 4;
  const EPaused: u64 = 6;
  const EAmountOverflow: u64 = 7;
  /// `expiration_block != 0 && expiration_block <= clock.timestamp_ms()`
  /// (Sui reinterprets EVM's `expirationBlock` as ms since epoch).
  const EExpiredMessage: u64 = 8;
  /// Attester charged more than the sender agreed to.
  const EFeeExceedsMaxFee: u64 = 9;
  /// Fee `>= amount` would leave the recipient with zero net mint.
  const EFeeExceedsAmount: u64 = 10;
  /// Attester marked source-chain state as less than "confirmed" (500).
  const EUnsupportedFinalityThreshold: u64 = 11;
  /// `MintReceipt.current_version` at consume time doesn't match
  /// `version_control::current_version()`. Fires when a receipt
  /// issued by phase-1@vN is fed to phase-2@vN+1 during a migration
  /// window (both versions are in `state.compatible_versions`, but
  /// the two phases must be pinned to the same package version).
  /// Mirrors MT's `EInvalidReceiptVersion` on the MT `Receipt`.
  const EInvalidReceiptVersion: u64 = 13;

  // === Constants ===
  /// Upper bound for the `u256 -> u64` cast on `BurnMessage.amount`;
  /// Sui's `Coin::mint` amount is `u64`.
  const MAX_U64: u256 = 18_446_744_073_709_551_615;
  /// Anything below "confirmed" (500) is too weak to mint on. Matches
  /// Aptos's `MIN_FINALITY_THRESHOLD_EXECUTED`.
  const MIN_FINALITY_THRESHOLD_EXECUTED: u32 = 500;

  // === Events ===
  public struct MintAndWithdraw has copy, drop {
    mint_recipient: address,
    /// Net amount (gross minus `fee_collected`) minted to `mint_recipient`.
    amount: u64,
    mint_token: address,
    /// Amount minted to `state.fee_recipient()`; 0 when `fee_executed == 0`.
    fee_collected: u64,
  }

  // === Hot-potato ===

  /// Handoff between `prepare_mint` (issues) and `complete_mint`
  /// (consumes). Zero abilities: must be consumed in the same PTB.
  /// Phantom `T` pins the receipt to the validated coin type. Also
  /// wraps the MT `StampReceiptTicket` so both payloads flow together.
  ///
  /// `current_version` is stamped at creation and re-checked at
  /// consumption so both phases must resolve to the same TMM
  /// package version (mirrors MT's `Receipt`). The embedded MT
  /// stamp ticket already pins MT's version internally; this
  /// separately pins TMM's — `state.compatible_versions` alone is
  /// insufficient during a migration window.
  public struct MintReceipt<phantom T> {
    /// MT stamp ticket produced from the consumed `Receipt`. Passed to
    /// `stamp_receipt` + `complete_receive_message` inside `complete_mint`.
    stamp_receipt_ticket: StampReceiptTicket<MessageTransmitterAuthenticator>,
    /// Local TMM token id (from remote->local mapping).
    local_token: address,
    /// Destination address that should receive the net mint.
    mint_recipient: address,
    /// Net amount to mint for `mint_recipient` (gross amount minus fee).
    amount: u64,
    /// Fee amount to mint for `state.fee_recipient()`.
    fee: u64,
    /// TMM package version at the time `prepare_mint` ran; re-checked
    /// in `complete_mint` so both phases must be the same version.
    current_version: u64,
  }

  // === Public-View Functions ===

  /// Returns `(local_token, mint_recipient, amount, fee)` from a
  /// Non-consuming view of `(local_token, mint_recipient, amount, fee)`
  /// so the handler can read + mint before `complete_mint`. Mirrors
  /// Aptos's `get_mint_details`.
  public fun get_mint_details<T>(receipt: &MintReceipt<T>): (address, address, u64, u64) {
    (receipt.local_token, receipt.mint_recipient, receipt.amount, receipt.fee)
  }

  // === Public phase-1 ===

  /// Phase 1: consume the MT `Receipt`, decode + validate the CCTP V2
  /// burn message, return a `MintReceipt<T>` for the handler to feed
  /// into `complete_mint<T, W>`. State is read-only.
  ///
  /// Aborts if the contract is paused, the remote messenger is
  /// unregistered or doesn't match the receipt sender, the burn
  /// message version is wrong, the remote burn token isn't mapped to
  /// `T`'s local id, `amount > MAX_U64`, the message has expired
  /// (`expiration_block != 0 && expiration_block <= clock.timestamp_ms()`),
  /// `fee_executed` violates its bounds
  /// (`> max_fee` or `>= amount`), or
  /// `finality_threshold_executed < 500` ("confirmed").
  ///
  /// `receipt.recipient() == this-TMM` is deliberately delegated to
  /// MT's `stamp_receipt` (`ERecipientNotAuth`), matching Sui V1.
  public fun prepare_mint<T: drop>(
    receipt: Receipt,
    state: &State,
    clock: &Clock,
  ): MintReceipt<T> {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    assert!(!state.paused(), EPaused);
    assert!(
      receipt.finality_threshold_executed() >= MIN_FINALITY_THRESHOLD_EXECUTED,
      EUnsupportedFinalityThreshold
    );

    let remote_domain = receipt.source_domain();
    let burn_message = burn_message::from_bytes(receipt.message_body());
    let burn_token_id = burn_message.burn_token();

    validate_remote_token_messenger(remote_domain, receipt.sender(), state);
    validate_burn_message_version(burn_message.version(), state);
    let local_token_id = validate_and_return_local_token<T>(remote_domain, burn_token_id, state);

    assert!(burn_message.amount() <= MAX_U64, EAmountOverflow);
    let gross = burn_message.amount() as u64;
    let fee = validate_fee_and_return_amount(gross, burn_message.max_fee(), burn_message.fee_executed());
    let net = gross - fee;

    let expiration = burn_message.expiration_block();
    if (expiration != 0) {
      assert!((clock.timestamp_ms() as u256) < expiration, EExpiredMessage);
    };

    // No CCTP denylist check on `mint_recipient` (matches Aptos):
    // recipient is passive, and Sui's framework `DenyList<T>` runs
    // when the handler mints in phase 2.
    let mint_recipient = burn_message.mint_recipient();

    let auth = message_transmitter_authenticator::new();
    let stamp_receipt_ticket = create_stamp_receipt_ticket(auth, receipt);

    MintReceipt<T> {
      stamp_receipt_ticket,
      local_token: local_token_id,
      mint_recipient,
      amount: net,
      fee,
      current_version: version_control::current_version(),
    }
  }

  // === Public phase-2 ===

  /// Phase 2: consume the `MintReceipt<T>`, stamp + complete the MT
  /// receipt, emit `MintAndWithdraw`. Does not touch any coin; the
  /// handler must have minted `amount` to `mint_recipient` and `fee`
  /// to `state.fee_recipient()` before calling here.
  ///
  /// The witness type `W` (carried inside the ticket) must be exactly the
  /// type registered as the handler for `local_token` — package + module +
  /// type. Aborts on version mismatch, unregistered handler, or MT
  /// stamp/complete failure.
  ///
  /// Ticket-based: the handler's Move package constructs the ticket via
  /// `create_complete_mint_ticket` (non-version-gated) and returns it to
  /// the client PTB, which feeds it here against the latest TMM V2
  /// package id. See the "Integrator Ticket Pattern" section below.
  public fun complete_mint<T: drop, W: drop>(
    ticket: CompleteMintTicket<T, W>,
    state: &State,
    message_transmitter_state: &MessageTransmitterState,
  ) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    let CompleteMintTicket { mint_receipt, witness } = ticket;
    let MintReceipt<T> {
      stamp_receipt_ticket,
      local_token,
      mint_recipient,
      amount,
      fee,
      current_version,
    } = mint_receipt;

    // Pin both phases to the same TMM package version. Prevents
    // cross-version splitting (phase-1@vN + phase-2@vN+1) during a
    // migration window when `state.compatible_versions` transiently
    // holds both.
    assert!(current_version == version_control::current_version(), EInvalidReceiptVersion);
    handler_registry::assert_is_registered_handler<W>(state, local_token, witness);

    // Emit `MintAndWithdraw` before MT's `MessageReceived` so indexers
    // see the mint result first (matches Sui V1 + Aptos).
    emit(MintAndWithdraw {
      mint_recipient,
      amount,
      mint_token: local_token,
      fee_collected: fee,
    });

    let stamped = stamp_receipt(stamp_receipt_ticket, message_transmitter_state);
    complete_receive_message(stamped, message_transmitter_state);
  }

  // === Integrator Ticket Pattern (upgrade-decoupling) ===
  //
  // See `deposit_for_burn` for the ticket-pattern rationale. Only
  // `complete_mint` needs a ticket variant here: `prepare_mint` is always
  // assembled by the client PTB (never called from a downstream Move
  // package), so it has no integrator to decouple.

  /// Hot-potato ticket carrying a `MintReceipt<T>` + handler witness.
  /// Consumed by `complete_mint`.
  public struct CompleteMintTicket<phantom T: drop, W: drop> {
    mint_receipt: MintReceipt<T>,
    witness: W,
  }

  /// NOT version-gated. Handler packages call this after minting the
  /// coin (and the fee, if any) and return the ticket to the client PTB.
  public fun create_complete_mint_ticket<T: drop, W: drop>(
    mint_receipt: MintReceipt<T>,
    witness: W,
  ): CompleteMintTicket<T, W> {
    CompleteMintTicket { mint_receipt, witness }
  }

  // === Private helpers ===

  fun validate_remote_token_messenger(remote_domain: u32, sender: address, state: &State) {
    assert!(state.remote_token_messenger_for_remote_domain_exists(remote_domain), EUnknownRemoteDomain);
    let remote_token_messenger = state.remote_token_messenger_from_remote_domain(remote_domain);
    assert!(remote_token_messenger == sender && sender != @0x0, EInvalidRemoteTokenMessenger);
  }

  fun validate_and_return_local_token<T: drop>(
    remote_domain: u32,
    burn_token_id: address,
    state: &State,
  ): address {
    assert!(state.local_token_from_remote_token_exists(remote_domain, burn_token_id), EUnknownBurnToken);
    let local_token_id = state.local_token_from_remote_token(remote_domain, burn_token_id);
    assert!(calculate_token_id<T>() == local_token_id, EInvalidTokenType);
    local_token_id
  }

  fun validate_burn_message_version(version: u32, state: &State) {
    assert!(version == state.message_body_version(), EInvalidBurnMessageVersion);
  }

  /// Validate fee bounds and return `fee_executed` as `u64`. Safe
  /// cast because `gross <= MAX_U64` and `fee_executed < gross`.
  fun validate_fee_and_return_amount(gross: u64, max_fee: u256, fee_executed: u256): u64 {
    assert!(fee_executed <= max_fee, EFeeExceedsMaxFee);
    assert!(fee_executed < (gross as u256), EFeeExceedsAmount);
    fee_executed as u64
  }

  // === Test Functions ===

  #[test_only]
  public fun create_mint_and_withdraw_event(
    mint_recipient: address,
    amount: u64,
    mint_token: address,
    fee_collected: u64,
  ): MintAndWithdraw {
    MintAndWithdraw { mint_recipient, amount, mint_token, fee_collected }
  }

  #[test_only]
  public fun destroy_mint_receipt_for_testing<T>(mint_receipt: MintReceipt<T>) {
    let MintReceipt<T> {
      stamp_receipt_ticket, local_token: _, mint_recipient: _, amount: _, fee: _, current_version: _,
    } = mint_receipt;
    std::unit_test::destroy(stamp_receipt_ticket);
  }

  /// Rewrites `current_version` on an existing `MintReceipt` to
  /// simulate the "phase-1@vN, phase-2@vN+1" migration-window
  /// scenario end-to-end without needing two published package
  /// addresses.
  #[test_only]
  public fun set_current_version_for_testing<T>(receipt: &mut MintReceipt<T>, version: u64) {
    receipt.current_version = version;
  }
}

#[test_only]
module token_messenger_minter_v2::invalid_test_token {
    public struct INVALID_TEST_TOKEN has drop {}
}

#[test_only]
module token_messenger_minter_v2::handle_receive_message_tests {
    use sui::{
        clock,
        coin_registry,
        deny_list::{Self, DenyList},
        event::num_events,
        test_scenario::{Self, Scenario},
        test_utils::{Self},
    };
    use std::unit_test::{Self, assert_eq};
    use stablecoin::treasury::{Self, Treasury, MintCap};
    use message_transmitter_v2::{
        auth::auth_caller_identifier,
        receive_message::{Self},
        state as message_transmitter_state,
    };
    use sui_extensions::test_utils::last_event_by_type;
    use token_messenger_minter_v2::{
        burn_message,
        handle_receive_message::{Self, MintAndWithdraw, create_mint_and_withdraw_event},
        handler_registry,
        invalid_test_token::INVALID_TEST_TOKEN,
        message_transmitter_authenticator::MessageTransmitterAuthenticator,
        state as token_messenger_state,
        token_utils::calculate_token_id,
        version_control,
    };

    // Test-token OTW.
    public struct HANDLE_RECEIVE_MESSAGE_TESTS has drop {}

    /// Test handler witness. Its type is registered as the test token's
    /// handler in setup.
    public struct MintHandlerWitness has drop {}

    const USER: address = @0x1A;
    const ADMIN: address = @0x2B;
    const LOCAL_DOMAIN: u32 = 0;
    const REMOTE_DOMAIN: u32 = 1;
    const REMOTE_TOKEN_MESSENGER: address = @0x0000000000000000000000003b61AbEe91852714E4e99b09a1AF3e9C13893eF1;
    const REMOTE_TOKEN: address = @0x0000000000000000000000001c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    const MINT_RECIPIENT: address = @0x1f26414439c8d03fc4b9ca912cefd5cb508c9605;
    const FEE_RECIPIENT: address = @0x3C;
    const AMOUNT: u64 = 1214;
    const VERSION: u32 = 1;
    /// "Finalized" per CCTP V2 (2000 >= 500 minimum).
    const FINALITY_THRESHOLD_FINALIZED: u32 = 2000;

    // === Happy-path tests ===

    /// Happy path: no fee, no expiration. Emits 3 events (Mint +
    /// MintAndWithdraw + MessageReceived).
    #[test]
    fun test_prepare_and_complete_mint_no_fee_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        {
            let receipt = receive_message::create_receipt(
                USER,
                auth_caller_identifier<MessageTransmitterAuthenticator>(),
                REMOTE_DOMAIN,
                REMOTE_TOKEN_MESSENGER,
                12,
                FINALITY_THRESHOLD_FINALIZED,
                burn_message::get_raw_test_message(),
                1
            );

            let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
                receipt, &token_messenger_state, &test_clock,
            );

            // Simulate handler-side mint between the two phases.
            treasury::mint(
                &mut treasury, &mint_cap, &deny_list,
                AMOUNT, MINT_RECIPIENT, scenario.ctx(),
            );

            let ticket = handle_receive_message::create_complete_mint_ticket<
                HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness
            >(mint_receipt, MintHandlerWitness {});
            handle_receive_message::complete_mint<HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness>(
                ticket,
                &token_messenger_state,
                &message_transmitter_state,
            );
        };

        // 3 events: Mint + MintAndWithdraw + MessageReceived.
        assert_eq!(num_events(), 3);
        let expected = create_mint_and_withdraw_event(
            MINT_RECIPIENT, AMOUNT, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), 0,
        );
        assert_eq!(last_event_by_type<MintAndWithdraw>(), expected);

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Happy path with non-zero `fee_executed`. Emits 4 events
    /// (2 Mints + MintAndWithdraw + MessageReceived).
    #[test]
    fun test_prepare_and_complete_mint_with_fee_successful() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, mut treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());
        let fee: u256 = 14;
        let max_fee: u256 = 20;
        let net_amount: u64 = AMOUNT - (fee as u64);

        scenario.next_tx(USER);
        {
            let raw = burn_message::build_raw_message_for_test(
                VERSION,
                REMOTE_TOKEN,
                MINT_RECIPIENT,
                AMOUNT as u256,
                REMOTE_TOKEN_MESSENGER,
                max_fee,
                fee,
                0,           // expiration_block
                x"",
            );
            let receipt = receive_message::create_receipt(
                USER,
                auth_caller_identifier<MessageTransmitterAuthenticator>(),
                REMOTE_DOMAIN,
                REMOTE_TOKEN_MESSENGER,
                13,
                FINALITY_THRESHOLD_FINALIZED,
                raw,
                1,
            );

            let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
                receipt, &token_messenger_state, &test_clock,
            );

            // Simulate handler-side mints (net + fee).
            treasury::mint(
                &mut treasury, &mint_cap, &deny_list,
                net_amount, MINT_RECIPIENT, scenario.ctx(),
            );
            treasury::mint(
                &mut treasury, &mint_cap, &deny_list,
                fee as u64, FEE_RECIPIENT, scenario.ctx(),
            );

            let ticket = handle_receive_message::create_complete_mint_ticket<
                HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness
            >(mint_receipt, MintHandlerWitness {});
            handle_receive_message::complete_mint<HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness>(
                ticket,
                &token_messenger_state,
                &message_transmitter_state,
            );
        };

        // 4 events: 2 Mints + MintAndWithdraw + MessageReceived.
        assert_eq!(num_events(), 4);
        let expected = create_mint_and_withdraw_event(
            MINT_RECIPIENT, net_amount, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), fee as u64,
        );
        assert_eq!(last_event_by_type<MintAndWithdraw>(), expected);

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// `get_mint_details` returns the receipt's fields without
    /// consuming it.
    #[test]
    fun test_get_mint_details_returns_components() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            14,
            FINALITY_THRESHOLD_FINALIZED,
            burn_message::get_raw_test_message(),
            1
        );
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        // Read via view; receipt NOT consumed.
        let (local_token, mint_recipient, amount, fee) =
            handle_receive_message::get_mint_details(&mint_receipt);
        assert_eq!(local_token, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>());
        assert_eq!(mint_recipient, MINT_RECIPIENT);
        assert_eq!(amount, AMOUNT);
        assert_eq!(fee, 0);

        // Same fields on second read; receipt intact.
        let (local_token2, mint_recipient2, amount2, fee2) =
            handle_receive_message::get_mint_details(&mint_receipt);
        assert_eq!(local_token, local_token2);
        assert_eq!(mint_recipient, mint_recipient2);
        assert_eq!(amount, amount2);
        assert_eq!(fee, fee2);

        // Consume the receipt without calling `complete_mint`.
        handle_receive_message::destroy_mint_receipt_for_testing(mint_receipt);

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    // === Unhappy-path tests ===

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EUnsupportedFinalityThreshold)]
    fun test_prepare_mint_revert_finality_below_minimum() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            15,
            499, // one below MIN_FINALITY_THRESHOLD_EXECUTED
            burn_message::get_raw_test_message(),
            1
        );

        // Expected to abort inside `prepare_mint` before any state mutation.
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        // Unreachable; kept only so the compiler sees the receipt consumed.
        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_prepare_mint_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        token_messenger_state.add_compatible_version(5);
        token_messenger_state.remove_compatible_version(version_control::current_version());

        scenario.next_tx(USER);
        let receipt = build_default_receipt(20);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EPaused)]
    fun test_prepare_mint_revert_paused() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        token_messenger_state.set_paused(true);

        scenario.next_tx(USER);
        let receipt = build_default_receipt(21);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EUnknownRemoteDomain)]
    fun test_prepare_mint_revert_unknown_remote_domain() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            9999, // no messenger registered for this remote domain
            REMOTE_TOKEN_MESSENGER,
            22,
            FINALITY_THRESHOLD_FINALIZED,
            burn_message::get_raw_test_message(),
            1
        );
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidRemoteTokenMessenger)]
    fun test_prepare_mint_revert_invalid_remote_token_messenger() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            @0xDEAD, // wrong sender vs the registered messenger
            23,
            FINALITY_THRESHOLD_FINALIZED,
            burn_message::get_raw_test_message(),
            1
        );
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Zero-address sender still aborts even when it matches the
    /// registered messenger (guards the `&& sender != @0x0` clause).
    /// Restores V1's `test_handle_receive_message_revert_null_address_remote_token_messenger`.
    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidRemoteTokenMessenger)]
    fun test_prepare_mint_revert_null_address_remote_token_messenger() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        // Swap the registered messenger to @0x0 so the receipt's
        // zero-address sender matches it.
        token_messenger_state.remove_remote_token_messenger(REMOTE_DOMAIN);
        token_messenger_state.add_remote_token_messenger(REMOTE_DOMAIN, @0x0);

        scenario.next_tx(USER);
        let receipt = receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            @0x0, // matches the (now zero) registered value, still must abort
            24,
            FINALITY_THRESHOLD_FINALIZED,
            burn_message::get_raw_test_message(),
            1
        );
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidBurnMessageVersion)]
    fun test_prepare_mint_revert_invalid_burn_message_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION + 1, // wrong version
            REMOTE_TOKEN, MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            0, 0, 0, x"",
        );
        let receipt = build_receipt_with_body(24, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EUnknownBurnToken)]
    fun test_prepare_mint_revert_unknown_burn_token() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION,
            @0xBAD, // unregistered burn token
            MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            0, 0, 0, x"",
        );
        let receipt = build_receipt_with_body(25, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Wrong `T` on `prepare_mint<T>` (via `INVALID_TEST_TOKEN`).
    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidTokenType)]
    fun test_prepare_mint_revert_invalid_token_type() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = build_default_receipt(26);
        // Wrong `T`: the receipt's burn_token maps to
        // HANDLE_RECEIVE_MESSAGE_TESTS, not INVALID_TEST_TOKEN.
        let mint_receipt = handle_receive_message::prepare_mint<INVALID_TEST_TOKEN>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EAmountOverflow)]
    fun test_prepare_mint_revert_amount_overflow() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION, REMOTE_TOKEN, MINT_RECIPIENT,
            18_446_744_073_709_551_616, // 2^64 (one above u64::MAX)
            REMOTE_TOKEN_MESSENGER, 0, 0, 0, x"",
        );
        let receipt = build_receipt_with_body(27, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EFeeExceedsMaxFee)]
    fun test_prepare_mint_revert_fee_exceeds_max_fee() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION, REMOTE_TOKEN, MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            10, // max_fee
            20, // fee_executed > max_fee
            0, x"",
        );
        let receipt = build_receipt_with_body(28, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = handle_receive_message::EFeeExceedsAmount)]
    fun test_prepare_mint_revert_fee_exceeds_amount() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION, REMOTE_TOKEN, MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            AMOUNT as u256, // max_fee = amount (large enough that fee_executed <= max_fee)
            AMOUNT as u256, // fee_executed == amount => fails the strict < check
            0, x"",
        );
        let receipt = build_receipt_with_body(29, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Expired: `expiration_block <= clock.timestamp_ms()`.
    #[test]
    #[expected_failure(abort_code = handle_receive_message::EExpiredMessage)]
    fun test_prepare_mint_revert_expired_message() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let mut test_clock = clock::create_for_testing(scenario.ctx());
        clock::set_for_testing(&mut test_clock, 1_000_000);

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION, REMOTE_TOKEN, MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            0, 0,
            500_000, // expiration_block (ms) < clock.now (1_000_000)
            x"",
        );
        let receipt = build_receipt_with_body(30, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Boundary: `now == expiration` is expired (the check is strict `<`).
    #[test]
    #[expected_failure(abort_code = handle_receive_message::EExpiredMessage)]
    fun test_prepare_mint_revert_expiration_equals_now() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let mut test_clock = clock::create_for_testing(scenario.ctx());
        clock::set_for_testing(&mut test_clock, 1_000_000);

        scenario.next_tx(USER);
        let raw = burn_message::build_raw_message_for_test(
            VERSION, REMOTE_TOKEN, MINT_RECIPIENT, AMOUNT as u256, REMOTE_TOKEN_MESSENGER,
            0, 0,
            1_000_000, // expiration_block (ms) == clock.now (1_000_000)
            x"",
        );
        let receipt = build_receipt_with_body(30, raw);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        unit_test::destroy(mint_receipt);
        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    // (No recipient-vs-this-TMM test; that invariant is enforced by
    // MT's `stamp_receipt`, not by TMM. Matches Sui V1.)

    /// Package upgraded between `prepare_mint` and `complete_mint`.
    #[test]
    #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
    fun test_complete_mint_revert_incompatible_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = build_default_receipt(32);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        // Simulate a mid-flow package upgrade: swap the compatible version.
        token_messenger_state.add_compatible_version(5);
        token_messenger_state.remove_compatible_version(version_control::current_version());

        let ticket = handle_receive_message::create_complete_mint_ticket<
            HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness
        >(mint_receipt, MintHandlerWitness {});
        handle_receive_message::complete_mint<HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness>(
            ticket,
            &token_messenger_state,
            &message_transmitter_state,
        );

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    /// Handler rotated between phases: `complete_mint` witness auth fails.
    #[test]
    #[expected_failure(abort_code = handler_registry::ENotRegisteredHandler)]
    fun test_complete_mint_revert_wrong_handler() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(USER);
        let receipt = build_default_receipt(33);
        let mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );

        // Overwrite the registered handler identifier with a value no
        // obtainable witness type resolves to, so `MintHandlerWitness`'s
        // identifier no longer matches.
        token_messenger_state.set_handler(
            calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), @0xDEAD,
        );

        let ticket = handle_receive_message::create_complete_mint_ticket<
            HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness
        >(mint_receipt, MintHandlerWitness {});
        handle_receive_message::complete_mint<HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness>(
            ticket,
            &token_messenger_state,
            &message_transmitter_state,
        );

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    // (`test_complete_mint_revert_missing_mint_cap` retired with the
    // handler decoupling; TMM no longer looks up a `MintCap<T>`.)

    /// Simulates the phase-1@vN + phase-2@vN+1 attack window: the
    /// state is currently compatible with both versions
    /// (mid-migration), but the receipt was stamped by an older TMM
    /// package version. The receipt's `current_version` guard must
    /// fire even though `state.compatible_versions` still admits
    /// both.
    #[test]
    #[expected_failure(abort_code = handle_receive_message::EInvalidReceiptVersion)]
    fun test_complete_mint_revert_stale_receipt_version() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (mint_cap, treasury, deny_list) = setup_coin<HANDLE_RECEIVE_MESSAGE_TESTS>(&mut scenario);
        let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
        let test_clock = clock::create_for_testing(scenario.ctx());

        // Simulate a live migration window: both v_current and a
        // next version are in `compatible_versions`, so the
        // `assert_object_version_is_compatible_with_package` gate on
        // `complete_mint` still passes.
        let next_version = version_control::current_version() + 1;
        token_messenger_state.add_compatible_version(next_version);

        scenario.next_tx(USER);
        let receipt = build_default_receipt(41);
        let mut mint_receipt = handle_receive_message::prepare_mint<HANDLE_RECEIVE_MESSAGE_TESTS>(
            receipt, &token_messenger_state, &test_clock,
        );
        // Simulate the receipt having been stamped by a different
        // (still-compatible) TMM package version than the one now
        // running. We rewrite to `next_version` so the receipt's
        // stamp is one of the versions in
        // `state.compatible_versions` but is NOT equal to
        // `version_control::current_version()` — exactly the
        // phase-1@vN + phase-2@vN+1 mismatch.
        handle_receive_message::set_current_version_for_testing(
            &mut mint_receipt, next_version,
        );

        let ticket = handle_receive_message::create_complete_mint_ticket<
            HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness
        >(mint_receipt, MintHandlerWitness {});
        handle_receive_message::complete_mint<HANDLE_RECEIVE_MESSAGE_TESTS, MintHandlerWitness>(
            ticket,
            &token_messenger_state,
            &message_transmitter_state,
        );

        clock::destroy_for_testing(test_clock);
        unit_test::destroy(token_messenger_state);
        unit_test::destroy(message_transmitter_state);
        unit_test::destroy(deny_list);
        unit_test::destroy(treasury);
        unit_test::destroy(mint_cap);
        scenario.end();
    }

    // === Test helpers ===

    /// Canonical `get_raw_test_message` body + `FINALITY_THRESHOLD_FINALIZED`.
    fun build_default_receipt(nonce: u256): receive_message::Receipt {
        receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            nonce,
            FINALITY_THRESHOLD_FINALIZED,
            burn_message::get_raw_test_message(),
            1
        )
    }

    /// Same as `build_default_receipt` but with a custom body.
    fun build_receipt_with_body(nonce: u256, message_body: vector<u8>): receive_message::Receipt {
        receive_message::create_receipt(
            USER,
            auth_caller_identifier<MessageTransmitterAuthenticator>(),
            REMOTE_DOMAIN,
            REMOTE_TOKEN_MESSENGER,
            nonce,
            FINALITY_THRESHOLD_FINALIZED,
            message_body,
            1
        )
    }


    fun setup_coin<T: drop>(
        scenario: &mut Scenario
    ): (MintCap<T>, Treasury<T>, DenyList) {
        let otw = test_utils::create_one_time_witness<T>();
        let (mut init, treasury_cap) = coin_registry::new_currency_with_otw(
            otw, 6, b"SYMBOL".to_string(), b"NAME".to_string(),
            b"".to_string(), b"".to_string(), scenario.ctx()
        );
        let deny_cap = coin_registry::make_regulated(&mut init, true, scenario.ctx());
        let metadata_cap = coin_registry::finalize(init, scenario.ctx());

        let mut treasury = treasury::new(
            treasury_cap, deny_cap,
            scenario.ctx().sender(), scenario.ctx().sender(),
            scenario.ctx().sender(), scenario.ctx().sender(),
            scenario.ctx().sender(), scenario.ctx()
        );
        treasury.configure_new_controller(ADMIN, ADMIN, scenario.ctx());
        scenario.next_tx(ADMIN);
        let mint_cap = scenario.take_from_address<MintCap<T>>(ADMIN);
        let deny_list = deny_list::new_for_testing(scenario.ctx());
        treasury.configure_minter(&deny_list, 999999999, scenario.ctx());
        unit_test::destroy(metadata_cap);

        (mint_cap, treasury, deny_list)
    }

    /// Builds TMM + MT state. Does not consume the caller's
    /// `MintCap`; tests keep it in scope (TMM no longer stores it).
    fun setup_cctp_states(
        scenario: &mut Scenario,
    ): (token_messenger_state::State, message_transmitter_state::State) {
        let ctx = test_scenario::ctx(scenario);

        let mut token_messenger_state = token_messenger_state::new(VERSION, ADMIN, ctx);
        let message_transmitter_state = message_transmitter_state::new_for_testing(
            LOCAL_DOMAIN, VERSION, 1000, ADMIN, ctx
        );

        token_messenger_state.add_remote_token_messenger(REMOTE_DOMAIN, REMOTE_TOKEN_MESSENGER);
        token_messenger_state.add_local_token_for_remote_token(
            REMOTE_DOMAIN, REMOTE_TOKEN, calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>()
        );
        token_messenger_state.add_burn_limit(calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(), 1000000);

        // Register the identifier for `MintHandlerWitness` as the handler.
        token_messenger_state.set_handler(
            calculate_token_id<HANDLE_RECEIVE_MESSAGE_TESTS>(),
            handler_registry::handler_identifier_for_testing<MintHandlerWitness>(),
        );
        // Distinct fee_recipient so the fee-path test can assert on it.
        token_messenger_state.set_fee_recipient(FEE_RECIPIENT);

        (token_messenger_state, message_transmitter_state)
    }
}
