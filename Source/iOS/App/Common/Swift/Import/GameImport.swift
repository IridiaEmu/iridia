// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: every way a game gets into Iridia ends here, so a game always lands on its own tab whichever tab
// it was added from. What a file is comes from its contents: the core's disc readers for GameCube and Wii
// (every disc format, compressed ones too), file signatures for Wii U. Archives are unpacked first and what's
// inside is sorted the same way.

#if os(iOS)
import Foundation
import UIKit

enum GameSystem: CaseIterable {
  case gameCube, wii, wiiU

  var tabName: String {
    switch self {
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .wiiU: return L("Wii U")
    }
  }

  var look: IridiaAlert.Look {
    switch self {
    case .gameCube: return .gameCube
    case .wii: return .wii
    case .wiiU: return .wiiU
    }
  }

  @MainActor static var current: GameSystem {
    switch HomeRouter.shared.system {
    case .gameCube: return .gameCube
    case .wii: return .wii
    case .wiiU: return .wiiU
    }
  }
}

enum GameDetect {
  enum Kind: Equatable { case game(GameSystem), wiiUKeys, archive, none }

  nonisolated static func kind(of url: URL) -> Kind {
    if WiiUFileTypes.isDirectory(url) { return WiiUFileTypes.isTitleFolder(url) ? .game(.wiiU) : .none }
    if isArchive(url) { return .archive }
    if isWiiU(url) { return .game(.wiiU) }
    switch TVGameItem.systemOfFile(atPath: url.path) {
    case 1: return .game(.gameCube)
    case 2: return .game(.wii)
    default: return isKeysFile(url) ? .wiiUKeys : .none
    }
  }

  /// Wii U files by their signatures: a disc image (WUD, or one named .iso) starts with "WUP-", WUX with "WUX0",
  /// a homebrew bundle with "WUHB", a program (RPX) is an ELF marked with the CAFE ABI, and a WUA ends with the
  /// ZArchive footer.
  nonisolated static func isWiiU(_ url: URL) -> Bool {
    guard let head = WiiUFileTypes.readHead(url, count: 9) else { return false }
    if head.starts(with: Data("WUP-".utf8)) || head.starts(with: Data("WUHB".utf8)) { return true }
    if head.starts(with: Data("WUX0".utf8) + Data([0x2E, 0xD0, 0x99, 0x10])) { return true }
    if head.starts(with: Data([0x7F]) + Data("ELF".utf8)), head[7] == 0xCA, head[8] == 0xFE { return true }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd(), end >= 8, (try? handle.seek(toOffset: end - 8)) != nil,
          let tail = try? handle.read(upToCount: 8) else { return false }
    return tail == Data([0x61, 0xBF, 0x3A, 0x01, 0x16, 0x9F, 0x52, 0xD6])
  }

  /// ZIP, 7Z, gzip, bzip2, xz or tar, by signature.
  nonisolated static func isArchive(_ url: URL) -> Bool {
    guard let head = WiiUFileTypes.readHead(url, count: 6) ?? WiiUFileTypes.readHead(url, count: 4) else { return false }
    let signatures: [[UInt8]] = [[0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06], [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
                                 [0x1F, 0x8B], [0x42, 0x5A, 0x68], [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]]
    if signatures.contains(where: { head.starts(with: $0) }) { return true }
    guard let tar = WiiUFileTypes.readHead(url, count: 262) else { return false }
    return tar[257..<262] == Data("ustar".utf8)
  }

  /// A small text file with at least one Wii U disc key line.
  nonisolated static func isKeysFile(_ url: URL) -> Bool {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    guard size < 64 * 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return text.split(whereSeparator: \.isNewline).contains { WiiUImport.key(in: $0) != nil }
  }

  /// From an archive's list of names alone (for offering it before it's unpacked): which systems it may hold.
  /// A .iso can be a Wii U disc, so it counts for both; keys.txt counts for Wii U.
  nonisolated static func systems(inArchiveNames names: [String]) -> Set<GameSystem> {
    var found = Set<GameSystem>()
    for name in names.map({ $0.lowercased() }) {
      let ext = (name as NSString).pathExtension
      if WiiUFileTypes.extensions.contains(ext) || name.hasSuffix("title.tmd") || name.hasSuffix("meta/meta.xml") || ext == "iso"
        || (name as NSString).lastPathComponent == "keys.txt" {
        found.insert(.wiiU)
      }
      if ["iso", "gcm", "tgc", "gcz", "ciso", "rvz", "wia", "wbfs", "nkit", "dol", "elf", "wad"].contains(ext) {
        found.insert(.gameCube)
        found.insert(.wii)
      }
    }
    return found
  }
}

/// The archive being unpacked, saved so an unpack the app was closed in the middle of can be offered again.
enum PendingUnpack {
  private static let key = "unpackInProgress"

