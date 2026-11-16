// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import CoreGraphics

/// Where the game screen's top-right buttons can go without covering a touch control.
final class TouchOverlayCorner: ObservableObject {
  static let shared = TouchOverlayCorner()
  /// The buttons' bottom edge below the safe area's top.
  static let buttonBottom: CGFloat = 60

  @Published var trailingClearance: CGFloat = 0
}
