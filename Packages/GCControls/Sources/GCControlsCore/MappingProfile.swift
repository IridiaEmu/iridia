// SPDX-License-Identifier: GPL-2.0-or-later
//
// Physical-controller → GameCube mapping with Smart Mapping:
//   per-game override  →  family custom profile  →  smart default (By position / By label)
// Profiles compile to a flat table so the controller handler path does no lookups.

import Foundation

/// Physical elements, named by position (GameController's convention: buttonA = south).
public enum PhysicalElement: Int, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case buttonSouth, buttonEast, buttonWest, buttonNorth
  case leftShoulder, rightShoulder, leftTrigger, rightTrigger
  case dpadUp, dpadDown, dpadLeft, dpadRight
  case leftStick, rightStick, leftStickButton, rightStickButton
  case buttonMenu, buttonOptions, buttonHome

  public static let count = allCases.count

  public var isStick: Bool { self == .leftStick || self == .rightStick }
  public var isAnalogTrigger: Bool { self == .leftTrigger || self == .rightTrigger }
  public var isFaceButton: Bool { rawValue <= PhysicalElement.buttonNorth.rawValue }

  public var name: String {
    switch self {
    case .buttonSouth: "Bottom face button"
    case .buttonEast: "Right face button"
    case .buttonWest: "Left face button"
    case .buttonNorth: "Top face button"
    case .leftShoulder: "Left shoulder"
    case .rightShoulder: "Right shoulder"
    case .leftTrigger: "Left trigger"
    case .rightTrigger: "Right trigger"
    case .dpadUp: "D-pad up"
    case .dpadDown: "D-pad down"
    case .dpadLeft: "D-pad left"
    case .dpadRight: "D-pad right"
    case .leftStick: "Left stick"
    case .rightStick: "Right stick"
    case .leftStickButton: "Left stick click"
    case .rightStickButton: "Right stick click"
    case .buttonMenu: "Menu / Start / +"
    case .buttonOptions: "Options / View / −"
    case .buttonHome: "Home"
    }
  }
}

/// What a physical element drives.
public enum GCTarget: String, Codable, Sendable, CaseIterable {
  case none
  case a, b, x, y, z, start
  case dpadUp, dpadDown, dpadLeft, dpadRight
  case l, r  // analog when the source is analog, else full press
  case mainStick, cStick  // stick sources
  case appMenu  // opens the app's menu (pause)

  public var button: GCButtons? {
    switch self {
    case .a: .a
    case .b: .b
    case .x: .x
    case .y: .y
    case .z: .z
    case .start: .start
    case .dpadUp: .dpadUp
    case .dpadDown: .dpadDown
    case .dpadLeft: .dpadLeft
    case .dpadRight: .dpadRight
    default: nil
    }
  }

  public var displayName: String {
    switch self {
    case .none: "—"
    case .a: "A"
    case .b: "B"
    case .x: "X"
    case .y: "Y"
    case .z: "Z"
    case .start: "Start"
    case .dpadUp: "D-pad ↑"
    case .dpadDown: "D-pad ↓"
    case .dpadLeft: "D-pad ←"
    case .dpadRight: "D-pad →"
    case .l: "L"
    case .r: "R"
    case .mainStick: "Main stick"
    case .cStick: "C-stick"
    case .appMenu: "App Menu"
    }
  }
}

