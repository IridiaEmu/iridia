// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii section's Settings, Help and Unlock Full Version screens. Unlock uses the app's one
// UnlockStore (IridiaUnlock.store), so a purchase or restore made here unlocks GameCube and Wii U too, and the reverse.

#if os(iOS)
import IridiaStore
import SwiftUI
import UIKit

enum WiiPaths {
  /// "On My iPhone > Iridia > Wii" (iPad on iPad), as the Files app names it.
  static var filesPath: String {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return "\(device) > \(FilesAppNames.appFolder) > \(UserFolderUtil.wiiFolderName)"
  }
}

/// The motion settings the Wii section offers, as plain switches. Both are off until the player turns
/// them on, so a Wii game only runs the motion sensors when something needs them.
enum WiiMotion {
  /// Shake the phone to shake the Wii Remote.
  static var shakeThePhone: Bool {
    get { MotionSettings.enhancedShakeDetection() }
    set {
      MotionSettings.setEnhancedShakeDetection(newValue)
      NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
    }
  }

  /// Tilting the phone tilts the Wii Remote.
  static var tiltThePhone: Bool {
    get { MotionSettings.wiimoteIMU() }
    set {
      UserDefaults.standard.set(newValue, forKey: MotionSettings.Key.wiimoteIMU)
      NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
    }
  }
}

struct WiiSettingsView: View {
  let onUnlock: () -> Void
  let onControllers: () -> Void

  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var store = IridiaUnlock.store
  @State private var restoreMessage: String?
  @State private var newGames = WiiControls.defaultForNewGames
  @State private var pointer = PointerModeController.shared.mode
  @State private var pointerSpeed = WiiPointer.speed(for: PointerModeController.shared.mode)
  @State private var showPointer = WiiPointer.showPointer
  @State private var shake = WiiMotion.shakeThePhone
  @State private var tilt = WiiMotion.tiltThePhone
  @State private var widescreen = DOLConfigBridge.sysconfWidescreen()
  private let hasKeyFile = FileManager.default.fileExists(atPath: TVGameItem.wiiKeyFilePath())

