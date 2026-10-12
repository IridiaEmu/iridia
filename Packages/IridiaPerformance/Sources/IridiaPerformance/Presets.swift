// SPDX-License-Identifier: GPL-2.0-or-later
//
// Performance presets: what the emulator settings should be for a device tier and power mode.
// Expressed as Dolphin config keys so the app can apply them through its existing config bridge
// (and so tests can check exactly what would be written).

/// A Dolphin config key: file (system), section and key, e.g. GFX / Settings / InternalResolution.
public struct EmulatorSetting: Hashable, Sendable, CustomStringConvertible {
  public enum System: String, Sendable { case main = "Main", gfx = "GFX" }
  public let system: System
  public let section: String
  public let key: String
  public init(_ system: System, _ section: String, _ key: String) {
    self.system = system; self.section = section; self.key = key
  }
  public var description: String { "\(system.rawValue)/\(section)/\(key)" }

  // The keys presets touch. Names are Dolphin's (Core/Config/GraphicsSettings.cpp, MainSettings.cpp).
  public static let internalResolution = EmulatorSetting(.gfx, "Settings", "InternalResolution")
  public static let shaderCompilationMode = EmulatorSetting(.gfx, "Settings", "ShaderCompilationMode")
  public static let maxAnisotropy = EmulatorSetting(.gfx, "Enhancements", "MaxAnisotropy")
  public static let msaa = EmulatorSetting(.gfx, "Settings", "MSAA")
  public static let viSkip = EmulatorSetting(.gfx, "Hacks", "VISkip")
  public static let efbAccess = EmulatorSetting(.gfx, "Hacks", "EFBAccessEnable")
  public static let boundingBox = EmulatorSetting(.gfx, "Hacks", "BBoxEnable")
  public static let textureCacheSamples = EmulatorSetting(.gfx, "Settings", "SafeTextureCacheColorSamples")
  public static let audioBufferSize = EmulatorSetting(.main, "Core", "AudioBufferSize")
  public static let cpuOverclockEnable = EmulatorSetting(.main, "Core", "OverclockEnable")
  public static let cpuOverclock = EmulatorSetting(.main, "Core", "Overclock")
}

/// Dolphin's ShaderCompilationMode values.
public enum ShaderMode: Int, Sendable, Codable {
  case synchronous = 0
  case synchronousUbershaders = 1
  /// Ubershaders while specialized shaders compile in the background: no stutter, more GPU work.
  case hybridUbershaders = 2
  /// Skip drawing until a shader is ready: cheapest, brief missing effects instead of stutter.
  case asyncSkipDrawing = 3
}

public enum PowerMode: String, Sendable, Codable, CaseIterable {
  /// Cooler and longer battery life: native resolution, minimal filtering.
  case batterySaver
  /// The tier's defaults.
  case balanced
  /// Speed first: native resolution, cheapest shader mode, frame skipping when behind.
  case maxPerformance

  public var displayName: String {
    switch self {
    case .batterySaver: "Battery Saver"
    case .balanced: "Balanced"
    case .maxPerformance: "Max Performance"
    }
  }
}

public struct PerformanceProfile: Equatable, Sendable {
  public var internalResolution: Int  // 1 = native 640×528
  public var shaderMode: ShaderMode
  public var maxAnisotropyLog2: Int  // Dolphin stores 0=1×, 1=2×, 2=4×, 3=8×, 4=16×
  public var viSkip: Bool  // present fewer frames when emulation falls behind ("frame skip")

  public init(internalResolution: Int, shaderMode: ShaderMode, maxAnisotropyLog2: Int, viSkip: Bool) {
    self.internalResolution = internalResolution; self.shaderMode = shaderMode
    self.maxAnisotropyLog2 = maxAnisotropyLog2; self.viSkip = viSkip
  }

  /// Defaults for a tier and power mode. Performance-first: native resolution is the default
  /// everywhere except devices with clear GPU headroom.
  public static func recommended(tier: DeviceTier, mode: PowerMode) -> PerformanceProfile {
    switch mode {
    case .batterySaver:
      return PerformanceProfile(
        internalResolution: 1, shaderMode: tier <= .mid ? .asyncSkipDrawing : .hybridUbershaders,
        maxAnisotropyLog2: 0, viSkip: true)
    case .maxPerformance:
      return PerformanceProfile(internalResolution: 1, shaderMode: .asyncSkipDrawing, maxAnisotropyLog2: 0, viSkip: true)
    case .balanced:
      switch tier {
      case .entry:
        return PerformanceProfile(internalResolution: 1, shaderMode: .asyncSkipDrawing, maxAnisotropyLog2: 0, viSkip: true)
      case .mid:
        return PerformanceProfile(internalResolution: 1, shaderMode: .hybridUbershaders, maxAnisotropyLog2: 1, viSkip: false)
      case .high:
        return PerformanceProfile(internalResolution: 2, shaderMode: .hybridUbershaders, maxAnisotropyLog2: 2, viSkip: false)
      case .ultra:
        return PerformanceProfile(internalResolution: 2, shaderMode: .hybridUbershaders, maxAnisotropyLog2: 3, viSkip: false)
      }
    }
  }

  public var settings: [EmulatorSetting: String] {
    [
      .internalResolution: String(internalResolution),
      .shaderCompilationMode: String(shaderMode.rawValue),
      .maxAnisotropy: String(maxAnisotropyLog2),
      .viSkip: viSkip ? "True" : "False",
    ]
  }

  /// One step cheaper on the GPU, used by the thermal governor. Nil when already at the floor.
  public func steppedDown() -> PerformanceProfile? {
    var p = self
    if p.internalResolution > 1 { p.internalResolution -= 1; return p }
    if p.maxAnisotropyLog2 > 0 { p.maxAnisotropyLog2 = 0; return p }
    if !p.viSkip { p.viSkip = true; return p }
    if p.shaderMode != .asyncSkipDrawing { p.shaderMode = .asyncSkipDrawing; return p }
    return nil
  }
}
