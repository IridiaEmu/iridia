// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import IridiaStore
import SwiftUI
import UIKit
#if canImport(IridiaCafeCore)
import IridiaCafeCore
#endif

enum HomeSystem: Int, CaseIterable, Identifiable {
  case gameCube, wii, wiiU
  var id: Int { rawValue }

  static var available: [HomeSystem] {
    #if canImport(IridiaCafeCore)
    return allCases
    #else
    return [.gameCube, .wii]
    #endif
  }
}

enum HomeAction {
  case chooseFile, filesGuide, checkDownloads, chooseDownloads, stopDownloads
  case settings, help, saves, controllers, unlock
}

@MainActor final class HomeRouter: ObservableObject {
  static let shared = HomeRouter()

  @Published private(set) var system: HomeSystem = .gameCube
  let actions = PassthroughSubject<(HomeSystem, HomeAction), Never>()

  static var switchAnimation: Animation {
    UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88)
  }

  func select(_ system: HomeSystem, animated: Bool = true) {
    guard system != self.system else { return }
    switch system {
    case .gameCube: IridiaAlert.tabLook = .gameCube
    case .wii: IridiaAlert.tabLook = .wii
    case .wiiU: IridiaAlert.tabLook = .wiiU
    }
    if animated {
      withAnimation(Self.switchAnimation) { self.system = system }
    } else {
      self.system = system
    }
  }

  func send(_ action: HomeAction) { actions.send((system, action)) }

  /// Fades the home screen to black (the game's first frame) before a game opens, and back when it closes.
  @Published private(set) var curtain = false
  var homeCovered = false

  func launch(_ start: @escaping () -> Void) {
    withAnimation(.easeIn(duration: 0.2)) { curtain = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { start() }
      // Nothing opened (a picker or a warning came up instead): show the shelf again.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        if !self.homeCovered { self.lift() }
      }
    }
  }

  func lift() {
    guard curtain else { return }
    withAnimation(.easeOut(duration: 0.4)) { curtain = false }
  }
}

extension View {
  func onHomeAction(_ system: HomeSystem, perform: @escaping (HomeAction) -> Void) -> some View {
    onReceive(HomeRouter.shared.actions) { target, action in
      if target == system { perform(action) }
    }
  }

  /// Like `controllerScope`, but only while `active`: the shelves stay alive behind the one showing.
  func controllerScope(_ id: UUID, active: Bool) -> some View {
    modifier(ActiveControllerScope(id: id, active: active))
  }
}

private struct ActiveControllerScope: ViewModifier {
  let id: UUID
  let active: Bool

  func body(content: Content) -> some View {
    content
      .onAppear { if active { ControllerFocusCoordinator.shared.push(id) } }
      .onDisappear { ControllerFocusCoordinator.shared.pop(id) }
      .onChange(of: active) { _, on in
        if on { ControllerFocusCoordinator.shared.push(id) } else { ControllerFocusCoordinator.shared.pop(id) }
      }
  }
}

struct HomeTheme {
  let ink: Color
  let soft: Color
  let icon: Color
  let prominent: Color
  let onProminent: Color
  let selection: Color
  let onSelection: Color
  let glassTint: Color
  let solid: Color

  private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }

  static func of(_ system: HomeSystem) -> HomeTheme {
    switch system {
    case .gameCube:
      return HomeTheme(ink: IridiaGlass.ink, soft: IridiaGlass.soft, icon: .white,
                       prominent: Color(red: 0.61, green: 0.55, blue: 1.0),
                       onProminent: Color(red: 0.07, green: 0.04, blue: 0.20),
                       selection: Color(red: 0.40, green: 0.33, blue: 0.92), onSelection: .white,
                       glassTint: Color(red: 0.31, green: 0.24, blue: 0.75).opacity(0.22),
                       solid: Color(red: 0.15, green: 0.11, blue: 0.36))
    case .wii:
      return HomeTheme(ink: WiiTheme.ink, soft: WiiTheme.soft, icon: WiiTheme.accent,
                       prominent: WiiTheme.accent, onProminent: WiiTheme.onAccent,
                       selection: WiiTheme.selection, onSelection: WiiTheme.onAccent,
                       glassTint: dynamic(UIColor(white: 1, alpha: 0.45), UIColor(white: 1, alpha: 0.06)),
                       solid: dynamic(UIColor(white: 0.985, alpha: 1), UIColor(white: 0.17, alpha: 1)))
    case .wiiU:
      #if canImport(IridiaCafeCore)
      return HomeTheme(ink: WiiUTheme.ink, soft: WiiUTheme.soft, icon: WiiUTheme.accent,
                       prominent: WiiUTheme.accent, onProminent: WiiUTheme.onAccent,
                       selection: WiiUTheme.accent, onSelection: WiiUTheme.onAccent,
                       glassTint: dynamic(UIColor(white: 1, alpha: 0.45), UIColor(white: 1, alpha: 0.06)),
                       solid: dynamic(UIColor(red: 0.99, green: 0.995, blue: 1, alpha: 1),
                                      UIColor(red: 0.08, green: 0.12, blue: 0.21, alpha: 1)))
      #else
      return of(.wii)
      #endif
    }
  }
}

