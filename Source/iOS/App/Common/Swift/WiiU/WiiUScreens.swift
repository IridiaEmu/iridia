// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U tab's Settings, Help and Unlock Full Version screens. Unlock uses the app's one
// UnlockStore (IridiaUnlock.store), so a purchase or restore made here unlocks GameCube too, and the reverse.

#if os(iOS) && canImport(IridiaCafeCore)
import IridiaCafeCore
import IridiaStore
import SwiftUI

/// Wii U settings, stored under `cafe*` keys. The engine reads them when a game starts.
enum WiiUSettings {
  static let variableTimingDefault = true

  /// The layout for games with no layout saved yet: the earlier "GamePad screen" setting if it was changed.
  static var defaultLayout: String {
    switch UserDefaults.standard.string(forKey: "cafeGamePadScreen") {
    case "main": return WiiULayoutMode.gamePad.rawValue
    case "window": return WiiULayoutMode.pip.rawValue
    default: return WiiULayoutMode.tvOnly.rawValue
    }
  }

  /// Called just before a game starts.
  static func applyToEngine() {
    let d = UserDefaults.standard
    // Variable frame timing goes with the audio catch-up and audio stretching it was measured with on the phone;
    // turning it off turns all three off.
    let vrr = d.object(forKey: "cafeVariableTiming") == nil ? variableTimingDefault : d.bool(forKey: "cafeVariableTiming")
    for (name, value) in [("IRIDIA_VRR", "1"), ("IRIDIA_AX_CATCHUP", "4"), ("IRIDIA_AUDIO_STRETCH", "1")] {
      if vrr { setenv(name, value, 1) } else { unsetenv(name) }
    }
    if d.bool(forKey: "cafePerformanceMode") { setenv("IRIDIA_PERF_MODE", "1", 1) } else { unsetenv("IRIDIA_PERF_MODE") }
  }
}

struct WiiUSettingsView: View {
  let onUnlock: () -> Void

  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var store = IridiaUnlock.store
  @AppStorage("cafeShowSpeed") private var showSpeed = true
  @AppStorage("cafeHaptics") private var haptics = true
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55
  @AppStorage("cafeLessMemory") private var lessMemory = false
  @AppStorage("cafeVariableTiming") private var variableTiming = WiiUSettings.variableTimingDefault
  @AppStorage("cafePerformanceMode") private var performanceMode = false
  @AppStorage("cafeDefaultLayout") private var defaultLayout = WiiUSettings.defaultLayout
  @AppStorage("cafeShowLayoutButton") private var showLayoutButton = true
  @State private var noJit: String?
  @State private var restoreMessage: String?