  static func remember(_ archive: URL) {
    // Default options, so a file picked in Files keeps the access it needs after a relaunch.
    let bookmark = try? archive.bookmarkData()
    UserDefaults.standard.set(bookmark, forKey: key)
  }

  static func forget() { UserDefaults.standard.removeObject(forKey: key) }

  static func take() -> URL? {
    defer { forget() }
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    var stale = false
    return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
  }
}

enum GameImport {
  struct Folders {
    var gameCube: URL
    var wii: URL
    var wiiU: URL
    /// Archives are unpacked here; on the same disk as the folders, so moving out is instant.
    var scratch: URL

    func folder(for system: GameSystem) -> URL {
      switch system {
      case .gameCube: return gameCube
      case .wii: return wii
      case .wiiU: return wiiU
      }
    }
  }

  /// What was found among picked files, folders and unpacked archives.
  struct Found {
    var games: [GameSystem: [URL]] = [:]
    var wiiUKeys: [URL] = []
    var archives: [URL] = []
    var noTicket: [String] = []
    var notGames: [String] = []

    var isEmpty: Bool { games.values.allSatisfy(\.isEmpty) && wiiUKeys.isEmpty && archives.isEmpty }
    /// Everything found that isn't a "not a game" note.
    var count: Int { games.values.map(\.count).reduce(0, +) + wiiUKeys.count + archives.count + noTicket.count }
    var hasGames: Bool { games.values.contains { !$0.isEmpty } || !archives.isEmpty }
  }

  struct Outcome {
    var added: [GameSystem: [String]] = [:]
    var addOns: [String] = []
    var keysAdded = 0
    var skipped: [String] = []
    var errors: [String] = []
    var notGames: [String] = []
    var noTicket: [String] = []
    /// Archives with nothing playable inside.
    var emptyArchives: [String] = []
    /// Archives kept because not everything in them was added.
    var keptArchives: [String] = []
    /// Archives the player stopped unpacking.
    var cancelled: [String] = []
    /// Archives whose unpacking was cut off (the app went to the background for too long), to offer again.
    var interrupted: [URL] = []

    var addedCount: Int { added.values.reduce(0) { $0 + $1.count } + addOns.count }
  }

  private static let unpackPrefix = ".unpacking-"

  /// Sorts `urls`. Picked folders are looked into `maxDepth` levels down; a picked item that isn't a game is
  /// named in `notGames` (things inside folders that aren't games are passed over quietly).
  nonisolated static func find(_ urls: [URL], maxDepth: Int = 2) -> Found {
    var found = Found()
    func visit(_ url: URL, depth: Int, picked: Bool) {
      if url.lastPathComponent.hasPrefix(".") { return }
      switch GameDetect.kind(of: url) {
      case .game(let system):
        if system == .wiiU, WiiUFileTypes.isMissingTicket(url) { found.noTicket.append(url.lastPathComponent) }
        else { found.games[system, default: []].append(url) }
      case .wiiUKeys: found.wiiUKeys.append(url)
      case .archive: found.archives.append(url)
      case .none:
        if WiiUFileTypes.isDirectory(url), depth < maxDepth {
          let before = found.count
          let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
          for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            visit(child, depth: depth + 1, picked: false)
          }
          if picked, found.count == before { found.notGames.append(url.lastPathComponent) }
        } else if picked {
          found.notGames.append(url.lastPathComponent)
        }
      }
    }
    for url in urls { visit(url, depth: 0, picked: true) }
    return found
  }

