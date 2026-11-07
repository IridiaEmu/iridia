// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: how the Wii U TV and GamePad pictures are shown. Four layouts (TV only, TV + GamePad, GamePad full
// screen, Split) plus Swap screens, saved per game. WiiUScreenLayout works out where each picture goes; each
// Metal view is given exactly its picture's aspect ratio, so GamePad touch is just (point - origin) / size.

#if os(iOS)
import CoreGraphics
import Foundation

enum WiiUScreen { case tv, gamePad }

enum WiiULayoutMode: String, CaseIterable, Identifiable {
  case tvOnly, pip, gamePad, split
  var id: String { rawValue }

  var label: String {
    switch self {
    case .tvOnly: return L("TV only")
    case .pip: return L("TV + GamePad")
    case .gamePad: return L("GamePad full screen")
    case .split: return L("Split")
    }
  }

  /// Split needs room for two pictures: iPad, or iPhone held upright.
  static func splitOffered(isPad: Bool, portrait: Bool) -> Bool { isPad || portrait }

  /// What the tap on the layout button does: the next layout, skipping Split where it isn't offered.
  func next(isPad: Bool, portrait: Bool) -> WiiULayoutMode {
    let all = Self.allCases
    var i = all.firstIndex(of: self)!
    repeat {
      i = (i + 1) % all.count
    } while all[i] == .split && !Self.splitOffered(isPad: isPad, portrait: portrait)
    return all[i]
  }
}

/// Where a small window sits: the four corners, or the middle of the top or bottom edge.
enum WiiUWindowAnchor: String, CaseIterable {
  case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
}

/// How the on-screen buttons behave while the GamePad picture fills the screen.
enum WiiUControlsStyle: String, CaseIterable {
  case normal, edges, hidden
  var label: String {
    switch self {
    case .normal: return L("Normal")
    case .edges: return L("Small, at the edges")
    case .hidden: return L("Hidden")
    }
  }
}

/// One game's screen settings, saved under its title ID.
struct WiiUScreenPrefs: Codable, Equatable {
  var mode: String = WiiULayoutMode.tvOnly.rawValue
  var swap = false
  var windowAnchor: String = WiiUWindowAnchor.topCenter.rawValue
  /// Small window width as a share of the screen width (0.2 ... 0.5).
  var windowScale: Double = 0.3
  var windowHidden = false
  /// GamePad full screen: also show the TV picture as a small window.
  var tvWindowInGamePad = false
  var controls: String = WiiUControlsStyle.normal.rawValue
  var motion = true

  var layout: WiiULayoutMode {
    get { WiiULayoutMode(rawValue: mode) ?? .tvOnly }
    set { mode = newValue.rawValue }
  }
  var anchor: WiiUWindowAnchor {
    get { WiiUWindowAnchor(rawValue: windowAnchor) ?? .topCenter }
    set { windowAnchor = newValue.rawValue }
  }
  var controlsStyle: WiiUControlsStyle {
    get { WiiUControlsStyle(rawValue: controls) ?? .normal }
    set { controls = newValue.rawValue }
  }

  static let windowScaleRange = 0.2...0.5

  /// Games played mainly on the GamePad start in GamePad full screen.
  static let gamePadFirstTitles: Set<UInt64> = [
    0x0005_0000_101A_BC00,   // Kirby and the Rainbow Curse
  ]

  private static func key(_ titleKey: String) -> String { "cafeScreens.\(titleKey)" }

  /// The saved settings, or the defaults for a game with nothing saved yet.
  static func load(_ titleKey: String, titleId: UInt64, defaults d: UserDefaults = .standard) -> WiiUScreenPrefs {
    if let data = d.data(forKey: key(titleKey)), let p = try? JSONDecoder().decode(WiiUScreenPrefs.self, from: data) { return p }
    var p = WiiUScreenPrefs()
    if gamePadFirstTitles.contains(titleId) {
      p.layout = .gamePad
    } else if let saved = d.string(forKey: "cafeDefaultLayout"), let mode = WiiULayoutMode(rawValue: saved) {
      p.layout = mode
    } else {
      // the earlier global "GamePad screen" setting becomes the default
      switch d.string(forKey: "cafeGamePadScreen") {
      case "main": p.layout = .gamePad
      case "window": p.layout = .pip
      default: break
      }
    }
    return p
  }

