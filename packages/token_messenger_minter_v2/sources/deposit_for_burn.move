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

/// Module: deposit_for_burn
/// V2 source-side burn + send flow, decoupled from any specific
/// stablecoin implementation (TMM never touches `Coin<T>`):
///
///   1. `deposit_for_burn`: validates inputs against TMM state,
///      returns a `BurnReceipt<T>` hot potato and the unchanged
///      `Coin<T>`. Callable by anyone.
///   2. `complete_burn<T, W: drop>`: called by the registered handler
///      package (proven via witness `W`). The handler burns the coin
///      itself between the two phases; `complete_burn` only sends the
///      MT message and emits `DepositForBurn`.
///
/// Trust boundary: `complete_burn` cannot observe whether the handler
/// actually burned the coin. Correctness is enforced by (a) the
/// witness `W` (proves the caller is the registered handler for
/// `burn_token`) and (b) the phantom `T` on `BurnReceipt<T>` (prevents
/// consuming a receipt for the wrong token).
module token_messenger_minter_v2::deposit_for_burn {

  // === Imports ===
  use sui::{
    coin::{Coin},
    event::emit
  };
  use message_transmitter_v2::{
    auth::{auth_caller_identifier, auth_caller_package_address},
    message::{Message},
    send_message::{create_send_message_ticket, send_message},
    state::{State as MessageTransmitterState}
  };
  use token_messenger_minter_v2::{
    burn_message::{Self, BurnMessage},
    denylistable,
    fee_controller,
    handler_registry,
    message_transmitter_authenticator,
    state::{State},
    token_utils::{calculate_token_id},
    version_control::{Self, assert_object_version_is_compatible_with_package}
  };

  // === Errors ===
  // Numbering gaps at 4, 9, 10 retired with the handler decoupling
  // (`EMissingMintCap`, `EBurnAmountMismatch`, `EBurnTokenTypeMismatch`);
  // do not reuse.
  const EZeroAmount: u64 = 0;
  const EZeroAddressMintRecipient: u64 = 1;
  const EInvalidDestinationDomain: u64 = 2;
  const EPaused: u64 = 3;
  const EMissingBurnLimit: u64 = 5;
  const EBurnLimitExceeded: u64 = 6;
  const EInvalidMaxFee: u64 = 7;
  const EInsufficientMaxFee: u64 = 8;
  /// `BurnReceipt.current_version` at consume time doesn't match
  /// `version_control::current_version()`. Fires when a receipt
  /// issued by phase-1@vN is fed to phase-2@vN+1 during a migration
  /// window (both versions are in `state.compatible_versions`, but
  /// the two phases must be pinned to the same package version).
  /// Mirrors MT's `EInvalidReceiptVersion` on the MT `Receipt`.
  const EInvalidReceiptVersion: u64 = 11;

  // === Events ===
  /// Emitted from `complete_burn`. No `nonce` because V2 assigns nonces
  /// off-chain in the attestation service.
  public struct DepositForBurn has copy, drop {
    burn_token: address,
    amount: u256,
    depositor: address,
    mint_recipient: address,
    destination_domain: u32,
    destination_token_messenger: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
  }

  // === Hot-potato ===

  /// Handoff between `deposit_for_burn` (issues) and `complete_burn`
  /// (consumes). Zero abilities: must be consumed in the same PTB.
  /// Phantom `T` pins the receipt to the validated coin type.
  ///
  /// `current_version` is stamped at creation and re-checked at
  /// consumption so both phases must resolve to the same package
  /// version (mirrors MT's `Receipt`). `state.compatible_versions`
  /// alone is insufficient during a migration window, when the set
  /// contains both v_N and v_{N+1}: a receipt from phase-1@v_N
  /// composed with phase-2@v_{N+1} in one PTB would otherwise pass
  /// both gates.
  public struct BurnReceipt<phantom T> {
    caller: address,
    burn_token: address,
    amount: u64,
    destination_domain: u32,
    mint_recipient: address,
    destination_caller: address,
    destination_token_messenger: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
    current_version: u64,
  }

  // === Public-View Functions ===

  /// Non-consuming view of `(burn_token, amount, mint_recipient)`.
  public fun get_burn_details<T>(receipt: &BurnReceipt<T>): (address, u64, address) {
    (receipt.burn_token, receipt.amount, receipt.mint_recipient)
  }

  // === Public-Mutative Functions ===

