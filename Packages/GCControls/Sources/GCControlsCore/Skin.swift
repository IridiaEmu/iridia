// SPDX-License-Identifier: GPL-2.0-or-later
//
// Controller skin format (.gcskin): a single JSON file. See docs/SKIN_FORMAT.md.

import Foundation

public struct SkinSize: Codable, Sendable, Equatable {
  public var width: Double
  public var height: Double
  public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct SkinRect: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
  public var midX: Double { x + width / 2 }
  public var midY: Double { y + height / 2 }
}

/// What an item does when touched.
public enum SkinInput: String, Codable, Sendable, CaseIterable {
  case a, b, x, y, z, start
  case dpad, mainStick, cStick
  case l, r
  case menu  // app menu; not a GameCube input
  case logo  // decoration only

  public var button: GCButtons? {
    switch self {
    case .a: .a
    case .b: .b
    case .x: .x
    case .y: .y
    case .z: .z
    case .start: .start
    default: nil
    }
  }

  /// Inputs every skin must provide so all GameCube controls are reachable.
  public static let required: [SkinInput] = [.a, .b, .x, .y, .z, .start, .dpad, .mainStick, .cStick, .l, .r, .menu]
}

public enum SkinShape: String, Codable, Sendable {
  case circle, pill, roundedRect, dpad, stick, logo
}

public struct SkinItem: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var input: SkinInput
  public var shape: SkinShape
  /// In the layout's mapping-size coordinate space (points, origin top-left).
  public var frame: SkinRect
  /// Palette role name (e.g. "buttonA") or "#RRGGBB".
  public var color: String?
  public var label: String?
  /// Extra touch slop around the frame, in mapping points. Default 8.
  public var hitInset: Double?
  /// Optional image names from `ControllerSkin.images`; replace the drawn art.
  public var image: String?
  public var pressedImage: String?

  public init(
    id: String, input: SkinInput, shape: SkinShape, frame: SkinRect,
    color: String? = nil, label: String? = nil, hitInset: Double? = nil,
    image: String? = nil, pressedImage: String? = nil
  ) {
    self.id = id; self.input = input; self.shape = shape; self.frame = frame
    self.color = color; self.label = label; self.hitInset = hitInset
    self.image = image; self.pressedImage = pressedImage
  }
}

public struct SkinLayout: Codable, Sendable, Equatable {
  public var mappingSize: SkinSize
  public var items: [SkinItem]
  /// 0…1 opacity of the whole controller. Portrait default 1, landscape overlay ~0.4.
  public var defaultOpacity: Double
  /// Draw the glass background panel (portrait). Landscape overlays leave it off.
  public var showsBackground: Bool
  public var backgroundImage: String?

  public init(
    mappingSize: SkinSize, items: [SkinItem], defaultOpacity: Double,
    showsBackground: Bool, backgroundImage: String? = nil
  ) {
    self.mappingSize = mappingSize; self.items = items
    self.defaultOpacity = defaultOpacity; self.showsBackground = showsBackground
    self.backgroundImage = backgroundImage
  }
}

public struct SkinPalette: Codable, Sendable, Equatable {
  public var backgroundTop: String
  public var backgroundBottom: String
  public var glassHighlight: String
  public var stickBase: String
  public var neutral: String
  public var label: String
  public var buttonA: String
  public var buttonB: String
  public var buttonZ: String
  public var cStick: String
  public var accent: String

  /// Resolve a role name or literal hex to a hex string.
  public func resolve(_ role: String?) -> String {
    guard let role else { return neutral }
    if role.hasPrefix("#") { return role }
    switch role {
    case "backgroundTop": return backgroundTop
    case "backgroundBottom": return backgroundBottom
    case "glassHighlight": return glassHighlight
    case "stickBase": return stickBase
    case "label": return label
    case "buttonA": return buttonA
    case "buttonB": return buttonB
    case "buttonZ": return buttonZ
    case "cStick": return cStick
    case "accent": return accent
    default: return neutral
    }
  }
}

public enum SkinOrientation: String, Codable, Sendable, CaseIterable {
  case portrait, landscape
}

public struct ControllerSkin: Codable, Sendable, Equatable, Identifiable {
  public static let currentFormatVersion = 1
  public static let fileExtension = "gcskin"

  public var formatVersion: Int
  public var identifier: String
  public var name: String
  public var author: String?
  public var palette: SkinPalette
  public var portrait: SkinLayout
  public var landscape: SkinLayout
  /// Optional embedded PNGs, base64-encoded, referenced by name from items.
  public var images: [String: Data]?

  public var id: String { identifier }

  public func layout(_ o: SkinOrientation) -> SkinLayout {
    o == .portrait ? portrait : landscape
  }
}

public enum SkinError: Error, Equatable, CustomStringConvertible {
  case unsupportedVersion(Int)
  case missingInputs(SkinOrientation, [SkinInput])
  case duplicateItemID(String)
  case invalidFrame(String)
  case missingImage(String)
  case tooLarge

  public var description: String {
    switch self {
    case .unsupportedVersion(let v): "This skin uses format version \(v), which this app doesn't support yet."
    case .missingInputs(let o, let i): "The \(o.rawValue) layout is missing: \(i.map(\.rawValue).joined(separator: ", "))."
    case .duplicateItemID(let id): "Two items share the id “\(id)”."
    case .invalidFrame(let id): "Item “\(id)” has an invalid frame."
    case .missingImage(let n): "Image “\(n)” is referenced but not included."
    case .tooLarge: "Skin file is too large (limit 20 MB)."
    }
  }
}

extension ControllerSkin {
  public static let maxFileSize = 20 * 1024 * 1024

  public static func decode(_ data: Data) throws -> ControllerSkin {
    guard data.count <= maxFileSize else { throw SkinError.tooLarge }
    let skin = try JSONDecoder().decode(ControllerSkin.self, from: data)
    try skin.validate()
    return skin
  }

  public func encoded() throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try e.encode(self)
  }

  public func validate() throws {
    guard formatVersion <= Self.currentFormatVersion, formatVersion >= 1 else {
      throw SkinError.unsupportedVersion(formatVersion)
    }
    for o in SkinOrientation.allCases {
      let l = layout(o)
      var seen = Set<String>()
      for item in l.items {
        guard seen.insert(item.id).inserted else { throw SkinError.duplicateItemID(item.id) }
        let f = item.frame
        guard f.width > 0, f.height > 0, f.x.isFinite, f.y.isFinite,
          f.x + f.width <= l.mappingSize.width * 1.05, f.y + f.height <= l.mappingSize.height * 1.05
        else { throw SkinError.invalidFrame(item.id) }
        for name in [item.image, item.pressedImage].compactMap({ $0 }) where images?[name] == nil {
          throw SkinError.missingImage(name)
        }
      }
      let present = Set(l.items.map(\.input))
      let missing = SkinInput.required.filter { !present.contains($0) }
      if !missing.isEmpty { throw SkinError.missingInputs(o, missing) }
    }
  }
}
