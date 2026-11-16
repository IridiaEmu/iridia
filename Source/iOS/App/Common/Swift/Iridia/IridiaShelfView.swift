// SPDX-License-Identifier: GPL-2.0-or-later
//
// The GameCube and Wii shelves: glass cases in a 3D carousel, the centred game's details below. The header and
// tab bar belong to IridiaHomeView.

#if os(iOS)
import GameController
import IridiaPerformance
import PhotosUI
import SwiftUI
import UIKit

enum IridiaGlass {
  static let ink = Color(red: 0.93, green: 0.91, blue: 1.0)
  static let soft = Color(red: 0.76, green: 0.73, blue: 0.96)
  static let dim = Color(red: 0.65, green: 0.62, blue: 0.88)

  /// The stage: deep indigo, a soft glow behind the shelf, a faint floor line. No spotlight beam.
  static var stage: some View {
    ZStack {
      RadialGradient(colors: [Color(red: 0.17, green: 0.12, blue: 0.43), Color(red: 0.08, green: 0.05, blue: 0.20),
                              Color(red: 0.024, green: 0.016, blue: 0.10)],
                     center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 620)
      RadialGradient(colors: [Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.22), .clear],
                     center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 260)
    }
    .ignoresSafeArea()
  }
}

/// Liquid-glass surface: translucent fill, bright top rim, faint inner glow, soft drop shadow.
struct GlassSurface: ViewModifier {
  var radius: CGFloat
  var prominent = false

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(prominent
                ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.84, green: 0.80, blue: 1.0), Color(red: 0.61, green: 0.55, blue: 1.0),
                                                        Color(red: 0.43, green: 0.36, blue: 0.90)],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(LinearGradient(colors: [.white.opacity(prominent ? 0.85 : 0.55), .white.opacity(0.10)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
          )
          .shadow(color: prominent ? Color(red: 0.49, green: 0.42, blue: 0.94).opacity(0.5) : .black.opacity(0.35),
                  radius: prominent ? 14 : 10, y: 8)
      }
  }
}

extension View {
  func glassSurface(radius: CGFloat, prominent: Bool = false) -> some View {
    modifier(GlassSurface(radius: radius, prominent: prominent))
  }
}

/// How much larger the shelf screens are drawn on iPad: the iPhone layout scaled up until it fills the screen
/// (up to 1.6x), instead of iPhone-sized buttons in the middle of a big empty screen.
enum ShelfScale {
  static func value(_ size: CGSize, regular: Bool) -> CGFloat {
    guard regular, size.width > 0 else { return 1 }
    return min(1.6, max(1, min(size.width / 430, size.height / 780)))
  }
}

struct IridiaShelfView: View {
  var system: HomeSystem = .gameCube
  let games: [TVGameItem]
  /// `fresh` starts at the title screen instead of the resume point.
  let onPlay: (TVGameItem, _ fresh: Bool) -> Void
  let onImport: () -> Void
  let onFilesGuide: () -> Void
  let onSettings: () -> Void
  let onSaves: (TVGameItem) -> Void
  let onControllers: () -> Void
  let onProperties: (TVGameItem) -> Void
  let onDelete: (TVGameItem) -> Void
  var onHelp: (() -> Void)? = nil
  var onUnlock: (() -> Void)? = nil
  var downloads: GameCubeDownloads.Kind = .gameCube

  @ObservedObject private var router = HomeRouter.shared
  @State private var centred: String?
  @State private var coverTarget: TVGameItem?
  @State private var coverPick: PhotosPickerItem?
  @State private var coverVersion = 0
  @State private var showHelpHook = false
  @State private var controllerScope = UUID()
  @ObservedObject private var store = IridiaUnlock.store
  @State private var showUnlock = false
  @State private var centredNeedsKey = false
  @State private var controlsVersion = 0
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  @State private var screen = CGSize.zero
  private var u: CGFloat { isLandscapePhone ? 1 : ShelfScale.value(screen, regular: horizontalSizeClass == .regular) }
  private var caseScale: CGFloat { isLandscapePhone ? 0.78 : u }
  private var isWii: Bool { system == .wii }
  private var isActive: Bool { router.system == system }
  private var style: ShelfStyle { isWii ? .wii : .gameCube }

