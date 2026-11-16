// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import IridiaStore
import SwiftUI

struct WiiHomeView: View {
  let games: [TVGameItem]
  let onPlay: (TVGameItem, _ fresh: Bool) -> Void
  let onImport: () -> Void
  let onFilesGuide: () -> Void
  let onSaves: (TVGameItem) -> Void
  let onProperties: (TVGameItem) -> Void
  let onDelete: (TVGameItem) -> Void

  @State private var sheet: Sheet?
  @State private var showUnlock = false
  @State private var keyFor: TVGameItem?

  enum Sheet: String, Identifiable { case settings, help, controllers; var id: String { rawValue } }

  private static var autoplayed = false

  var body: some View {
    IridiaShelfView(
      system: .wii,
      games: games,
      onPlay: play,
      onImport: onImport,
      onFilesGuide: onFilesGuide,
      onSettings: { sheet = .settings },
      onSaves: onSaves,
      onControllers: { sheet = .controllers },
      onProperties: onProperties,
      onDelete: onDelete,
      onHelp: { sheet = .help },
      onUnlock: { showUnlock = true },
      downloads: .wii
    )
    .onAppear {
      #if !APPSTORE
      autoplayHook()
      if let screen = UserDefaults.standard.string(forKey: "wiiOpen") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          if screen == "unlock" { showUnlock = true } else { sheet = Sheet(rawValue: screen) }
        }
      }
      #endif
    }
    .onChange(of: games.count) { _, _ in autoplayHook() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IridiaWiiKeyNeeded"))) { note in
      guard let path = note.userInfo?["path"] as? String else { return }
      keyFor = games.first { $0.filePath == path }
    }
    .sheet(item: $sheet) { which in
      NavigationStack {
        switch which {
        case .settings: WiiSettingsView(onUnlock: { sheet = nil; showUnlock = true }, onControllers: { sheet = .controllers })
        case .help: WiiHelpView()
        case .controllers:
          ControllerHubView(system: .wiiAndGameCube, onBack: { sheet = nil })
            .menuClose { sheet = nil }
        }
      }
      .environment(\.menuLook, .wii)
      .claimsController()
    }
    .sheet(item: $keyFor) { item in
      NavigationStack { WiiKeyFileView(item: item) { opened in HomeRouter.shared.launch { onPlay(opened, true) } } }
        .environment(\.menuLook, .wii)
        .claimsController()
    }
    .fullScreenCover(isPresented: $showUnlock) {
      WiiUnlockView(onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
        .claimsController()
    }
  }

  /// An encrypted disc opens the key file prompt until the key file is added.
  private func play(_ item: TVGameItem, fresh: Bool) {
    if item.needsWiiKey() { keyFor = item } else { onPlay(item, fresh) }
  }

  /// -wiiAutoplay <name part> starts the first matching Wii game once per launch; -wiiAutopause YES then opens
  /// the pause menu, -wiiEditLayout YES opens Edit Layout and -wiiLandscape YES turns the screen.
  private func autoplayHook() {
    #if !APPSTORE
    guard let want = UserDefaults.standard.string(forKey: "wiiAutoplay"), !Self.autoplayed,
          let item = games.first(where: { $0.title == want })
            ?? games.first(where: { $0.title.localizedCaseInsensitiveContains(want) }) else { return }
    Self.autoplayed = true
    NSLog("[Wii] test hook: starting %@", item.title)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { play(item, fresh: true) }
    if UserDefaults.standard.bool(forKey: "wiiAutopause") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
      }
    }
    if UserDefaults.standard.bool(forKey: "wiiEditLayout") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
        NotificationCenter.default.post(name: .DOLEditTouchLayout, object: nil)
      }
    }
    if UserDefaults.standard.bool(forKey: "wiiLandscape") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { Self.turnToLandscape() }
    }
    #endif
  }
}

#if !APPSTORE
extension WiiHomeView {
  /// Windowed iPad apps can't ask for an orientation, so the simulated device is turned as well.
  @MainActor static func turnToLandscape() {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
      Task { @MainActor in UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation") }
    }
    UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
  }
}
#endif

/// A white case with a grey band across the top and the title on its face, or the player's own cover picture.
struct WiiGameCase: View {
  let item: TVGameItem
  let isCentred: Bool
  let coverVersion: Int

  var body: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(LinearGradient(colors: [WiiTheme.surfaceTop, WiiTheme.surfaceBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WiiTheme.stageTop))
      if item.hasCoverArt {
        Image(uiImage: item.coverImage)
          .resizable()
          .scaledToFill()
          .frame(width: 194, height: 280)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .padding(.top, 10)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Capsule()
            .fill(LinearGradient(colors: [WiiTheme.accentTop, WiiTheme.deep], startPoint: .leading, endPoint: .trailing))
            .frame(height: 10)
            .padding(.top, 22)
          Spacer()
          Text(Self.displayTitle(item))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(WiiTheme.ink)
            .lineLimit(4)
            .minimumScaleFactor(0.7)
          Text(Self.formatLabel(item))
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(WiiTheme.dim)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(LinearGradient(colors: [WiiTheme.rimTop, WiiTheme.rimBottom], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
    )
    .shadow(color: WiiTheme.accent.opacity(isCentred ? 0.30 : 0.10), radius: isCentred ? 20 : 8, y: 10)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.displayTitle(item))
    .accessibilityAddTraits(.isButton)
  }

  /// The game's name. A file with no name inside it is listed by its file name; drop the extension then.
  static func displayTitle(_ item: TVGameItem) -> String {
    guard !item.title.isEmpty else { return L("Unknown Game") }
    let ext = (item.filePath as NSString).pathExtension
    if !ext.isEmpty, item.title.lowercased().hasSuffix("." + ext.lowercased()) {
      return String(item.title.dropLast(ext.count + 1))
    }
    return item.title
  }

  /// "RVZ", "WBFS", "HOMEBREW": what the file is, small under the title.
  static func formatLabel(_ item: TVGameItem) -> String {
    let ext = (item.filePath as NSString).pathExtension.lowercased()
    if ext == "dol" || ext == "elf" { return L("Homebrew").uppercased() }
    return ext.uppercased()
  }
}
#endif