public enum ControllerFamily: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case xbox, dualSense, dualShock, switchPro, joyConPair, joyConSingle, backbone, mfi, generic

  public var displayName: String {
    switch self {
    case .xbox: "Xbox controller"
    case .dualSense: "DualSense"
    case .dualShock: "DualShock 4"
    case .switchPro: "Switch Pro Controller"
    case .joyConPair: "Joy-Con (pair)"
    case .joyConSingle: "Joy-Con"
    case .backbone: "Backbone"
    case .mfi: "MFi controller"
    case .generic: "Controller"
    }
  }

  /// Nintendo layout: printed A is on the right (east), B on the bottom.
  public var hasNintendoLabels: Bool { self == .switchPro || self == .joyConPair || self == .joyConSingle }
  public var hasLetterLabels: Bool { self != .dualSense && self != .dualShock }

  /// - Parameters: `productCategory`/`vendorName` from GCController; capabilities from its profile.
  public static func detect(
    productCategory: String, vendorName: String?, hasRightStick: Bool, hasAnalogTriggers: Bool
  ) -> ControllerFamily {
    let s = (productCategory + " " + (vendorName ?? "")).lowercased()
    if s.contains("xbox") { return .xbox }
    if s.contains("dualsense") { return .dualSense }
    if s.contains("dualshock") || s.contains("playstation") { return .dualShock }
    if s.contains("joy-con") || s.contains("joycon") {
      // A Joy-Con pair (L+R) exposes two sticks; a single sideways one has one.
      return hasRightStick ? .joyConPair : .joyConSingle
    }
    if s.contains("switch pro") || s.contains("pro controller") { return .switchPro }
    if s.contains("backbone") { return .backbone }
    if s.contains("mfi") || s.contains("extended gamepad") { return .mfi }
    _ = hasAnalogTriggers
    return .generic
  }
}

public enum MappingStyle: String, Codable, Sendable, CaseIterable {
  case byPosition, byLabel
  public var displayName: String { self == .byPosition ? "By position" : "By label" }
}

/// Which physical face button carries each printed letter. Built at connect time from
/// GameController element names, so "By label" is right even if a vendor reports
/// elements unusually. Nil when the controller has no letters (PlayStation).
public struct FaceLabels: Sendable, Equatable, Codable {
  public var a: PhysicalElement, b: PhysicalElement, x: PhysicalElement, y: PhysicalElement
  public init(a: PhysicalElement, b: PhysicalElement, x: PhysicalElement, y: PhysicalElement) {
    self.a = a; self.b = b; self.x = x; self.y = y
  }
  public static let xbox = FaceLabels(a: .buttonSouth, b: .buttonEast, x: .buttonWest, y: .buttonNorth)
  public static let nintendo = FaceLabels(a: .buttonEast, b: .buttonSouth, x: .buttonNorth, y: .buttonWest)

  /// Build from element display letters (e.g. ["A": .buttonEast, …]). Needs all four.
  public static func from(letters: [String: PhysicalElement]) -> FaceLabels? {
    guard let a = letters["A"], let b = letters["B"], let x = letters["X"], let y = letters["Y"],
      Set([a, b, x, y]).count == 4
    else { return nil }
    return FaceLabels(a: a, b: b, x: x, y: y)
  }
}

public struct MappingProfile: Codable, Sendable, Equatable {
  public var bindings: [PhysicalElement: GCTarget]
  public var style: MappingStyle
  /// True once the user has edited it; false for an unmodified smart default.
  public var isCustom: Bool
  public var stick: AnalogSettings
  /// Analog trigger value at which L/R's digital click registers.
  public var triggerClickThreshold: Double

  public init(
    bindings: [PhysicalElement: GCTarget], style: MappingStyle = .byPosition, isCustom: Bool = false,
    stick: AnalogSettings = .physicalDefault, triggerClickThreshold: Double = 0.92
  ) {
    self.bindings = bindings; self.style = style; self.isCustom = isCustom
    self.stick = stick; self.triggerClickThreshold = triggerClickThreshold
  }

  public func target(for e: PhysicalElement) -> GCTarget { bindings[e] ?? .none }

  public func compiled() -> CompiledMapping { CompiledMapping(self) }
}