  private func play(_ item: TVGameItem, fresh: Bool) {
    // The key file prompt opens over the shelf, so it isn't faded out first.
    if isWii && centredNeedsKey && item.filePath == current?.filePath { onPlay(item, fresh); return }
    router.launch { onPlay(item, fresh) }
  }

  private var ordered: [TVGameItem] {
    let played = LastPlayedStore.all()
    return games.sorted {
      let a = played[$0.gameID] ?? .distantPast, b = played[$1.gameID] ?? .distantPast
      return a != b ? a > b : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private var current: TVGameItem? {
    let list = ordered
    return list.first { $0.filePath == centred } ?? list.first
  }

  var body: some View {
    ZStack {
      if isLandscapePhone {
        VStack(spacing: 0) {
          Color.clear.frame(height: HomeMetrics.headerHeight(u))
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              shelfOrEmpty.frame(height: 300 * caseScale + 30)
              Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              details
              Spacer(minLength: 8)
              Color.clear.frame(height: HomeMetrics.tabBarHeight(u))
            }
            .frame(width: HomeMetrics.landscapeColumn)
          }
        }
      } else {
        VStack(spacing: 0) {
          Color.clear.frame(height: HomeMetrics.headerHeight(u))
          shelfCaption
          shelfOrEmpty
            .frame(height: 300 * caseScale + 40)
          details
            .frame(maxWidth: 480 * u)
          Spacer(minLength: 12)
          Color.clear.frame(height: HomeMetrics.tabBarHeight(u))
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
    .onAppear {
      if centred == nil { centred = ordered.first?.filePath }
      checkKey()
      installControllerNavigation()
      if system == .gameCube { runTestHooks() }
    }
    .onChange(of: centred) { _, _ in checkKey() }
    .onChange(of: games.count) { _, _ in
      if centred == nil || !games.contains(where: { $0.filePath == centred }) { centred = ordered.first?.filePath }
      checkKey()
      installControllerNavigation()
    }
    .onChange(of: isActive) { _, active in if active { installControllerNavigation() } }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IridiaWiiKeyAdded"))) { _ in
      Self.needsKey.removeAll()
      checkKey()
    }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in installControllerNavigation() }
    .controllerScope(controllerScope, active: isActive)
    .onHomeAction(system, perform: handle)
    .sheet(isPresented: $showHelpHook) { NavigationStack { IridiaHelpView() } }
    .fullScreenCover(isPresented: $showUnlock) {
      UnlockView(context: .browsing, onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
    }
  }

  private func handle(_ action: HomeAction) {
    switch action {
    case .chooseFile: onImport()
    case .filesGuide: onFilesGuide()
    case .checkDownloads: GameCubeDownloads.check(downloads, manual: true)
    case .chooseDownloads: GameCubeDownloads.chooseFolder(downloads)
    case .stopDownloads: DownloadsFolder.stop()
    case .settings: onSettings()
    case .help: if let onHelp { onHelp() } else { showHelpHook = true }
    case .saves:
      if let item = current {
        onSaves(item)
      } else {
        IridiaAlert.show(L("No Games Yet"), L("Saves appear here after you add a game and play it."), look: isWii ? .wii : .gameCube)
      }
    case .controllers: onControllers()
    case .unlock: if let onUnlock { onUnlock() } else { showUnlock = true }
    }
  }

  // Opening a disc to ask is slow, and this runs on every scroll step.
  private static var needsKey: [String: Bool] = [:]

  private func checkKey() {
    guard isWii, let item = current else { centredNeedsKey = false; return }
    if let known = Self.needsKey[item.filePath] { centredNeedsKey = known; return }
    let answer = item.needsWiiKey()
    Self.needsKey[item.filePath] = answer
    centredNeedsKey = answer
  }

  private func runTestHooks() {
    #if !APPSTORE
    if UserDefaults.standard.bool(forKey: "gcemuOpenSettings") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onSettings() } }
    if let raw = UserDefaults.standard.string(forKey: "iridiaPowerMode"), let mode = PowerMode(rawValue: raw) {
      IridiaPresets.apply(mode: mode)
      NSLog("[Presets] test hook applied %@", raw)
    }
    if UserDefaults.standard.bool(forKey: "iridiaAutoplay"), let item = current {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onPlay(item, true) }
      // -iridiaAutopause / -iridiaEditLayout: the pause menu or Edit Layout, a few seconds into the game.
      if UserDefaults.standard.bool(forKey: "iridiaAutopause") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil) }
      }
      if UserDefaults.standard.bool(forKey: "iridiaEditLayout") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { NotificationCenter.default.post(name: .DOLEditTouchLayout, object: nil) }
      }
    }
    if let screen = UserDefaults.standard.string(forKey: "iridiaOpen") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if screen == "filesguide" { onFilesGuide(); return }
        if screen == "help" { showHelpHook = true; return }
        guard let item = current else { return }
        switch screen {
        case "saves": onSaves(item)
        case "controllers": onControllers()
        case "properties": onProperties(item)
        default: break
        }
      }
    }
    #endif
  }

  private var shelfCaption: some View {
    let format = isWii
      ? (games.count == 1 ? L("Your Wii shelf · %d game") : L("Your Wii shelf · %d games"))
      : (games.count == 1 ? L("Your shelf · %d game") : L("Your shelf · %d games"))
    return Text(String(format: format, games.count).uppercased())
      .font(.system(size: 13 * u, weight: .medium))
      .tracking(1.5 * u)
      .foregroundStyle(style.dim)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20 * u)
      .padding(.top, 14 * u)
  }

  /// Left/right move along the shelf, A plays, Y starts at the title screen, B goes back to the first game.
  /// The handler slots are shared by every shelf, so the shelf that becomes active installs them again.
  private func installControllerNavigation() {
    guard isActive else { return }
    let scope = controllerScope
    var lastMove = Date.distantPast
    for controller in GCController.controllers() {
      guard let pad = controller.extendedGamepad else { continue }
      pad.valueChangedHandler = { gamepad, element in
        guard ControllerFocusCoordinator.isActiveScope(scope), !TVEmulationBridge.isRunning() else { return }
        func step(_ delta: Int) {
          guard Date().timeIntervalSince(lastMove) > 0.22 else { return }
          lastMove = Date()
          DispatchQueue.main.async { move(by: delta) }
        }
        if element == gamepad.dpad || element == gamepad.leftThumbstick {
          let x = (element == gamepad.dpad ? gamepad.dpad.xAxis.value : gamepad.leftThumbstick.xAxis.value)
          if x > 0.6 { step(1) } else if x < -0.6 { step(-1) }
        }
        if element == gamepad.buttonA, gamepad.buttonA.isPressed {
          DispatchQueue.main.async { if let item = current { play(item, fresh: false) } }
        }
        if element == gamepad.buttonY, gamepad.buttonY.isPressed {
          DispatchQueue.main.async { if let item = current { play(item, fresh: true) } }
        }
        if element == gamepad.buttonB, gamepad.buttonB.isPressed {
          DispatchQueue.main.async { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = ordered.first?.filePath } }
        }
      }
    }
  }

  private func move(by delta: Int) {
    let list = ordered
    guard !list.isEmpty else { return }
    let index = list.firstIndex { $0.filePath == current?.filePath } ?? 0
    let next = max(0, min(list.count - 1, index + delta))
    guard next != index else { return }
    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = list[next].filePath }
  }

  @ViewBuilder
  private var shelfOrEmpty: some View {
    if ordered.isEmpty { emptySlot } else { shelf }
  }

  private var emptySlot: some View {
    Menu {
      Button(action: onImport) { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
      Button(action: onFilesGuide) { Label(L("Add with the Files App"), systemImage: "folder") }
    } label: {
      VStack(spacing: 12 * u) {
        Image(systemName: "plus")
          .font(.system(size: 34 * u, weight: .semibold))
        Text(L("Add a game"))
          .font(.system(size: 15 * u, weight: .semibold))
      }
      .foregroundStyle(style.emptyIcon)
      .frame(width: 214 * caseScale, height: 300 * caseScale)
      .background(
        RoundedRectangle(cornerRadius: 22 * u, style: .continuous)
          .strokeBorder(style.emptyRim, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
      )
      .shelfSurface(style, radius: 22 * u)
    }
    .accessibilityLabel(L("Add a game"))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private func gameCase(_ item: TVGameItem) -> some View {
    if isWii {
      WiiGameCase(item: item, isCentred: item.filePath == current?.filePath, coverVersion: coverVersion)
        .frame(width: 214, height: 300)
    } else {
      GlassCase(item: item, isCentred: item.filePath == current?.filePath, coverVersion: coverVersion)
    }
  }

  private var shelf: some View {
    GeometryReader { geo in
    ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 18 * u) {
        ForEach(ordered, id: \.filePath) { item in
          gameCase(item)
            .scaleEffect(caseScale)
            .frame(width: 214 * caseScale, height: 300 * caseScale)
            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
              view
                .rotation3DEffect(.degrees(phase.value * -38), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .scaleEffect(1 - abs(phase.value) * 0.22)
                .opacity(1 - abs(phase.value) * 0.35)
            }
            .onTapGesture {
              if item.filePath == current?.filePath {
                play(item, fresh: false)
              } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = item.filePath }
              }
            }
            .contextMenu {
              Button { play(item, fresh: true) } label: { Label(L("Start at Title Screen"), systemImage: "arrow.counterclockwise") }
              Button { onSaves(item) } label: { Label(L("Save States"), systemImage: "square.stack.3d.up") }
              Button { onProperties(item) } label: { Label(L("Properties"), systemImage: "info.circle") }
              Button { coverTarget = item } label: { Label(L("Choose Cover Image…"), systemImage: "photo") }
              if item.hasCoverArt {
                Button { IridiaCovers.remove(for: item) } label: { Label(L("Use Iridia Cover"), systemImage: "rectangle.portrait") }
              }
              Button(role: .destructive) { onDelete(item) } label: { Label(L("Delete"), systemImage: "trash") }
            }
        }
      }
      .scrollTargetLayout()
      .padding(.vertical, 12 * u)
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: $centred, anchor: .center)
    .safeAreaPadding(.horizontal, max(16, (geo.size.width - 214 * caseScale) / 2))
    // Rotation changes the width but not the scroll offset, which leaves the centred case tilted off-centre.
    .onChange(of: geo.size) { _, _ in
      guard let id = current?.filePath else { return }
      DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
    .sensoryFeedback(.selection, trigger: centred) { _, _ in IridiaHaptics.enabled && isActive }
    .photosPicker(isPresented: Binding(get: { coverTarget != nil }, set: { if !$0 { coverTarget = nil } }),
                  selection: $coverPick, matching: .images)
    .onChange(of: coverPick) { _, pick in
      guard let pick, let item = coverTarget else { return }
      Task {
        if let data = try? await pick.loadTransferable(type: Data.self) { IridiaCovers.set(data, for: item) }
        coverPick = nil
        coverTarget = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: IridiaCovers.changed)) { _ in coverVersion &+= 1 }
    }
    }
    .frame(height: 300 * caseScale + 24)
  }

  private var details: some View {
    VStack(spacing: 6 * u) {
      if games.isEmpty {
        Text(L("Your shelf is empty"))
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(style.title)
        Text(isWii ? L("Add a Wii game to start playing.") : L("Add a GameCube game to start playing."))
          .font(.system(size: 14 * u))
          .foregroundStyle(style.soft)
          .multilineTextAlignment(.center)
        HStack(spacing: 12 * u) {
          Button(action: onImport) {
            Label(L("Choose a Game File"), systemImage: "doc.badge.plus")
              .font(.system(size: 16 * u, weight: .bold))
              .foregroundStyle(style.onProminent)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .frame(maxWidth: .infinity, minHeight: 58 * u)
              .shelfSurface(style, radius: 29 * u, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          Button(action: onFilesGuide) {
            Text(L("Files App"))
              .font(.system(size: 15 * u, weight: .semibold))
              .foregroundStyle(style.secondary)
              .frame(width: 134 * u, height: 58 * u)
              .shelfSurface(style, radius: 29 * u)
          }
          .buttonStyle(SpringPressStyle())
        }
        .padding(.horizontal, 20 * u)
        .padding(.top, 14 * u)
      } else if let item = current {
        Text(isWii ? WiiGameCase.displayTitle(item) : (item.title.isEmpty ? L("Unknown Game") : item.title))
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(style.title)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.7)
        if centredNeedsKey || (isWii && item.isWiiWAD) {
          Label(centredNeedsKey ? L("Needs your key file") : L("WAD files aren't supported"), systemImage: "exclamationmark.circle")
            .font(.system(size: 14 * u, weight: .medium))
            .foregroundStyle(WiiTheme.warning)
            .multilineTextAlignment(.center)
        } else {
          Text(subtitle(for: item))
            .font(.system(size: 14 * u))
            .foregroundStyle(style.soft)
        }
        HStack(spacing: 12 * u) {
          let resumable = Self.hasResumePoint(item)
          Button { play(item, fresh: false) } label: {
            Label(resumable ? L("Continue") : L("Play"), systemImage: "play.fill")
              .font(.system(size: 18 * u, weight: .bold))
              .foregroundStyle(style.onProminent)
              .frame(maxWidth: .infinity, minHeight: 58 * u)
              .shelfSurface(style, radius: 29 * u, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          if resumable {
            Button { play(item, fresh: true) } label: {
              Text(L("Title Screen"))
                .font(.system(size: 15 * u, weight: .semibold))
                .foregroundStyle(style.secondary)
                .frame(width: 134 * u, height: 58 * u)
                .shelfSurface(style, radius: 29 * u)
            }
            .buttonStyle(SpringPressStyle())
          }
        }
        .padding(.horizontal, 20 * u)
        .padding(.top, 14 * u)
        if isWii { controlsPicker(for: item).padding(.top, 8 * u) }
      }
    }
    .padding(.top, 8 * u)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current?.filePath)
  }

  private func controlsPicker(for item: TVGameItem) -> some View {
    let _ = controlsVersion
    let choice = WiiControls.choice(for: item.gameID)
    return Menu {
      Picker(L("Controls"), selection: Binding(
        get: { WiiControls.choice(for: item.gameID) },
        set: { WiiControls.remember($0, for: item.gameID); controlsVersion &+= 1 })) {
        ForEach(WiiControls.options, id: \.self) { option in
          Label(option.title, systemImage: WiiControls.symbol(option)).tag(option)
        }
      }
    } label: {
      HStack(spacing: 8 * u) {
        Image(systemName: WiiControls.symbol(choice))
        Text(String(format: L("Controls: %@"), choice.title))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11 * u, weight: .semibold))
      }
      .font(.system(size: 14 * u, weight: .semibold))
      .foregroundStyle(style.secondary)
      .padding(.horizontal, 16 * u)
      .frame(minHeight: 44 * u)
      .shelfSurface(style, radius: 22 * u)
    }
    .accessibilityLabel(String(format: L("Controls: %@"), choice.title))
  }

  private func subtitle(for item: TVGameItem) -> String {
    var parts: [String] = []
    if let date = LastPlayedStore.lastPlayed(gameID: item.gameID) {
      let f = RelativeDateTimeFormatter()
      f.unitsStyle = .full
      parts.append(String(format: L("Last played %@"), f.localizedString(for: date, relativeTo: Date())))
    } else {
      parts.append(L("Not played yet"))
    }
    if Self.hasResumePoint(item) { parts.append(L("Resume point saved")) }
    return parts.joined(separator: " · ")
  }

  static func hasResumePoint(_ item: TVGameItem) -> Bool {
    guard !item.gameID.isEmpty else { return false }
    let path = (UserFolderUtil.getUserFolder() as NSString).appendingPathComponent("StateSaves/\(item.gameID).auto")
    return SaveStateService.resumeEnabled && FileManager.default.fileExists(atPath: path)
  }
}

