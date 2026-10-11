// SPDX-License-Identifier: GPL-2.0-or-later
//
// App-facing state for controls: which skin, whether the on-screen controller is
// shown, connect toasts, and the "controller disconnected → pause" rule.

#if canImport(UIKit)
import GCControlsCore
import Observation
import SwiftUI

public struct ControllerToast: Identifiable, Equatable {
  public let id = UUID()
  public let message: String
  public let controllerID: ObjectIdentifier?
}

@MainActor
@Observable
public final class ControllerSession {
  public let physical: PhysicalControllerManager
  public let skins: SkinLibrary
  @ObservationIgnored public let layoutStore: LayoutOverrideStore

  public var skin: ControllerSkin {
    didSet { UserDefaults.standard.set(skin.identifier, forKey: Keys.skin); reloadOverrides() }
  }
  public private(set) var overrides: [SkinOrientation: LayoutOverrides] = [:]
  public var settings = TouchControllerSettings() { didSet { saveSettings() } }

  /// nil = automatic (hidden while a physical controller is connected).
  public var manualOnScreenVisible: Bool?
  public private(set) var toast: ControllerToast?
  /// Set when the last physical controller disconnects; the host pauses the game
  /// and clears this when the user resumes.
  public var pausedForDisconnect = false

  /// Host hook: Menu button (on-screen or App Menu binding).
  @ObservationIgnored public var onMenu: (() -> Void)?
  /// Host hook: the connect toast was tapped (open that controller's mapping).
  @ObservationIgnored public var onToastTap: ((ControllerToast) -> Void)?

  public var isOnScreenControllerVisible: Bool {
    manualOnScreenVisible ?? physical.controllers.isEmpty
  }

  private enum Keys {
    static let skin = "gccontrols.skin"
    static let haptics = "gccontrols.haptics"
    static let digitalTriggers = "gccontrols.digitalTriggers"
    static let deadZone = "gccontrols.touchDeadZone"
    static let sensitivity = "gccontrols.touchSensitivity"
  }

  @ObservationIgnored private var toastTask: Task<Void, Never>?

  public init(
    physical: PhysicalControllerManager? = nil,
    skins: SkinLibrary? = nil,
    layoutStore: LayoutOverrideStore? = nil
  ) {
    let physical = physical ?? PhysicalControllerManager()
    let skins = skins ?? SkinLibrary()
    self.physical = physical
    self.skins = skins
    self.layoutStore = layoutStore ?? LayoutOverrideStore(directory: LayoutOverrideStore.defaultDirectory())
    let saved = UserDefaults.standard.string(forKey: Keys.skin)
    skin = skins.all.first { $0.identifier == saved } ?? BuiltinSkins.default
    let d = UserDefaults.standard
    if d.object(forKey: Keys.haptics) != nil { settings.hapticsEnabled = d.bool(forKey: Keys.haptics) }
    settings.digitalTriggers = d.bool(forKey: Keys.digitalTriggers)
    if d.object(forKey: Keys.deadZone) != nil { settings.stick.deadZone = d.double(forKey: Keys.deadZone) }
    if d.object(forKey: Keys.sensitivity) != nil { settings.stick.sensitivity = d.double(forKey: Keys.sensitivity) }
    reloadOverrides()

    physical.onConnect = { [weak self] c in self?.handleConnect(c) }
    physical.onDisconnect = { [weak self] c, remaining in self?.handleDisconnect(c, remaining: remaining) }
    physical.onAppMenu = { [weak self] _ in self?.onMenu?() }
  }

  public func start() { physical.start() }

  // MARK: Overrides

  public func overrides(for o: SkinOrientation) -> LayoutOverrides { overrides[o] ?? LayoutOverrides() }

  public func setOverrides(_ v: LayoutOverrides, for o: SkinOrientation) {
    overrides[o] = v
    layoutStore.save(v, skin: skin.identifier, orientation: o)
  }

  public func resetLayout(_ o: SkinOrientation) {
    layoutStore.reset(skin: skin.identifier, orientation: o)
    overrides[o] = LayoutOverrides()
  }

  private func reloadOverrides() {
    for o in SkinOrientation.allCases { overrides[o] = layoutStore.load(skin: skin.identifier, orientation: o) }
  }

  private func saveSettings() {
    let d = UserDefaults.standard
    d.set(settings.hapticsEnabled, forKey: Keys.haptics)
    d.set(settings.digitalTriggers, forKey: Keys.digitalTriggers)
    d.set(settings.stick.deadZone, forKey: Keys.deadZone)
    d.set(settings.stick.sensitivity, forKey: Keys.sensitivity)
  }

  // MARK: Visibility

  /// The Menu button's quick toggle.
  public func toggleOnScreenController() {
    manualOnScreenVisible = !isOnScreenControllerVisible
  }

  // MARK: Connect / disconnect

  private func handleConnect(_ c: ConnectedController) {
    manualOnScreenVisible = nil  // auto-hide
    pausedForDisconnect = false
    let mapping: String
    switch c.mappingSource {
    case .gameOverride: mapping = "Custom mapping for this game"
    case .custom: mapping = "Custom mapping"
    case .smart(let s):
      mapping = "Smart mapping: \(s.displayName)" + (c.labelFallback ? " (no letter labels)" : "")
    }
    showToast("\(c.family.displayName) connected — \(mapping)", controllerID: c.id)
  }

  private func handleDisconnect(_ c: ConnectedController, remaining: Int) {
    if remaining == 0 {
      manualOnScreenVisible = nil
      pausedForDisconnect = true
    }
    showToast("Player \(c.player + 1) controller disconnected", controllerID: nil)
  }

  public func showToast(_ message: String, controllerID: ObjectIdentifier?) {
    toast = ControllerToast(message: message, controllerID: controllerID)
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  public func dismissToast() { toast = nil }
}

/// Built-in skins plus user-imported .gcskin files (Application Support/Skins).
@MainActor
@Observable
public final class SkinLibrary {
  public private(set) var imported: [ControllerSkin] = []
  @ObservationIgnored private let directory: URL

  public var all: [ControllerSkin] { BuiltinSkins.all + imported }

  public init(directory: URL? = nil) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.directory = directory ?? base.appendingPathComponent("Skins", isDirectory: true)
    try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    reload()
  }

  public func reload() {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    imported = urls.filter { $0.pathExtension == ControllerSkin.fileExtension }
      .compactMap { try? ControllerSkin.decode(Data(contentsOf: $0)) }
      .filter { s in !BuiltinSkins.all.contains { $0.identifier == s.identifier } }
      .sorted { $0.name < $1.name }
  }

  /// Import from a Files-app URL. Validates before copying; replaces a skin with the same identifier.
  @discardableResult
  public func importSkin(from url: URL) throws -> ControllerSkin {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    let skin = try ControllerSkin.decode(data)
    guard !BuiltinSkins.all.contains(where: { $0.identifier == skin.identifier }) else {
      throw SkinError.duplicateItemID(skin.identifier)
    }
    let safe = skin.identifier.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    try data.write(to: directory.appendingPathComponent("\(safe).\(ControllerSkin.fileExtension)"), options: .atomic)
    reload()
    return skin
  }

  public func delete(_ skin: ControllerSkin) {
    let safe = skin.identifier.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(safe).\(ControllerSkin.fileExtension)"))
    reload()
  }
}
#endif