public enum SmartMapping {
  /// The smart default for a family and style. `labels` overrides the family's
  /// assumed letter layout when the controller reported its own.
  /// Returns the profile and the style actually applied (By label falls back to
  /// By position on controllers without letters).
  public static func profile(
    for family: ControllerFamily, style: MappingStyle, labels: FaceLabels? = nil
  ) -> (profile: MappingProfile, appliedStyle: MappingStyle) {
    var b: [PhysicalElement: GCTarget] = [
      .leftStick: .mainStick, .rightStick: .cStick,
      .dpadUp: .dpadUp, .dpadDown: .dpadDown, .dpadLeft: .dpadLeft, .dpadRight: .dpadRight,
      .leftTrigger: .l, .rightTrigger: .r,
      .rightShoulder: .z, .leftShoulder: .none,
      .buttonMenu: .start, .buttonOptions: .appMenu, .buttonHome: .appMenu,
      .leftStickButton: .none, .rightStickButton: .none,
    ]

    var applied = style
    let letterLayout = labels ?? (family.hasLetterLabels ? (family.hasNintendoLabels ? .nintendo : .xbox) : nil)
    if style == .byLabel, let L = letterLayout {
      b[L.a] = .a; b[L.b] = .b; b[L.x] = .x; b[L.y] = .y
    } else {
      // GameCube cluster: A center (main), B lower-left, X right, Y top.
      b[.buttonSouth] = .a; b[.buttonWest] = .b; b[.buttonEast] = .x; b[.buttonNorth] = .y
      applied = .byPosition
    }

    switch family {
    case .joyConSingle:
      // Sideways Joy-Con: one stick, no analog triggers, SL/SR arrive as shoulders.
      b[.leftShoulder] = .l; b[.rightShoulder] = .r
      b[.leftTrigger] = .z; b[.rightTrigger] = .z
      b[.rightStick] = GCTarget.none
    case .joyConPair, .switchPro:
      // Digital ZL/ZR: still L/R (full press); R shoulder stays Z.
      break
    default: break
    }
    return (MappingProfile(bindings: b, style: applied), applied)
  }
}

/// Flat, allocation-free form of a profile for the controller handler queue.
public struct CompiledMapping: Sendable {
  public let targets: [GCTarget]  // indexed by PhysicalElement.rawValue
  public let stick: AnalogSettings
  public let triggerClickThreshold: Double

  public init(_ p: MappingProfile) {
    var t = [GCTarget](repeating: .none, count: PhysicalElement.count)
    for (e, g) in p.bindings { t[e.rawValue] = g }
    targets = t
    stick = p.stick
    triggerClickThreshold = p.triggerClickThreshold
  }
}

/// One raw read of a controller, in fixed-size storage.
public struct PhysicalSnapshot: Sendable {
  /// 0…1 per element (buttons/triggers); stick slots unused here.
  public var values = [Double](repeating: 0, count: PhysicalElement.count)
  public var leftStick: (x: Double, y: Double) = (0, 0)
  public var rightStick: (x: Double, y: Double) = (0, 0)
  public init() {}

  @inline(__always) public subscript(_ e: PhysicalElement) -> Double {
    get { values[e.rawValue] }
    set { values[e.rawValue] = newValue }
  }
}

public enum PhysicalMapper {
  /// Snapshot → pad state. Returns whether an App Menu binding is held.
  @inline(__always)
  public static func map(_ s: PhysicalSnapshot, _ m: CompiledMapping) -> (state: PadState, appMenu: Bool) {
    var st = PadState.neutral
    var menu = false
    var l = 0.0, r = 0.0

    for i in 0..<PhysicalElement.count {
      let target = m.targets[i]
      if target == .none || target == .mainStick || target == .cStick { continue }
      let value = s.values[i]
      if value <= 0 { continue }
      let isAnalog = i == PhysicalElement.leftTrigger.rawValue || i == PhysicalElement.rightTrigger.rawValue
      switch target {
      case .appMenu: if value > 0.5 { menu = true }
      case .l: l = max(l, isAnalog ? value : (value > 0.5 ? 1 : 0))
      case .r: r = max(r, isAnalog ? value : (value > 0.5 ? 1 : 0))
      default: if value > 0.5, let bit = target.button { st.buttons.insert(bit) }
      }
    }

    @inline(__always) func applyStick(_ target: GCTarget, _ v: (x: Double, y: Double)) {
      guard target != .none else { return }
      let s = AnalogMath.shape(x: v.x, y: v.y, m.stick)
      switch target {
      case .mainStick: st.stickX = AnalogMath.axisByte(s.x); st.stickY = AnalogMath.axisByte(s.y)
      case .cStick: st.cStickX = AnalogMath.axisByte(s.x); st.cStickY = AnalogMath.axisByte(s.y)
      case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
        st.buttons.formUnion(AnalogMath.dpad(x: s.x, y: s.y, deadRadius: 0.5))
      default: break
      }
    }
    applyStick(m.targets[PhysicalElement.leftStick.rawValue], s.leftStick)
    applyStick(m.targets[PhysicalElement.rightStick.rawValue], s.rightStick)

    st.triggerL = AnalogMath.triggerByte(l)
    st.triggerR = AnalogMath.triggerByte(r)
    if l >= m.triggerClickThreshold { st.buttons.insert(.l) }
    if r >= m.triggerClickThreshold { st.buttons.insert(.r) }
    return (st, menu)
  }
}

