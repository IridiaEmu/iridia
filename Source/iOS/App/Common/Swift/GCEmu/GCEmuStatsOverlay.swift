// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// gc-emu: the small "30 FPS · 100%" pill shown over the game. Drawn by SwiftUI at 2 Hz from
/// DOLPerfBridge (atomic reads), so it adds no work to the emulator's CPU or GPU threads, unlike
/// Dolphin's in-frame ImGui OSD.
///
/// Visible when the player turns it on (`defaultsKey`) or when the app forces it (free play
/// sessions show it so people can judge performance before buying).
struct GCEmuStatsOverlay: View {
  static let defaultsKey = "gcemu_show_stats_overlay"

  /// Set by the free play session (Phase 6). Not persisted.
  static var forced = false

  @AppStorage(defaultsKey) private var enabled = false
  @State private var fps = 0.0
  @State private var speed = 0.0

  var body: some View {
    if enabled || Self.forced {
      TimelineView(.periodic(from: .now, by: 0.5)) { context in
        pill
          .onChange(of: context.date) { _, _ in refresh() }
      }
      .onAppear(perform: refresh)
      .allowsHitTesting(false)
      .accessibilityElement(children: .combine)
    }
  }

  private var pill: some View {
    HStack(spacing: 6) {
      Text("\(Int(fps.rounded())) FPS")
      Text("·").foregroundStyle(.white.opacity(0.5))
      Text("\(Int((speed * 100).rounded()))%")
        .foregroundStyle(speedColor)
    }
    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
  }

  /// Green at full speed, amber when slightly behind, red when clearly slow.
  private var speedColor: Color {
    if speed >= 0.97 { return Color(red: 0.55, green: 0.95, blue: 0.65) }
    if speed >= 0.85 { return Color(red: 1.0, green: 0.8, blue: 0.4) }
    return Color(red: 1.0, green: 0.5, blue: 0.5)
  }

  private func refresh() {
    let snap = DOLPerfBridge.snapshot()
    fps = snap["fps"]?.doubleValue ?? 0
    speed = snap["speed"]?.doubleValue ?? 0
  }
}
