// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's library home, direction A "Glass Shelf". Games stand as thick glass cases on a
// dark indigo stage; the centred one is large and lit, its neighbours turn away in 3D. Below it:
// the title, when it was last played, Continue / Title Screen, and a liquid-glass tab bar.
// Everything the screen does (launch, import, settings, save states, controllers) is handed to
// the host (TVLibraryView), which already owns those flows.

#if os(iOS)
import GameController
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

struct IridiaShelfView: View {
  let games: [TVGameItem]
  /// Launch. `fresh` = start at the title screen (skip the resume point).
  let onPlay: (TVGameItem, _ fresh: Bool) -> Void
  let onImport: () -> Void
  let onSettings: () -> Void
  let onSaves: (TVGameItem) -> Void
  let onControllers: () -> Void
  let onShowGrid: () -> Void
  let onProperties: (TVGameItem) -> Void
  let onDelete: (TVGameItem) -> Void

  @State private var centred: String?
  @State private var controllerScope = UUID()
  @ObservedObject private var store = IridiaUnlock.store
  @State private var showUnlock = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  /// Cases grow on iPad, shrink in iPhone landscape.
  private var caseScale: CGFloat {
    if isLandscapePhone { return 0.78 }
    return horizontalSizeClass == .regular ? 1.35 : 1
  }

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
        // iPhone landscape: shelf on the left, the selected game and actions on the right.
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            header
            shelf.frame(height: 300 * caseScale + 30)
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
      } else {
        VStack(spacing: 0) {
          header
          shelfCaption
          shelf
            .frame(height: 300 * caseScale + 40)
          details
            .frame(maxWidth: 560)
          Spacer(minLength: 12)
          tabBar
            .frame(maxWidth: 560)
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .onAppear {
      if centred == nil { centred = ordered.first?.filePath }
      installControllerNavigation()
      // Test hook for UI checks on device: -gcemuOpenSettings YES opens Settings at launch.
      if UserDefaults.standard.bool(forKey: "gcemuOpenSettings") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onSettings() } }
      // -iridiaOpen saves|controllers|properties opens that screen for the centred game.
      if let screen = UserDefaults.standard.string(forKey: "iridiaOpen") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
      .font(.system(size: 13, weight: .medium))
      .tracking(1.5)
      .foregroundStyle(IridiaGlass.dim)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.top, 14)
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
    HStack(spacing: 8) {
      IridiaCube.mark
        .resizable()
        .scaledToFit()
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
      Text("Iridia")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(IridiaGlass.ink)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer()
      if !IridiaUnlock.isUnlocked {
        Button { showUnlock = true } label: {
          Text(L("Unlock"))
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
            .lineLimit(1)
            .fixedSize()                 // never squeeze or wrap ("Unlo / ck")
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassSurface(radius: 18, prominent: true)
        }
        .buttonStyle(SpringPressStyle())
      }
      glassIconButton("square.grid.2x2", label: L("Grid view"), action: onShowGrid)
      glassIconButton("plus", label: L("Add a game"), action: onImport)
      glassIconButton("slider.horizontal.3", label: L("Settings"), action: onSettings)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
  }

  private func glassIconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .glassSurface(radius: 22)
    }
    .buttonStyle(SpringPressStyle())
    .accessibilityLabel(label)
  }

  // MARK: Shelf (3D carousel)

  private var shelf: some View {
    GeometryReader { geo in
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 18) {
        ForEach(ordered, id: \.filePath) { item in
          GlassCase(item: item, isCentred: item.filePath == current?.filePath)
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
              Button(role: .destructive) { onDelete(item) } label: { Label(L("Delete"), systemImage: "trash") }
            }
        }
      }
      .scrollTargetLayout()
      .padding(.vertical, 12)
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: $centred, anchor: .center)
    // Half the leftover width on each side, so the first and last case can sit in the centre too.
    .safeAreaPadding(.horizontal, max(16, (geo.size.width - 214 * caseScale) / 2))
    .sensoryFeedback(.selection, trigger: centred)
    }
    .frame(height: 300 * caseScale + 24)
  }

  // MARK: Details + actions

  private var details: some View {
    VStack(spacing: 6) {
      if let item = current {
        Text(item.title.isEmpty ? L("Unknown Game") : item.title)
          .font(.system(size: 26, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.7)
        Text(subtitle(for: item))
          .font(.system(size: 14))
          .foregroundStyle(IridiaGlass.soft)
        HStack(spacing: 12) {
          let resumable = Self.hasResumePoint(item)
          Button { play(item, fresh: false) } label: {
            Label(resumable ? L("Continue") : L("Play"), systemImage: "play.fill")
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
              .frame(maxWidth: .infinity, minHeight: 58)
              .glassSurface(radius: 29, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          if resumable {
            Button { play(item, fresh: true) } label: {
              Text(L("Title Screen"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 134, height: 58)
                .glassSurface(radius: 29)
            }
            .buttonStyle(SpringPressStyle())
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
      }
    }
    .padding(.top, 8)
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
    HStack(spacing: 6) {
      tab(L("Games"), symbol: "cube", selected: true) {}
      tab(L("Saves"), symbol: "square.stack.3d.up", selected: false) { if let item = current { onSaves(item) } }
      tab(L("Controllers"), symbol: "gamecontroller", selected: false, action: onControllers)
    }
    .padding(8)
    .glassSurface(radius: 35)
    .padding(.horizontal, 20)
    .padding(.bottom, 8)
  }

  private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
        Text(title).font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(selected ? .white : IridiaGlass.soft)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 27, style: .continuous)
            .fill(Color(red: 0.67, green: 0.59, blue: 1.0).opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
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

  private var hasCover: Bool {
    let img = item.coverImage
    let desc = img.description.lowercased()
    return img.size.width > 50 && img.size.height > 50 && !desc.contains("nocover") && !desc.contains("placeholder")
  }

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
      .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: configuration.isPressed) { _, pressed in pressed }
  }
}
#endif
