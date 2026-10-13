// SPDX-License-Identifier: GPL-2.0-or-later
//
// Chip generation and performance tier from the device's model identifier (`utsname.machine`,
// e.g. "iPhone17,1"). Every iPhone iOS 26 supports is an iPhone11-era (A13) model or newer.

public enum Chip: Equatable, Sendable, CustomStringConvertible {
  /// Apple A-series by generation number (13 = A13 Bionic, 18 = A18/A18 Pro, …).
  case a(Int, pro: Bool)
  /// Apple M-series by generation number.
  case m(Int)
  /// Running in the Simulator or on a Mac (Apple silicon).
  case host
  case unknown

  public var description: String {
    switch self {
    case .a(let n, let pro): "A\(n)\(pro ? " Pro" : "")"
    case .m(let n): "M\(n)"
    case .host: "Mac/Simulator"
    case .unknown: "unknown"
    }
  }
}

/// Performance tiers used to pick defaults. Ordered from slowest to fastest.
public enum DeviceTier: Int, Comparable, Sendable, CaseIterable, Codable {
  /// A12–A14 (A12/A12X iPads, iPhone 11, SE 2, iPhone 12). JIT-less GameCube is tough here: native resolution,
  /// cheapest shader mode, speed hacks on.
  case entry = 0
  /// A15–A16 (iPhone 13/14/15, SE 3).
  case mid = 1
  /// A17 Pro, A18, M1–M2 (iPhone 15 Pro, iPhone 16 family, older M iPads).
  case high = 2
  /// A19 and newer, M3 and newer.
  case ultra = 3

  public static func < (l: DeviceTier, r: DeviceTier) -> Bool { l.rawValue < r.rawValue }

  public var displayName: String {
    switch self {
    case .entry: "Entry"
    case .mid: "Mid"
    case .high: "High"
    case .ultra: "Ultra"
    }
  }
}

public struct DeviceInfo: Equatable, Sendable {
  public let model: String
  public let chip: Chip
  public let tier: DeviceTier

  public init(model: String) {
    self.model = model
    chip = Self.chip(for: model)
    tier = Self.tier(for: chip)
  }

  // iPads whose identifiers don't follow a simple rule. Anything not listed falls back to .mid.
  private static let iPadChips: [String: Chip] = [
    // M1
    "iPad13,4": .m(1), "iPad13,5": .m(1), "iPad13,6": .m(1), "iPad13,7": .m(1),
    "iPad13,8": .m(1), "iPad13,9": .m(1), "iPad13,10": .m(1), "iPad13,11": .m(1),
    "iPad13,16": .m(1), "iPad13,17": .m(1),
    // M2
    "iPad14,3": .m(2), "iPad14,4": .m(2), "iPad14,5": .m(2), "iPad14,6": .m(2),
    "iPad14,8": .m(2), "iPad14,9": .m(2), "iPad14,10": .m(2), "iPad14,11": .m(2),
    // M3 (iPad Air 2025)
    "iPad15,3": .m(3), "iPad15,4": .m(3), "iPad15,5": .m(3), "iPad15,6": .m(3),
    // M4 (iPad Pro 2024)
    "iPad16,3": .m(4), "iPad16,4": .m(4), "iPad16,5": .m(4), "iPad16,6": .m(4),
    // A-series iPads
    // A12X / A12Z (iPad Pro 2018 and 2020: still on iPadOS 26), A12 (Air 3, mini 5, iPad 8), A13 (iPad 9)
    "iPad8,1": .a(12, pro: true), "iPad8,2": .a(12, pro: true), "iPad8,3": .a(12, pro: true),
    "iPad8,4": .a(12, pro: true), "iPad8,5": .a(12, pro: true), "iPad8,6": .a(12, pro: true),
    "iPad8,7": .a(12, pro: true), "iPad8,8": .a(12, pro: true), "iPad8,9": .a(12, pro: true),
    "iPad8,10": .a(12, pro: true), "iPad8,11": .a(12, pro: true), "iPad8,12": .a(12, pro: true),
    "iPad11,1": .a(12, pro: false), "iPad11,2": .a(12, pro: false), "iPad11,3": .a(12, pro: false),
    "iPad11,4": .a(12, pro: false), "iPad11,6": .a(12, pro: false), "iPad11,7": .a(12, pro: false),
    "iPad12,1": .a(13, pro: false), "iPad12,2": .a(13, pro: false),
    "iPad13,1": .a(14, pro: false), "iPad13,2": .a(14, pro: false),  // Air 4
    "iPad13,18": .a(14, pro: false), "iPad13,19": .a(14, pro: false),  // iPad 10
    "iPad14,1": .a(15, pro: false), "iPad14,2": .a(15, pro: false),  // mini 6
    "iPad15,7": .a(16, pro: false), "iPad15,8": .a(16, pro: false),  // iPad 11
    "iPad16,1": .a(17, pro: true), "iPad16,2": .a(17, pro: true),  // mini 7
  ]

  static func chip(for model: String) -> Chip {
    if model == "arm64" || model == "x86_64" || model.hasPrefix("Mac") { return .host }
    if let c = iPadChips[model] { return c }
    guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
      let comma = model.firstIndex(of: ","),
      let major = Int(model[model.index(model.startIndex, offsetBy: model.hasPrefix("iPhone") ? 6 : 4)..<comma]),
      let minor = Int(model[model.index(after: comma)...])
    else { return .unknown }

    if model.hasPrefix("iPad") {
      // Unlisted iPads: newer than the table means M4 or later; older is unknown.
      return major > 16 ? .m(5) : .unknown
    }

    // iPhones from the iPhone 11 (iPhone12,x) on: chip generation = major + 1.
    guard major >= 12 else { return .a(major + 1, pro: false) }
    let gen = major + 1
    let pro: Bool = switch major {
    case 16: true  // iPhone 15 Pro / Pro Max (A17 Pro)
    case 17: minor <= 2  // iPhone 16 Pro / Pro Max (A18 Pro)
    case 18: minor <= 2 || minor == 4  // iPhone 17 Pro / Pro Max and Air (A19 Pro)
    default: false
    }
    return .a(gen, pro: pro)
  }

  static func tier(for chip: Chip) -> DeviceTier {
    switch chip {
    case .host: .ultra
    case .unknown: .mid
    case .m(let n): n >= 3 ? .ultra : .high
    case .a(let n, let pro):
      switch n {
      case ...14: .entry
      case 15, 16: .mid
      case 17: pro ? .high : .mid
      case 18: .high
      default: .ultra
      }
    }
  }
}