/// Persistence. Files: "<family>.json" (custom profile), "<family>@<game>.json"
/// (per-game override), and "styles.json" (chosen smart style per family).
public final class MappingProfileStore: @unchecked Sendable {
  private let directory: URL
  private let lock = NSLock()
  private var cache: [String: MappingProfile] = [:]
  private var styles: [ControllerFamily: MappingStyle]

  public init(directory: URL) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    styles = (try? Data(contentsOf: directory.appendingPathComponent("styles.json")))
      .flatMap { try? JSONDecoder().decode([ControllerFamily: MappingStyle].self, from: $0) } ?? [:]
  }

  public static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ControllerMappings", isDirectory: true)
  }

  private static func key(_ f: ControllerFamily, _ game: String?) -> String {
    guard let game, !game.isEmpty else { return f.rawValue }
    let safe = game.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return "\(f.rawValue)@\(safe)"
  }

  public func style(for f: ControllerFamily) -> MappingStyle {
    lock.lock(); defer { lock.unlock() }
    return styles[f] ?? .byPosition
  }

  public func setStyle(_ s: MappingStyle, for f: ControllerFamily) {
    lock.lock(); defer { lock.unlock() }
    styles[f] = s
    if let d = try? JSONEncoder().encode(styles) {
      try? d.write(to: directory.appendingPathComponent("styles.json"), options: .atomic)
    }
  }

  public enum Source: Sendable, Equatable { case gameOverride, custom, smart(MappingStyle) }

  /// Resolution order: per-game override → custom family profile → smart default.
  public func resolve(
    family: ControllerFamily, gameID: String?, labels: FaceLabels? = nil
  ) -> (profile: MappingProfile, source: Source) {
    if let game = gameID, let p = load(key: Self.key(family, game)) { return (p, .gameOverride) }
    if let p = load(key: Self.key(family, nil)) { return (p, .custom) }
    let smart = SmartMapping.profile(for: family, style: style(for: family), labels: labels)
    return (smart.profile, .smart(smart.appliedStyle))
  }

  /// Saving marks the profile custom so it's used automatically next time.
  public func save(_ p: MappingProfile, family: ControllerFamily, gameID: String? = nil) {
    var p = p
    p.isCustom = true
    let k = Self.key(family, gameID)
    lock.lock(); defer { lock.unlock() }
    cache[k] = p
    if let data = try? JSONEncoder().encode(p) {
      try? data.write(to: directory.appendingPathComponent("\(k).json"), options: .atomic)
    }
  }

  /// "Reset to smart defaults": drop the custom (or per-game) profile.
  public func reset(family: ControllerFamily, gameID: String? = nil) {
    let k = Self.key(family, gameID)
    lock.lock(); defer { lock.unlock() }
    cache[k] = nil
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(k).json"))
  }

  public func hasGameOverride(family: ControllerFamily, gameID: String) -> Bool {
    load(key: Self.key(family, gameID)) != nil
  }

  private func load(key k: String) -> MappingProfile? {
    lock.lock(); defer { lock.unlock() }
    if let p = cache[k] { return p }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(k).json")),
      let p = try? JSONDecoder().decode(MappingProfile.self, from: data)
    else { return nil }
    cache[k] = p
    return p
  }
}
