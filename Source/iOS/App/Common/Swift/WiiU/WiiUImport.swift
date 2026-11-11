// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: "Choose a Game File" for the Wii U tab, the same flow as the GameCube shelf's: Apple's picker,
// then Copy or Move into Documents/Wii U. Takes Wii U disc images (.wux, .wud, .iso), .wua and .wuhb files,
// game, update and extra content folders, homebrew (.rpx) and keys.txt. A picked folder that isn't a game
// itself is searched (two levels) for those. Archives (.zip, .7z, ...) are unpacked and searched the same way,
// also when the Files app put them in the Wii U folder. GameCube files get a plain message pointing to their tab.
// Also: files opened into Iridia from other apps (share sheet, AirDrop), and Wii U games left in the GameCube
// folder by the Files app (offered a move to the Wii U folder).

#if os(iOS) && canImport(IridiaCafeCore)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum WiiUImport {
  enum Kind: Equatable { case wiiU, keys, archive, gameCube, wii, other }

  /// GameCube (and Wii) formats the GameCube shelf knows; picking one here gets a pointer to that tab.
  /// (Archives can hold any system's game, so they're unpacked and looked inside instead.)
  private static let gameCubeExtensions: Set<String> = ["gcm", "tgc", "rvz", "wia", "gcz", "ciso", "nkit", "dol", "elf"]
  private static let wiiExtensions: Set<String> = ["wbfs", "wad"]

  /// What `url` is. Disc images named .iso are told apart by the Wii U, GameCube and Wii disc headers. Any text
  /// file with a disc key in it counts as keys (Safari saves a second download as "keys 2.txt").
  nonisolated static func classify(_ url: URL) -> Kind {
    if isDirectory(url) { return isTitleFolder(url) ? .wiiU : .other }
    let ext = url.pathExtension.lowercased()
    if url.lastPathComponent.lowercased() == "keys.txt" || (ext == "txt" && hasKeys(url)) { return .keys }
    if ext == "iso" {
      if WiiUFileTypes.isWiiUDisc(url) { return .wiiU }
      switch discMagic(url) {
      case .gameCube?: return .gameCube
      case .wii?: return .wii
      default: return .wiiU   // no header the GameCube shelf knows; the Wii U core gets a try
      }
    }
    if WiiUFileTypes.extensions.contains(ext) { return .wiiU }
    if ZipImportHelper.isArchivePath(url.path) { return .archive }
    if gameCubeExtensions.contains(ext) { return .gameCube }
    if wiiExtensions.contains(ext) { return .wii }
    return .other
  }

  nonisolated static func isTitleFolder(_ url: URL) -> Bool { WiiUFileTypes.isTitleFolder(url) }

  nonisolated private static func isDirectory(_ url: URL) -> Bool { WiiUFileTypes.isDirectory(url) }

  /// A small text file with at least one disc key line.
  nonisolated private static func hasKeys(_ url: URL) -> Bool {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    guard size < 64 * 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.split(whereSeparator: \.isNewline).contains { key(in: $0) != nil }
  }

  nonisolated private static func discMagic(_ url: URL) -> Kind? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 0x20), head.count == 0x20 else { return nil }
    let word = { (at: Int) in head[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    if word(0x18) == 0x5D1C_9EA3 { return .wii }
    if word(0x1C) == 0xC233_9F3D { return .gameCube }
    return nil
  }

  /// Sorts what the player picked: Wii U items to add, keys.txt files, and names to explain.
  struct Sorted {
    var items: [URL] = []
    var keys: [URL] = []
    var archives: [URL] = []
    /// Installed game folders without their title.tik: they can't be opened, so they aren't copied.
    var noTicket: [String] = []
    var gameCube: [String] = []
    var wii: [String] = []
    var other: [String] = []
  }

  /// `maxDepth`: how far into picked folders to look (an unpacked archive gets one level more).
  nonisolated static func sort(_ urls: [URL], maxDepth: Int = 2) -> Sorted {
    var sorted = Sorted()
    func visit(_ url: URL, depth: Int, picked: Bool) {
      switch classify(url) {
      case .wiiU:
        if isDirectory(url), WiiUFileTypes.isMissingTicket(url) { sorted.noTicket.append(url.lastPathComponent) }
        else { sorted.items.append(url) }
      case .keys: sorted.keys.append(url)
      case .archive: if picked { sorted.archives.append(url) }
      case .gameCube: sorted.gameCube.append(url.lastPathComponent)
      case .wii: sorted.wii.append(url.lastPathComponent)
      case .other:
        if isDirectory(url), depth < maxDepth {
          let before = sorted.items.count + sorted.keys.count
          let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
          for child in children { visit(child, depth: depth + 1, picked: false) }
          if picked, sorted.items.count + sorted.keys.count == before { sorted.other.append(url.lastPathComponent) }
        } else if picked {
          sorted.other.append(url.lastPathComponent)
        }
      }
    }
    for url in urls { visit(url, depth: 0, picked: true) }
    return sorted
  }

  /// Puts `source` (a file or a folder) into `folder` under its own name. Like the GameCube import it goes
  /// through a `.importing` sibling, so a game only ever appears complete.
  nonisolated static func place(_ source: URL, in folder: URL, move: Bool) throws {
    let fm = FileManager.default
    let destination = folder.appendingPathComponent(source.lastPathComponent)
    guard isDirectory(source) else {
      if move {
        try ImportStaging.stagedMove(fromPath: source.path, toPath: destination.path)
      } else {
        try ImportStaging.stagedCopy(fromPath: source.path, toPath: destination.path)
      }
      return
    }
    let staged = destination.path + ImportStaging.stagingSuffix
    try? fm.removeItem(atPath: staged)
    if move {
      try fm.moveItem(atPath: source.path, toPath: staged)
      do { try fm.moveItem(atPath: staged, toPath: destination.path) } catch {
        try? fm.moveItem(atPath: staged, toPath: source.path)   // never lose the player's files
        throw error
      }
    } else {
      do {
        try fm.copyItem(atPath: source.path, toPath: staged)
        try fm.moveItem(atPath: staged, toPath: destination.path)
      } catch {
        try? fm.removeItem(atPath: staged)
        throw error
      }
    }
  }

  enum KeyError: LocalizedError {
    case noKeys
    var errorDescription: String? { L("That isn't a disc key. A key is 32 characters, using 0 to 9 and A to F.") }
  }

  /// The key on a keys.txt line, the way the core reads it: before any # or ;, without spaces, dashes or
  /// underscores. Nil unless it's 32 hex characters (anything else would make the core show an error).
  nonisolated static func key(in line: Substring) -> String? {
    let text = line.prefix { $0 != "#" && $0 != ";" }
    let k = text.filter { !" \t-_".contains($0) }.lowercased()
    return k.count == 32 && k.allSatisfy(\.isHexDigit) ? k : nil
  }

  /// Adds the keys in `source` that the Wii U folder's keys.txt doesn't have yet. Returns how many.
  nonisolated static func mergeKeys(from source: URL, into folder: URL) throws -> Int {
    try mergeKeys(text: String(contentsOf: source, encoding: .utf8), into: folder)
  }

  /// Adds the keys in `incoming` that keys.txt doesn't have yet (other lines are left out). Returns how many;
  /// throws when `incoming` has no key at all.
  nonisolated static func mergeKeys(text incoming: String, into folder: URL) throws -> Int {
    let target = folder.appendingPathComponent("keys.txt")
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    var known = Set(existing.split(whereSeparator: \.isNewline).compactMap { key(in: $0) })
    var added: [String] = []
    var valid = 0
    for line in incoming.split(whereSeparator: \.isNewline) {
      guard let k = key(in: line) else { continue }
      valid += 1
      guard !known.contains(k) else { continue }
      known.insert(k)
      added.append(line.contains("#") ? line.trimmingCharacters(in: .whitespaces) : k)
    }
    guard valid > 0 else { throw KeyError.noKeys }
    guard !added.isEmpty else { return 0 }
    var text = existing
    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    text += added.joined(separator: "\n") + "\n"
    try text.write(to: target, atomically: true, encoding: .utf8)
    return added.count
  }

  struct Outcome {
    var added: [String] = []
    var skipped: [String] = []
    var errors: [String] = []
    var keysAdded = 0
    /// Archives with no Wii U game inside, and whether a GameCube or Wii game was found instead.
    var archivesWithoutWiiU: [(url: URL, otherSystem: Bool)] = []
    /// Game folders found inside archives without their title.tik.
    var noTicket: [String] = []
    /// Updates and extra content that were added: they don't get a case of their own.
    var addOns: [String] = []
  }

  /// Hidden folders archives are unpacked into, inside the Wii U folder (same disk, so moving out is instant).
  static let unpackPrefix = ".unpacking-"

  /// The file work of an import, off the main thread. A name already in the folder is skipped, never replaced.
  nonisolated static func copy(_ sorted: Sorted, into folder: URL, move: Bool) -> Outcome {
    let fm = FileManager.default
    _ = ImportStaging.removeStaleStagedImports(inFolder: folder.path)
    for leftover in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where leftover.hasPrefix(unpackPrefix) {
      try? fm.removeItem(at: folder.appendingPathComponent(leftover))   // an unpack cut short last time
    }
    var outcome = Outcome()
    for archive in sorted.archives {
      unpack(archive, into: folder, deleteArchive: move, outcome: &outcome)
    }
    for url in sorted.items {
      add(url, into: folder, move: move, outcome: &outcome)
    }
    for url in sorted.keys {
      do { outcome.keysAdded += try mergeKeys(from: url, into: folder) }
      catch { outcome.errors.append("keys.txt: \(error.localizedDescription)") }
    }
    return outcome
  }

  /// Places one game, update or homebrew file, after checking it isn't there already and that it fits.
  nonisolated private static func add(_ url: URL, into folder: URL, move: Bool, outcome: inout Outcome) {
    let name = url.lastPathComponent
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
      outcome.skipped.append(name); return
    }
    if !sameDisk(url, folder), let message = spaceProblem(for: url, needing: size(of: url), into: folder) {
      outcome.errors.append(message); return
    }
    do { try place(url, in: folder, move: move) } catch {
      outcome.errors.append("\(name): \(error.localizedDescription)"); return
    }
    let placed = folder.appendingPathComponent(name)
    if isDirectory(placed), let id = WiiUFileTypes.titleID(ofFolder: placed), WiiUFileTypes.kind(ofTitleID: id) != .game {
      outcome.addOns.append(name)
    } else {
      outcome.added.append(name)
    }
  }

  /// On the same disk a copy is a clone and a move a rename, so neither needs free space.
  nonisolated private static func sameDisk(_ a: URL, _ b: URL) -> Bool {
    guard let x = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
          let y = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject else { return false }
    return x.isEqual(y)
  }

  /// A message when `needed` bytes for `url` won't fit in the space left in `folder`.
  nonisolated private static func spaceProblem(for url: URL, needing needed: Int64, into folder: URL) -> String? {
    guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage else { return nil }
    let margin: Int64 = 200 * 1024 * 1024
    guard needed + margin > free else { return nil }
    let f = ByteCountFormatter()
    f.countStyle = .file
    return String(format: L("There isn't enough space for %@. It needs %@, and %@ is free."),
                  url.lastPathComponent, f.string(fromByteCount: needed), f.string(fromByteCount: max(0, free)))
  }

  nonisolated private static func size(of url: URL) -> Int64 {
    guard isDirectory(url) else {
      return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total: Int64 = 0
    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    while let file = e?.nextObject() as? URL {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }

  /// Unpacks `archive` into a hidden folder, adds the Wii U games and keys inside, then removes that folder.
  /// The archive itself is deleted only when `deleteArchive` and a game came out of it.
  nonisolated private static func unpack(_ archive: URL, into folder: URL, deleteArchive: Bool, outcome: inout Outcome) {
    let fm = FileManager.default
    let name = archive.lastPathComponent
    let temp = folder.appendingPathComponent(unpackPrefix + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: temp) }
    // The unpacked game is at least as big as the archive.
    if let message = spaceProblem(for: archive, needing: size(of: archive), into: folder) {
      outcome.errors.append(message); return
    }
    do { try ZipImportHelper.extractArchive(at: archive, to: temp) } catch {
      outcome.errors.append(String(format: L("%@ couldn't be unpacked: %@"), name, error.localizedDescription))
      return
    }
    let children = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let inner = sort(children, maxDepth: 3)
    outcome.noTicket += inner.noTicket
    if inner.items.isEmpty && inner.keys.isEmpty {
      if inner.noTicket.isEmpty {
        outcome.archivesWithoutWiiU.append((archive, !inner.gameCube.isEmpty || !inner.wii.isEmpty))
      }
      return
    }
    let before = outcome.added.count + outcome.addOns.count
    for url in inner.items {
      add(url, into: folder, move: true, outcome: &outcome)
    }
    for url in inner.keys {
      do { outcome.keysAdded += try mergeKeys(from: url, into: folder) }
      catch { outcome.errors.append("keys.txt: \(error.localizedDescription)") }
    }
    if deleteArchive, outcome.added.count + outcome.addOns.count > before { try? fm.removeItem(at: archive) }
  }
}

