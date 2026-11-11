// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: files opened into Iridia from another app (share sheet, AirDrop, "Open in"). iOS hands over a copy in
// Documents/Inbox, which no library scans, so each file is sent to the tab its game belongs on.

#if os(iOS)
import UIKit

enum IncomingFiles {
  @MainActor static func open(_ url: URL) {
    // On a cold launch the library needs a moment to come up, so the import's alerts have somewhere to show.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { route(url) }
  }

  @MainActor private static func route(_ url: URL) {
    #if canImport(IridiaCafeCore)
    if WiiUModel.canRunGames {
      let scoped = url.startAccessingSecurityScopedResource()
      let kind = WiiUImport.classify(url)
      if scoped { url.stopAccessingSecurityScopedResource() }
      switch kind {
      case .wiiU, .keys:
        NotificationCenter.default.post(name: WiiUImport.showTabNotification, object: nil)
        WiiUModel.shared.addIncoming([url])
        return
      case .archive:
        // Could hold either system's game: the Wii U import unpacks it and passes GameCube ones on.
        WiiUModel.shared.addIncoming([url])
        return
      default:
        break
      }
    }
    #endif
    ImportFileManager.shared().importFiles(at: [url as NSURL])
  }
}
#endif