enum HomeMetrics {
  static func headerHeight(_ u: CGFloat) -> CGFloat { 52 * u }
  static func tabBarHeight(_ u: CGFloat) -> CGFloat { 78 * u }
  static let landscapeColumn: CGFloat = 380
}

/// The three shelves stacked in one place. Each stays alive once shown, so switching back shows its art and
/// scroll position as they were; the header and tab bar are drawn once on top and never reload.
struct IridiaHomeView<GameCube: View, Wii: View, WiiU: View>: View {
  @ViewBuilder let gameCube: () -> GameCube
  @ViewBuilder let wii: () -> Wii
  @ViewBuilder let wiiU: () -> WiiU

  @ObservedObject private var router = HomeRouter.shared
  @State private var shown: Set<HomeSystem> = []
  @State private var screen = CGSize.zero
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  private var u: CGFloat { isLandscapePhone ? 1 : ShelfScale.value(screen, regular: horizontalSizeClass == .regular) }

  var body: some View {
    ZStack {
      ForEach(HomeSystem.available) { system in
        stage(system).opacity(router.system == system ? 1 : 0)
      }
      Group {
        if shown.contains(.gameCube) { layer(.gameCube, gameCube()) }
        if shown.contains(.wii) { layer(.wii, wii()) }
        if shown.contains(.wiiU) { layer(.wiiU, wiiU()) }
        HomeChrome(u: u, isLandscapePhone: isLandscapePhone)
      }
      .scaleEffect(router.curtain && !reduceMotion ? 1.06 : 1)
      Color.black
        .ignoresSafeArea()
        .opacity(router.curtain ? 1 : 0)
        .allowsHitTesting(router.curtain)
    }
    .toolbar(.hidden, for: .navigationBar)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
    .onAppear {
      shown.insert(router.system)
      router.homeCovered = false
      router.lift()
    }
    .onDisappear { router.homeCovered = true }
    .onChange(of: router.system) { _, system in shown.insert(system) }
  }

  @ViewBuilder private func stage(_ system: HomeSystem) -> some View {
    switch system {
    case .gameCube: IridiaGlass.stage
    case .wii: WiiTheme.stage
    case .wiiU:
      #if canImport(IridiaCafeCore)
      WiiUTheme.stage
      #endif
    }
  }

  private func layer(_ system: HomeSystem, _ content: some View) -> some View {
    let active = router.system == system
    let slide = reduceMotion ? 0 : CGFloat(system.rawValue - router.system.rawValue) * 28
    return content
      .opacity(active ? 1 : 0)
      .offset(x: slide)
      .allowsHitTesting(active)
      .accessibilityHidden(!active)
  }
}

private struct HomeChrome: View {
  let u: CGFloat
  let isLandscapePhone: Bool

  @ObservedObject private var router = HomeRouter.shared
  @ObservedObject private var store = IridiaUnlock.store
  @AppStorage("downloadsFolderName") private var downloadsName: String?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ScaledMetric(relativeTo: .caption2) private var textScale: CGFloat = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var glass
  @State private var drag: TabDrag?
  /// The button a drag began on also gets a tap when the finger lifts near it; a drag's release isn't a tap.
  @State private var ignoreTapsUntil = Date.distantPast
  @State private var tabFrames: [Int: CGRect] = [:]