  var body: some View {
    List {
      Section {
        if IridiaUnlock.isUnlocked {
          Label(L("Full version unlocked"), systemImage: "checkmark.seal.fill")
            .foregroundStyle(WiiTheme.ink)
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
        Text(restoreMessage ?? L("One purchase unlocks GameCube, Wii and Wii U games. Without it, each Wii game plays in free play sessions of 10 minutes, the same as GameCube."))
      }

      Section {
        PowerModeRow()
      } header: { Text(L("Speed")) } footer: {
        Text(L("Power Mode sets the picture quality for this device. Battery Saver runs cooler, and Max Performance looks sharper. It applies to GameCube games too."))
      }

      Section {
        Picker(L("Controls for new games"), selection: $newGames) {
          ForEach(WiiControls.options, id: \.self) { Text($0.title).tag($0) }
        }
        Picker(L("Aim the pointer"), selection: $pointer) {
          Text(L("Follow your finger")).tag(PointerMode.touchFollow)
          Text(L("Drag on the screen")).tag(PointerMode.touchDrag)
          Text(PointerMode.gyro.title).tag(PointerMode.gyro)
        }
        if pointer != .touchFollow {
          VStack(alignment: .leading, spacing: 4) {
            Text(L("Pointer speed"))
            Slider(value: $pointerSpeed, in: WiiPointer.speedRange) {
              Text(L("Pointer speed"))
            } minimumValueLabel: {
              Image(systemName: "tortoise").accessibilityLabel(L("Slower"))
            } maximumValueLabel: {
              Image(systemName: "hare").accessibilityLabel(L("Faster"))
            } onEditingChanged: { editing in
              if !editing { WiiPointer.setSpeed(pointerSpeed, for: pointer) }
            }
          }
        }
        Toggle(L("Show the pointer"), isOn: $showPointer)
        Toggle(onPad ? L("Shake the iPad to shake") : L("Shake the phone to shake"), isOn: $shake)
        Toggle(onPad ? L("Tilt the iPad to tilt") : L("Tilt the phone to tilt"), isOn: $tilt)
        Button(action: onControllers) { Label(L("Game Controllers"), systemImage: "gamecontroller") }
      } header: { Text(L("Controls")) } footer: {
        Text(onPad ? L("Each game remembers its controls. Switch them in the game with the controls button at the top, or in the pause menu. With Point the iPad, the Recenter button puts the pointer back in the middle. Show the pointer draws a dot where you're pointing, for games that don't show their own. Real Wii Remotes can't connect: iOS doesn't let apps use them.") : L("Each game remembers its controls. Switch them in the game with the controls button at the top, or in the pause menu. With Point the phone, the Recenter button puts the pointer back in the middle. Show the pointer draws a dot where you're pointing, for games that don't show their own. Real Wii Remotes can't connect: iOS doesn't let apps use them."))
      }

      Section {
        Toggle(L("Widescreen (16:9)"), isOn: $widescreen)
      } header: { Text(L("Wii")) } footer: {
        Text(L("Games that support it draw a wider picture. Applies the next time you start a game."))
      }

      Section {
        LabeledContent(L("Wii games"), value: L("RVZ, WIA, ISO, WBFS, GCZ, CISO"))
        LabeledContent(L("Wii homebrew"), value: L(".dol, .elf"))
        LabeledContent(L("Key file"), value: hasKeyFile ? L("Added") : L("Not added"))
      } header: { Text(L("Game Files")) } footer: {
        Text(L("ISO, WBFS, GCZ and CISO files need the key file from your own Wii. Iridia asks for it the first time you play one. WAD files aren't supported."))
      }

      Section {
        Button {
          dismiss()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NotificationCenter.default.post(name: .iridiaOpenAllSettings, object: nil) }
        } label: { Label(L("All Settings"), systemImage: "slider.horizontal.3") }
      } footer: {
        Text(L("Graphics, sound, controller details and everything else. These apply to GameCube games too."))
      }

      Section(L("About")) {
        LabeledContent(L("CPU"), value: L("Interpreter"))
        Text(L("Online features are not available. Games start without the Wii Menu; a game that tries to open it stops and keeps what it saved."))
          .font(.footnote).foregroundStyle(WiiTheme.dim)
      }
    }
    .foregroundStyle(WiiTheme.ink)
    .navigationTitle(L("Wii Settings"))
    .menuClose { dismiss() }
    .onChange(of: newGames) { _, v in WiiControls.defaultForNewGames = v }
    .onChange(of: pointer) { _, v in
      PointerModeController.shared.set(v)
      pointerSpeed = WiiPointer.speed(for: v)
    }
    .onChange(of: showPointer) { _, v in WiiPointer.showPointer = v }
    .onChange(of: shake) { _, v in WiiMotion.shakeThePhone = v }
    .onChange(of: tilt) { _, v in WiiMotion.tiltThePhone = v }
    .onChange(of: widescreen) { _, v in DOLConfigBridge.setSysconfWidescreen(v) }
    .wiiScreen()
  }
}

