// SPDX-License-Identifier: GPL-2.0-or-later
//
// "Check Downloads for Games" on the GameCube and Wii tabs. Looks in the folder the player chose
// (DownloadsFolder) for that tab's games and ZIP or 7Z files with one inside, and offers to move them in.

#if os(iOS)
import Foundation
import UIKit

enum GameCubeDownloads {
  enum Kind {
    case gameCube, wii

    var askedKey: String { self == .wii ? "wiiDownloadsAsked" : "gcDownloadsAsked" }
    var look: IridiaAlert.Look { self == .wii ? .wii : .gameCube }
    var folder: String { self == .wii ? UserFolderUtil.getWiiFolder() : UserFolderUtil.getSoftwareFolder() }
    var system: GameSystem { self == .wii ? .wii : .gameCube }

    /// This tab's games, by their contents. An archive is offered when its names show a disc or homebrew file
    /// and no Wii U game (the Wii U tab offers those); it's sorted by what's inside when it's unpacked.
    func wants(_ url: URL) -> Bool {
      guard DownloadsFolder.mayHoldGame(url, extensions: ImportableFileTypes.softwareExtensions) else { return false }
      switch GameDetect.kind(of: url) {
      case .game(let found): return found == system
      case .archive:
        guard let names = DownloadsFolder.archiveNames(url) else { return false }
        let systems = GameDetect.systems(inArchiveNames: names)
        return systems.contains(system) && !names.contains { WiiUFileTypes.extensions.contains(($0 as NSString).pathExtension) }
      default: return false
      }
    }
  }

  @MainActor private static var busy: Set<Kind> = []

  @MainActor static func chooseFolder(_ kind: Kind = .gameCube) {
    DownloadsFolder.choose(look: kind.look) { check(kind, manual: true) }
  }

  /// Looks in the folder and offers to move what's new. `manual`: the player asked, so "nothing new" is said too.
  @MainActor static func check(_ kind: Kind = .gameCube, manual: Bool = false) {
    guard DownloadsFolder.isOn, !busy.contains(kind), !TVEmulationBridge.isRunning() else { return }
    guard let folder = DownloadsFolder.open() else {
      tellProblem(kind, manual: manual)
      return
    }
    busy.insert(kind)
    let software = URL(fileURLWithPath: kind.folder)
    Task.detached(priority: .userInitiated) {
      let have = Set(WiiUFileTypes.walk(software, maxDepth: 2).map { $0.lastPathComponent.lowercased() })
      let found = DownloadsFolder.find(in: folder, askedKey: kind.askedKey, haveNames: have, wanted: kind.wants)
      await MainActor.run {
        busy.remove(kind)
        // A game started while the folder was read: nothing pops up over it unless the player asked.
        guard manual || !TVEmulationBridge.isRunning() else {
          folder.stopAccessingSecurityScopedResource()
          return
        }
        guard let found else {
          folder.stopAccessingSecurityScopedResource()
          tellProblem(kind, manual: manual)
          return
        }
        guard !found.isEmpty else {
          folder.stopAccessingSecurityScopedResource()
          if manual {
            let text = kind == .wii ? L("There are no new Wii games in %@.") : L("There are no new GameCube games in %@.")
            IridiaAlert.show(L("Nothing New"), String(format: text, DownloadsFolder.name), look: kind.look)
          }
          return
        }
        offer(found, kind: kind, from: folder, into: software)
      }
    }
  }

  @MainActor private static func offer(_ found: [URL], kind: Kind, from folder: URL, into software: URL) {
    let name = DownloadsFolder.name
    IridiaAlert.show(
      String(format: kind == .wii ? L("Wii Games in %@") : L("GameCube Games in %@"), name),
      String(format: found.count == 1 ? L("Found %@. Add it to your shelf? It's moved out of %@.")
                                      : L("Found %@. Add them to your shelf? They're moved out of %@."),
             DownloadsFolder.shortList(found.map(\.lastPathComponent)), name),
      look: kind.look,
      buttons: [
        IridiaAlertButton(L("Add")) {
          DownloadsFolder.remember(found, askedKey: kind.askedKey)
          add(found, kind: kind) { folder.stopAccessingSecurityScopedResource() }
        },
        IridiaAlertButton(L("Not Now"), .cancel) {
          DownloadsFolder.remember(found, askedKey: kind.askedKey)
          folder.stopAccessingSecurityScopedResource()
        },
      ])
  }

  @MainActor private static func tellProblem(_ kind: Kind, manual: Bool) {
    DownloadsFolder.tellProblem(look: kind.look, manual: manual) { chooseFolder(kind) }
  }

  /// Moves games in (same disk: instant, no extra space). Archives are unpacked and then removed.
  @MainActor private static func add(_ urls: [URL], kind: Kind, done: @escaping () -> Void) {
    GameImport.add(urls, from: kind.system, incoming: true, done: done)
  }
}
#endif