  private var system: HomeSystem { router.system }
  private var theme: HomeTheme { .of(system) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Spacer(minLength: 0)
      HStack {
        if isLandscapePhone { Spacer(minLength: 0) }
        tabBar
          .frame(maxWidth: isLandscapePhone ? HomeMetrics.landscapeColumn : 480 * u)
      }
    }
  }

  private var title: String {
    switch system {
    case .gameCube: return "Iridia"
    case .wii: return L("Wii")
    case .wiiU: return L("Wii U (Experimental)")
    }
  }

  private var canAddGames: Bool {
    #if canImport(IridiaCafeCore)
    if system == .wiiU { return WiiUModel.canRunGames }
    #endif
    return true
  }

  private var header: some View {
    HStack(spacing: 8 * u) {
      ZStack {
        IridiaCube.mark.resizable().scaledToFit().opacity(system == .gameCube ? 1 : 0)
        WiiMark(size: 38 * u).opacity(system == .wii ? 1 : 0)
        #if canImport(IridiaCafeCore)
        WiiUMark(size: 38 * u).opacity(system == .wiiU ? 1 : 0)
        #endif
      }
      .frame(width: 40 * u, height: 40 * u)
      .accessibilityHidden(true)
      Text(title)
        .font(.system(size: (system == .wiiU ? 22 : 24) * u, weight: .semibold))
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.opacity)
        .layoutPriority(1)
      Spacer(minLength: 4)
      GlassEffectContainer(spacing: 8 * u) {
        HStack(spacing: 8 * u) {
          if !IridiaUnlock.isUnlocked {
            Button { router.send(.unlock) } label: {
              Text(L("Unlock"))
                .font(.system(size: 14 * u, weight: .bold))
                .foregroundStyle(theme.onProminent)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14 * u)
                .frame(height: 36 * u)
                .homeGlass(theme.prominent.opacity(0.9), solid: theme.prominent, in: Capsule(), reduce: reduceTransparency)
                .glassEffectID("unlock", in: glass)
            }
            .buttonStyle(SpringPressStyle())
            .accessibilityLabel(L("Unlock Full Version"))
          }
          if canAddGames {
            Menu { addMenu } label: { circleIcon("plus", id: "add") }
              .accessibilityLabel(L("Add a game"))
          }
          Button { router.send(.settings) } label: { circleIcon("slider.horizontal.3", id: "settings") }
            .buttonStyle(SpringPressStyle())
            .accessibilityLabel(L("Settings"))
        }
      }
    }
    .padding(.horizontal, 20 * u)
    .padding(.top, 8 * u)
    .frame(height: HomeMetrics.headerHeight(u), alignment: .bottom)
  }

  private func circleIcon(_ symbol: String, id: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 17 * u, weight: .semibold))
      .foregroundStyle(theme.icon)
      .frame(width: 44 * u, height: 44 * u)
      .homeGlass(theme.glassTint, solid: theme.solid, in: Circle(), reduce: reduceTransparency)
      .glassEffectID(id, in: glass)
  }

  @ViewBuilder private var addMenu: some View {
    Button { router.send(.chooseFile) } label: { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
    Button { router.send(.filesGuide) } label: { Label(L("Add with the Files App"), systemImage: "folder") }
    if let name = downloadsName {
      Button { router.send(.checkDownloads) } label: {
        Label(String(format: L("Check %@ Now"), name), systemImage: "arrow.down.circle")
      }
      if system != .wiiU {
        Button { router.send(.stopDownloads) } label: {
          Label(String(format: L("Stop Checking %@"), name), systemImage: "xmark.circle")
        }
      }
    } else {
      Button { router.send(.chooseDownloads) } label: {
        Label(L("Check Downloads for Games"), systemImage: "arrow.down.circle")
      }
    }
  }

  private var extraTabs: [(title: String, symbol: String, action: HomeAction)] {
    system == .wiiU
      ? [(L("Controllers"), "gamecontroller", .controllers), (L("Help"), "questionmark.circle", .help)]
      : [(L("Saves"), "square.stack.3d.up", .saves), (L("Controllers"), "gamecontroller", .controllers)]
  }

  /// A press on the selected tab that is being dragged along the bar.
  private struct TabDrag {
    let began: Date
    var x: CGFloat
    var lifted = false
    /// The tab under the finger, by frame key; nil above or below the bar.
    var hover: Int?
    var onBar = true
  }

  private static let barSpace = "homeTabBar"

  /// The tab drawn as selected: while a lifted pill is dragged, the one under the finger, if any.
  private var highlighted: Int? {
    guard let drag, drag.lifted else { return system.rawValue }
    return drag.hover
  }

  private var tabBar: some View {
    HStack(spacing: 2 * u) {
      ForEach(HomeSystem.available) { item in
        let selected = item.rawValue == highlighted
        tab(systemTitle(item), selected: selected, frameKey: item.rawValue) {
          SystemIcon(system: item, bold: selected, size: iconSize)
        } action: { router.select(item) }
      }
      ForEach(extraTabs.indices, id: \.self) { slot in
        let extra = extraTabs[slot]
        tab(extra.title, selected: highlighted == 10 + slot, frameKey: 10 + slot) {
          Image(systemName: extra.symbol)
            .font(.system(size: iconSize * 0.8, weight: .semibold))
            .frame(width: iconSize, height: iconSize)
        } action: { router.send(extra.action) }
      }
    }
    // One pill behind every tab, so it never slides over an icon.
    .background { if !reduceMotion { movingPill } }
    .coordinateSpace(.named(Self.barSpace))
    .simultaneousGesture(pillDrag)
    .sensoryFeedback(.selection, trigger: drag?.lifted == true ? drag?.hover : nil) { _, new in
      new != nil && IridiaHaptics.enabled
    }
    .padding(6 * u)
    .homeGlass(theme.glassTint, solid: theme.solid, in: RoundedRectangle(cornerRadius: 30 * u, style: .continuous),
               reduce: reduceTransparency)
    .padding(.horizontal, 20 * u)
    .padding(.bottom, 8 * u)
  }

  private func systemTitle(_ system: HomeSystem) -> String {
    switch system {
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .wiiU: return L("Wii U")
    }
  }

  private var iconSize: CGFloat { min(24 * u * textScale, 30 * u) }

  /// Sits on the selected tab, and while held stays under the finger anywhere along the bar. It glides only
  /// when let go; above or below the bar it drops back to its normal size, since letting go there cancels.
  @ViewBuilder private var movingPill: some View {
    if let home = tabFrames[system.rawValue] {
      let lifted = drag?.lifted == true
      let x = lifted ? fingerPillX(width: home.width) : home.midX
      selectionPill
        .frame(width: home.width, height: home.height)
        .scaleEffect(lifted && drag?.onBar == true ? 1.12 : 1)
        .position(x: x, y: home.midY)
        .animation(lifted ? nil : HomeRouter.switchAnimation, value: x)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lifted && drag?.onBar == true)
    }
  }

  private func fingerPillX(width: CGFloat) -> CGFloat {
    let frames = tabFrames.values
    guard let x = drag?.x, let lo = frames.map(\.minX).min(), let hi = frames.map(\.maxX).max() else { return 0 }
    return min(max(x, lo + width / 2), hi - width / 2)
  }

  private func isOnBar(_ point: CGPoint) -> Bool {
    guard let f = tabFrames[system.rawValue] else { return false }
    return point.y >= f.minY - 44 * u && point.y <= f.maxY + 44 * u
  }

  private func tabKey(at point: CGPoint) -> Int? {
    guard isOnBar(point) else { return nil }
    return tabFrames.first { point.x >= $0.value.minX && point.x <= $0.value.maxX }?.key
  }

  /// Press on the pill, hold or move, and drag along the bar; letting go over a tab picks it.
  private var pillDrag: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barSpace))
      .onChanged { value in
        if drag == nil {
          guard let home = tabFrames[system.rawValue], home.contains(value.startLocation) else { return }
          let began = Date()
          drag = TabDrag(began: began, x: value.location.x, hover: system.rawValue)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if drag?.began == began { drag?.lifted = true }
          }
        }
        guard var current = drag else { return }
        current.x = value.location.x
        if abs(value.translation.width) > 6 { current.lifted = true }
        current.hover = tabKey(at: value.location)
        current.onBar = isOnBar(value.location)
        drag = current
      }
      .onEnded { value in
        let lifted = drag?.lifted == true
        let target = lifted ? tabKey(at: value.location) : nil
        if lifted { ignoreTapsUntil = Date().addingTimeInterval(0.3) }
        drag = nil
        guard let target else { return }
        if let picked = HomeSystem(rawValue: target), HomeSystem.available.contains(picked) {
          if picked != system { router.select(picked) }
        } else if (10..<10 + extraTabs.count).contains(target) {
          router.send(extraTabs[target - 10].action)
        }
      }
  }

  private func tab<Icon: View>(_ title: String, selected: Bool, frameKey: Int?, @ViewBuilder icon: () -> Icon,
                               action: @escaping () -> Void) -> some View {
    Button {
      guard drag?.lifted != true, Date() > ignoreTapsUntil else { return }
      action()
    } label: {
      VStack(spacing: 3 * u) {
        icon()
          .foregroundStyle(selected ? theme.onSelection : (system == .gameCube ? theme.soft : theme.ink))
        Text(title)
          .font(.system(size: min(11 * u * textScale, 15 * u), weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .contentTransition(.opacity)
      }
      .foregroundStyle(selected ? theme.onSelection : theme.soft)
      .frame(maxWidth: .infinity, minHeight: 48 * u)
      .background {
        if selected && reduceMotion { selectionPill.transition(.opacity) }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.barSpace)) } action: { frame in
        if let frameKey { tabFrames[frameKey] = frame }
      }
      .contentShape(selectionShape)
    }
    .buttonStyle(SpringPressStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var selectionShape: RoundedRectangle { RoundedRectangle(cornerRadius: 24 * u, style: .continuous) }

  @ViewBuilder private var selectionPill: some View {
    if reduceTransparency {
      selectionShape.fill(theme.selection)
    } else {
      selectionShape.fill(.clear).glassEffect(.regular.tint(theme.selection), in: selectionShape)
        .overlay(selectionShape.strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }
  }
}

extension View {
  /// Liquid Glass, or a plain fill when Reduce Transparency is on.
  @ViewBuilder func homeGlass<S: Shape>(_ tint: Color, solid: Color, in shape: S, reduce: Bool) -> some View {
    if reduce {
      background(shape.fill(solid))
    } else {
      glassEffect(.regular.tint(tint).interactive(), in: shape)
    }
  }
}
#endif
