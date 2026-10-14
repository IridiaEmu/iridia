import Foundation
import UIKit

/// Monitors device thermal state and auto-tunes graphics settings when enabled
final class ThermalManager {
  @MainActor
  static let shared = ThermalManager()
  private init() {}

  static let changedNotification = Notification.Name("DOLThermalStateChanged")
  private var observing = false
  private var baselineCaptured = false
  private var baselineEfbScale: Int = 1
  private var baselineAnisotropy: Int = 1
  private var baselineShaderEnabled: Bool = false
  private var baselineHDREnabled: Bool = false
  private var lastNotified: ProcessInfo.ThermalState = .nominal
  private var throttled = false

  /// Start observing thermal changes
  func start() {
    guard !observing else { return }
    observing = true
    NotificationCenter.default.addObserver(self, selector: #selector(onThermalChange), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    // gc-emu: re-read the player's settings each game, so a later change is what gets restored.
    baselineCaptured = false
    throttled = false
    captureBaselineIfNeeded()
    applyForState(ProcessInfo.processInfo.thermalState)
  }

  /// Stop observing
  func stop() {
    guard observing else { return }
    observing = false
    NotificationCenter.default.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
  }

  @objc private func onThermalChange() {
    applyForState(ProcessInfo.processInfo.thermalState)
  }

  private func captureBaselineIfNeeded() {
    guard !baselineCaptured else { return }
    baselineEfbScale = DOLConfigBridge.gfxEfbScale()
    baselineAnisotropy = DOLConfigBridge.gfxEnhanceAnisotropySamples()
    baselineShaderEnabled = UserDefaults.standard.bool(forKey: "shader_enabled")
    baselineHDREnabled = UserDefaults.standard.bool(forKey: "gfx_edr_enabled")
    baselineCaptured = true
  }

  private func restoreBaseline() {
    // EFB scale is an AUTO behavior here, so it lives on the CurrentRun layer (resolver step #3).
    // Clear the CurrentRun override rather than writing the baseline back into CurrentRun: that
    // re-exposes the user's manual Base value and avoids pinning the key (which would leave the
    // "Auto" badge stuck on / the manual IR control disabled after the device cools).
    DOLConfigBridge.clearGfxEfbScaleAuto()
    DOLConfigBridge.setGfxEnhanceAnisotropySamples(baselineAnisotropy)
    UserDefaults.standard.set(baselineShaderEnabled, forKey: "shader_enabled")
    NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
    UserDefaults.standard.set(baselineHDREnabled, forKey: "gfx_edr_enabled")
    TVEmulationBridge.resizeSurfaceNow()
  }

  private func notify(_ state: ProcessInfo.ThermalState) {
    guard state != lastNotified else { return }
    lastNotified = state
    NotificationCenter.default.post(name: ThermalManager.changedNotification, object: nil, userInfo: ["state": mapState(state)])
  }

  private func mapState(_ state: ProcessInfo.ThermalState) -> Int {
    switch state {
    case .nominal: return 0
    case .fair: return 1
    case .serious: return 2
    case .critical: return 3
    @unknown default: return 0
    }
  }

  private func applyForState(_ state: ProcessInfo.ThermalState) {
    notify(state)
    guard UserDefaults.standard.bool(forKey: "thermal_auto_enable") else { return }
    // gc-emu: "fair" is normal for gaming (sustained play sits there), so nothing changes until
    // "serious"; one step down there, the full power-saving set only at "critical".
    switch state {
    case .nominal, .fair:
      guard throttled else { break }
      throttled = false
      restoreBaseline()
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Cooled down: full quality restored")])
    case .serious:
      captureBaselineIfNeeded()
      throttled = true
      let efb = max(1, min(baselineEfbScale, DOLConfigBridge.gfxEfbScale()) - 1)
      // AUTO throttle → CurrentRun layer (resolver step #3): shadows the user's manual Base value.
      DOLConfigBridge.setGfxEfbScaleAuto(efb)
      DOLConfigBridge.setGfxEnhanceAnisotropySamples(max(1, baselineAnisotropy / 2))
      TVEmulationBridge.resizeSurfaceNow()
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Your iPhone is warm, so resolution is a little lower")])
    case .critical:
      captureBaselineIfNeeded()
      throttled = true
      DOLConfigBridge.setGfxEfbScaleAuto(1)
      DOLConfigBridge.setGfxEnhanceAnisotropySamples(1)
      UserDefaults.standard.set(false, forKey: "gfx_edr_enabled")
      if UserDefaults.standard.bool(forKey: "shader_enabled") {
        UserDefaults.standard.set(false, forKey: "shader_enabled")
        NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      }
      TVEmulationBridge.resizeSurfaceNow()
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Your iPhone is hot, so power saving is on")])
    @unknown default:
      break
    }
  }
}
