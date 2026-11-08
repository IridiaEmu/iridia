// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Settings > Full Version. Always there, with or without games: Unlock Full Version and Restore
// Purchases before the purchase, a confirmation after it.

#if os(iOS)
import IridiaStore
import SwiftUI

struct FullVersionView: View {
  @ObservedObject private var store = IridiaUnlock.store
  @State private var showUnlock = false
  @State private var restoreMessage: String?

  var body: some View {
    List {
      Section {
        if IridiaUnlock.isUnlocked {
          Label(L("Full version unlocked"), systemImage: "checkmark.seal.fill")
        } else {
          Button { showUnlock = true } label: { Label(L("Unlock Full Version"), systemImage: "lock.open") }
          Button {
            Task {
              restoreMessage = nil
              restoreMessage = await store.restore() ? L("Purchase restored.") : L("No earlier purchase found for this Apple Account.")
            }
          } label: { Label(L("Restore Purchases"), systemImage: "arrow.clockwise") }
          .disabled(store.isBusy)
        }
      } footer: {
        Text(restoreMessage ?? (IridiaUnlock.isUnlocked
          ? L("Unlimited play in every GameCube and Wii U game. Thank you for your support.")
          : L("One purchase unlocks GameCube and Wii U games. Without it, each game plays in free play sessions: 10 minutes for GameCube, 20 for Wii U.")))
      }
    }
    .navigationTitle(L("Full Version"))
    .fullScreenCover(isPresented: $showUnlock) {
      UnlockView(context: .browsing, onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
    }
  }
}
#endif
