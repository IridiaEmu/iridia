// SPDX-License-Identifier: GPL-2.0-or-later
//
// GameController integration with Smart Mapping.
// - Detects the controller family on connect and resolves its mapping
//   (per-game override → custom profile → smart default).
// - Value changes run on a per-controller serial queue (never main): read a
//   fixed-size snapshot, map through the precompiled table, publish one atomic word.
// - Extras: DualSense adaptive triggers, rumble passthrough, theme light color.

#if canImport(UIKit)
import CoreHaptics
import GameController
import GCControlsCore
import Observation
import Synchronization
import UIKit

public struct ConnectedController: Identifiable, Equatable, Sendable {
  public let id: ObjectIdentifier
  public let player: Int
  public let family: ControllerFamily
  public let name: String
  public var mappingSource: MappingProfileStore.Source
  public var style: MappingStyle
  /// By label was requested but the controller has no letters.
  public var labelFallback: Bool
  public var labels: FaceLabels?
  public var supportsAdaptiveTriggers: Bool
  public var supportsRumble: Bool
}

/// Lives on the controller's handler queue. Holds reusable buffers so the
/// value-changed path allocates nothing.
private final class InputContext: @unchecked Sendable {
  let queue: DispatchQueue
  let player: Int
  var mapping: CompiledMapping
  var snapshot = PhysicalSnapshot()
  var lastMenu = false
  /// Bitmask of held physical elements, for the mapping screen's live highlight.
  let held = Atomic<UInt32>(0)

  init(queue: DispatchQueue, player: Int, mapping: CompiledMapping) {
    self.queue = queue; self.player = player; self.mapping = mapping
  }
}

@MainActor
@Observable
public final class PhysicalControllerManager {
  public private(set) var controllers: [ConnectedController] = []

  /// Called on main when a controller connects (for the toast).
  @ObservationIgnored public var onConnect: ((ConnectedController) -> Void)?
  /// Called on main when a controller disconnects; `remaining` is how many are left.
  @ObservationIgnored public var onDisconnect: ((ConnectedController, _ remaining: Int) -> Void)?
  /// Called on main when a bound App Menu button is pressed.
  @ObservationIgnored public var onAppMenu: ((Int) -> Void)?

  /// Current game, for per-game mapping overrides. Re-resolves every controller.
  public var gameID: String? { didSet { if oldValue != gameID { reresolveAll() } } }

  @ObservationIgnored public let profiles: MappingProfileStore
  @ObservationIgnored private let store: PadStateStore
  @ObservationIgnored private var gc: [ObjectIdentifier: GCController] = [:]
  @ObservationIgnored private var contexts: [ObjectIdentifier: InputContext] = [:]
  @ObservationIgnored private var rumble: [Int: RumbleChannel] = [:]
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  /// Theme light color for controllers with a light bar (indigo).
  @ObservationIgnored public var lightColor = GCColor(red: 0.42, green: 0.32, blue: 1.0)

  public init(profiles: MappingProfileStore = MappingProfileStore(directory: MappingProfileStore.defaultDirectory()),
              store: PadStateStore = .shared) {
    self.profiles = profiles
    self.store = store
  }