  /// Puts every game in `urls` into its system's folder. `move` moves files and removes archives a game came out
  /// of; otherwise the originals are left as they are. Archives inside archives aren't opened.
  nonisolated static func run(_ urls: [URL], into folders: Folders, move: Bool, look: IridiaAlert.Look = .gameCube) -> Outcome {
    var outcome = Outcome()
    let found = find(urls)
    outcome.notGames = found.notGames
    outcome.noTicket = found.noTicket
    place(found, into: folders, move: move, outcome: &outcome)
    for archive in found.archives { unpack(archive, into: folders, deleteArchive: move, look: look, outcome: &outcome) }
    return outcome
  }

  nonisolated private static func place(_ found: Found, into folders: Folders, move: Bool, outcome: inout Outcome) {
    for system in [GameSystem.gameCube, .wii] {
      let folder = folders.folder(for: system)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for url in found.games[system] ?? [] {
        let name = url.lastPathComponent
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
          outcome.skipped.append(name)
          continue
        }
        if !WiiUImport.sameDisk(url, folder),
           let message = WiiUImport.spaceProblem(for: url, needing: WiiUImport.size(of: url), into: folder) {
          outcome.errors.append(message)
          continue
        }
        do {
          try WiiUImport.place(url, in: folder, move: move)
          LibraryAddedDateStore.record(path: folder.appendingPathComponent(name).path)
          outcome.added[system, default: []].append(name)
        } catch {
          outcome.errors.append("\(name): \(error.localizedDescription)")
        }
      }
    }
    let wiiU = found.games[.wiiU] ?? []
    guard !wiiU.isEmpty || !found.wiiUKeys.isEmpty else { return }
    try? FileManager.default.createDirectory(at: folders.wiiU, withIntermediateDirectories: true)
    var sorted = WiiUImport.Sorted()
    sorted.items = wiiU
    sorted.keys = found.wiiUKeys
    let result = WiiUImport.copy(sorted, into: folders.wiiU, move: move)
    outcome.added[.wiiU, default: []] += result.added
    outcome.addOns += result.addOns
    outcome.keysAdded += result.keysAdded
    outcome.skipped += result.skipped
    outcome.errors += result.errors
  }

  nonisolated private static func unpack(_ archive: URL, into folders: Folders, deleteArchive: Bool, look: IridiaAlert.Look,
                                          outcome: inout Outcome) {
    let fm = FileManager.default
    let name = archive.lastPathComponent
    try? fm.createDirectory(at: folders.scratch, withIntermediateDirectories: true)
    let temp = folders.scratch.appendingPathComponent(unpackPrefix + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: temp) }
    // What comes out, plus the private copy of the archive when it has to be copied from another disk.
    let unpacked = ZipImportHelper.unpackedSize(of: archive) ?? WiiUImport.size(of: archive)
    let copy = WiiUImport.sameDisk(archive, folders.scratch) ? 0 : WiiUImport.size(of: archive)
    if let message = unpackSpaceProblem(archive, needing: unpacked + copy, into: folders.scratch) {
      outcome.errors.append(message)
      return
    }
    let progress = UnpackProgress()
    UnpackCard.begin(name, progress: progress, look: look)
    defer { UnpackCard.end() }
    current.set(progress)
    defer { current.set(nil) }
    PendingUnpack.remember(archive)
    defer { PendingUnpack.forget() }
    do { try ZipImportHelper.extractArchive(at: archive, to: temp, progress: progress) } catch UnpackError.cancelled {
      if progress.wasInterrupted { outcome.interrupted.append(archive) } else { outcome.cancelled.append(name) }
      return
    } catch {
      outcome.errors.append(String(format: L("%@ couldn't be unpacked: %@"), name, error.localizedDescription))
      return
    }
    let children = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    var inner = find(children, maxDepth: 3)
    inner.archives = []
    inner.notGames = []
    outcome.noTicket += inner.noTicket
    guard !inner.isEmpty else {
      if inner.noTicket.isEmpty { outcome.emptyArchives.append(name) }
      return
    }
    let before = outcome.addedCount + outcome.keysAdded
    let failed = (outcome.errors.count, outcome.noTicket.count)
    place(inner, into: folders, move: true, outcome: &outcome)
    guard deleteArchive, outcome.addedCount + outcome.keysAdded > before else { return }
    if outcome.errors.count == failed.0, outcome.noTicket.count == failed.1 {
      try? fm.removeItem(at: archive)
    } else {
      outcome.keptArchives.append(name)
    }
  }

  nonisolated static func unpackSpaceProblem(_ archive: URL, needing needed: Int64, into folder: URL) -> String? {
    guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage else { return nil }
    let margin: Int64 = 200 * 1024 * 1024
    guard needed + margin > free else { return nil }
    let f = ByteCountFormatter()
    f.countStyle = .file
    return String(format: L("There isn't enough space to unpack %@. It needs %@ free, and %@ is free. Free up %@ and try again."),
                  archive.lastPathComponent, f.string(fromByteCount: needed + margin), f.string(fromByteCount: max(0, free)),
                  f.string(fromByteCount: needed + margin - max(0, free)))
  }

  /// The unpack running now, so the background time running out can stop it cleanly.
  nonisolated private static let current = CurrentUnpack()

  private final class CurrentUnpack: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: UnpackProgress?
    func set(_ progress: UnpackProgress?) { lock.withLock { self.progress = progress } }
    func interrupt() { lock.withLock { progress?.interrupt() } }
  }

  /// Archives and other systems' games the Files app put straight into one of the three folders: each goes to
  /// its own folder. Archives that have nothing playable are left where they are and not tried again.
  nonisolated static func tidy(_ folders: Folders) -> Outcome {
    let fm = FileManager.default
    let tried = Set(UserDefaults.standard.stringArray(forKey: triedKey) ?? [])
    var stray: [URL] = []
    var archives: [URL] = []
    for system in GameSystem.allCases {
      let folder = folders.folder(for: system)
      for url in WiiUFileTypes.walk(folder, maxDepth: 2) where !url.lastPathComponent.hasPrefix(".") {
        if url.lastPathComponent.hasSuffix(ImportStaging.stagingSuffix) { continue }
        let direct = url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
        if WiiUFileTypes.isDirectory(url) {
          if system != .wiiU, direct, WiiUFileTypes.isTitleFolder(url) { stray.append(url) }
          continue
        }
        if GameDetect.isArchive(url) {
          if !tried.contains(key(url)) { archives.append(url) }
          continue
        }
        guard direct else { continue }
        // GameCube and Wii games show on their own shelves from either of their folders; only moves between
        // those and the Wii U folder are needed. The disc reader only runs on the few files the Wii U shelf can't use.
        if system == .wiiU {
          let ext = url.pathExtension.lowercased()
          if !GameDetect.isWiiU(url), ext != "txt", ext != "tik", ext != "tmd" {
            if case .game = GameDetect.kind(of: url) { stray.append(url) }
          }
        } else if GameDetect.isWiiU(url) || (url.pathExtension.lowercased() == "txt" && GameDetect.isKeysFile(url)) {
          stray.append(url)
        }
      }
    }
    var outcome = Outcome()
    if !stray.isEmpty {
      var found = Found()
      for url in stray {
        switch GameDetect.kind(of: url) {
        case .game(let system): found.games[system, default: []].append(url)
        case .wiiUKeys: found.wiiUKeys.append(url)
        default: break
        }
      }
      place(found, into: folders, move: true, outcome: &outcome)
    }
    for archive in archives {
      let stopped = outcome.cancelled.count + outcome.interrupted.count
      unpack(archive, into: folders, deleteArchive: true, look: .gameCube, outcome: &outcome)
      if outcome.cancelled.count + outcome.interrupted.count > stopped { continue }
      if fm.fileExists(atPath: archive.path) {
        let now = Set(UserDefaults.standard.stringArray(forKey: triedKey) ?? []).union([key(archive)])
        UserDefaults.standard.set(Array(now), forKey: triedKey)
      }
    }
    return outcome
  }

  private static let triedKey = "archivesTried"
  nonisolated private static func key(_ url: URL) -> String {
    "\(url.lastPathComponent)|\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
  }
}

