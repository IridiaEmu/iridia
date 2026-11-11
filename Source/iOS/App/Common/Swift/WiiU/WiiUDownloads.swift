// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Check Downloads for Games" on the Wii U tab. iOS only lets an app into a folder the player picked, so
// the player picks Downloads once; Iridia keeps a bookmark to it and, each time the Wii U tab opens, offers to move
// the new Wii U games it finds there (game files and folders, ZIP or 7Z archives with one inside, keys.txt) into
// the Wii U folder. Nothing is moved without asking, and a game the player says "Not Now" to isn't asked about
// again. If the bookmark stops working, it says so and offers to pick the folder again or Choose a Game File.

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum WiiUDownloads {
  private static let bookmarkKey = "wiiuWatchedFolder"
  private static let nameKey = "wiiuWatchedFolderName"
  private static let askedKey = "wiiuWatchedAsked"
  @MainActor private static var busy = false
  /// The "can't open" message is shown once per launch, not every time the tab opens.
  @MainActor private static var toldProblem = false

  static var isOn: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
  static var folderName: String { UserDefaults.standard.string(forKey: nameKey) ?? L("Downloads") }

  /// Explains the one step, then opens Apple's picker for the folder.
  @MainActor static func chooseFolder(model: WiiUModel) {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    IridiaAlert.show(
      L("Check Downloads for Games"),
      String(format: L("Next, go to %@ (or wherever you download games), tap the Downloads folder, then tap Open. Each time you open the Wii U tab, Iridia looks there for Wii U games and asks before adding any."), device),
      look: .wiiU,
      buttons: [
        IridiaAlertButton(L("Continue")) {
          GameFilePicker.present(types: [.folder], directory: model.gamesDir.deletingLastPathComponent()) { urls in
            guard let folder = urls.first else { return }
            save(folder, model: model)
          }
        },
        .cancel(),
      ])
  }

  @MainActor private static func save(_ folder: URL, model: WiiUModel) {
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    guard let data = try? folder.bookmarkData() else {
      alert(L("Iridia Can't Use That Folder"), L("Choose another folder, or add games with Choose a Game File."))
      return
    }
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    UserDefaults.standard.set(folder.lastPathComponent, forKey: nameKey)
    toldProblem = false
    check(model: model, manual: true)
  }

  @MainActor static func stop() {
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    UserDefaults.standard.removeObject(forKey: nameKey)
  }

  /// Looks in the folder and offers to move what's new. `manual`: the player asked, so "nothing new" is said too.
  @MainActor static func check(model: WiiUModel, manual: Bool = false) {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey), WiiUModel.canRunGames,
          !busy, !model.importing, model.playing == nil else { return }
    var stale = false
    guard let folder = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
          folder.startAccessingSecurityScopedResource() else {
      tellProblem(model: model, manual: manual)
      return
    }
    if stale, let fresh = try? folder.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
    busy = true
    let asked = Set(UserDefaults.standard.stringArray(forKey: askedKey) ?? [])
    let gamesDir = model.gamesDir
    Task.detached(priority: .userInitiated) {
      let found = newGames(in: folder, asked: asked, gamesDir: gamesDir)
      await MainActor.run {
        busy = false
        guard let found else {
          folder.stopAccessingSecurityScopedResource()
          tellProblem(model: model, manual: manual)
          return
        }
        guard !found.isEmpty else {
          folder.stopAccessingSecurityScopedResource()
          if manual { alert(L("Nothing New"), String(format: L("There are no new Wii U games in %@."), folderName)) }
          return
        }
        offer(found, from: folder, model: model)
      }
    }
  }

  @MainActor private static func offer(_ found: [URL], from folder: URL, model: WiiUModel) {
    let remember = {
      let now = Set(UserDefaults.standard.stringArray(forKey: askedKey) ?? []).union(found.map(key))
      UserDefaults.standard.set(Array(now), forKey: askedKey)
    }
    let names = WiiUModel.shortList(found.map(\.lastPathComponent))
    IridiaAlert.show(
      String(format: L("Wii U Games in %@"), folderName),
      String(format: found.count == 1 ? L("Found %@. Add it to your Wii U shelf? It's moved out of %@.")
                                      : L("Found %@. Add them to your Wii U shelf? They're moved out of %@."),
             names, folderName),
      look: .wiiU,
      buttons: [
        IridiaAlertButton(L("Add")) {
          remember()
          model.addFromFolder(found) { folder.stopAccessingSecurityScopedResource() }
        },
        IridiaAlertButton(L("Not Now"), .cancel) {
          remember()
          folder.stopAccessingSecurityScopedResource()
        },
      ])
  }

  /// Access to the folder is gone (moved, renamed, or iOS dropped the permission): say so, with both ways forward.
  @MainActor private static func tellProblem(model: WiiUModel, manual: Bool) {
    guard manual || !toldProblem else { return }
    toldProblem = true
    IridiaAlert.show(
      String(format: L("Iridia Can't Open %@"), folderName),
      L("Choose the folder again, or add games with Choose a Game File."),
      look: .wiiU,
      buttons: [
        IridiaAlertButton(L("Choose Folder")) { chooseFolder(model: model) },
        IridiaAlertButton(L("Choose a Game File")) { model.chooseGameFiles() },
        IridiaAlertButton(L("Not Now"), .cancel),
      ])
  }

  @MainActor private static func alert(_ title: String, _ message: String) {
    IridiaAlert.show(title, message, look: .wiiU)
  }

  /// The Wii U games in `folder` (two levels) not asked about yet and not already in the Wii U folder. Nil when
  /// the folder can't be read.
  nonisolated private static func newGames(in folder: URL, asked: Set<String>, gamesDir: URL) -> [URL]? {
    guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else { return nil }
    // Names already on the Wii U shelf, in its subfolders too.
    let have = Set(WiiUFileTypes.walk(gamesDir, maxDepth: 3).map { $0.lastPathComponent.lowercased() })
    return WiiUFileTypes.walk(folder, maxDepth: 2).filter { url in
      guard !asked.contains(key(url)), !have.contains(url.lastPathComponent.lowercased()),
            !WiiUFileTypes.isMissingTicket(url) else { return false }
      switch WiiUImport.classify(url) {
      case .wiiU, .keys: return true
      case .archive: return archiveHasWiiUGame(url)
      default: return false
      }
    }
  }

  /// Reads only the archive's list of names: a ZIP or 7Z of anything else in Downloads isn't offered.
  nonisolated private static func archiveHasWiiUGame(_ url: URL) -> Bool {
    guard let names = ZipImportHelper.entryNames(ofArchiveAt: url) else { return false }
    return names.contains { name in
      let lower = name.lowercased()
      let ext = (lower as NSString).pathExtension
      return WiiUFileTypes.extensions.contains(ext) || lower.hasSuffix("title.tmd") || lower.hasSuffix("meta/meta.xml")
    }
  }

  nonisolated private static func key(_ url: URL) -> String {
    "\(url.lastPathComponent)|\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
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