  public func start() {
    guard observers.isEmpty else { return }
    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
      guard let c = n.object as? GCController else { return }
      MainActor.assumeIsolated { self?.connect(c) }
    })
    observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
      guard let c = n.object as? GCController else { return }
      MainActor.assumeIsolated { self?.disconnect(c) }
    })
    GCController.shouldMonitorBackgroundEvents = false
    for c in GCController.controllers() { connect(c) }
  }

  public func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    for c in Array(gc.values) { disconnect(c, notify: false) }
  }

  // MARK: Connect / disconnect

  private func connect(_ c: GCController) {
    let id = ObjectIdentifier(c)
    guard gc[id] == nil, let pad = c.extendedGamepad else { return }  // ignore Siri Remote etc.
    guard let player = (0..<PadStateStore.playerCount).first(where: { p in !controllers.contains { $0.player == p } }) else { return }

    let profile = c.physicalInputProfile
    let family = ControllerFamily.detect(
      productCategory: c.productCategory, vendorName: c.vendorName,
      hasRightStick: profile.dpads[GCInputRightThumbstick] != nil,
      hasAnalogTriggers: pad.leftTrigger.isAnalog)
    let labels = Self.readFaceLabels(pad)
    let requested = profiles.style(for: family)
    let resolved = profiles.resolve(family: family, gameID: gameID, labels: labels)
    let applied: MappingStyle = { if case .smart(let s) = resolved.source { return s }; return resolved.profile.style }()

    let queue = DispatchQueue(label: "gc.input.p\(player + 1)", qos: .userInteractive)
    let ctx = InputContext(queue: queue, player: player, mapping: resolved.profile.compiled())
    c.handlerQueue = queue
    c.playerIndex = GCControllerPlayerIndex(rawValue: player) ?? .indexUnset
    let store = self.store
    pad.valueChangedHandler = { [weak self] gamepad, _ in
      // On `queue`.
      Self.read(gamepad, into: &ctx.snapshot)
      ctx.held.store(Self.heldMask(ctx.snapshot), ordering: .relaxed)
      let (state, menu) = PhysicalMapper.map(ctx.snapshot, ctx.mapping)
      store.publish(state, player: ctx.player, source: .physical)
      if menu && !ctx.lastMenu {
        DispatchQueue.main.async { self?.onAppMenu?(ctx.player) }
      }
      ctx.lastMenu = menu
    }

    let isDualSense = pad is GCDualSenseGamepad
    let info = ConnectedController(
      id: id, player: player, family: family,
      name: c.vendorName ?? family.displayName,
      mappingSource: resolved.source, style: applied,
      labelFallback: requested == .byLabel && applied == .byPosition && resolved.source != .custom,
      labels: labels,
      supportsAdaptiveTriggers: isDualSense,
      supportsRumble: c.haptics != nil)

    gc[id] = c
    contexts[id] = ctx
    controllers.append(info)
    controllers.sort { $0.player < $1.player }
    applyExtras(c, family: family)
    if c.haptics != nil { rumble[player] = RumbleChannel(controller: c) }
    onConnect?(info)
  }

  private func disconnect(_ c: GCController, notify: Bool = true) {
    let id = ObjectIdentifier(c)
    guard let info = controllers.first(where: { $0.id == id }) else { return }
    c.extendedGamepad?.valueChangedHandler = nil
    gc[id] = nil
    contexts[id] = nil
    rumble[info.player]?.stop()
    rumble[info.player] = nil
    controllers.removeAll { $0.id == id }
    store.clear(player: info.player, source: .physical)
    if notify { onDisconnect?(info, controllers.count) }
  }

  // MARK: Mapping changes

  /// Re-resolve and hot-swap the compiled table on the controller's own queue.
  public func reresolve(_ controllerID: ObjectIdentifier) {
    guard let i = controllers.firstIndex(where: { $0.id == controllerID }), let ctx = contexts[controllerID] else { return }
    let info = controllers[i]
    let requested = profiles.style(for: info.family)
    let resolved = profiles.resolve(family: info.family, gameID: gameID, labels: info.labels)
    let applied: MappingStyle = { if case .smart(let s) = resolved.source { return s }; return resolved.profile.style }()
    controllers[i].mappingSource = resolved.source
    controllers[i].style = applied
    controllers[i].labelFallback = requested == .byLabel && applied == .byPosition && resolved.source != .custom
    let compiled = resolved.profile.compiled()
    ctx.queue.async { ctx.mapping = compiled }
  }

  public func reresolveAll() { for c in controllers { reresolve(c.id) } }

  public func profile(for controllerID: ObjectIdentifier) -> MappingProfile? {
    guard let info = controllers.first(where: { $0.id == controllerID }) else { return nil }
    return profiles.resolve(family: info.family, gameID: gameID, labels: info.labels).profile
  }

  public func setStyle(_ style: MappingStyle, for controllerID: ObjectIdentifier) {
    guard let info = controllers.first(where: { $0.id == controllerID }) else { return }
    profiles.setStyle(style, for: info.family)
    reresolveAll()  // other controllers of the same family follow
  }

  /// Saves as the family's custom profile (or per-game when `forGame`) and applies it.
  public func saveEdited(_ p: MappingProfile, for controllerID: ObjectIdentifier, forGame: Bool) {
    guard let info = controllers.first(where: { $0.id == controllerID }) else { return }
    profiles.save(p, family: info.family, gameID: forGame ? gameID : nil)
    reresolveAll()
  }

  public func resetToSmartDefaults(for controllerID: ObjectIdentifier, includingGame: Bool) {
    guard let info = controllers.first(where: { $0.id == controllerID }) else { return }
    profiles.reset(family: info.family)
    if includingGame, let g = gameID { profiles.reset(family: info.family, gameID: g) }
    reresolveAll()
  }

  /// Held physical elements (bit = PhysicalElement.rawValue). Lock-free; poll from UI.
  public func heldElements(for controllerID: ObjectIdentifier) -> UInt32 {
    contexts[controllerID]?.held.load(ordering: .relaxed) ?? 0
  }

  public func controller(_ id: ObjectIdentifier) -> GCController? { gc[id] }

  // MARK: Rumble (called by the emulation core; any thread)

  public nonisolated func setRumble(player: Int, intensity: Float) {
    Task { @MainActor in self.rumble[player]?.set(intensity: intensity) }
  }

  // MARK: Reading

  nonisolated private static func read(_ g: GCExtendedGamepad, into s: inout PhysicalSnapshot) {
    s[.buttonSouth] = Double(g.buttonA.value)
    s[.buttonEast] = Double(g.buttonB.value)
    s[.buttonWest] = Double(g.buttonX.value)
    s[.buttonNorth] = Double(g.buttonY.value)
    s[.leftShoulder] = Double(g.leftShoulder.value)
    s[.rightShoulder] = Double(g.rightShoulder.value)
    s[.leftTrigger] = Double(g.leftTrigger.value)
    s[.rightTrigger] = Double(g.rightTrigger.value)
    s[.dpadUp] = Double(g.dpad.up.value)
    s[.dpadDown] = Double(g.dpad.down.value)
    s[.dpadLeft] = Double(g.dpad.left.value)
    s[.dpadRight] = Double(g.dpad.right.value)
    s[.leftStickButton] = Double(g.leftThumbstickButton?.value ?? 0)
    s[.rightStickButton] = Double(g.rightThumbstickButton?.value ?? 0)
    s[.buttonMenu] = Double(g.buttonMenu.value)
    s[.buttonOptions] = Double(g.buttonOptions?.value ?? 0)
    s[.buttonHome] = Double(g.buttonHome?.value ?? 0)
    s.leftStick = (Double(g.leftThumbstick.xAxis.value), Double(g.leftThumbstick.yAxis.value))
    s.rightStick = (Double(g.rightThumbstick.xAxis.value), Double(g.rightThumbstick.yAxis.value))
  }

  nonisolated private static func heldMask(_ s: PhysicalSnapshot) -> UInt32 {
    var m: UInt32 = 0
    for e in PhysicalElement.allCases where s[e] > 0.5 { m |= 1 << UInt32(e.rawValue) }
    let l = s.leftStick, r = s.rightStick
    if l.x * l.x + l.y * l.y > 0.25 { m |= 1 << UInt32(PhysicalElement.leftStick.rawValue) }
    if r.x * r.x + r.y * r.y > 0.25 { m |= 1 << UInt32(PhysicalElement.rightStick.rawValue) }
    return m
  }

  /// Letters printed on the face buttons, from GameController's element symbols
  /// ("a.circle", …) or names. Nil for controllers without letters.
  private static func readFaceLabels(_ g: GCExtendedGamepad) -> FaceLabels? {
    func letter(_ e: GCControllerButtonInput) -> String? {
      let candidates = [e.sfSymbolsName, e.unmappedSfSymbolsName, e.localizedName, e.unmappedLocalizedName].compactMap { $0 }
      for c in candidates {
        let head = c.split(whereSeparator: { $0 == "." || $0 == " " }).first.map(String.init)?.uppercased() ?? ""
        if ["A", "B", "X", "Y"].contains(head) { return head }
      }
      return nil
    }
    var letters: [String: PhysicalElement] = [:]
    for (e, pos) in [(g.buttonA, PhysicalElement.buttonSouth), (g.buttonB, .buttonEast), (g.buttonX, .buttonWest), (g.buttonY, .buttonNorth)] {
      if let l = letter(e) { letters[l] = pos }
    }
    return FaceLabels.from(letters: letters)
  }

  // MARK: Extras

  private func applyExtras(_ c: GCController, family: ControllerFamily) {
    c.light?.color = lightColor
    if let ds = c.extendedGamepad as? GCDualSenseGamepad {
      // Resistance ramps toward the digital-click point so L/R feel analog.
      for t in [ds.leftTrigger, ds.rightTrigger] {
        t.setModeSlopeFeedback(startPosition: 0.15, endPosition: 0.9, startStrength: 0.1, endStrength: 0.55)
      }
    }
  }
}

/// One continuous haptic player per controller, intensity updated in place.
@MainActor
private final class RumbleChannel {
  private var engine: CHHapticEngine?
  private var player: CHHapticAdvancedPatternPlayer?
  private var running = false

  init(controller: GCController) {
    engine = controller.haptics?.createEngine(withLocality: .default)
    engine?.isAutoShutdownEnabled = true
  }

  func set(intensity: Float) {
    guard let engine else { return }
    let v = min(max(intensity, 0), 1)
    if v == 0 { stop(); return }
    do {
      if player == nil {
        try engine.start()
        let ev = CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                       CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)],
          relativeTime: 0, duration: 30)
        player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
        player?.loopEnabled = true
      }
      try player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: 0)
      if !running { try player?.start(atTime: 0); running = true }
    } catch {
      stop()
    }
  }

  func stop() {
    try? player?.stop(atTime: 0)
    running = false
  }
}
#endif