extension WiiUImport {
  static let showTabNotification = Notification.Name("IridiaShowWiiUTab")
  private static let strayAskedKey = "wiiuStrayAsked"
  @MainActor private static var strayAlertShowing = false

  /// Wii U games (and keys.txt) the Files app put in the GameCube folder, where nothing shows them. Each one is
  /// offered a move to the Wii U folder once; "Not Now" isn't asked again for the same name.
  @MainActor static func offerToMoveStrayGames() {
    guard WiiUModel.canRunGames, !strayAlertShowing, !EmulationState.shared.isActive,
          WiiUModel.shared.playing == nil, !WiiUModel.shared.importing else { return }
    let games = URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true)
    let asked = Set(UserDefaults.standard.stringArray(forKey: strayAskedKey) ?? [])
    let stray = WiiUFileTypes.walk(games, maxDepth: 2).filter { url in
      guard !asked.contains(url.lastPathComponent) else { return false }
      if WiiUFileTypes.isDirectory(url) { return WiiUFileTypes.isTitleFolder(url) }
      return WiiUFileTypes.isWiiUFile(url) || url.lastPathComponent.lowercased() == "keys.txt"
    }
    guard !stray.isEmpty else { return }
    let remember = {
      UserDefaults.standard.set(Array(asked.union(stray.map(\.lastPathComponent))), forKey: strayAskedKey)
      strayAlertShowing = false
    }
    strayAlertShowing = true
    IridiaAlert.show(
      L("Wii U Games in the GameCube Folder"),
      String(format: stray.count == 1 ? L("%@ belongs on the Wii U tab. Move it to the Wii U folder?")
                                      : L("%@ belong on the Wii U tab. Move them to the Wii U folder?"),
             WiiUModel.shortList(stray.map(\.lastPathComponent))),
      buttons: [
        IridiaAlertButton(L("Move")) {
          remember()
          NotificationCenter.default.post(name: showTabNotification, object: nil)
          WiiUModel.shared.addIncoming(stray)
        },
        IridiaAlertButton(L("Not Now"), .cancel) { remember() },
      ])
  }
}

