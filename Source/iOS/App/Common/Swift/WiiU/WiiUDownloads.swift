// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Check Downloads for Games" on the Wii U tab. Looks in the folder the player chose (DownloadsFolder,
// shared with the GameCube tab) and offers to move the new Wii U games it finds there (game files and folders,
// ZIP or 7Z archives with one inside, keys.txt) into the Wii U folder. Nothing is moved without asking, and
// game folders missing title.tik aren't offered (they couldn't be played).

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit

enum WiiUDownloads {
  private static let askedKey = "wiiuWatchedAsked"
  @MainActor private static var busy = false

  static var isOn: Bool { DownloadsFolder.isOn }
  static var folderName: String { DownloadsFolder.name }

  @MainActor static func chooseFolder(model: WiiUModel) {
    DownloadsFolder.choose(look: .wiiU) { check(model: model, manual: true) }
  }

  @MainActor static func stop() { DownloadsFolder.stop() }

  /// Looks in the folder and offers to move what's new. `manual`: the player asked, so "nothing new" is said too.
  @MainActor static func check(model: WiiUModel, manual: Bool = false) {
    guard DownloadsFolder.isOn, WiiUModel.canRunGames, !busy, !model.importing, model.playing == nil else { return }
    guard let folder = DownloadsFolder.open() else {
      tellProblem(model: model, manual: manual)
      return
    }
    busy = true
    let gamesDir = model.gamesDir
    Task.detached(priority: .userInitiated) {
      // Names already on the Wii U shelf, in its subfolders too.
      let have = Set(WiiUFileTypes.walk(gamesDir, maxDepth: 3).map { $0.lastPathComponent.lowercased() })
      let found = DownloadsFolder.find(in: folder, askedKey: askedKey, haveNames: have, wanted: isWiiUGame)
      await MainActor.run {
        busy = false
        guard let found else {
          folder.stopAccessingSecurityScopedResource()
          tellProblem(model: model, manual: manual)
          return
        }
        guard !found.isEmpty else {
          folder.stopAccessingSecurityScopedResource()
          if manual {
            IridiaAlert.show(L("Nothing New"), String(format: L("There are no new Wii U games in %@."), folderName), look: .wiiU)
          }
          return
        }
        offer(found, from: folder, model: model)
      }
    }
  }

  @MainActor private static func offer(_ found: [URL], from folder: URL, model: WiiUModel) {
    IridiaAlert.show(
      String(format: L("Wii U Games in %@"), folderName),
      String(format: found.count == 1 ? L("Found %@. Add it to your Wii U shelf? It's moved out of %@.")
                                      : L("Found %@. Add them to your Wii U shelf? They're moved out of %@."),
             WiiUModel.shortList(found.map(\.lastPathComponent)), folderName),
      look: .wiiU,
      buttons: [
        IridiaAlertButton(L("Add")) {
          DownloadsFolder.remember(found, askedKey: askedKey)
          model.addFromFolder(found) { folder.stopAccessingSecurityScopedResource() }
        },
        IridiaAlertButton(L("Not Now"), .cancel) {
          DownloadsFolder.remember(found, askedKey: askedKey)
          folder.stopAccessingSecurityScopedResource()
        },
      ])
  }

  @MainActor private static func tellProblem(model: WiiUModel, manual: Bool) {
    DownloadsFolder.tellProblem(look: .wiiU, manual: manual, chooseAgain: { chooseFolder(model: model) },
                                chooseFile: { model.chooseGameFiles() })
  }

  nonisolated private static func isWiiUGame(_ url: URL) -> Bool {
    if WiiUFileTypes.isMissingTicket(url) { return false }
    switch WiiUImport.classify(url) {
    case .wiiU, .keys: return true
    case .archive:
      // Reads only the archive's list of names: a ZIP or 7Z of anything else isn't offered.
      return DownloadsFolder.archiveNames(url)?.contains { name in
        WiiUFileTypes.extensions.contains((name as NSString).pathExtension)
          || name.hasSuffix("title.tmd") || name.hasSuffix("meta/meta.xml")
      } ?? false
    default: return false
    }
  }
}

extension WiiUModel {
  /// Moves games found by the Downloads check into the Wii U folder (same disk: instant, no extra space).
  func addFromFolder(_ urls: [URL], done: @escaping () -> Void) {
    let sorted = WiiUImport.sort(urls)
    var notes: [String] = []
    if !sorted.noTicket.isEmpty { notes.append(Self.noTicketNote(sorted.noTicket)) }
    copyIn(sorted, move: true, notes: notes, done: done)
  }
}
#endif