  func save(_ titleKey: String, defaults d: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key(titleKey)) }
  }
}

#if canImport(IridiaCafeCore)
extension WiiUGame {
  /// Key for per-game settings: the title ID (the same for the disc, the installed copy and its update), or the
  /// file path for homebrew.
  var settingsKey: String { title.titleId != 0 ? String(format: "%016llX", title.titleId) : id }
}
#endif

/// Where everything goes on screen for one layout.
struct WiiUScreenLayout: Equatable {
  /// The main Metal view (always present: the game draws into it) and what it shows.
  var main: CGRect
  var mainShows: WiiUScreen
  /// The second Metal view, if two pictures are shown.
  var second: CGRect?
  var secondShows: WiiUScreen
  /// True if the second picture is a small window (drag, resize, hide, tap to enlarge).
  var secondIsWindow: Bool
  /// The layout actually shown (Split falls back to TV + GamePad on an iPhone held sideways).
  var shown: WiiULayoutMode
  /// Portrait: the bottom of the pictures (the touch controls use the space below).
  var picturesBottom: CGFloat
  /// The top bar (layout button, speed, pause): its frame, kept off every GamePad picture.
  var topBar: CGRect

  /// The GamePad picture's frame, if it is on screen.
  var gamePad: CGRect? {
    if mainShows == .gamePad { return main }
    if secondShows == .gamePad { return second }
    return nil
  }

  static let tvAspect: CGFloat = 16.0 / 9.0
  static let gamePadAspect: CGFloat = 854.0 / 480.0
  static let barHeight: CGFloat = 52
  static let gap: CGFloat = 8
  static let margin: CGFloat = 10

  static func aspect(_ s: WiiUScreen) -> CGFloat { s == .tv ? tvAspect : gamePadAspect }

