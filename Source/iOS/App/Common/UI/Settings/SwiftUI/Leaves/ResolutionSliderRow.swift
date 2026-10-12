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

  /// "2x · 1280×1056" (GameCube native EFB is 640×528).
  static func label(_ scale: Int) -> String {
    "\(scale)x · \(640 * scale)×\(528 * scale)"
  }
}