struct ShelfStyle {
  let title: Color
  let soft: Color
  let dim: Color
  let onProminent: Color
  let secondary: Color
  let emptyIcon: Color
  let emptyRim: Color
  let isWii: Bool

  static let gameCube = ShelfStyle(title: .white, soft: IridiaGlass.soft, dim: IridiaGlass.dim,
                                   onProminent: Color(red: 0.07, green: 0.04, blue: 0.20), secondary: .white,
                                   emptyIcon: IridiaGlass.soft, emptyRim: .white.opacity(0.28), isWii: false)
  static let wii = ShelfStyle(title: WiiTheme.ink, soft: WiiTheme.soft, dim: WiiTheme.dim,
                              onProminent: WiiTheme.onAccent, secondary: WiiTheme.accent,
                              emptyIcon: WiiTheme.accent, emptyRim: WiiTheme.accent.opacity(0.35), isWii: true)
}

extension View {
  @ViewBuilder func shelfSurface(_ style: ShelfStyle, radius: CGFloat, prominent: Bool = false) -> some View {
    if style.isWii {
      wiiSurface(radius: radius, prominent: prominent)
    } else {
      glassSurface(radius: radius, prominent: prominent)
    }
  }
}

/// One game on the shelf: a thick glass slab with the cover (or the Iridia cube) inside.
private struct GlassCase: View {
  let item: TVGameItem
  let isCentred: Bool