  /// The largest rect of `aspect` that fits in `box`, centred.
  static func fit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
    guard box.width > 0, box.height > 0 else { return .zero }
    var w = box.width, h = w / aspect
    if h > box.height { h = box.height; w = h * aspect }
    return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h).integral(keepingSize: true)
  }

  /// `expanded`: the small GamePad window is shown large for precise touch.
  static func compute(prefs: WiiUScreenPrefs, size: CGSize, safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat),
                      isPad: Bool, expanded: Bool = false) -> WiiUScreenLayout {
    let portrait = size.height > size.width
    var mode = prefs.layout
    if mode == .split && !WiiULayoutMode.splitOffered(isPad: isPad, portrait: portrait) { mode = .pip }

    // Big and small picture for each layout (Swap exchanges them).
    let first: WiiUScreen = prefs.swap ? .gamePad : .tv, other: WiiUScreen = prefs.swap ? .tv : .gamePad
    let big: WiiUScreen, small: WiiUScreen?
    switch mode {
    case .tvOnly: big = .tv; small = nil   // one picture: nothing to swap
    case .pip: big = first; small = prefs.windowHidden ? nil : other
    case .gamePad: big = other; small = prefs.tvWindowInGamePad && !prefs.windowHidden ? first : nil
    case .split: big = first; small = other
    }

    // The top bar: beside the Dynamic Island / notch on iPhones held upright, otherwise at the top of the safe area.
    let side = max(safe.left, safe.right)
    let barY: CGFloat = portrait && safe.top >= barHeight ? safe.top - barHeight + 2 : safe.top
    let topBar = CGRect(x: side, y: barY, width: size.width - side * 2, height: barHeight)

    // The area the pictures share. Landscape: the full height (bars beside the picture), inside the side safe
    // areas. Portrait: below the top bar.
    let picTop = portrait ? max(safe.top, topBar.maxY) : 0
    var stage = CGRect(x: side, y: picTop, width: size.width - side * 2,
                       height: size.height - picTop - (portrait ? safe.bottom : 0))
    // a GamePad picture never sits under the top bar (the layout and pause buttons) or the home indicator
    if !portrait {
      let below = CGRect(x: stage.minX, y: topBar.maxY, width: stage.width, height: size.height - topBar.maxY - safe.bottom)
      if mode == .split {
        stage = below
      } else if big == .gamePad {
        let bars = size.height - fit(aspect(big), in: stage).height
        if bars / 2 < max(topBar.maxY, safe.bottom) { stage = below }
      }
    }

    var main: CGRect, second: CGRect? = nil, secondIsWindow = false
    var bottom: CGFloat
    if mode == .split, let small {
      if portrait {
        // one above the other at full width, from the top
        let w = stage.width
        var top = CGRect(x: stage.minX, y: stage.minY, width: w, height: w / aspect(big))
        var low = CGRect(x: stage.minX, y: top.maxY + gap, width: w, height: w / aspect(small))
        let need = low.maxY - stage.minY, have = stage.height * (isPad ? 0.8 : 0.62)
        if need > have {   // leave room for the touch controls below
          let k = have / need
          top = fit(aspect(big), in: CGRect(x: stage.minX, y: stage.minY, width: w, height: top.height * k))
          low = fit(aspect(small), in: CGRect(x: stage.minX, y: top.maxY + gap, width: w, height: low.height * k))
        }
        main = top.integral(keepingSize: true); second = low.integral(keepingSize: true)
      } else {
        let h = (stage.height - gap) / 2
        let top = fit(aspect(big), in: CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: h))
        let low = fit(aspect(small), in: CGRect(x: stage.minX, y: stage.minY + h + gap, width: stage.width, height: h))
        // close the gap between the two pictures
        let pair = top.height + gap + low.height, y0 = stage.midY - pair / 2
        main = CGRect(x: top.minX, y: y0, width: top.width, height: top.height)
        second = CGRect(x: low.minX, y: y0 + top.height + gap, width: low.width, height: low.height)
      }
      bottom = second!.maxY
    } else {
      if portrait {
        let w = stage.width
        main = CGRect(x: stage.minX, y: stage.minY, width: w, height: (w / aspect(big)).rounded())
      } else {
        main = fit(aspect(big), in: stage)
      }
      bottom = main.maxY
      if let small {
        secondIsWindow = true
        second = window(for: small, prefs: prefs, size: size, safe: safe, topBar: topBar, picture: main,
                        portrait: portrait, expanded: expanded)
      }
    }
    return WiiUScreenLayout(main: main, mainShows: big, second: second, secondShows: small ?? .gamePad,
                            secondIsWindow: secondIsWindow, shown: mode, picturesBottom: bottom, topBar: topBar)
  }

  /// The small window: at its anchor, inside the safe area and below the top bar. Portrait: over the picture.
  static func window(for screen: WiiUScreen, prefs: WiiUScreenPrefs, size: CGSize,
                     safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat), topBar: CGRect,
                     picture: CGRect, portrait: Bool, expanded: Bool) -> CGRect {
    let side = max(safe.left, safe.right)
    let area: CGRect = portrait
      ? picture
      : CGRect(x: side, y: topBar.maxY, width: size.width - side * 2, height: size.height - topBar.maxY - max(safe.bottom, margin))
    if expanded {
      return fit(aspect(screen), in: area.insetBy(dx: area.width * 0.06, dy: margin))
    }
    let r = WiiUScreenPrefs.windowScaleRange
    let scale = min(max(prefs.windowScale, r.lowerBound), r.upperBound)
    var w = (portrait ? picture.width * max(scale, 0.3) : size.width * scale).rounded()
    var h = (w / aspect(screen)).rounded()
    let maxH = area.height * (portrait ? 0.6 : 0.9)
    if h > maxH { h = maxH.rounded(); w = (h * aspect(screen)).rounded() }
    let m = portrait ? 6 : margin
    let x: CGFloat, y: CGFloat
    switch prefs.anchor {
    case .topLeft, .bottomLeft: x = area.minX + m
    case .topRight, .bottomRight: x = area.maxX - m - w
    case .topCenter, .bottomCenter: x = area.midX - w / 2
    }
    switch prefs.anchor {
    case .topLeft, .topCenter, .topRight: y = area.minY + m
    default: y = area.maxY - m - h
    }
    return CGRect(x: x, y: y, width: w, height: h).integral(keepingSize: true)
  }

  /// The anchor nearest to a point (for snapping a dragged window).
  static func nearestAnchor(to p: CGPoint, in size: CGSize) -> WiiUWindowAnchor {
    let col = p.x < size.width / 3 ? 0 : (p.x < size.width * 2 / 3 ? 1 : 2)
    let top = p.y < size.height / 2
    switch (col, top) {
    case (0, true): return .topLeft
    case (1, true): return .topCenter
    case (2, true): return .topRight
    case (0, false): return .bottomLeft
    case (1, false): return .bottomCenter
    default: return .bottomRight
    }
  }

  /// A point in a GamePad picture of `size` -> the GamePad touch screen, 0..1 (clamped to the edge).
  static func touch(_ p: CGPoint, in size: CGSize) -> CGPoint {
    guard size.width > 0, size.height > 0 else { return .zero }
    return CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
  }
}

