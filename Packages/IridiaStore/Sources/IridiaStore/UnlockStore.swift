// SPDX-License-Identifier: GPL-2.0-or-later
//
// "Unlock Full Version": one non-consumable In-App Purchase (StoreKit 2).
// - Only transactions StoreKit verifies (JWS signed by Apple for this app and device) unlock.
// - Refunds and revoked purchases re-lock (revocationDate), live via Transaction.updates.
// - Restore Purchases = AppStore.sync() + re-reading current entitlements (Guideline 3.1.1).
// - The last known state is cached so a paying player isn't shown the limit while offline before
//   StoreKit answers; StoreKit's answer always wins.

import Foundation
import StoreKit

@MainActor
public final class UnlockStore: ObservableObject {
  /// The product identifier configured in App Store Connect (and Iridia.storekit for testing).
  public static let productID = "iridia.unlock.full"

  @Published public private(set) var isUnlocked: Bool
  @Published public private(set) var product: Product?
  /// True while a purchase or restore is running (disable the buttons).
  @Published public private(set) var isBusy = false

  public enum PurchaseOutcome: Equatable, Sendable {
    case unlocked
    case cancelled
    /// Waiting on Ask to Buy or a payment step; it unlocks through Transaction.updates later.
    case pending
    case failed(String)
  }

  private let defaults: UserDefaults
  private static let cacheKey = "iridia_full_version_unlocked"
  private var updatesTask: Task<Void, Never>?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isUnlocked = defaults.bool(forKey: Self.cacheKey)
  }

  deinit { updatesTask?.cancel() }

  /// Call once at launch: listens for purchases made elsewhere, Ask to Buy approvals, refunds and
  /// revocations, then loads the product and the current entitlement.
  public func start() {
    guard updatesTask == nil else { return }
    updatesTask = Task { [weak self] in
      for await result in Transaction.updates {
        await self?.handle(result)
      }
    }
    Task {
      await loadProduct()
      await refreshEntitlement()
    }
  }

  public func loadProduct() async {
    do {
      product = try await Product.products(for: [Self.productID]).first
    } catch {
      product = nil
    }
  }

  /// Re-read what the player owns from StoreKit (works offline from StoreKit's own cache).
  public func refreshEntitlement() async {
    var owned = false
    for await result in Transaction.currentEntitlements {
      if case .verified(let transaction) = result, transaction.productID == Self.productID,
         transaction.revocationDate == nil {
        owned = true
      }
    }
    setUnlocked(owned)
  }

  public func purchase() async -> PurchaseOutcome {
    if product == nil { await loadProduct() }
    guard let product else { return .failed("The App Store isn't available right now. Try again later.") }
    isBusy = true
    defer { isBusy = false }
    do {
      switch try await product.purchase() {
      case .success(let verification):
        guard case .verified(let transaction) = verification else {
          return .failed("The purchase couldn't be verified.")
        }
        await transaction.finish()
        setUnlocked(transaction.revocationDate == nil)
        return isUnlocked ? .unlocked : .failed("This purchase was refunded.")
      case .userCancelled:
        return .cancelled
      case .pending:
        return .pending
      @unknown default:
        return .failed("Something went wrong. Try again.")
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Restore Purchases. Returns whether the full version is unlocked afterwards.
  /// `syncWithAppStore` asks the App Store to re-send purchases, which always shows Apple's Apple ID
  /// sign-in; the app's Restore button uses it (the player asked), tests pass false so nothing prompts.
  @discardableResult
  public func restore(syncWithAppStore: Bool = true) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    if syncWithAppStore { try? await AppStore.sync() }
    await refreshEntitlement()
    return isUnlocked
  }

  private func handle(_ result: VerificationResult<Transaction>) async {
    guard case .verified(let transaction) = result, transaction.productID == Self.productID else { return }
    setUnlocked(transaction.revocationDate == nil)
    await transaction.finish()
  }

  private func setUnlocked(_ value: Bool) {
    isUnlocked = value
    defaults.set(value, forKey: Self.cacheKey)
  }
}