  /// Phase 1: validate inputs, issue `BurnReceipt<T>`, return the
  /// `Coin<T>` unchanged. Callable by anyone; handler auth is
  /// enforced in `complete_burn`.
  ///
  /// Aborts if the contract is paused, `ctx.sender()` is on the CCTP
  /// denylist, `amount == 0`, `mint_recipient == @0x0`, `max_fee` is not
  /// strictly less than `amount` (the check is `<`, so `max_fee == amount`
  /// aborts too — intentional so the net minted amount on the destination
  /// stays strictly positive) or `max_fee` falls below the per-token
  /// min-fee floor, `destination_domain` has no registered TokenMessenger,
  /// `T` has no registered burn limit, or the burn amount exceeds it.
  ///
  /// `destination_caller` restricts who can execute the receive on
  /// the destination; pass `@0x0` for no restriction. `hook_data` is
  /// opaque bytes forwarded to the destination-side handler.
  public fun deposit_for_burn<T: drop>(
    coin: Coin<T>,
    destination_domain: u32,
    mint_recipient: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
    state: &State,
    ctx: &mut TxContext,
  ): (BurnReceipt<T>, Coin<T>) {
    // `ctx.sender()` is screened inside `create_burn_receipt` (it is the
    // `caller`); the gas sponsor, if any, is screened here.
    denylistable::assert_sponsor_not_denylisted(state, ctx);

    create_burn_receipt<T>(
      coin, destination_domain, mint_recipient, destination_caller,
      max_fee, min_finality_threshold, hook_data,
      ctx.sender(),
      state
    )
  }

  /// Phase 1, package-callable variant. Records
  /// `auth_caller_identifier<W>()` as the receipt's caller (also used
  /// for the denylist check) so the outbound message's
  /// `message_sender` reflects the calling package, not the PTB
  /// signer. Same aborts as `deposit_for_burn`.
  ///
  /// Ticket-based: the integrator's Move package constructs the ticket
  /// via `create_deposit_for_burn_with_package_auth_ticket` (non-version-
  /// gated) and the client PTB feeds it here against the latest TMM V2
  /// package id. See the "Integrator Ticket Pattern" section below.
  public fun deposit_for_burn_with_package_auth<T: drop, W: drop>(
    ticket: DepositForBurnWithPackageAuthTicket<T, W>,
    state: &State,
    ctx: &mut TxContext,
  ): (BurnReceipt<T>, Coin<T>) {
    let DepositForBurnWithPackageAuthTicket {
      coin,
      destination_domain,
      mint_recipient,
      destination_caller,
      max_fee,
      min_finality_threshold,
      hook_data,
      witness: _witness,
    } = ticket;

    // Four denylist screens:
    //   - `ctx.sender()`: blocks a denylisted user regardless of helper package.
    //   - `ctx.sponsor()`: blocks a denylisted gas payer funding the call
    //     through an unlisted sender. No-op when unsponsored.
    //   - `auth_caller_package_address<W>()`: blocks the whole calling
    //     package. The type-hash screen below is per-witness-type, so
    //     without this a denylisted package could rotate to a different
    //     `drop` witness and bypass.
    //   - `auth_caller_identifier<W>()` (inside `create_burn_receipt`):
    //     lets an admin narrowly block a single witness type.
    denylistable::assert_not_denylisted(state, ctx.sender());
    denylistable::assert_sponsor_not_denylisted(state, ctx);
    denylistable::assert_not_denylisted(state, auth_caller_package_address<W>());
    create_burn_receipt<T>(
      coin, destination_domain, mint_recipient, destination_caller,
      max_fee, min_finality_threshold, hook_data,
      auth_caller_identifier<W>(),
      state
    )
  }

  // === Private Phase-1 helper ===

  /// Shared validation + `BurnReceipt` construction. Called by both
  /// public wrappers with the appropriate `caller` value.
  fun create_burn_receipt<T: drop>(
    coin: Coin<T>,
    destination_domain: u32,
    mint_recipient: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
    caller: address,
    state: &State,
  ): (BurnReceipt<T>, Coin<T>) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    let amount = coin.value();
    let token_id = calculate_token_id<T>();

    assert!(!state.paused(), EPaused);
    // Framework `DenyList<T>` on the coin itself runs in phase 2 when
    // the handler calls `stablecoin::treasury::burn`.
    denylistable::assert_not_denylisted(state, caller);
    assert!(amount > 0, EZeroAmount);
    assert!(mint_recipient != @0x0, EZeroAddressMintRecipient);
    assert!(max_fee < (amount as u256), EInvalidMaxFee);
    assert!(
      max_fee >= fee_controller::calculate_min_fee_amount(state, token_id, amount as u256),
      EInsufficientMaxFee
    );

    let destination_token_messenger = safe_get_remote_token_messenger(destination_domain, state);
    let burn_limit = safe_get_burn_limit(token_id, state);
    assert!(burn_limit >= amount, EBurnLimitExceeded);

