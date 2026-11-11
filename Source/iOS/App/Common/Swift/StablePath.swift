// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: a file's path that survives app updates. iOS can move the app's folder when it updates the app
// (/…/Application/<new id>/Documents/…), so anything remembered by full path (last played, date added,
// per-game settings) is remembered by the part from Documents/ or Library/ on instead.

import Foundation

enum StablePath {
  /// "Documents/Wii U/Game.wua" for a path inside the app's folder; anything else as given.
  static func key(_ path: String) -> String {
    let full = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
    for marker in ["/Documents/", "/Library/"] {
      if let range = full.range(of: marker) { return String(full[full.index(after: range.lowerBound)...]) }
    }
    return full
  }
}
