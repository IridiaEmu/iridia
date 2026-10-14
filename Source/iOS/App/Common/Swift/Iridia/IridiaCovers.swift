// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: covers are the player's own pictures (chosen from Photos) or Iridia's generated cover
// (TVGameItem draws it from the title). Iridia never downloads box art.

#if os(iOS)
import SwiftUI
import UIKit

enum IridiaCovers {
  /// Posted after a cover is set or removed, so visible covers redraw.
  static let changed = Notification.Name("IridiaCoverChanged")

  /// Saves `data` (any image format Photos hands over) as this game's cover, at most 900 px tall.
  @discardableResult
  static func set(_ data: Data, for item: TVGameItem) -> Bool {
    guard let image = UIImage(data: data) else { return false }
    let scale = min(1, 900 / max(image.size.height, 1))
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let png = resized.pngData() else { return false }
    let url = URL(fileURLWithPath: item.customCoverPath)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: url, options: .atomic)
    } catch {
      return false
    }
    item.reloadCover()
    NotificationCenter.default.post(name: changed, object: item)
    return true
  }

  static func remove(for item: TVGameItem) {
    try? FileManager.default.removeItem(atPath: item.customCoverPath)
    item.reloadCover()
    NotificationCenter.default.post(name: changed, object: item)
  }
}
#endif
