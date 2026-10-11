// SPDX-License-Identifier: GPL-2.0-or-later
//
// User edits from the on-screen controller editor, stored per skin and orientation.
// Kept separate from the skin so "Reset to default" is just deleting the overrides.

import Foundation

public struct ItemOverride: Codable, Sendable, Equatable {
  /// Offset of the item's center, in mapping points.
  public var dx: Double = 0
  public var dy: Double = 0
  /// Uniform scale around the item's center, 0.5…2.0.
  public var scale: Double = 1
  /// Per-item opacity, 0.1…1. Multiplied with the layout opacity.
  public var opacity: Double = 1

  public init(dx: Double = 0, dy: Double = 0, scale: Double = 1, opacity: Double = 1) {
    self.dx = dx; self.dy = dy; self.scale = scale; self.opacity = opacity
  }

  public var isIdentity: Bool { dx == 0 && dy == 0 && scale == 1 && opacity == 1 }
}

public struct LayoutOverrides: Codable, Sendable, Equatable {
  public var items: [String: ItemOverride] = [:]
  /// Whole-controller opacity; nil = the skin's default for this orientation.
  public var opacity: Double?

  public init(items: [String: ItemOverride] = [:], opacity: Double? = nil) {
    self.items = items; self.opacity = opacity
  }

  public var isEmpty: Bool { items.values.allSatisfy(\.isIdentity) && opacity == nil }

  /// The layout with these overrides applied.
  public func apply(to layout: SkinLayout) -> SkinLayout {
    var out = layout
    out.items = layout.items.map { item in
      guard let o = items[item.id], !o.isIdentity else { return item }
      var it = item
      let s = min(max(o.scale, 0.5), 2.0)
      let w = item.frame.width * s, h = item.frame.height * s
      it.frame = SkinRect(
        x: item.frame.midX + o.dx - w / 2, y: item.frame.midY + o.dy - h / 2, width: w, height: h)
      return it
    }
    if let opacity { out.defaultOpacity = min(max(opacity, 0.05), 1) }
    return out
  }

  public func itemOpacity(_ id: String) -> Double {
    min(max(items[id]?.opacity ?? 1, 0.1), 1)
  }
}

/// JSON-file persistence for overrides, keyed by skin + orientation.
public final class LayoutOverrideStore: @unchecked Sendable {
  private let directory: URL
  private let lock = NSLock()

  public init(directory: URL) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ControllerLayouts", isDirectory: true)
  }

  private func url(skin: String, orientation: SkinOrientation) -> URL {
    let safe = skin.replacingOccurrences(of: "/", with: "_")
    return directory.appendingPathComponent("\(safe).\(orientation.rawValue).json")
  }

  public func load(skin: String, orientation: SkinOrientation) -> LayoutOverrides {
    lock.lock(); defer { lock.unlock() }
    guard let data = try? Data(contentsOf: url(skin: skin, orientation: orientation)),
      let o = try? JSONDecoder().decode(LayoutOverrides.self, from: data)
    else { return LayoutOverrides() }
    return o
  }

  public func save(_ o: LayoutOverrides, skin: String, orientation: SkinOrientation) {
    lock.lock(); defer { lock.unlock() }
    let u = url(skin: skin, orientation: orientation)
    if o.isEmpty {
      try? FileManager.default.removeItem(at: u)
    } else if let data = try? JSONEncoder().encode(o) {
      try? data.write(to: u, options: .atomic)
    }
  }

  public func reset(skin: String, orientation: SkinOrientation) {
    save(LayoutOverrides(), skin: skin, orientation: orientation)
  }
}