struct WiiHelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section(L("Adding a game")) {
        Text(String(format: L("1. Open the Files app and go to %@."), WiiPaths.filesPath))
        Text(L("2. Copy your own Wii game there (RVZ, WIA, ISO, WBFS, GCZ or CISO)."))
        Text(L("3. Come back to Iridia. The game shows up on the Wii shelf. Wii homebrew (.dol, .elf) works too."))
        Text(L("Wii games added to the GameCube folder or with Choose a Game File show up here as well."))
        Text(L("ISO, WBFS, GCZ and CISO files need the key file from your own Wii. Iridia asks for it the first time you play one. WAD files aren't supported."))
      }
      Section(L("Controls")) {
        Text(L("Touch controls show a Wii Remote, a Wii Remote with a Nunchuk, a sideways Wii Remote, a Classic Controller or a GameCube controller. Switch with the controls button at the top of the game screen or in the pause menu. Each game remembers its choice."))
        Text(onPad ? L("Aim the pointer by dragging on the game picture, or turn on Point the iPad in Wii Settings and use Recenter to put it back in the middle.") : L("Aim the pointer by dragging on the game picture, or turn on Point the phone in Wii Settings and use Recenter to put it back in the middle."))
        Text(onPad ? L("Tap Shake to shake the Wii Remote. Wii Settings can also let you shake or tilt the iPad itself.") : L("Tap Shake to shake the Wii Remote. Wii Settings can also let you shake or tilt the phone itself."))
        Text(L("Game controllers work as a Wii Remote with a Nunchuk: the left stick is the Nunchuk stick, the right stick aims (or the controller's motion, if it has it), and the right shoulder shakes. As a Classic Controller the buttons match by position."))
        Text(L("Real Wii Remotes can't connect to an iPhone or iPad: iOS doesn't let apps use them."))
      }
      Section(L("Saves")) {
        Text(L("Games save to Iridia's own Wii storage, which is part of your device backup. Save states and resume points work like GameCube."))
      }
      Section(L("Free play")) {
        Text(L("Without the full version, each Wii game plays for 10 minutes at a time, like GameCube. You can start as many sessions as you like. Time in the pause menu doesn't count."))
      }
      Section(L("About Wii support")) {
        Text(L("Games start without the Wii Menu. A game that tries to go to the Wii Menu or open a channel stops there, and keeps what it saved."))
        Text(L("Online features are not available."))
        Text(L("Wii games ask more of the device than GameCube games. Speed depends on the game and on the device."))
      }
    }
    .foregroundStyle(WiiTheme.ink)
    .navigationTitle(L("Help"))
    .menuClose { dismiss() }
    .wiiScreen()
  }
}

/// "Unlock Full Version" in the Wii section's look, from its header and Settings. Same product, purchase
/// and restore as the GameCube screen.
struct WiiUnlockView: View {
  /// Called after a successful purchase or restore.
  let onUnlocked: () -> Void
  /// "Not now".
  let onDismiss: () -> Void

  @ObservedObject private var store = IridiaUnlock.store
  @State private var message: String?

  private var buyText: String {
    guard let price = store.product?.displayPrice else { return L("Unlock Full Version") }
    return String(format: L("Unlock for %@"), price)
  }

  var body: some View {
    ZStack {
      WiiTheme.stage
      ScrollView {
        VStack(spacing: 18) {
          WiiMark(size: 96)
            .padding(.top, 36)
            .accessibilityHidden(true)

          VStack(spacing: 8) {
            Text(L("Unlock Full Version"))
              .font(.system(size: 28, weight: .bold))
              .foregroundStyle(WiiTheme.ink)
              .multilineTextAlignment(.center)
            Text(L("Wii free play sessions last 10 minutes, and you can start as many as you like. One purchase removes the limit for GameCube, Wii and Wii U games."))
              .font(.system(size: 15))
              .foregroundStyle(WiiTheme.soft)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 24)

          VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", L("Unlimited play time in GameCube, Wii and Wii U games"))
            benefit("gauge.with.dots.needle.67percent", L("Hide the FPS and speed readout"))
            benefit("sparkles", L("Every feature, plus future updates"))
            benefit("checkmark.seal", L("One-time purchase. No subscription, no ads."))
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
          .wiiSurface(radius: 24)
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
                if store.isBusy { ProgressView().tint(WiiTheme.onAccent) }
                Text(buyText)
              }
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(WiiTheme.onAccent)
              .frame(maxWidth: .infinity, minHeight: 58)
              .wiiSurface(radius: 29, prominent: true)
            }
            .buttonStyle(WiiPress())
            .disabled(store.isBusy)

            HStack(spacing: 12) {
              Button {
                Task {
                  message = nil
                  if await store.restore() { onUnlocked() } else { message = L("No earlier purchase found for this Apple Account.") }
                }
              } label: {
                Text(L("Restore Purchases")).frame(maxWidth: .infinity, minHeight: 50).wiiSurface(radius: 25)
              }
              Button(action: onDismiss) {
                Text(L("Not now")).frame(maxWidth: .infinity, minHeight: 50).wiiSurface(radius: 25)
              }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WiiTheme.accent)
            .buttonStyle(WiiPress())
            .disabled(store.isBusy)

            if let message {
              Text(message)
                .font(.system(size: 14))
                .foregroundStyle(WiiTheme.warning)
                .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, 20)

          Text(L("Payment is charged to your Apple Account. The purchase is linked to your Apple Account and can be restored on your other devices."))
            .font(.system(size: 12))
            .foregroundStyle(WiiTheme.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
      }
    }
    .task { if store.product == nil { await store.loadProduct() } }
  }