  /// Redraws when a cover is chosen or removed (the item's image changes in place).
  let coverVersion: Int

  /// The player's own picture; otherwise the case shows Iridia's cube and the title.
  private var hasCover: Bool { item.hasCoverArt }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0),
                                     .init(color: Color(red: 0.67, green: 0.59, blue: 1.0).opacity(0.24), location: 0.22),
                                     .init(color: Color(red: 0.31, green: 0.24, blue: 0.75).opacity(0.42), location: 0.6),
                                     .init(color: Color(red: 0.10, green: 0.06, blue: 0.29).opacity(0.80), location: 1)],
                             startPoint: .topLeading, endPoint: .bottomTrailing))
      if hasCover {
        Image(uiImage: item.coverImage)
          .resizable()
          .scaledToFill()
          .frame(width: 190, height: 276)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      } else {
        VStack(spacing: 10) {
          IridiaCube.mark
            .resizable()
            .scaledToFit()
            .frame(width: 140, height: 140)
          Text(item.title.isEmpty ? L("Unknown Game") : item.title)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 14)
        }
      }
      // Glass: a bright bevel on top, a sheen across the upper half.
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.12), Color(red: 0.6, green: 0.5, blue: 1.0).opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
      LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .allowsHitTesting(false)
    }
    .frame(width: 214, height: 300)
    .shadow(color: .black.opacity(0.55), radius: 22, y: 18)
    .shadow(color: Color(red: 0.59, green: 0.51, blue: 1.0).opacity(isCentred ? 0.35 : 0), radius: 26)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(.isButton)
  }
}

/// Springy press: squish a little and spring back, like a toy button, with a light haptic tap.
struct SpringPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
      .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: configuration.isPressed) { _, pressed in pressed && IridiaHaptics.enabled }
  }
}
#endif
