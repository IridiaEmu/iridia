// SPDX-License-Identifier: GPL-2.0-or-later

import StoreKit
import StoreKitTest
import XCTest
@testable import IridiaStore

final class FreePlayTimerTests: XCTestCase {
  func testCountsOnlyPlayingTime() {
    var t = FreePlayTimer(limit: 10, warningAt: 3)
    XCTAssertNil(t.tick(elapsed: 4, isPlaying: false))
    XCTAssertEqual(t.played, 0)
    XCTAssertNil(t.tick(elapsed: 4, isPlaying: true))
    XCTAssertEqual(t.played, 4)
  }

  func testWarnsOnceThenExpires() {
    var t = FreePlayTimer(limit: 10, warningAt: 3)
    XCTAssertNil(t.tick(elapsed: 5, isPlaying: true))
    XCTAssertEqual(t.tick(elapsed: 3, isPlaying: true), .warning(secondsLeft: 2))
    XCTAssertNil(t.tick(elapsed: 1, isPlaying: true))
    XCTAssertEqual(t.tick(elapsed: 1, isPlaying: true), .expired)
    XCTAssertTrue(t.isExpired)
    XCTAssertNil(t.tick(elapsed: 1, isPlaying: true), "nothing after expiry")
  }

  func testLongGapCountsAsAtMostFiveSeconds() {
    var t = FreePlayTimer()
    _ = t.tick(elapsed: 3600, isPlaying: true)   // e.g. the app was suspended mid-tick
    XCTAssertEqual(t.played, 5)
  }

  func testDefaultIsTenMinutesWithOneMinuteWarning() {
    var t = FreePlayTimer()
    var events: [FreePlayTimer.Event] = []
    for _ in 0..<600 { if let e = t.tick(elapsed: 1, isPlaying: true) { events.append(e) } }
    XCTAssertEqual(events, [.warning(secondsLeft: 60), .expired])
  }
}

@MainActor
final class UnlockStoreTests: XCTestCase {
  /// StoreKitTest delivers refunds and off-device purchases asynchronously: re-read until `expected`.
  private func settle(_ store: UnlockStore, to expected: Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      await store.refreshEntitlement()
      if store.isUnlocked == expected { return }
      try? await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
  }

  private var session: SKTestSession!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Iridia", withExtension: "storekit"))
    session = try SKTestSession(contentsOf: url)
    session.resetToDefaultState()
    session.clearTransactions()
    session.disableDialogs = true
    defaults = UserDefaults(suiteName: "IridiaStoreTests-\(UUID().uuidString)")
  }

  func testProductLoadsWithPrice() async {
    let store = UnlockStore(defaults: defaults)
    await store.loadProduct()
    XCTAssertEqual(store.product?.id, UnlockStore.productID)
    XCTAssertEqual(store.product?.displayName, "Unlock Full Version")
    XCTAssertEqual(store.product?.type, .nonConsumable)
  }

  func testStartsLocked() async {
    let store = UnlockStore(defaults: defaults)
    await store.refreshEntitlement()
    XCTAssertFalse(store.isUnlocked)
  }

  func testPurchaseUnlocksAndPersists() async {
    let store = UnlockStore(defaults: defaults)
    await store.loadProduct()
    let outcome = await store.purchase()
    XCTAssertEqual(outcome, .unlocked)
    XCTAssertTrue(store.isUnlocked)
    // A fresh store (next launch) is unlocked from StoreKit, not just the cache.
    let next = UnlockStore(defaults: UserDefaults(suiteName: "IridiaStoreTests-fresh-\(UUID().uuidString)")!)
    await next.refreshEntitlement()
    XCTAssertTrue(next.isUnlocked)
  }

  func testRestoreFindsAnEarlierPurchase() async throws {
    try await session.buyProduct(identifier: UnlockStore.productID)
    let store = UnlockStore(defaults: defaults)
    XCTAssertFalse(store.isUnlocked)
    // No AppStore.sync(): it always asks for an Apple ID sign-in, even under StoreKitTest.
    var restored = await store.restore(syncWithAppStore: false)
    if !restored { await settle(store, to: true); restored = store.isUnlocked }
    XCTAssertTrue(restored)
  }

  func testRefundRelocks() async throws {
    let store = UnlockStore(defaults: defaults)
    await store.loadProduct()
    _ = await store.purchase()
    XCTAssertTrue(store.isUnlocked)
    let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == UnlockStore.productID })
    try session.refundTransaction(identifier: transaction.identifier)
    await settle(store, to: false)
    XCTAssertFalse(store.isUnlocked, "a refunded purchase must lock again")
  }

  func testCancelledPurchaseStaysLocked() async {
    session.failTransactionsEnabled = true
    session.failureError = .unknown
    let store = UnlockStore(defaults: defaults)
    await store.loadProduct()
    let outcome = await store.purchase()
    XCTAssertNotEqual(outcome, .unlocked)
    XCTAssertFalse(store.isUnlocked)
  }
}
