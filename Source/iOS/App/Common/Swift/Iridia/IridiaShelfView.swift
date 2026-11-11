// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's library home, direction A "Glass Shelf". Games stand as thick glass cases on a
// dark indigo stage; the centred one is large and lit, its neighbours turn away in 3D. Below it:
// the title, when it was last played, Continue / Title Screen, and a liquid-glass tab bar.
// Everything the screen does (launch, import, settings, save states, controllers) is handed to
// the host (TVLibraryView), which already owns those flows.

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
  let games: [TVGameItem]
  /// Launch. `fresh` = start at the title screen (skip the resume point).
  let onPlay: (TVGameItem, _ fresh: Bool) -> Void
  let onImport: () -> Void
  /// The step-by-step guide for adding games with the Files app.
  let onFilesGuide: () -> Void
  let onSettings: () -> Void
  let onSaves: (TVGameItem) -> Void
  let onControllers: () -> Void
  let onProperties: (TVGameItem) -> Void
  let onDelete: (TVGameItem) -> Void
  /// Opens the Wii U tab (nil where the Wii U core isn't built in).
  var onWiiU: (() -> Void)? = nil

  @State private var centred: String?
  /// Set while a Downloads folder is chosen (DownloadsFolder); here so the + menu updates.
  @AppStorage("downloadsFolderName") private var downloadsName: String?
  /// Choosing a cover from Photos: the game it's for, the picked photo, and a redraw counter.
  @State private var coverTarget: TVGameItem?
  @State private var coverPick: PhotosPickerItem?
  @State private var coverVersion = 0
  @State private var showHelpHook = false   // -iridiaOpen help (test hook)
  @State private var controllerScope = UUID()
  @ObservedObject private var store = IridiaUnlock.store
  @State private var showUnlock = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  /// The screen's size, for `u`.
  @State private var screen = CGSize.zero
  /// iPad: the iPhone layout drawn larger to fill the screen (ShelfScale). 1 on iPhone.
  private var u: CGFloat { isLandscapePhone ? 1 : ShelfScale.value(screen, regular: horizontalSizeClass == .regular) }
  /// Cases grow with the rest on iPad, shrink in iPhone landscape.
  private var caseScale: CGFloat { isLandscapePhone ? 0.78 : u }

  /// Every launch from the shelf goes through here.
  private func play(_ item: TVGameItem, fresh: Bool) {
    onPlay(item, fresh)
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
      IridiaGlass.stage
      if isLandscapePhone {
        // iPhone landscape: header across the top (so the title never truncates), then the shelf
        // on the left and the selected game and actions on the right.
        VStack(spacing: 0) {
          header
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
              tabBar
            }
            .frame(width: 380)
          }
        }
      } else {
        VStack(spacing: 0) {
          header
          shelfCaption
          shelfOrEmpty
            .frame(height: 300 * caseScale + 40)
          details
            .frame(maxWidth: 480 * u)
          Spacer(minLength: 12)
          tabBar
            .frame(maxWidth: 480 * u)
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
    .onAppear {
      if centred == nil { centred = ordered.first?.filePath }
      installControllerNavigation()
      // Test hook for UI checks on device: -gcemuOpenSettings YES opens Settings at launch.
      if UserDefaults.standard.bool(forKey: "gcemuOpenSettings") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onSettings() } }
      // Test hook: -iridiaPowerMode batterySaver|balanced|maxPerformance applies that mode, as Settings does.
      if let raw = UserDefaults.standard.string(forKey: "iridiaPowerMode"), let mode = PowerMode(rawValue: raw) {
        IridiaPresets.apply(mode: mode)
        NSLog("[Presets] test hook applied %@", raw)
      }
      // -iridiaOpen saves|controllers|properties|filesguide opens that screen (the first three for the centred game).
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
    }
    .onChange(of: games.count) { _, _ in installControllerNavigation() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in installControllerNavigation() }
    .controllerScope(controllerScope)
    .fullScreenCover(isPresented: $showUnlock) {
      UnlockView(context: .browsing, onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
    }
  }

  private var shelfCaption: some View {
    Text(String(format: games.count == 1 ? L("Your shelf · %d game") : L("Your shelf · %d games"), games.count).uppercased())
      .font(.system(size: 13 * u, weight: .medium))
      .tracking(1.5 * u)
      .foregroundStyle(IridiaGlass.dim)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20 * u)
      .padding(.top, 14 * u)
  }

  // MARK: Controller navigation

  /// Left/right (d-pad or stick) move along the shelf, A plays (Continue), Y starts at the title
  /// screen, B returns to the first game. Self-gated on this screen's controller scope, so a sheet
  /// or the game on top takes the controller over.
  private func installControllerNavigation() {
    let scope = controllerScope
    var lastMove = Date.distantPast
    for controller in GCController.controllers() {
      guard let pad = controller.extendedGamepad else { continue }
      pad.valueChangedHandler = { gamepad, element in
        // Never while a game runs: the core reads the controller itself.
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

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8 * u) {
      IridiaCube.mark
        .resizable()
        .scaledToFit()
        .frame(width: 40 * u, height: 40 * u)
        .accessibilityHidden(true)
      Text("Iridia")
        .font(.system(size: 24 * u, weight: .semibold))
        .foregroundStyle(IridiaGlass.ink)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer()
      if !IridiaUnlock.isUnlocked {
        Button { showUnlock = true } label: {
          Text(L("Unlock"))
            .font(.system(size: 14 * u, weight: .bold))
            .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
            .lineLimit(1)
            .fixedSize()                 // never squeeze or wrap ("Unlo / ck")
            .padding(.horizontal, 14 * u)
            .frame(height: 36 * u)
            .glassSurface(radius: 18 * u, prominent: true)
        }
        .buttonStyle(SpringPressStyle())
      }
      // Two ways in: pick a file now, or learn the Files app route (better for big games).
      Menu {
        Button(action: onImport) { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
        Button(action: onFilesGuide) { Label(L("Add with the Files App"), systemImage: "folder") }
        downloadsMenuItems
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 17 * u, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44 * u, height: 44 * u)
          .glassSurface(radius: 22 * u)
      }
      .accessibilityLabel(L("Add a game"))
      glassIconButton("slider.horizontal.3", label: L("Settings"), action: onSettings)
    }
    .padding(.horizontal, 20 * u)
    .padding(.top, 8 * u)
  }

  private func glassIconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17 * u, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44 * u, height: 44 * u)
        .glassSurface(radius: 22 * u)
    }
    .buttonStyle(SpringPressStyle())
    .accessibilityLabel(label)
  }

  /// "Check Downloads for Games" until a folder is chosen, then "Check Downloads Now" and "Stop Checking".
  @ViewBuilder private var downloadsMenuItems: some View {
    if let name = downloadsName {
      Button { GameCubeDownloads.check(manual: true) } label: {
        Label(String(format: L("Check %@ Now"), name), systemImage: "arrow.down.circle")
      }
      Button { DownloadsFolder.stop() } label: {
        Label(String(format: L("Stop Checking %@"), name), systemImage: "xmark.circle")
      }
    } else {
      Button { GameCubeDownloads.chooseFolder() } label: {
        Label(L("Check Downloads for Games"), systemImage: "arrow.down.circle")
      }
    }
  }

  // MARK: Shelf (3D carousel)

  @ViewBuilder
  private var shelfOrEmpty: some View {
    if ordered.isEmpty { emptySlot } else { shelf }
  }

  /// No games yet: one empty glass case in the middle of the shelf. Tapping it adds a game.
  private var emptySlot: some View {
    Menu {
      Button(action: onImport) { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
      Button(action: onFilesGuide) { Label(L("Add with the Files App"), systemImage: "folder") }
      downloadsMenuItems
    } label: {
      VStack(spacing: 12 * u) {
        Image(systemName: "plus")
          .font(.system(size: 34 * u, weight: .semibold))
        Text(L("Add a game"))
          .font(.system(size: 15 * u, weight: .semibold))
      }
      .foregroundStyle(IridiaGlass.soft)
      .frame(width: 214 * caseScale, height: 300 * caseScale)
      .background(
        RoundedRectangle(cornerRadius: 22 * u, style: .continuous)
          .strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
      )
      .glassSurface(radius: 22 * u)
    }
    .accessibilityLabel(L("Add a game"))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var shelf: some View {
    GeometryReader { geo in
    ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 18 * u) {
        ForEach(ordered, id: \.filePath) { item in
          GlassCase(item: item, isCentred: item.filePath == current?.filePath, coverVersion: coverVersion)
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
    // Half the leftover width on each side, so the first and last case can sit in the centre too.
    .safeAreaPadding(.horizontal, max(16, (geo.size.width - 214 * caseScale) / 2))
    // Rotation changes the width but not the scroll offset, which left the centred case
    // off-centre and stuck at a tilt until the next swipe. Re-centre it after every resize.
    .onChange(of: geo.size) { _, _ in
      guard let id = current?.filePath else { return }
      DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
    .sensoryFeedback(.selection, trigger: centred) { _, _ in IridiaHaptics.enabled }
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
    .sheet(isPresented: $showHelpHook) { NavigationStack { IridiaHelpView() } }
    }
    }
    .frame(height: 300 * caseScale + 24)
  }

  // MARK: Details + actions

  private var details: some View {
    VStack(spacing: 6 * u) {
      if games.isEmpty {
        Text(L("Your shelf is empty"))
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(.white)
        Text(L("Add a GameCube game to start playing."))
          .font(.system(size: 14 * u))
          .foregroundStyle(IridiaGlass.soft)
          .multilineTextAlignment(.center)
        HStack(spacing: 12 * u) {
          Button(action: onImport) {
            Label(L("Choose a Game File"), systemImage: "doc.badge.plus")
              .font(.system(size: 16 * u, weight: .bold))
              .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .frame(maxWidth: .infinity, minHeight: 58 * u)
              .glassSurface(radius: 29 * u, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          Button(action: onFilesGuide) {
            Text(L("Files App"))
              .font(.system(size: 15 * u, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 134 * u, height: 58 * u)
              .glassSurface(radius: 29 * u)
          }
          .buttonStyle(SpringPressStyle())
        }
        .padding(.horizontal, 20 * u)
        .padding(.top, 14 * u)
      } else if let item = current {
        Text(item.title.isEmpty ? L("Unknown Game") : item.title)
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.7)
        Text(subtitle(for: item))
          .font(.system(size: 14 * u))
          .foregroundStyle(IridiaGlass.soft)
        HStack(spacing: 12 * u) {
          let resumable = Self.hasResumePoint(item)
          Button { play(item, fresh: false) } label: {
            Label(resumable ? L("Continue") : L("Play"), systemImage: "play.fill")
              .font(.system(size: 18 * u, weight: .bold))
              .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
              .frame(maxWidth: .infinity, minHeight: 58 * u)
              .glassSurface(radius: 29 * u, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          if resumable {
            Button { play(item, fresh: true) } label: {
              Text(L("Title Screen"))
                .font(.system(size: 15 * u, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 134 * u, height: 58 * u)
                .glassSurface(radius: 29 * u)
            }
            .buttonStyle(SpringPressStyle())
          }
        }
        .padding(.horizontal, 20 * u)
        .padding(.top, 14 * u)
      }
    }
    .padding(.top, 8 * u)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current?.filePath)
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

  // MARK: Tab bar

  private var tabBar: some View {
    HStack(spacing: 6 * u) {
      // GameCube and Wii U side by side, the same as in the Wii U tab's bar.
      tab(L("GameCube"), symbol: "cube", selected: true) {}
      if let onWiiU { tab(L("Wii U"), symbol: "square.stack", selected: false, action: onWiiU) }
      tab(L("Saves"), symbol: "square.stack.3d.up", selected: false) { if let item = current { onSaves(item) } }
      tab(L("Controllers"), symbol: "gamecontroller", selected: false, action: onControllers)
    }
    .padding(8 * u)
    .glassSurface(radius: 35 * u)
    .padding(.horizontal, 20 * u)
    .padding(.bottom, 8 * u)
  }

  private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3 * u) {
        Image(systemName: symbol).font(.system(size: 19 * u, weight: .semibold))
        Text(title).font(.system(size: 11 * u, weight: .semibold))
      }
      .foregroundStyle(selected ? .white : IridiaGlass.soft)
      .frame(maxWidth: .infinity, minHeight: 54 * u)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 27 * u, style: .continuous)
            .fill(Color(red: 0.67, green: 0.59, blue: 1.0).opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: 27 * u, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        }
      }
    }
    .buttonStyle(SpringPressStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
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