  var body: some View {
    List {
      Section {
        if IridiaUnlock.isUnlocked {
          Label(L("Full version unlocked"), systemImage: "checkmark.seal.fill")
            .foregroundStyle(WiiUTheme.ink)
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
        Text(restoreMessage ?? L("One purchase unlocks GameCube and Wii U games. Without it, each game plays in free play sessions of 20 minutes."))
      }
      Section {
        Toggle(L("Show speed"), isOn: $showSpeed)
        Toggle(L("Variable frame timing"), isOn: $variableTiming)
        Toggle(L("Performance mode"), isOn: $performanceMode)
      } header: { Text(L("Speed")) } footer: {
        Text(L("Variable frame timing shows each frame as soon as it is ready, which can raise the frame rate. Performance mode skips one wait for the graphics chip each frame; it is faster, but some games may show glitches. Changes apply the next time you start a game."))
      }
      Section(L("Controls")) {
        Toggle(L("Button vibration"), isOn: $haptics)
        VStack(alignment: .leading) {
          Text(L("Touch controls visibility"))
          Slider(value: $touchOpacity, in: 0.15...1)
        }
        Text(L("Touch controls hide when you use a game controller."))
          .font(.footnote).foregroundStyle(WiiUTheme.dim)
      }
      Section {
        Picker(L("Layout for new games"), selection: $defaultLayout) {
          ForEach(WiiULayoutMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Toggle(L("Show the layout button"), isOn: $showLayoutButton)
      } header: { Text(L("Screens")) } footer: {
        Text(L("Each game remembers its own layout; change it in the game's settings, with the layout button, or in the pause menu. Touch the GamePad picture to use its touch screen.") + " " + WiiUShortcut.text)
      }
      Section {
        Toggle(L("Use less memory"), isOn: $lessMemory)
      } header: { Text(L("Memory")) } footer: {
        Text(L("Turn this on if the app closes by itself during play. It uses about 150 MB less and runs a little slower. Takes effect the next time you open the app."))
      }
      Section(L("About")) {
        LabeledContent(L("Renderer"), value: "Metal")
        LabeledContent(L("CPU"), value: L("Interpreter (no JIT)"))
        if WiiUModel.canRunGames {
          Button(L("Check for JIT")) { noJit = CemuBridge.noJitSelfCheck() }
          if let noJit {
            Text(noJit.hasPrefix("PASS") ? L("Passed: no code is generated at runtime.") : noJit)
              .font(.footnote).foregroundStyle(WiiUTheme.dim)
          }
        }
        Text(L("Wii U support is experimental. Games may run slowly or show glitches. Based on Cemu (MPL 2.0)."))
          .font(.footnote).foregroundStyle(WiiUTheme.dim)
      }
    }
    .foregroundStyle(WiiUTheme.ink)
    .navigationTitle(L("Wii U Settings"))
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    .wiiUScreen()
  }
}

/// One game's settings, from the Wii U library: its screen layout, the on-screen buttons and motion.
struct WiiUGameSettingsView: View {
  let game: WiiUGame
  @Environment(\.dismiss) private var dismiss
  @State private var prefs: WiiUScreenPrefs

  init(game: WiiUGame) {
    self.game = game
    _prefs = State(initialValue: WiiUScreenPrefs.load(game.settingsKey, titleId: game.title.titleId))
  }

  var body: some View {
    List {
      Section {
        WiiUScreenOptions(prefs: $prefs, portrait: WiiUScreenModel.portrait)
          .padding(.vertical, 6)
      } header: { Text(L("Screens")) } footer: {
        Text(L("Saved for this game. You can also change the layout while playing, with the layout button or in the pause menu.") + " " + WiiUShortcut.text)
      }
    }
    .foregroundStyle(WiiUTheme.ink)
    .navigationTitle(game.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    .onChange(of: prefs) { _, p in p.save(game.settingsKey) }
    .wiiUScreen()
  }
}

struct WiiUHelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section(L("Adding a game")) {
        Text(L("1. Tap + at the top, then Choose a Game File, and pick your own game. Or copy it with the Files app into the Wii U folder."))
        Text(L("2. Disc images (.wux, .wud), .wua files and installed game folders all work. Add updates and extra content the same way. Homebrew programs (.rpx) work too."))
        Text(L("3. Disc images also need keys.txt with the key for your own disc. Add it the same way, then close and reopen Iridia."))
        Text(String(format: L("4. If you used the Files app (%@), come back here and tap the refresh button."), WiiUModel.filesPath))
      }
      Section(L("Controls")) {
        Text(L("Touch controls follow the GamePad layout. A quick tap on a stick clicks it. Using a game controller hides the touch controls."))
        Text(L("Tap the pause button at the top right for the pause menu."))
      }
      Section(L("Free play")) {
        Text(L("Without the full version, each Wii U game plays for 20 minutes at a time. You can start as many sessions as you like. Time in the pause menu doesn't count."))
      }
      Section(L("About Wii U support")) {
        Text(L("Wii U support is experimental. It needs a device with 8 GB of memory. Speed depends on the game and on how warm the device is."))
        Text(L("Online features are not available."))
      }
    }
    .foregroundStyle(WiiUTheme.ink)
    .navigationTitle(L("Help"))
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    .wiiUScreen()
  }
}

/// Adding a Wii U game with the Files app, step by step (the Wii U tab's version of the GameCube shelf's guide).
struct WiiUFilesGuideView: View {
  @Environment(\.dismiss) private var dismiss

  private var steps: [String] {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return [
      L("Open the Files app."),
      L("Go to where your game is (for example Downloads or iCloud Drive)."),
      L("Press and hold the game file or folder."),
      L("Tap Move."),
      String(format: L("Tap %1$@, then the %2$@ folder, then the %3$@ folder."), device, FilesAppNames.appFolder, WiiUModel.folderName),
      String(format: L("Tap Move, then come back to %@ and tap the refresh button."), FilesAppNames.appFolder),
    ]
  }