    let receipt = BurnReceipt<T> {
      caller,
      burn_token: token_id,
      amount,
      destination_domain,
      mint_recipient,
      destination_caller,
      destination_token_messenger,
      max_fee,
      min_finality_threshold,
      hook_data,
      current_version: version_control::current_version(),
    };

    (receipt, coin)
  }

  /// Phase 2: consume the `BurnReceipt<T>`, send the MT message, emit
  /// `DepositForBurn`. Does not touch any coin; the handler must have
  /// burned the `Coin<T>` returned from `deposit_for_burn` before
  /// calling here.
  ///
  /// The witness type `W` (carried inside the ticket) must be exactly the
  /// type registered as the handler for the receipt's `burn_token` —
  /// package + module + type (see
  /// `handler_registry::assert_is_registered_handler`). Aborts on version
  /// mismatch, unregistered handler, or MT send failure.
  ///
  /// Ticket-based: the handler's Move package constructs the ticket via
  /// `create_complete_burn_ticket` (non-version-gated) and returns it to
  /// the client PTB, which feeds it here against the latest TMM V2
  /// package id. See the "Integrator Ticket Pattern" section below.
  public fun complete_burn<T: drop, W: drop>(
    ticket: CompleteBurnTicket<T, W>,
    state: &State,
    message_transmitter_state: &MessageTransmitterState,
  ) {
    assert_object_version_is_compatible_with_package(state.compatible_versions());
    let CompleteBurnTicket { burn_receipt, witness } = ticket;
    let BurnReceipt<T> {
      caller,
      burn_token,
      amount,
      destination_domain,
      mint_recipient,
      destination_caller,
      destination_token_messenger,
      max_fee,
      min_finality_threshold,
      hook_data,
      current_version,
    } = burn_receipt;

    // Pin both phases to the same package version. Prevents
    // cross-version splitting (phase-1@vN + phase-2@vN+1) during a
    // migration window when `state.compatible_versions` transiently
    // holds both.
    assert!(current_version == version_control::current_version(), EInvalidReceiptVersion);
    handler_registry::assert_is_registered_handler<W>(state, burn_token, witness);

    let burn_message = burn_message::new(
      state.message_body_version(), burn_token, mint_recipient, amount as u256,
      caller, max_fee, hook_data
    );

    let _ = send_burn_message(
      destination_domain,
      destination_token_messenger,
      destination_caller,
      min_finality_threshold,
      &burn_message,
      message_transmitter_state
    );

    emit(DepositForBurn {
      burn_token,
      amount: amount as u256,
      depositor: caller,
      mint_recipient,
      destination_domain,
      destination_token_messenger,
      destination_caller,
      max_fee: burn_message.max_fee(),
      min_finality_threshold,
      hook_data: burn_message.hook_data()
    });
  }

  // === Integrator Ticket Pattern (upgrade-decoupling) ===
  //
  // Ticket constructors let cross-package callers avoid linking against
  // TMM V2's version-gated public entry points:
  //   1. `create_*_ticket` (non-version-gated) — integrator's Move package
  //      builds a hot-potato ticket carrying inputs + witness. No `&State`
  //      in the constructor signature, so linking against these symbols
  //      does not couple the integrator's bytecode to TMM V2's version.
  //   2. The version-gated public entry points above
  //      (`deposit_for_burn_with_package_auth` / `complete_burn`) consume
  //      the ticket. Invoked from the client PTB against the latest TMM V2
  //      package id.
  //
  // Both tickets are hot potatoes (no abilities) — must be consumed in the
  // same PTB, so the two-phase atomicity is preserved.

  /// Hot-potato ticket for phase 1 (package-auth variant). Consumed by
  /// `deposit_for_burn_with_package_auth`.
  #[allow(lint(coin_field))]
  public struct DepositForBurnWithPackageAuthTicket<phantom T: drop, W: drop> {
    coin: Coin<T>,
    destination_domain: u32,
    mint_recipient: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
    witness: W,
  }

  /// NOT version-gated. Parameters mirror `deposit_for_burn`.
  public fun create_deposit_for_burn_with_package_auth_ticket<T: drop, W: drop>(
    coin: Coin<T>,
    destination_domain: u32,
    mint_recipient: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>,
    witness: W,
  ): DepositForBurnWithPackageAuthTicket<T, W> {
    DepositForBurnWithPackageAuthTicket {
      coin,
      destination_domain,
      mint_recipient,
      destination_caller,
      max_fee,
      min_finality_threshold,
      hook_data,
      witness,
    }
  }

  /// Hot-potato ticket carrying a `BurnReceipt<T>` + handler witness.
  /// Consumed by `complete_burn`.
  public struct CompleteBurnTicket<phantom T: drop, W: drop> {
    burn_receipt: BurnReceipt<T>,
    witness: W,
  }

  /// NOT version-gated. Handler packages call this after burning the coin
  /// and return the ticket to the client PTB.
  public fun create_complete_burn_ticket<T: drop, W: drop>(
    burn_receipt: BurnReceipt<T>,
    witness: W,
  ): CompleteBurnTicket<T, W> {
    CompleteBurnTicket { burn_receipt, witness }
  }

  // === Private Functions ===

  fun safe_get_remote_token_messenger(remote_domain: u32, state: &State): address {
    assert!(
      state.remote_token_messenger_for_remote_domain_exists(remote_domain),
      EInvalidDestinationDomain
    );
    state.remote_token_messenger_from_remote_domain(remote_domain)
  }

  fun safe_get_burn_limit(local_token_id: address, state: &State): u64 {
    assert!(state.burn_limit_for_token_id_exists(local_token_id), EMissingBurnLimit);
    state.burn_limit_from_token_id(local_token_id)
  }

  /// Delegates to MT V2's `send_message`. `destination_caller == @0x0`
  /// means "no caller restriction" on the destination side.
  fun send_burn_message(
    destination_domain: u32,
    destination_token_messenger: address,
    destination_caller: address,
    min_finality_threshold: u32,
    burn_message: &BurnMessage,
    message_transmitter_state: &MessageTransmitterState
  ): Message {
    let authenticator = message_transmitter_authenticator::new();
    let ticket = create_send_message_ticket(
      authenticator,
      destination_domain,
      destination_token_messenger,
      destination_caller,
      min_finality_threshold,
      burn_message.serialize()
    );
    send_message(ticket, message_transmitter_state)
  }

  // === Test-only helpers ===

  #[test_only]
  public fun create_deposit_for_burn_event(
    burn_token: address,
    amount: u256,
    depositor: address,
    mint_recipient: address,
    destination_domain: u32,
    destination_token_messenger: address,
    destination_caller: address,
    max_fee: u256,
    min_finality_threshold: u32,
    hook_data: vector<u8>
  ): DepositForBurn {
    DepositForBurn {
      burn_token, amount, depositor, mint_recipient,
      destination_domain, destination_token_messenger, destination_caller,
      max_fee, min_finality_threshold, hook_data
    }
  }

  /// Destructor for tests that only exercise the deposit phase and
  /// never call `complete_burn`.
  #[test_only]
  public fun destroy_burn_receipt_for_testing<T>(receipt: BurnReceipt<T>) {
    let BurnReceipt<T> { .. } = receipt;
  }

  /// Rewrites `current_version` on an existing `BurnReceipt` to
  /// simulate the "phase-1@vN, phase-2@vN+1" migration-window scenario
  /// end-to-end without needing two published package addresses.
  #[test_only]
  public fun set_current_version_for_testing<T>(receipt: &mut BurnReceipt<T>, version: u64) {
    receipt.current_version = version;
  }
}