extension WiiUModel {
  /// "Choose a Game File" on the Wii U tab.
  func chooseGameFiles() {
    GameFilePicker.present(types: [.data, .folder], directory: gamesDir) { [weak self] urls in
      self?.add(urls)
    }
  }

  /// Adds picked files and folders: explains anything that isn't a Wii U game, then asks Copy or Move.
  func add(_ urls: [URL]) {
    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    let sorted = WiiUImport.sort(urls)
    var notes: [String] = []
    // GameCube formats (.rvz, .gcz, ...) can hold Wii games too, so these say what they aren't.
    let notWiiU = sorted.gameCube + sorted.wii
    if !notWiiU.isEmpty {
      notes.append(String(format: notWiiU.count == 1 ? L("%@ isn't a Wii U game. GameCube games go on the GameCube tab.")
                                                     : L("%@ aren't Wii U games. GameCube games go on the GameCube tab."),
                          Self.shortList(notWiiU)))
    }
    if !sorted.other.isEmpty {
      notes.append(String(format: sorted.other.count == 1
                            ? L("%@ isn't a Wii U game. Use WUA, WUX, WUD or RPX files, a game folder, or a ZIP or 7Z with one inside.")
                            : L("%@ aren't Wii U games. Use WUA, WUX, WUD or RPX files, a game folder, or a ZIP or 7Z with one inside."),
                          Self.shortList(sorted.other)))
    }
    if !sorted.noTicket.isEmpty {
      notes.append(Self.noTicketNote(sorted.noTicket))
    }
    guard !sorted.items.isEmpty || !sorted.keys.isEmpty || !sorted.archives.isEmpty else {
      accessed.forEach { $0.stopAccessingSecurityScopedResource() }
      alert(title: L("Nothing to Add"), message: notes.joined(separator: "\n\n"))
      return
    }
    let finish = { (move: Bool?) in
      guard let move else {
        accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        return
      }
      self.copyIn(sorted, move: move, notes: notes) { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
    }
    // keys.txt alone is always copied; games get the same Copy / Move question as the GameCube shelf.
    if sorted.items.isEmpty && sorted.archives.isEmpty { finish(false); return }
    IridiaAlert.show(L("Import"), look: .wiiU, buttons: [
      IridiaAlertButton(L("Copy")) { finish(false) },
      IridiaAlertButton(L("Move")) { finish(true) },
      .cancel { finish(nil) },
    ])
  }

  /// Archives the Files app put straight into the Wii U folder: unpacked once, and removed when a game came out.
  /// One that has no Wii U game is left where it is and not tried again. Returns true when an unpack started
  /// (it scans the shelf again when it's done).
  func unpackArchivesInFolder() -> Bool {
    guard !importing else { return false }
    let tried = Set(UserDefaults.standard.stringArray(forKey: Self.archivesTriedKey) ?? [])
    let archives = WiiUFileTypes.walk(gamesDir, maxDepth: 3)
      .filter { WiiUImport.classify($0) == .archive && !tried.contains(Self.archiveKey($0)) }
    guard !archives.isEmpty else { return false }
    let keys = archives.map(Self.archiveKey)
    var sorted = WiiUImport.Sorted()
    sorted.archives = archives
    // Marked as tried only once the unpack is done, so one cut short (Iridia closed) is tried again.
    copyIn(sorted, move: true, notes: []) {
      let now = Set(UserDefaults.standard.stringArray(forKey: Self.archivesTriedKey) ?? []).union(keys)
      UserDefaults.standard.set(Array(now), forKey: Self.archivesTriedKey)
    }
    return true
  }

  private static let archivesTriedKey = "wiiuArchivesTried"
  nonisolated private static func archiveKey(_ url: URL) -> String {
    "\(url.lastPathComponent)|\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
  }

  /// "A, B, C and 4 more": a folder of other files can hold dozens.
  static func shortList(_ names: [String]) -> String {
    guard names.count > 3 else { return names.joined(separator: ", ") }
    return String(format: L("%@ and %ld more"), names.prefix(3).joined(separator: ", "), names.count - 3)
  }

  static func noTicketNote(_ names: [String]) -> String {
    String(format: L("%@ is missing its title.tik file, so it can't be opened. Use a copy of the game folder that has title.tik in it."),
           shortList(names))
  }

  /// Files opened into Iridia from another app (share sheet, AirDrop, "Open in"). iOS hands over a copy in
  /// Documents/Inbox, so it's moved, not copied. Archives with a GameCube game go on to the GameCube import.
  func addIncoming(_ urls: [URL]) {
    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    let sorted = WiiUImport.sort(urls)
    var notes: [String] = []
    if !sorted.noTicket.isEmpty { notes.append(Self.noTicketNote(sorted.noTicket)) }
    copyIn(sorted, move: true, notes: notes, gameCubeArchivesToGameCube: true) {
      accessed.forEach { $0.stopAccessingSecurityScopedResource() }
    }
  }

  func copyIn(_ sorted: WiiUImport.Sorted, move: Bool, notes: [String], gameCubeArchivesToGameCube: Bool = false,
                      done: @escaping () -> Void) {
    importing = true
    let folder = gamesDir
    let task = ImportStaging.beginBackgroundTask()
    Task.detached(priority: .userInitiated) {
      let outcome = WiiUImport.copy(sorted, into: folder, move: move)
      await MainActor.run {
        ImportStaging.endBackgroundTask(task)
        done()
        self.importing = false
        var lines = notes
        if !outcome.added.isEmpty {
          lines.insert(outcome.added.count == 1 ? String(format: L("Added %@."), outcome.added[0])
                                                : String(format: L("Added %ld games."), outcome.added.count), at: 0)
        }
        if outcome.keysAdded > 0 {
          lines.append(outcome.keysAdded == 1 ? L("Added 1 key to keys.txt.")
                                              : String(format: L("Added %ld keys to keys.txt."), outcome.keysAdded))
        } else if !sorted.keys.isEmpty, outcome.errors.isEmpty {
          lines.append(L("keys.txt already has these keys."))
        }
        var toGameCube: [URL] = []
        for archive in outcome.archivesWithoutWiiU {
          let name = archive.url.lastPathComponent
          if archive.otherSystem, gameCubeArchivesToGameCube {
            toGameCube.append(archive.url)
          } else {
            lines.append(archive.otherSystem
              ? String(format: L("%@ has a GameCube or Wii game inside, not a Wii U game. GameCube games go on the GameCube tab."), name)
              : String(format: L("%@ doesn't have a Wii U game inside."), name))
          }
        }
        if !outcome.noTicket.isEmpty { lines.append(Self.noTicketNote(outcome.noTicket)) }
        if !outcome.addOns.isEmpty {
          lines.append(String(format: L("Added %@. Updates and extra content don't get their own case: the game uses them when you play it."),
                              Self.shortList(outcome.addOns)))
        }
        if !outcome.skipped.isEmpty {
          lines.append(String(format: L("Already in the Wii U folder: %@."), Self.shortList(outcome.skipped)))
        }
        lines += outcome.errors.prefix(3)
        if !toGameCube.isEmpty { ImportFileManager.shared().importFiles(at: toGameCube as [NSURL]) }
        self.rescan()
        // A plain "Added" needs no alert: the game appears on the shelf. Anything else is said once.
        if !lines.isEmpty, !(lines.count == 1 && !outcome.added.isEmpty) {
          self.alert(title: outcome.errors.isEmpty ? L("Import") : L("Some Files Weren't Added"), message: lines.joined(separator: "\n\n"))
        }
      }
    }
  }

  private func alert(title: String, message: String) {
    IridiaAlert.show(title, message, look: .wiiU)
  }
}
#endif
