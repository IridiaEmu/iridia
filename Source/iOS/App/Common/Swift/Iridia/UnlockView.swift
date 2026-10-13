// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Unlock Full Version" screen. Shown when a free play session ends, and from the shelf /
// Settings. States exactly what the purchase gives and that it's one-time (Guideline 3.1.1/3.1.2(c)
// style disclosure), has Restore Purchases, and always offers "Not now".

#if os(iOS)
import IridiaStore
import SwiftUI

struct UnlockView: View {
  enum Context { case sessionEnded, browsing }

  let context: Context
  /// Called after a successful purchase or restore.
  let onUnlocked: () -> Void
  /// "Not now" / close.
  let onDismiss: () -> Void

  @ObservedObject private var store = IridiaUnlock.store
  @State private var message: String?

  private var priceText: String { store.product?.displayPrice ?? "$2.99" }

  var body: some View {
    ZStack {
      IridiaGlass.stage
      ScrollView {
        VStack(spacing: 18) {
          IridiaCubeView()
            .frame(width: 130, height: 130)
            .padding(.top, 30)
            .accessibilityHidden(true)

          VStack(spacing: 8) {
            Text(context == .sessionEnded ? L("Free play session over") : L("Unlock Full Version"))
              .font(.system(size: 28, weight: .bold))
              .foregroundStyle(.white)
              .multilineTextAlignment(.center)
            Text(context == .sessionEnded
                 ? L("Your progress is saved. Unlock the full version to keep playing, or start another free 10-minute session any time.")
                 : L("Free play sessions are 10 minutes each, as many as you like. Unlock once to remove the limit."))
              .font(.system(size: 15))
              .foregroundStyle(IridiaGlass.soft)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 24)

          VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", L("Unlimited play time in every game"))
            benefit("gauge.with.dots.needle.67percent", L("Hide the FPS and speed readout"))
            benefit("sparkles", L("Every feature, and all future updates"))
            benefit("checkmark.seal", L("One-time purchase. No subscription, no ads."))
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
          .glassSurface(radius: 24)
          .padding(.horizontal, 20)

          VStack(spacing: 12) {
            Button {
              Task {
                message = nil
                switch await store.purchase() {
                case .unlocked: onUnlocked()
                case .cancelled: break
                case .pending: message = L("Waiting for approval. The full version unlocks as soon as it's approved.")
                case .failed(let why): message = why
                }
              }
            } label: {
              HStack(spacing: 8) {
                if store.isBusy { ProgressView().tint(Color(red: 0.07, green: 0.04, blue: 0.20)) }
                Text(String(format: L("Unlock for %@"), priceText))
              }
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
              .frame(maxWidth: .infinity, minHeight: 58)
              .glassSurface(radius: 29, prominent: true)
            }
            .buttonStyle(SpringPressStyle())
            .disabled(store.isBusy)

            HStack(spacing: 12) {
              Button {
                Task {
                  message = nil
                  if await store.restore() { onUnlocked() } else { message = L("No earlier purchase found for this Apple Account.") }
                }
              } label: {
                Text(L("Restore Purchases")).frame(maxWidth: .infinity, minHeight: 50).glassSurface(radius: 25)
              }
              Button(action: onDismiss) {
                Text(L("Not now")).frame(maxWidth: .infinity, minHeight: 50).glassSurface(radius: 25)
              }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .buttonStyle(SpringPressStyle())
            .disabled(store.isBusy)

            if let message {
              Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 1.0, green: 0.8, blue: 0.85))
                .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, 20)

          Text(L("Payment is charged to your Apple Account. The purchase is linked to your Apple Account and can be restored on your other devices."))
            .font(.system(size: 12))
            .foregroundStyle(IridiaGlass.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
      }
    }
    .environment(\.colorScheme, .dark)
    .task { if store.product == nil { await store.loadProduct() } }
  }

  private func benefit(_ symbol: String, _ text: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color(red: 0.79, green: 0.75, blue: 1.0))
        .frame(width: 26)
      Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
    }
  }
}
#endif