#[test_only]
module token_messenger_minter_v2::deposit_for_burn_tests {
  use sui::{
    coin::{Coin},
    coin_registry,
    deny_list::{Self, DenyList},
    event::{num_events},
    test_scenario::{Self, Scenario},
  };
  use sui::test_utils;
  use std::unit_test::{Self, assert_eq};
  use message_transmitter_v2::{
    auth::auth_caller_identifier,
    state as message_transmitter_state,
  };
  use stablecoin::treasury::{Self, Treasury, MintCap};
  use token_messenger_minter_v2::{
    denylistable,
    deposit_for_burn::{Self, BurnReceipt},
    fee_controller,
    handler_registry,
    state as token_messenger_state,
    token_utils::calculate_token_id,
    version_control
  };
  use sui_extensions::test_utils::last_event_by_type;

  // === Test types + constants ===

  /// Test-token OTW.
  public struct DEPOSIT_FOR_BURN_TESTS has drop {}

  /// Test handler witness. Its type is registered as the test token's
  /// handler in setup (via `register_handler<BurnHandlerWitness>`).
  public struct BurnHandlerWitness has drop {}

  const AMOUNT: u256 = 100;
  const ADMIN: address = @0xAD;
  const USER: address = @0xA1;
  // Gas sponsor for the sponsored-transaction denylist tests.
  const SPONSOR: address = @0xE5;
  const DESTINATION_DOMAIN: u32 = 2;
  const MINT_RECIPIENT: address = @0xB2;
  const DESTINATION_CALLER: address = @0xC3;
  const REMOTE_TOKEN_MESSENGER: address = @0xD4;

  // === Successful two-phase flow ===

  #[test]
  fun test_deposit_and_complete_burn_no_destination_caller_successful() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();

