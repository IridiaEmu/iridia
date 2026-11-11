// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Check Downloads for Games" on the GameCube tab. Looks in the folder the player chose (DownloadsFolder)
// for GameCube games and ZIP or 7Z files with one inside, and offers to move them to the Games folder. Wii U
// games there are left for the Wii U tab.

#if os(iOS)
import Foundation
import UIKit

enum GameCubeDownloads {
  private static let askedKey = "gcDownloadsAsked"
  @MainActor private static var busy = false

  /// GameCube game files. Disc images are checked by content: Wii games use the same formats, and this
  /// version doesn't play them. (A .dol can't be told apart, so it's offered.)
  private static let gameExtensions: Set<String> = ["gcm", "tgc", "gcz", "ciso", "rvz", "nkit", "wia", "dol", "iso", "bin", "img"]

  @MainActor static func chooseFolder() {
    DownloadsFolder.choose(look: .gameCube) { check(manual: true) }
  }

  /// Looks in the folder and offers to move what's new. `manual`: the player asked, so "nothing new" is said too.
  @MainActor static func check(manual: Bool = false) {
    guard DownloadsFolder.isOn, !busy, !TVEmulationBridge.isRunning() else { return }
    guard let folder = DownloadsFolder.open() else {
      tellProblem(manual: manual)
      return
    }
    busy = true
    let software = URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder())
    Task.detached(priority: .userInitiated) {
      let have = Set(WiiUFileTypes.walk(software, maxDepth: 2).map { $0.lastPathComponent.lowercased() })
      let found = DownloadsFolder.find(in: folder, askedKey: askedKey, haveNames: have, wanted: isGameCubeGame)
      await MainActor.run {
        busy = false
        guard let found else {
          folder.stopAccessingSecurityScopedResource()
          tellProblem(manual: manual)
          return
        }
        guard !found.isEmpty else {
          folder.stopAccessingSecurityScopedResource()
          if manual {
            IridiaAlert.show(L("Nothing New"), String(format: L("There are no new GameCube games in %@."), DownloadsFolder.name))
          }
          return
        }
        offer(found, from: folder, into: software)
      }
    }
  }

  @MainActor private static func offer(_ found: [URL], from folder: URL, into software: URL) {
    let name = DownloadsFolder.name
    IridiaAlert.show(
      String(format: L("GameCube Games in %@"), name),
      String(format: found.count == 1 ? L("Found %@. Add it to your shelf? It's moved out of %@.")
                                      : L("Found %@. Add them to your shelf? They're moved out of %@."),
             DownloadsFolder.shortList(found.map(\.lastPathComponent)), name),
      buttons: [
        IridiaAlertButton(L("Add")) {
          DownloadsFolder.remember(found, askedKey: askedKey)
          add(found, into: software) { folder.stopAccessingSecurityScopedResource() }
        },
        IridiaAlertButton(L("Not Now"), .cancel) {
          DownloadsFolder.remember(found, askedKey: askedKey)
          folder.stopAccessingSecurityScopedResource()
        },
      ])
  }

  @MainActor private static func tellProblem(manual: Bool) {
    DownloadsFolder.tellProblem(look: .gameCube, manual: manual, chooseAgain: { chooseFolder() }, chooseFile: {
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowImportGame"), object: nil)
    })
  }

  /// Moves games in (same disk: instant, no extra space). Archives are unpacked and then removed.
  @MainActor private static func add(_ urls: [URL], into software: URL, done: @escaping () -> Void) {
    let task = ImportStaging.beginBackgroundTask()
    Task.detached(priority: .userInitiated) {
      var added = 0
      var already: [String] = []
      var errors: [String] = []
      let fm = FileManager.default
      for url in urls {
        let name = url.lastPathComponent
        if ImportableFileTypes.isArchiveFile(url) {
          let result = ZipImportHelper.importPickedArchive(at: url, toFolder: software.path)
          added += result.importedCount
          if result.skippedExistingCount > 0 { already.append(name) }
          if result.importedCount + result.skippedExistingCount > 0 {
            try? fm.removeItem(at: url)
          } else if let message = result.errorMessage {
            errors.append("\(name): \(message)")
          }
          continue
        }
        let destination = software.appendingPathComponent(name).path
        if fm.fileExists(atPath: destination) { already.append(name); continue }
        do {
          try ImportStaging.stagedMove(fromPath: url.path, toPath: destination)
          LibraryAddedDateStore.record(path: destination)
          added += 1
        } catch {
          errors.append("\(name): \(error.localizedDescription)")
        }
      }
      let (added2, already2, errors2) = (added, already, errors)
      await MainActor.run {
        let (added, already, errors) = (added2, already2, errors2)
        ImportStaging.endBackgroundTask(task)
        done()
        NotificationCenter.default.post(name: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil)
        if added > 0 {
          let text = added == 1 ? L("Added 1 game.") : String(format: L("Added %ld games."), added)
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
        }
        var lines = errors.prefix(3).map { $0 }
        if !already.isEmpty {
          lines.append(String(format: L("Already on your shelf: %@."), DownloadsFolder.shortList(already)))
        }
        if !lines.isEmpty {
          IridiaAlert.show(errors.isEmpty ? L("Import") : L("Some Files Weren't Added"), lines.joined(separator: "\n\n"))
        }
      }
    }
  }

  /// A GameCube game file, or an archive with one inside. Not Wii U files.
  nonisolated private static func isGameCubeGame(_ url: URL) -> Bool {
    if WiiUFileTypes.isDirectory(url) { return false }
    let ext = url.pathExtension.lowercased()
    if gameExtensions.contains(ext) { return ext == "dol" || isGameCubeDisc(url, ext: ext) }
    if ImportableFileTypes.isArchiveFile(url), let names = DownloadsFolder.archiveNames(url) {
      return names.contains { name in
        let ext = (name as NSString).pathExtension
        return gameExtensions.contains(ext) || ext == "iso"
      } && !names.contains { WiiUFileTypes.extensions.contains(($0 as NSString).pathExtension) }
    }
    return false
  }

  /// GameCube, not Wii, by the disc header: a GameCube disc has 0xC2339F3D at 0x1C. RVZ and WIA say so at
  /// 0x48 (1 GameCube, 2 Wii), GCZ at 4 (0 GameCube, 1 Wii), and a CISO's disc starts at 0x8000.
  nonisolated private static func isGameCubeDisc(_ url: URL, ext: String) -> Bool {
    let magic = Data([0xC2, 0x33, 0x9F, 0x3D])
    switch ext {
    case "rvz", "wia":
      guard let head = WiiUFileTypes.readHead(url, count: 0x4C) else { return false }
      return head[0x48..<0x4C] == Data([0, 0, 0, 1])
    case "gcz":
      guard let head = WiiUFileTypes.readHead(url, count: 8) else { return false }
      return head[4..<8] == Data([0, 0, 0, 0])
    case "ciso":
      guard let head = WiiUFileTypes.readHead(url, count: 0x8020) else { return false }
      return head[0x801C..<0x8020] == magic
    default:
      guard let head = WiiUFileTypes.readHead(url, count: 0x20) else { return false }
      return head[0x1C..<0x20] == magic
    }
  }
}
#endif
