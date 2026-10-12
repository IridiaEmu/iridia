// SPDX-License-Identifier: GPL-2.0-or-later
//
// Optional speed hacks that trade accuracy for speed, with plain-language labels and honest risk
// notes for the settings screen. Each maps to Dolphin config keys.

public struct SpeedHack: Identifiable, Equatable, Sendable {
  public enum Risk: Int, Comparable, Sendable {
    /// Rarely visible.
    case low = 0
    /// Some games show glitches.
    case medium
    /// Can break games; for experimenting.
    case high
    public static func < (l: Risk, r: Risk) -> Bool { l.rawValue < r.rawValue }
  }

  public let id: String
  public let title: String
  public let detail: String
  public let risk: Risk
  /// Settings applied when the hack is ON.
  public let on: [EmulatorSetting: String]
  /// Settings applied when the hack is OFF (the accurate default).
  public let off: [EmulatorSetting: String]
  /// Whether Iridia enables it by default (the tested, low-risk ones).
  public let defaultOn: Bool

  public func settings(enabled: Bool) -> [EmulatorSetting: String] { enabled ? on : off }

  public static let all: [SpeedHack] = [
    SpeedHack(
      id: "skipEFBAccess", title: "Skip EFB Access from CPU",
      detail: "Faster. Some games use this for effects like lens flares, light shafts or picking objects with a cursor; those may not appear.",
      risk: .low, on: [.efbAccess: "False"], off: [.efbAccess: "True"], defaultOn: true),
    SpeedHack(
      id: "frameSkip", title: "Frame Skip When Behind",
      detail: "When emulation can't keep up, show fewer frames instead of slowing the game down. Motion looks less smooth.",
      risk: .low, on: [.viSkip: "True"], off: [.viSkip: "False"], defaultOn: false),
    SpeedHack(
      id: "fastTextureCache", title: "Fast Texture Cache",
      detail: "Checks fewer bytes to detect changed textures. Rarely, a texture may not update.",
      risk: .low, on: [.textureCacheSamples: "128"], off: [.textureCacheSamples: "0"], defaultOn: true),
    SpeedHack(
      id: "disableBoundingBox", title: "Disable Bounding Box",
      detail: "Faster. A few games use it for 2D effects (e.g. some menus or paper-style graphics), which may break.",
      risk: .medium, on: [.boundingBox: "False"], off: [.boundingBox: "True"], defaultOn: true),
    SpeedHack(
      id: "largerAudioBuffer", title: "Larger Audio Buffer",
      detail: "Fewer audio wake-ups and less crackling when the device is busy, at the cost of slightly delayed sound. (Dolphin has no lower-quality audio mode; this is the closest saving.)",
      risk: .low, on: [.audioBufferSize: "160"], off: [.audioBufferSize: "80"], defaultOn: false),
    SpeedHack(
      id: "cpuUnderclock", title: "Emulated CPU Underclock (75%)",
      detail: "Runs the emulated CPU slower so each frame needs less work. Big speed-ups in some games, but others will slow down, stutter or break.",
      risk: .high, on: [.cpuOverclockEnable: "True", .cpuOverclock: "0.75"],
      off: [.cpuOverclockEnable: "False", .cpuOverclock: "1"], defaultOn: false),
  ]
}
