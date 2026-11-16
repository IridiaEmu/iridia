// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: files opened into Iridia from another app (share sheet, AirDrop, "Open in", Files). GameImport sends
// each to the tab its game belongs on. A copy iOS made in Documents/Inbox is moved in; the player's own file,
// opened in place from Files, stays where it is unless they choose Move.

#if os(iOS)
import UIKit

enum IncomingFiles {
  @MainActor static func open(_ url: URL, inPlace: Bool) {
    // On a cold launch the library needs a moment to come up, so the import's alerts have somewhere to show.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      GameImport.add([url], from: .current, incoming: !inPlace)
    }
  }
}
#endif
