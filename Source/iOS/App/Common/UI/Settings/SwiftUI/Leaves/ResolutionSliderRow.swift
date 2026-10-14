// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// gc-emu: the simple Resolution control at the top of Video settings. Same rules as the in-game
/// Performance panel: writes the user's base internal resolution and turns Auto IR off, since both
/// drive GFX_EFB_SCALE. Applies live if a game is running.
struct ResolutionSliderRow: View {
  /// Above this the phone can run out of memory on big scenes.
  static let maxScale = 8

  @State private var scale = 1
  @State private var lockedByOverride = false

  private var upper: Int { min(Self.maxScale, max(2, DOLConfigBridge.gfxEfbMaxScale())) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(L("Resolution"))
        Spacer()
        Text(Self.label(scale))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: Binding(get: { Double(scale) }, set: { set(Int($0.rounded())) }),
             in: 1 ... Double(upper), step: 1)
        .disabled(lockedByOverride)
      if lockedByOverride {
        Text(L("Set automatically for this game right now."))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if scale >= Self.hotScale {
        Self.hotWarning
      }
    }
    .padding(.vertical, 4)
    .onAppear {
      // Auto (0) shows as 1x here; moving the slider picks a fixed resolution.
      scale = max(1, DOLConfigBridge.gfxEfbScaleBase())
      lockedByOverride = DOLConfigBridge.efbScaleOverride() != .none
    }
  }

  private func set(_ newScale: Int) {
    guard newScale != scale else { return }
    scale = newScale
    DOLConfigBridge.setGfxEfbScale(newScale)
    DOLConfigBridge.setGfxAutoIREnable(false)
  }

  /// gc-emu: from here up the GPU works ~10× harder for little visible gain (BENCHMARKS #17: iPhone 16
  /// Pro, Twilight Princess: 8% GPU busy at 1x–4x, 82–87% at 5x–8x; the screen shows ~3x at most).
  static let hotScale = 5

  static var hotWarning: some View {
    Label(L("This runs hot, and on this screen it looks about the same as 4x."),
          systemImage: "thermometer.high")
      .font(.caption)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// "2x · 1280×1056" (GameCube native EFB is 640×528).
  static func label(_ scale: Int) -> String {
    "\(scale)x · \(640 * scale)×\(528 * scale)"
  }
}

/// gc-emu: Settings > Video toggle for the in-game "30 FPS · 100%" pill.
struct StatsOverlayToggleRow: View {
  @AppStorage(GCEmuStatsOverlay.defaultsKey) private var enabled = false

  var body: some View {
    Toggle(L("Show FPS & Speed"), isOn: $enabled)
  }
}

#if os(iOS)
import IridiaPerformance

/// gc-emu: Settings > Video > Power Mode. Applies the device tier's profile for the chosen mode
/// (resolution, shader mode, texture filtering); the Resolution slider can still fine-tune after.
struct PowerModeRow: View {
  @State private var mode = IridiaPresets.mode

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(L("Power Mode"), selection: $mode) {
        ForEach(PowerMode.allCases, id: \.self) { m in Text(L(m.displayName)).tag(m) }
      }
      .pickerStyle(.segmented)
      .onChange(of: mode) { _, m in IridiaPresets.apply(mode: m) }
      Text(String(format: L("This %@ is in the %@ tier."), IridiaPresets.device.chip.description, L(IridiaPresets.device.tier.displayName)))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}
#endif

