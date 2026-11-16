// SPDX-License-Identifier: GPL-2.0-or-later
//
// The top of every menu, on all three tabs: a large title, and at the top right the home screen's glass circle
// with an X, in that tab's colours.

#if os(iOS)
import SwiftUI

struct MenuCloseButton: View {
  let action: () -> Void
  @Environment(\.menuLook) private var look
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let theme = HomeTheme.of(look.system)
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(theme.icon)
        .frame(width: 40, height: 40)
        .homeGlass(theme.glassTint, solid: theme.solid, in: Circle(), reduce: reduceTransparency)
    }
    .buttonStyle(SpringPressStyle())
    .accessibilityLabel(L("Close"))
  }
}

extension View {
  /// Large title and the glass close button, for a menu shown as a sheet.
  func menuClose(_ action: @escaping () -> Void) -> some View {
    navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { MenuCloseButton(action: action) }
          .sharedBackgroundVisibility(.hidden)
      }
  }
}
#endif