  var body: some View {
    List {
      Section(L("Steps")) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          Text("\(index + 1). \(step)")
        }
      }
      Section(L("Where games go")) {
        Text(WiiUModel.filesPath)
        Text(L("WUA files, game folders, updates and homebrew (.rpx) work as they are. Disc images (.wux, .wud) also need keys.txt with your own disc's key in the same folder."))
          .font(.footnote)
          .foregroundStyle(WiiUTheme.dim)
      }
      Section {
        Button {
          let path = WiiUModel.shared.gamesDir.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
          if let url = URL(string: "shareddocuments://" + path) { UIApplication.shared.open(url) }
        } label: {
          Label(L("Open the Files App"), systemImage: "arrow.up.forward.app")
        }
      }
    }
    .foregroundStyle(WiiUTheme.ink)
    .navigationTitle(L("Add Games with Files"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    .wiiUScreen()
  }
}

/// "Unlock Full Version" in the Wii U tab's look. Shown when a free play session ends and from the tab's header
/// and Settings. Same product, purchase and restore as the GameCube screen.
struct WiiUUnlockView: View {
  enum Context { case sessionEnded, browsing }

  let context: Context
  /// Called after a successful purchase or restore.
  let onUnlocked: () -> Void
  /// "Not now" (browsing) or "Quit Game" (session ended).
  let onDismiss: () -> Void

  @ObservedObject private var store = IridiaUnlock.store
  @State private var message: String?

  private var priceText: String { store.product?.displayPrice ?? "$2.99" }

  var body: some View {
    ZStack {
      WiiUTheme.stage
      ScrollView {
        VStack(spacing: 18) {
          WiiUMark(size: 96)
            .padding(.top, 36)
            .accessibilityHidden(true)

          VStack(spacing: 8) {
            Text(context == .sessionEnded ? L("Free play session over") : L("Unlock Full Version"))
              .font(.system(size: 28, weight: .bold))
              .foregroundStyle(WiiUTheme.ink)
              .multilineTextAlignment(.center)
            Text(context == .sessionEnded
                 ? L("The game is paused. Unlock the full version to keep playing, or quit and start another free 20-minute session whenever you like. Quitting keeps everything the game has saved.")
                 : L("Wii U free play sessions last 20 minutes, and you can start as many as you like. One purchase removes the limit for GameCube and Wii U games."))
              .font(.system(size: 15))
              .foregroundStyle(WiiUTheme.soft)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 24)

          VStack(alignment: .leading, spacing: 12) {
            benefit("infinity", L("Unlimited play time in GameCube and Wii U games"))
            benefit("gauge.with.dots.needle.67percent", L("Hide the speed readout"))
            benefit("sparkles", L("Every feature, plus future updates"))
            benefit("checkmark.seal", L("One-time purchase. No subscription, no ads."))
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
          .wiiUSurface(radius: 24)
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
                if store.isBusy { ProgressView().tint(WiiUTheme.onAccent) }
                Text(String(format: L("Unlock for %@"), priceText))
              }
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(WiiUTheme.onAccent)
              .frame(maxWidth: .infinity, minHeight: 58)
              .wiiUSurface(radius: 29, prominent: true)
            }
            .buttonStyle(WiiUPress())
            .disabled(store.isBusy)

            HStack(spacing: 12) {
              Button {
                Task {
                  message = nil
                  if await store.restore() { onUnlocked() } else { message = L("No earlier purchase found for this Apple Account.") }
                }
              } label: {
                Text(L("Restore Purchases")).frame(maxWidth: .infinity, minHeight: 50).wiiUSurface(radius: 25)
              }
              Button(action: onDismiss) {
                Text(context == .sessionEnded ? L("Quit Game") : L("Not now"))
                  .frame(maxWidth: .infinity, minHeight: 50).wiiUSurface(radius: 25)
              }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WiiUTheme.accent)
            .buttonStyle(WiiUPress())
            .disabled(store.isBusy)

            if let message {
              Text(message)
                .font(.system(size: 14))
                .foregroundStyle(WiiUTheme.warning)
                .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, 20)

          Text(L("Payment is charged to your Apple Account. The purchase is linked to your Apple Account and can be restored on your other devices."))
            .font(.system(size: 12))
            .foregroundStyle(WiiUTheme.dim)
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
        .foregroundStyle(WiiUTheme.accent)
        .frame(width: 26)
      Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(WiiUTheme.ink)
    }
  }
}
#endif
