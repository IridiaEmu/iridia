// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Iridia look for full screens outside the shelf (save states, game info, controller
// sheets): the indigo stage behind, dark appearance, lavender accents, and a see-through navigation
// bar. Settings lists get the same look from MenuScreen's list style.

#if os(iOS)
import SwiftUI

extension IridiaGlass {
  static let accent = Color(red: 0.72, green: 0.66, blue: 1.0)
  static let violet = Color(red: 0.55, green: 0.45, blue: 1.0)
}

extension View {
  /// Stage background, dark, lavender tint, clear navigation bar.
  func iridiaScreen() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(IridiaGlass.stage)
      .environment(\.colorScheme, .dark)
      .tint(IridiaGlass.accent)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
  }

  /// A glass panel: padded content on the translucent glass surface used across the app.
  func iridiaPanel(radius: CGFloat = 18) -> some View {
    self
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassSurface(radius: radius)
  }
}

/// Small section heading in the shelf's letter-spaced caps style ("YOUR SHELF · 1 GAME").
struct IridiaSectionLabel: View {
  let text: String
  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 12, weight: .semibold))
      .tracking(1.6)
      .foregroundStyle(IridiaGlass.dim)
  }
}
#endif
