// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the folder "Check Downloads for Games" looks in, shared by the GameCube and Wii U tabs. iOS only lets
// an app into a folder the player picked, so the player picks Downloads once and Iridia keeps a bookmark to
// it. Each tab then looks there for its own games (GameCubeDownloads, WiiUDownloads) and asks before moving
// any. A game the player says "Not Now" to isn't asked about again.

#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum DownloadsFolder {
  private static let bookmarkKey = "downloadsFolder"
  private static let nameKey = "downloadsFolderName"
  /// The "can't open" message is shown once per launch, not every time a tab opens.
  @MainActor private static var toldProblem = false

  static var isOn: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
  static var name: String { UserDefaults.standard.string(forKey: nameKey) ?? L("Downloads") }

  /// Explains the one step, then opens Apple's picker for the folder. `then` runs once it's saved.
  @MainActor static func choose(look: IridiaAlert.Look, then: @escaping () -> Void) {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    let start = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
    IridiaAlert.show(
      L("Check Downloads for Games"),
      String(format: L("Next, go to %@ (or wherever you download games), tap the Downloads folder, then tap Open. Each time you open Iridia, it looks there for games and asks before adding any."), device),
      look: look,
      buttons: [
        IridiaAlertButton(L("Continue")) {
          GameFilePicker.present(types: [.folder], directory: start) { urls in
            guard let folder = urls.first else { return }
            if save(folder) {
              then()
            } else {
              IridiaAlert.show(L("Iridia Can't Use That Folder"), L("Choose another folder, or add games with Choose a Game File."), look: look)
            }
          }
        },
        .cancel(),
      ])
  }

  @MainActor private static func save(_ folder: URL) -> Bool {
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    guard let data = try? folder.bookmarkData() else { return false }
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    UserDefaults.standard.set(folder.lastPathComponent, forKey: nameKey)
    toldProblem = false
    return true
  }

  @MainActor static func stop() {
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    UserDefaults.standard.removeObject(forKey: nameKey)
  }

  /// The folder, with access started (the caller stops it). Nil when it can't be opened.
  static func open() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
    var stale = false
    guard let folder = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
          folder.startAccessingSecurityScopedResource() else { return nil }
    if stale, let fresh = try? folder.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
    return folder
  }

  /// Access to the folder is gone (moved, renamed, or iOS dropped the permission): say so, with both ways forward.
  @MainActor static func tellProblem(look: IridiaAlert.Look, manual: Bool, chooseAgain: @escaping () -> Void,
                                     chooseFile: @escaping () -> Void) {
    guard manual || !toldProblem else { return }
    toldProblem = true
    IridiaAlert.show(
      String(format: L("Iridia Can't Open %@"), name),
      L("Choose the folder again, or add games with Choose a Game File."),
      look: look,
      buttons: [
        IridiaAlertButton(L("Choose Folder"), action: chooseAgain),
        IridiaAlertButton(L("Choose a Game File"), action: chooseFile),
        IridiaAlertButton(L("Not Now"), .cancel),
      ])
  }

  /// The items in `folder` (two levels down) that `wanted` accepts, not asked about under `askedKey` and not
  /// named like anything in `haveNames`. Nil when the folder can't be read.
  static func find(in folder: URL, askedKey: String, haveNames: Set<String>, wanted: (URL) -> Bool) -> [URL]? {
    guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else { return nil }
    let asked = Set(UserDefaults.standard.stringArray(forKey: askedKey) ?? [])
    return WiiUFileTypes.walk(folder, maxDepth: 2).filter { url in
      !asked.contains(key(url)) && !haveNames.contains(url.lastPathComponent.lowercased()) && wanted(url)
    }
  }

  /// Answered (Add or Not Now): not offered again.
  static func remember(_ urls: [URL], askedKey: String) {
    let now = Set(UserDefaults.standard.stringArray(forKey: askedKey) ?? []).union(urls.map(key))
    UserDefaults.standard.set(Array(now), forKey: askedKey)
  }

  /// Name and size: a new download with the same name is asked about again.
  private static func key(_ url: URL) -> String {
    "\(url.lastPathComponent)|\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
  }

  /// Names of the archive's files, lowercased; nil when it can't be read.
  static func archiveNames(_ url: URL) -> [String]? {
    ZipImportHelper.entryNames(ofArchiveAt: url)?.map { $0.lowercased() }
  }

  static func shortList(_ names: [String]) -> String {
    guard names.count > 3 else { return names.joined(separator: ", ") }
    return String(format: L("%@ and %ld more"), names.prefix(3).joined(separator: ", "), names.count - 3)
  }
}
#endif