      // Phase 1: validate + get receipt back
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      let (burn_token, amount, mint_recipient) = deposit_for_burn::get_burn_details(&receipt);
      assert_eq!(burn_token, calculate_token_id<DEPOSIT_FOR_BURN_TESTS>());
      assert_eq!(amount, AMOUNT as u64);
      assert_eq!(mint_recipient, MINT_RECIPIENT);

      // Phase 2: handler completes. Fields on the constructed burn
      // message + MT message are covered by the `DepositForBurn` event
      // check below (which asserts on the exact expected event), so no
      // per-field assertions needed here.
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );

      // Events: message_sent + burn + DepositForBurn
      assert!(num_events() == 3);
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(
        last_event_by_type<deposit_for_burn::DepositForBurn>() ==
          deposit_for_burn::create_deposit_for_burn_event(
            burn_token, AMOUNT, USER, MINT_RECIPIENT,
            2, REMOTE_TOKEN_MESSENGER, @0x0, 0, 0, x""
          )
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  fun test_deposit_for_burn_with_package_auth_records_witness_package_as_sender() {
    // A handler-fronted burn using the ticket-based package-auth path:
    // integrator's Move package constructs the ticket via
    // `create_deposit_for_burn_with_package_auth_ticket`, and the client
    // PTB feeds it into `deposit_for_burn_with_package_auth`. The
    // receipt's `caller`, and eventually the burn message's
    // `message_sender`, should be the witness's originating package
    // address (`@token_messenger_minter_v2` for `BurnHandlerWitness`),
    // *not* `ctx.sender()`.
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    // Deliberately switch to USER so ctx.sender() differs from the
    // witness package address. The package-auth path should ignore
    // ctx.sender() entirely.
    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let ticket = deposit_for_burn::create_deposit_for_burn_with_package_auth_ticket<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        0, 0, x"",
        BurnHandlerWitness {},
      );
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn_with_package_auth<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        ticket, &token_messenger_state, scenario.ctx(),
      );

      // Receipt reflects the witness's originating package, not USER.
      let expected_caller = auth_caller_identifier<BurnHandlerWitness>();
      assert!(expected_caller != USER);

      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );

      // Event's `depositor` reflects the package (same value goes into
      // the on-wire burn message's `message_sender`).
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(
        last_event_by_type<deposit_for_burn::DepositForBurn>() ==
          deposit_for_burn::create_deposit_for_burn_event(
            burn_token, AMOUNT, expected_caller, MINT_RECIPIENT,
            2, REMOTE_TOKEN_MESSENGER, @0x0, 0, 0, x""
          )
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  fun test_deposit_and_complete_burn_with_destination_caller() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, DESTINATION_CALLER,
        0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );

      // `destination_caller` propagates through: TMM records it in the
      // receipt, threads it into MT's `send_message`, and mirrors it
      // in the `DepositForBurn` event.
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(
        last_event_by_type<deposit_for_burn::DepositForBurn>() ==
          deposit_for_burn::create_deposit_for_burn_event(
            burn_token, AMOUNT, USER, MINT_RECIPIENT,
            2, REMOTE_TOKEN_MESSENGER, DESTINATION_CALLER, 0, 0, x""
          )
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  fun test_deposit_and_complete_burn_emits_v2_event_fields() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    let max_fee: u256 = 42;
    let min_finality_threshold: u32 = 500;
    let hook_data: vector<u8> = b"hookpayload";

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, DESTINATION_CALLER,
        max_fee, min_finality_threshold, hook_data,
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );

      // `max_fee`, `min_finality_threshold`, and `hook_data` propagate
      // through the burn message into the emitted `DepositForBurn` event.
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(
        last_event_by_type<deposit_for_burn::DepositForBurn>() ==
          deposit_for_burn::create_deposit_for_burn_event(
            burn_token, AMOUNT, USER, MINT_RECIPIENT,
            2, REMOTE_TOKEN_MESSENGER, DESTINATION_CALLER,
            max_fee, min_finality_threshold, hook_data
          )
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  fun test_deposit_at_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    // Reset burn limit to exactly AMOUNT
    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    token_messenger_state.remove_burn_limit(token_id);
    token_messenger_state.add_burn_limit(token_id, AMOUNT as u64);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // === Fee floor (deposit phase) ===

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EInsufficientMaxFee)]
  fun test_deposit_revert_max_fee_below_min_fee_amount() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    // min_fee_amount = (100 * 1_000_000) / 10_000_000 = 10
    scenario.next_tx(ADMIN);
    fee_controller::set_min_fee(
      &mut token_messenger_state,
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(),
      1_000_000,
      scenario.ctx()
    );

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        5, // max_fee below min_fee_amount(10) => EInsufficientMaxFee
        0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      // Unreachable cleanup for the type checker
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  fun test_deposit_fee_floor_exact_boundary_ok() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    scenario.next_tx(ADMIN);
    fee_controller::set_min_fee(
      &mut token_messenger_state,
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(),
      1_000_000, // yields min_fee_amount = 10 for AMOUNT=100
      scenario.ctx()
    );

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        10, // exactly equals min_fee_amount
        0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );

      // Verify the fee-floor-boundary max_fee propagated into the event.
      let burn_token = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
      assert!(
        last_event_by_type<deposit_for_burn::DepositForBurn>() ==
          deposit_for_burn::create_deposit_for_burn_event(
            burn_token, AMOUNT, USER, MINT_RECIPIENT,
            2, REMOTE_TOKEN_MESSENGER, @0x0,
            10, // max_fee at exact fee-floor boundary
            0, x""
          )
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // === Deposit-phase revert paths ===

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EPaused)]
  fun test_deposit_when_paused() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    token_messenger_state.set_paused(true);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// Denylisting the witness's defining package address must block the
  /// package-auth path even though `ctx.sender()` and the type-hash
  /// `auth_caller_identifier<W>()` are different (unlisted) addresses.
  #[test]
  #[expected_failure(abort_code = denylistable::EDenylistedAddress)]
  fun test_deposit_with_package_auth_when_witness_package_denylisted() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    // `BurnHandlerWitness` is defined in this test module, so its
    // defining package address is `@token_messenger_minter_v2` (== @0x0
    // in test builds).
    token_messenger_state.add_denylisted_address(
      message_transmitter_v2::auth::auth_caller_package_address<BurnHandlerWitness>(),
    );

    // USER signs the PTB but the package-address screen is what fires:
    // `ctx.sender()` is not denylisted, and the type-hash
    // `auth_caller_identifier<W>` isn't either — only the package
    // address is.
    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let ticket = deposit_for_burn::create_deposit_for_burn_with_package_auth_ticket<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        0, 0, x"",
        BurnHandlerWitness {},
      );
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn_with_package_auth<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        ticket, &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// Phase 1 aborts if the depositor is on the CCTP denylist.
  #[test]
  #[expected_failure(abort_code = denylistable::EDenylistedAddress)]
  fun test_deposit_when_caller_denylisted() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    // Add USER to the CCTP denylist directly. Bypasses the denylister
    // role check on the `denylist` entry function; the assertion in
    // `create_burn_receipt` only cares about `is_denylisted`.
    token_messenger_state.add_denylisted_address(USER);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// Phase 1 aborts if the transaction's gas sponsor is denylisted, even
  /// though the sender is not. Without the sponsor screen a denylisted
  /// party could fund CCTP activity through an unlisted sender.
  #[test]
  #[expected_failure(abort_code = denylistable::EDenylistedAddress)]
  fun test_deposit_when_sponsor_denylisted() {
    let mut scenario = test_scenario::begin_with_context(
      test_scenario::ctx_builder_from_sender(ADMIN).set_sponsor(SPONSOR)
    );
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    // Only the sponsor is denylisted; USER (the sender) is clean.
    token_messenger_state.add_denylisted_address(SPONSOR);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// A sponsored transaction whose sponsor is not denylisted proceeds
  /// normally — the screen must not reject sponsorship as such.
  #[test]
  fun test_deposit_succeeds_when_sponsor_not_denylisted() {
    let mut scenario = test_scenario::begin_with_context(
      test_scenario::ctx_builder_from_sender(ADMIN).set_sponsor(SPONSOR)
    );
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// The sponsor screen also covers the package-auth entry point, where
  /// the sender, the witness package and the witness type are all clean.
  #[test]
  #[expected_failure(abort_code = denylistable::EDenylistedAddress)]
  fun test_deposit_with_package_auth_when_sponsor_denylisted() {
    let mut scenario = test_scenario::begin_with_context(
      test_scenario::ctx_builder_from_sender(ADMIN).set_sponsor(SPONSOR)
    );
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    token_messenger_state.add_denylisted_address(SPONSOR);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let ticket = deposit_for_burn::create_deposit_for_burn_with_package_auth_ticket<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        0, 0, x"",
        BurnHandlerWitness {},
      );
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn_with_package_auth<
        DEPOSIT_FOR_BURN_TESTS,
        BurnHandlerWitness
      >(
        ticket, &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EZeroAmount)]
  fun test_deposit_zero_amount() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    scenario.next_tx(USER);
    {
      let user_coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      std::unit_test::destroy(user_coin);
      let zero_coin = sui::coin::zero<DEPOSIT_FOR_BURN_TESTS>(scenario.ctx());
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        zero_coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EZeroAddressMintRecipient)]
  fun test_deposit_zero_address_mint_recipient() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, @0x0, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EInvalidMaxFee)]
  fun test_deposit_max_fee_equals_amount() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0,
        AMOUNT, // == amount
        0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EInvalidDestinationDomain)]
  fun test_deposit_invalid_destination_domain() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, 999 /* unregistered */, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // (`test_deposit_missing_mint_cap` retired with the handler
  // decoupling; TMM stores no `MintCap<T>`.)

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EMissingBurnLimit)]
  fun test_deposit_missing_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    token_messenger_state.remove_burn_limit(token_id);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EBurnLimitExceeded)]
  fun test_deposit_exceed_burn_limit() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    token_messenger_state.remove_burn_limit(token_id);
    token_messenger_state.add_burn_limit(token_id, (AMOUNT as u64) - 1);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EBurnLimitExceeded)]
  /// Pins the "limit = 0 disables burns" semantic at the enforcement site.
  /// `token_controller::set_max_burn_amount_per_message` accepts 0, so that
  /// operators can disable burns for a token without unlinking remote
  /// pairs. This test locks in that a stored 0 causes every real
  /// (amount > 0) burn to abort with `EBurnLimitExceeded` from the
  /// `burn_limit >= amount` check in `safe_get_burn_limit`'s caller.
  fun test_deposit_zero_burn_limit_disables_burns() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    let token_id = calculate_token_id<DEPOSIT_FOR_BURN_TESTS>();
    token_messenger_state.remove_burn_limit(token_id);
    token_messenger_state.add_burn_limit(token_id, 0);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  fun test_deposit_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);

    token_messenger_state.add_compatible_version(5);
    token_messenger_state.remove_compatible_version(version_control::current_version());

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      deposit_for_burn::destroy_burn_receipt_for_testing(receipt);
      std::unit_test::destroy(coin_back);
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // === complete_burn revert paths ===

  #[test]
  #[expected_failure(abort_code = handler_registry::ENotRegisteredHandler)]
  fun test_complete_burn_revert_wrong_handler() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    // Store a handler identifier that no obtainable witness type resolves to, so
    // BurnHandlerWitness fails the type-scoped check on complete.
    token_messenger_state.set_handler(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(),
      @0xDEADBEEF,
    );

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  #[test]
  #[expected_failure(abort_code = handler_registry::ENoHandlerRegistered)]
  fun test_complete_burn_revert_no_handler_registered() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    // No handler registered for the token.

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // (`test_complete_burn_revert_amount_mismatch` retired with the
  // handler decoupling; `complete_burn` no longer accepts a `Coin<T>`,
  // so coin-shape checks are the handler's responsibility.)

  /// Simulates the phase-1@vN + phase-2@vN+1 attack window: the state
  /// is currently compatible with both versions (mid-migration), but
  /// the receipt was stamped by an older TMM package version. The
  /// receipt's `current_version` guard must fire even though
  /// `state.compatible_versions` still admits both.
  #[test]
  #[expected_failure(abort_code = deposit_for_burn::EInvalidReceiptVersion)]
  fun test_complete_burn_revert_stale_receipt_version() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    // Simulate a live migration window: both v_current and a next
    // version are in `compatible_versions`, so the
    // `assert_object_version_is_compatible_with_package` gate on
    // `complete_burn` still passes.
    let next_version = version_control::current_version() + 1;
    token_messenger_state.add_compatible_version(next_version);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (mut receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );
      // Simulate the receipt having been stamped by a different
      // (still-compatible) TMM package version than the one now
      // running. We rewrite to `next_version` so the receipt's stamp
      // is one of the versions in `state.compatible_versions` but is
      // NOT equal to `version_control::current_version()` — exactly
      // the phase-1@vN + phase-2@vN+1 mismatch.
      receipt.set_current_version_for_testing(next_version);

      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  /// Package upgraded between `deposit_for_burn` and `complete_burn`:
  /// the running version is dropped from `compatible_versions`, so the
  /// pre-existing `assert_object_version_is_compatible_with_package`
  /// gate on `complete_burn` aborts. This exercises the package-version
  /// gate at phase-2, distinct from the receipt-stamp guard covered by
  /// `test_complete_burn_revert_stale_receipt_version` above. Mirrors
  /// `handle_receive_message::test_complete_mint_revert_incompatible_version`.
  #[test]
  #[expected_failure(abort_code = version_control::EIncompatibleVersion)]
  fun test_complete_burn_revert_incompatible_version() {
    let mut scenario = test_scenario::begin(ADMIN);
    let (mint_cap, mut treasury, deny_list) = setup_coin(&mut scenario);
    let (mut token_messenger_state, message_transmitter_state) = setup_cctp_states(&mut scenario);
    register_test_handler(&mut token_messenger_state, &mut scenario);

    scenario.next_tx(USER);
    {
      let coin = scenario.take_from_sender<Coin<DEPOSIT_FOR_BURN_TESTS>>();
      let (receipt, coin_back) = deposit_for_burn::deposit_for_burn(
        coin, DESTINATION_DOMAIN, MINT_RECIPIENT, @0x0, 0, 0, x"",
        &token_messenger_state, scenario.ctx(),
      );

      // Simulate a mid-flow package upgrade: swap the version that
      // `deposit_for_burn` ran under out of `compatible_versions`, so
      // the package-version gate on `complete_burn` no longer admits
      // the running version and aborts.
      token_messenger_state.add_compatible_version(5);
      token_messenger_state.remove_compatible_version(version_control::current_version());

      burn_and_complete_test(
        receipt, coin_back, &mint_cap,
        &token_messenger_state, &message_transmitter_state,
        &deny_list, &mut treasury, scenario.ctx(),
      );
    };

    unit_test::destroy(deny_list);
    unit_test::destroy(treasury);
    unit_test::destroy(token_messenger_state);
    unit_test::destroy(message_transmitter_state);
    unit_test::destroy(mint_cap);
    scenario.end();
  }

  // === Test helpers ===

  fun setup_coin(scenario: &mut Scenario): (
    MintCap<DEPOSIT_FOR_BURN_TESTS>,
    Treasury<DEPOSIT_FOR_BURN_TESTS>,
    DenyList
  ) {
    let otw = test_utils::create_one_time_witness<DEPOSIT_FOR_BURN_TESTS>();

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
    let mint_cap = scenario.take_from_address<MintCap<DEPOSIT_FOR_BURN_TESTS>>(ADMIN);
    let deny_list = deny_list::new_for_testing(scenario.ctx());
    treasury.configure_minter(&deny_list, 999999999, scenario.ctx());
    unit_test::destroy(metadata_cap);

    treasury::mint(
      &mut treasury, &mint_cap, &deny_list, AMOUNT as u64, USER, scenario.ctx()
    );

    (mint_cap, treasury, deny_list)
  }

  /// Builds shared TMM + MT state for tests. TMM no longer stores
  /// `MintCap<T>`, so tests keep their own in scope.
  fun setup_cctp_states(
    scenario: &mut Scenario
  ): (token_messenger_state::State, message_transmitter_state::State) {
    let ctx = test_scenario::ctx(scenario);

    let mut token_messenger_state = token_messenger_state::new(1, ADMIN, ctx);
    let message_transmitter_state = message_transmitter_state::new_for_testing(
      0, 1, 1000, ADMIN, ctx
    );

    token_messenger_state.add_remote_token_messenger(
      DESTINATION_DOMAIN, REMOTE_TOKEN_MESSENGER
    );
    token_messenger_state.add_burn_limit(
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(), 1000000
    );

    (token_messenger_state, message_transmitter_state)
  }

  /// Registers the `BurnHandlerWitness` type as the test token's handler
  /// (via `register_handler<BurnHandlerWitness>`); the stored value is that
  /// type's identifier hash.
  fun register_test_handler(state: &mut token_messenger_state::State, scenario: &mut Scenario) {
    scenario.next_tx(ADMIN);
    handler_registry::register_handler<BurnHandlerWitness>(
      state,
      calculate_token_id<DEPOSIT_FOR_BURN_TESTS>(),
      scenario.ctx()
    );
  }

  /// Simulates `stablecoin_handler::burn`: assert coin matches receipt,
  /// burn via `treasury::burn`, build the complete-burn ticket, and feed
  /// it into TMM's `complete_burn`.
  fun burn_and_complete_test(
    receipt: BurnReceipt<DEPOSIT_FOR_BURN_TESTS>,
    coin: Coin<DEPOSIT_FOR_BURN_TESTS>,
    mint_cap: &MintCap<DEPOSIT_FOR_BURN_TESTS>,
    token_messenger_state: &token_messenger_state::State,
    message_transmitter_state: &message_transmitter_state::State,
    deny_list: &DenyList,
    treasury: &mut Treasury<DEPOSIT_FOR_BURN_TESTS>,
    ctx: &TxContext,
  ) {
    let (_, amount, _) = deposit_for_burn::get_burn_details(&receipt);
    assert!(coin.value() == amount);
    treasury::burn(treasury, mint_cap, deny_list, coin, ctx);
    let ticket = deposit_for_burn::create_complete_burn_ticket<
      DEPOSIT_FOR_BURN_TESTS, BurnHandlerWitness
    >(receipt, BurnHandlerWitness {});
    deposit_for_burn::complete_burn<DEPOSIT_FOR_BURN_TESTS, BurnHandlerWitness>(
      ticket, token_messenger_state, message_transmitter_state,
    );
  }
}