  private func benefit(_ symbol: String, _ text: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(WiiTheme.accent)
        .frame(width: 26)
      Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(WiiTheme.ink)
    }
  }
}
/// Shown when Play is pressed on an encrypted Wii disc image before the player's key file is added. The file
/// is copied into Iridia's Wii storage, kept only if it opens the disc, and the game then starts.
struct WiiKeyFileView: View {
  let item: TVGameItem
  let onOpened: (TVGameItem) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var message: String?

  /// A Wii key file is exactly this long.
  private static let fileSize = 0x400

  var body: some View {
    List {
      Section {
        Text(String(format: L("%@ is a disc image. To open it, Iridia needs the key file from your own Wii."), WiiGameCase.displayTitle(item)))
      }
      Section {
        Button(L("Choose Key File")) { choose() }
          .fontWeight(.semibold)
          .foregroundStyle(WiiTheme.accent)
      } footer: {
        Text(L("You only need to add it once. Iridia keeps it in its own Wii storage."))
      }
      if let message {
        Section { Text(message).foregroundStyle(WiiTheme.warning) }
      }
    }
    .foregroundStyle(WiiTheme.ink)
    .navigationTitle(L("Key File Needed"))
    .navigationBarTitleDisplayMode(.inline)
    .menuClose { dismiss() }
    .wiiScreen()
    .onAppear {
      #if !APPSTORE
      // -wiiKeyFileTest <path> picks that file, since the Simulator's file picker can't be driven.
      if let path = UserDefaults.standard.string(forKey: "wiiKeyFileTest") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pick(URL(fileURLWithPath: path)) }
      }
      #endif
    }
  }

  private func choose() {
    GameFilePicker.present(types: [.data]) { urls in
      if let url = urls.first { pick(url) }
    }
  }

  private func pick(_ url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    // Checked before reading, so picking a whole game by mistake reads nothing.
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    guard size == Self.fileSize, let data = try? Data(contentsOf: url), data.count == Self.fileSize else {
      message = L("That isn't a Wii key file. A key file is exactly 1 KB.")
      return
    }
    add(data)
  }

  /// Keeps the file only if the disc opens with it; otherwise puts back whatever was there before.
  private func add(_ data: Data) {
    message = nil
    let path = TVGameItem.wiiKeyFilePath()
    let fm = FileManager.default
    let previous = fm.contents(atPath: path)
    do {
      try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      message = error.localizedDescription
      return
    }
    guard item.wiiKeyOpensDisc() else {
      if let previous { try? previous.write(to: URL(fileURLWithPath: path), options: .atomic) } else { try? fm.removeItem(atPath: path) }
      message = L("That key file doesn't open this disc.")
      return
    }
    NotificationCenter.default.post(name: Notification.Name("IridiaWiiKeyAdded"), object: nil)
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onOpened(item) }
  }
}

private var onPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
#endif
