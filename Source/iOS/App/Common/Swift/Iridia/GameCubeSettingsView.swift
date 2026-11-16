// SPDX-License-Identifier: GPL-2.0-or-later
//
// The GameCube tab's Settings: the same sheet and sections as Wii and Wii U Settings. Everything else Dolphin
// offers is one row away, under All Settings.

#if os(iOS)
import IridiaStore
import SwiftUI

extension Notification.Name {
  /// Opens the full settings list (from the GameCube and Wii Settings sheets).
  static let iridiaOpenAllSettings = Notification.Name("IridiaOpenAllSettings")
}

struct GameCubeSettingsView: View {
  let onUnlock: () -> Void
  let onControllers: () -> Void

  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var store = IridiaUnlock.store
  @State private var restoreMessage: String?
  @State private var invertX = UserDefaults.standard.bool(forKey: ControlOptions.invertCameraXKey)
  @State private var invertY = UserDefaults.standard.bool(forKey: ControlOptions.invertCameraYKey)
  @State private var downloadsOn = DownloadsFolder.isOn

  var body: some View {
    List {
      Section {
        if IridiaUnlock.isUnlocked {
          Label(L("Full version unlocked"), systemImage: "checkmark.seal.fill")
        } else {
          Button(action: onUnlock) { Label(L("Unlock Full Version"), systemImage: "lock.open") }
          Button {
            Task {
              restoreMessage = nil
              restoreMessage = await store.restore() ? L("Purchase restored.") : L("No earlier purchase found for this Apple Account.")
            }
          } label: { Label(L("Restore Purchases"), systemImage: "arrow.clockwise") }
          .disabled(store.isBusy)
        }
      } header: { Text(L("Full Version")) } footer: {
        Text(restoreMessage ?? L("One purchase unlocks GameCube, Wii and Wii U games. Without it, each GameCube game plays in free play sessions of 10 minutes."))
      }

      Section {
        PowerModeRow()
      } header: { Text(L("Speed")) } footer: {
        Text(L("Power Mode sets the picture quality for this device. Battery Saver runs cooler, and Max Performance looks sharper."))
      }

      Section {
        Toggle(L("Invert camera up/down"), isOn: $invertY)
        Toggle(L("Invert camera left/right"), isOn: $invertX)
        Button(action: onControllers) { Label(L("Game Controllers"), systemImage: "gamecontroller") }
      } header: { Text(L("Controls")) } footer: {
        Text(L("The camera stick is the C-stick. Inverting it affects every game and every controller, touch included."))
      }

      Section {
        if downloadsOn {
          LabeledContent(L("Checking"), value: DownloadsFolder.name)
          Button(L("Stop Checking")) { DownloadsFolder.stop(); downloadsOn = false }
        } else {
          Button(L("Check Downloads for Games")) {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { GameCubeDownloads.chooseFolder() }
          }
        }
      } header: { Text(L("Downloads")) } footer: {
        Text(L("Each time you open Iridia, it looks in the folder you chose for games and asks before moving any."))
      }

      Section {
        LabeledContent(L("GameCube games"), value: L("RVZ, ISO, GCM, CISO, GCZ"))
        LabeledContent(L("Homebrew"), value: L(".dol, .elf"))
      } header: { Text(L("Game Files")) } footer: {
        Text(L("ZIP and 7Z files are unpacked when you add them."))
      }

      Section {
        Button {
          dismiss()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NotificationCenter.default.post(name: .iridiaOpenAllSettings, object: nil) }
        } label: { Label(L("All Settings"), systemImage: "slider.horizontal.3") }
      } footer: {
        Text(L("Graphics, sound, controller details and everything else. These apply to Wii games too."))
      }

      Section(L("About")) {
        LabeledContent(L("CPU"), value: L("Interpreter"))
      }
    }
    .navigationTitle(L("GameCube Settings"))
    .menuClose { dismiss() }
    .onChange(of: invertX) { _, v in UserDefaults.standard.set(v, forKey: ControlOptions.invertCameraXKey); ControlOptions.apply() }
    .onChange(of: invertY) { _, v in UserDefaults.standard.set(v, forKey: ControlOptions.invertCameraYKey); ControlOptions.apply() }
    .iridiaScreen()
  }
}
#endif