private extension CGRect {
  /// Whole points for the origin, size kept (so a picture keeps its exact aspect ratio).
  func integral(keepingSize: Bool) -> CGRect {
    CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width.rounded(), height: height.rounded())
  }
}

/// The controller shortcut, written out for the pause menu.
enum WiiUShortcut {
  static var text: String { L("Hold Menu and press L to change the layout, or R to swap screens.") }
}

/// The controller shortcut: hold Menu (the GamePad's +) and press L (next layout) or R (swap screens). While
/// Menu is held, L and R go to the app instead of the game. Menu itself is held back for 0.3 s to see whether
/// L or R follows; a quick press on its own still reaches the game as a short + press, a longer hold as a hold.
struct WiiUShortcutFilter {
  enum Fired: Equatable { case nextLayout, swap }
  static let plus: UInt32 = 0x0008, l: UInt32 = 0x0020, r: UInt32 = 0x0010
  static let wait: TimeInterval = 0.3

  private var menuDownAt: Date?
  private var used = false
  private var lastShoulders: UInt32 = 0
  private var held: UInt32 = 0          // L/R kept from the game until released after a shortcut
  private var plusTapUntil: Date?

  /// The controller's buttons (VPAD bits) -> what the game gets, and the shortcuts pressed just now.
  mutating func filter(_ pad: UInt32, now: Date) -> (UInt32, [Fired]) {
    let plus = Self.plus, l = Self.l, r = Self.r
    var out = pad, fired: [Fired] = []
    let shoulders = pad & (l | r)
    if pad & plus != 0 {
      if menuDownAt == nil { menuDownAt = now; used = false }
      let pressed = shoulders & ~lastShoulders
      if pressed & l != 0 { used = true; fired.append(.nextLayout) }
      if pressed & r != 0 { used = true; fired.append(.swap) }
      if used {
        out &= ~(plus | l | r)
        held |= shoulders
      } else if now.timeIntervalSince(menuDownAt!) < Self.wait {
        out &= ~plus
      }
    } else if let down = menuDownAt {
      // released quickly without a shortcut: send the + press now, as a short tap
      if !used && now.timeIntervalSince(down) < Self.wait { plusTapUntil = now.addingTimeInterval(0.08) }
      menuDownAt = nil
    }
    held &= shoulders
    out &= ~held
    if let until = plusTapUntil {
      if now < until { out |= plus } else { plusTapUntil = nil }
    }
    lastShoulders = shoulders
    return (out, fired)
  }
}
#endif