// MARK: - On screen

extension GameImport {
  static var appFolders: Folders {
    let user = URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
    let docs = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0], isDirectory: true)
    return Folders(gameCube: URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true),
                   wii: URL(fileURLWithPath: UserFolderUtil.getWiiFolder(), isDirectory: true),
                   wiiU: docs.appendingPathComponent(UserFolderUtil.wiiUFolderName, isDirectory: true),
                   scratch: user.appendingPathComponent("Unpacking", isDirectory: true))
  }

  @MainActor private(set) static var busy = false
  @MainActor private static var waiting: [() -> Void] = []

  @MainActor private static func startNext() {
    busy = false
    if !waiting.isEmpty { waiting.removeFirst()() }
  }

  @MainActor private static var gameRunning: Bool {
    #if canImport(IridiaCafeCore)
    if WiiUModel.shared.playing != nil { return true }
    #endif
    return TVEmulationBridge.isRunning()
  }

  /// Picked files and folders, from any tab. `incoming` (share sheet, Open in, Downloads): moved, not copied,
  /// without asking.
  @MainActor static func add(_ urls: [URL], from tab: GameSystem, incoming: Bool = false, done: (() -> Void)? = nil) {
    let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    let finish = {
      accessed.forEach { $0.stopAccessingSecurityScopedResource() }
      done?()
    }
    Task.detached(priority: .userInitiated) {
      let found = find(urls)
      await MainActor.run {
        guard !found.isEmpty else {
          finish()
          var lines: [String] = []
          if !found.notGames.isEmpty { lines.append(notGamesNote(found.notGames)) }
          if !found.noTicket.isEmpty { lines.append(noTicketNote(found.noTicket)) }
          IridiaAlert.show(L("Nothing to Add"), lines.joined(separator: "\n\n"), look: tab.look)
          return
        }
        if incoming || !found.hasGames { start(urls, from: tab, move: incoming, done: finish); return }
        IridiaAlert.show(L("Import"), look: tab.look, buttons: [
          IridiaAlertButton(L("Copy")) { start(urls, from: tab, move: false, done: finish) },
          IridiaAlertButton(L("Move")) { start(urls, from: tab, move: true, done: finish) },
          .cancel { finish() },
        ])
      }
    }
  }

  @MainActor private static func start(_ urls: [URL], from tab: GameSystem, move: Bool, done: @escaping () -> Void) {
    guard !busy else {
      waiting.append { start(urls, from: tab, move: move, done: done) }
      return
    }
    busy = true
    let folders = appFolders
    // When the extra time in the background runs out, the unpack stops and cleans up, and is offered again.
    let task = UIApplication.shared.beginBackgroundTask(withName: "iridia.import") { current.interrupt() }
    Task.detached(priority: .userInitiated) {
      let outcome = run(urls, into: folders, move: move, look: tab.look)
      await MainActor.run {
        ImportStaging.endBackgroundTask(task)
        done()
        report(outcome, from: tab)
        offerAgain(outcome.interrupted, from: tab, move: move)
        startNext()
      }
    }
  }

  @MainActor private static var checkedInterrupted = false

  @MainActor private static func offerAgain(_ archives: [URL], from tab: GameSystem, move: Bool, appWasClosed: Bool = false) {
    guard !archives.isEmpty else { return }
    let names = shortList(archives.map(\.lastPathComponent))
    let reason = appWasClosed
      ? L("%@ wasn't finished unpacking because Iridia was closed. Nothing was added.")
      : L("%@ wasn't finished unpacking because Iridia was in the background. Nothing was added.")
    IridiaAlert.show(L("Unpacking Stopped"), String(format: reason, names),
                     look: tab.look, buttons: [
                       IridiaAlertButton(L("Try Again")) {
                         let accessed = archives.filter { $0.startAccessingSecurityScopedResource() }
                         start(archives, from: tab, move: move) { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                       },
                       .cancel(),
                     ])
  }

  /// An unpack the app was closed in the middle of: its leftovers are removed, and it's offered again if the
  /// archive is still there.
  @MainActor static func finishInterruptedUnpack(from tab: GameSystem) {
    guard !checkedInterrupted, !busy else { return }
    checkedInterrupted = true
    let folders = appFolders
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folders.scratch.path)) ?? []
    for name in names where name.hasPrefix(unpackPrefix) {
      try? FileManager.default.removeItem(at: folders.scratch.appendingPathComponent(name, isDirectory: true))
    }
    guard let archive = PendingUnpack.take() else { return }
    let accessed = archive.startAccessingSecurityScopedResource()
    let there = FileManager.default.fileExists(atPath: archive.path)
    if accessed { archive.stopAccessingSecurityScopedResource() }
    guard there else { return }
    offerAgain([archive], from: tab, move: false, appWasClosed: true)
  }

  /// Files the Files app put in the wrong folder, and archives put in any of them. Runs before the shelves scan.
  @MainActor static func tidyFolders(then: (() -> Void)? = nil) {
    guard !busy, !gameRunning else { then?(); return }
    busy = true
    let folders = appFolders
    Task.detached(priority: .utility) {
      UserFolderUtil.moveOldGamesFolder()
      let outcome = tidy(folders)
      await MainActor.run {
        if outcome.addedCount + outcome.keysAdded > 0 || !outcome.errors.isEmpty { report(outcome, from: nil) }
        then?()
        startNext()
      }
    }
  }

  /// Says what happened. Games that went to another tab are named with that tab. A plain "Added" is a snackbar;
  /// anything that needs reading is a popup.
  @MainActor static func report(_ outcome: Outcome, from tab: GameSystem?) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil)
    #if canImport(IridiaCafeCore)
    if !(outcome.added[.wiiU] ?? []).isEmpty || !outcome.addOns.isEmpty || outcome.keysAdded > 0 { WiiUModel.shared.rescan() }
    #endif
    let (news, problems) = lines(for: outcome, from: tab)
    if problems.isEmpty {
      guard !news.isEmpty else { return }
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil,
                                      userInfo: ["text": news.joined(separator: " "), "seconds": 4.0])
    } else {
      IridiaAlert.show(outcome.errors.isEmpty ? L("Import") : L("Some Files Weren't Added"),
                       (news + problems).joined(separator: "\n\n"), look: (tab ?? .current).look)
    }
  }

  /// What to tell the player: short news (what was added, and where games for another tab went), and problems
  /// that need reading.
  static func lines(for outcome: Outcome, from tab: GameSystem?) -> (news: [String], problems: [String]) {
    var news: [String] = []
    for system in GameSystem.allCases {
      let names = outcome.added[system] ?? []
      guard !names.isEmpty else { continue }
      if system == tab {
        news.append(names.count == 1 ? String(format: L("Added %@."), names[0]) : String(format: L("Added %ld games."), names.count))
      } else {
        news.append(String(format: L("%@ went to the %@ tab."), shortList(names), system.tabName))
      }
    }
    var problems: [String] = []
    if outcome.keysAdded > 0 {
      news.append(outcome.keysAdded == 1 ? L("Added 1 key to keys.txt.") : String(format: L("Added %ld keys to keys.txt."), outcome.keysAdded))
    }
    if !outcome.addOns.isEmpty {
      problems.append(String(format: L("Added %@. Updates and extra content don't get their own case: the game uses them when you play it."),
                             shortList(outcome.addOns)))
    }
    if !outcome.notGames.isEmpty { problems.append(notGamesNote(outcome.notGames)) }
    for name in outcome.emptyArchives { problems.append(String(format: L("%@ doesn't have a game inside."), name)) }
    for name in outcome.keptArchives {
      problems.append(String(format: L("Not everything in %@ could be added, so it was kept."), name))
    }
    if !outcome.cancelled.isEmpty { news.append(String(format: L("Stopped unpacking %@."), shortList(outcome.cancelled))) }
    if !outcome.noTicket.isEmpty { problems.append(noTicketNote(outcome.noTicket)) }
    if !outcome.skipped.isEmpty { problems.append(String(format: L("Already on your shelf: %@."), shortList(outcome.skipped))) }
    problems += outcome.errors.prefix(3)
    return (news, problems)
  }

  static func notGamesNote(_ names: [String]) -> String {
    String(format: names.count == 1 ? L("%@ isn't a game Iridia can play.") : L("%@ aren't games Iridia can play."), shortList(names))
  }

  static func noTicketNote(_ names: [String]) -> String {
    String(format: L("%@ is missing its title.tik file, so it can't be opened. Use a copy of the game folder that has title.tik in it."),
           shortList(names))
  }

  static func shortList(_ names: [String]) -> String {
    guard names.count > 3 else { return names.joined(separator: ", ") }
    return String(format: L("%@ and %ld more"), names.prefix(3).joined(separator: ", "), names.count - 3)
  }
}
#endif
