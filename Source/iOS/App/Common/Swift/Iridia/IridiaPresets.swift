// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: applies IridiaPerformance's per-device presets. A fresh install gets the "Balanced"
// profile for its chip tier (e.g. native resolution on older phones, 2x on A18-class and up); an
// existing install keeps whatever the player set. Settings > Video > Power Mode switches profiles.

#if os(iOS)
import Foundation
import IridiaPerformance

enum IridiaPresets {
  static let modeKey = "iridia_power_mode"
  private static let appliedKey = "iridia_presets_applied_v1"

  /// Captured at launch before Dolphin writes its config: true only on a brand-new install.
  private static var isFreshInstall = false

  static var device: DeviceInfo {
    var info = utsname()
    uname(&info)
    let model = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return DeviceInfo(model: model)
  }

  static var mode: PowerMode {
    get { PowerMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .balanced }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
  }

  /// Call first thing at launch (before the core loads its config).
  static func noteLaunch() {
    let gfx = (UserFolderUtil.getUserFolder() as NSString).appendingPathComponent("Config/GFX.ini")
    isFreshInstall = !UserDefaults.standard.bool(forKey: appliedKey) && !FileManager.default.fileExists(atPath: gfx)
  }

  /// Call once the core's config is loaded (the library has appeared).
  static func applyFirstRunIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: appliedKey) else { return }
    UserDefaults.standard.set(true, forKey: appliedKey)
    guard isFreshInstall else { return }   // existing installs keep the player's settings
    apply(mode: .balanced)
    NSLog("[Presets] fresh install on %@ (%@ tier): applied Balanced", device.chip.description, device.tier.displayName)
  }

  /// Write a power mode's profile for this device.
  static func apply(mode newMode: PowerMode) {
    mode = newMode
    let profile = PerformanceProfile.recommended(tier: device.tier, mode: newMode)
    DOLConfigBridge.setGfxEfbScale(profile.internalResolution)
    DOLConfigBridge.setGfxAutoIREnable(false)
    DOLConfigBridge.setGfxShaderCompilationMode(profile.shaderMode.rawValue)
    DOLConfigBridge.setGfxEnhanceAnisotropySamples(1 << profile.maxAnisotropyLog2)
  }
}
#endif
