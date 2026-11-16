// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Every game, in every format and inside ZIP and 7Z files, must land on its own system's tab, whichever tab it
/// was added from. Fixtures/Games has one small test file per format per system (made-up discs and programs, no
/// real games and no keys), and Archives has a ZIP and a 7Z of each, plus a mixed one.
final class GameImportTests: XCTestCase {
  private var root: URL!
  private var folders: GameImport.Folders!

  private var fixtures: URL { Bundle(for: Self.self).resourceURL!.appendingPathComponent("Games", isDirectory: true) }

  override func setUpWithError() throws {
    // Tidy remembers archives it has tried in the app's real defaults; a run before this one must not hide them.
    UserDefaults.standard.removeObject(forKey: "archivesTried")
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GameImportTests-\(UUID().uuidString)", isDirectory: true)
    folders = GameImport.Folders(gameCube: root.appendingPathComponent("Games"), wii: root.appendingPathComponent("Wii"),
                                 wiiU: root.appendingPathComponent("Wii U"), scratch: root.appendingPathComponent("Unpacking"))
    for system in GameSystem.allCases {
      try FileManager.default.createDirectory(at: folders.folder(for: system), withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Fixtures

  private static let systemFolders: [(folder: String, system: GameSystem)] = [("GameCube", .gameCube), ("Wii", .wii), ("Wii U", .wiiU)]

  private func items(in folder: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent(folder), includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// The system an archive fixture's game belongs to, from its name ("Wii U - WiiU Test (wua).zip"); nil for Other.
  private func expectedSystem(ofArchive url: URL) -> GameSystem? {
    let name = url.lastPathComponent
    if name.hasPrefix("Wii U - ") { return .wiiU }
    if name.hasPrefix("Wii - ") { return .wii }
    if name.hasPrefix("GameCube - ") { return .gameCube }
    return nil
  }

  private func contents(of system: GameSystem) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folders.folder(for: system).path)) ?? [])
      .filter { !$0.hasPrefix(".") }
  }

  private func assertOnly(_ name: String, on system: GameSystem, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    for other in GameSystem.allCases {
      let has = contents(of: other).contains(name)
      XCTAssertEqual(has, other == system, "\(message): \(name) \(has ? "is" : "isn't") in the \(other) folder", file: file, line: line)
    }
  }

  private func clearFolders() throws {
    try tearDownWithError()
    try setUpWithError()
  }

  // MARK: - Detection

  func testEveryFileIsDetectedByItsContents() throws {
    for (folder, system) in Self.systemFolders {
      for url in try items(in: folder) {
        let expected: GameDetect.Kind = url.lastPathComponent == "keys.txt" ? .wiiUKeys : .game(system)
        XCTAssertEqual(GameDetect.kind(of: url), expected, url.lastPathComponent)
      }
    }
    for url in try items(in: "Other") {
      XCTAssertEqual(GameDetect.kind(of: url), .none, url.lastPathComponent)
    }
    for url in try items(in: "Archives") {
      XCTAssertEqual(GameDetect.kind(of: url), .archive, url.lastPathComponent)
    }
  }

  /// A file's name says nothing: a Wii disc named .gcm, a GameCube disc named .wbfs and a Wii U disc named .rvz
  /// are still sorted by what they are.
  func testMisnamedFilesAreDetectedByContents() throws {
    let cases: [(String, String, GameSystem)] = [("Wii/Wii Test.iso", "Renamed.gcm", .wii),
                                                 ("GameCube/GC Test.iso", "Renamed.wbfs", .gameCube),
                                                 ("Wii U/WiiU Test.wud", "Renamed.rvz", .wiiU),
                                                 ("Wii/Wii Test.rvz", "Renamed.wua", .wii)]
    for (source, name, system) in cases {
      let copy = root.appendingPathComponent(name)
      try FileManager.default.copyItem(at: fixtures.appendingPathComponent(source), to: copy)
      XCTAssertEqual(GameDetect.kind(of: copy), .game(system), "\(source) as \(name)")
      try FileManager.default.removeItem(at: copy)
    }
  }

  // MARK: - Where games land

  func testEveryFileLandsOnItsTab() throws {
    for (folder, system) in Self.systemFolders {
      for url in try items(in: folder) {
        try clearFolders()
        let outcome = GameImport.run([url], into: folders, move: false)
        XCTAssertTrue(outcome.errors.isEmpty, "\(url.lastPathComponent): \(outcome.errors)")
        if url.lastPathComponent == "keys.txt" {
          XCTAssertEqual(outcome.keysAdded, 1)
          continue
        }
        assertOnly(url.lastPathComponent, on: system, "picked file")
      }
    }
  }

  func testEveryArchiveLandsOnItsTab() throws {
    for archive in try items(in: "Archives") where !archive.lastPathComponent.hasPrefix("Mixed") {
      try clearFolders()
      let outcome = GameImport.run([archive], into: folders, move: false)
      XCTAssertTrue(outcome.errors.isEmpty, "\(archive.lastPathComponent): \(outcome.errors)")
      guard let system = expectedSystem(ofArchive: archive) else {
        XCTAssertEqual(outcome.emptyArchives, [archive.lastPathComponent], "nothing playable inside")
        for any in GameSystem.allCases { XCTAssertTrue(contents(of: any).isEmpty, "\(archive.lastPathComponent) put something in \(any)") }
        continue
      }
      if archive.lastPathComponent.contains("keys (txt)") {
        XCTAssertEqual(outcome.keysAdded, 1, archive.lastPathComponent)
        continue
      }
      let inner = archive.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: #"^.* - "#, with: "", options: .regularExpression)
      let name = inner.hasSuffix("(folder)") ? String(inner.dropLast(" (folder)".count))
        : inner.replacingOccurrences(of: #" \((\w+)\)$"#, with: ".$1", options: .regularExpression)
      assertOnly(name, on: system, archive.lastPathComponent)
    }
  }

  func testSaysWhenThereIsNoRoomToUnpack() throws {
    let archive = root.appendingPathComponent("Big Game.7z")
    let message = try XCTUnwrap(GameImport.unpackSpaceProblem(archive, needing: 1 << 60, into: root))
    XCTAssertTrue(message.hasPrefix("There isn't enough space to unpack Big Game.7z."), message)
    XCTAssertTrue(message.hasSuffix("and try again."), message)
    XCTAssertNil(GameImport.unpackSpaceProblem(archive, needing: 1, into: root))
  }

  func testMixedArchiveSplitsAcrossTabs() throws {
    for archive in ["Mixed.zip", "Mixed.7z"] {
      try clearFolders()
      let outcome = GameImport.run([fixtures.appendingPathComponent("Archives/\(archive)")], into: folders, move: false)
      XCTAssertTrue(outcome.errors.isEmpty, "\(archive): \(outcome.errors)")
      assertOnly("GC Test.rvz", on: .gameCube, archive)
      assertOnly("Wii Test.wbfs", on: .wii, archive)
      assertOnly("WiiU Test.wua", on: .wiiU, archive)
      assertOnly("WiiU Test Folder", on: .wiiU, archive)
    }
  }

  /// A picked folder holding games for all three systems.
  func testPickedFolderIsSorted() throws {
    let picked = root.appendingPathComponent("Picked", isDirectory: true)
    try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
    for (folder, _) in Self.systemFolders {
      try FileManager.default.copyItem(at: fixtures.appendingPathComponent(folder), to: picked.appendingPathComponent(folder))
    }
    let outcome = GameImport.run([picked], into: folders, move: false)
    XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    for (folder, system) in Self.systemFolders {
      for url in try items(in: folder) where url.lastPathComponent != "keys.txt" {
        assertOnly(url.lastPathComponent, on: system, "picked folder")
      }
    }
    XCTAssertEqual(outcome.keysAdded, 1)
  }

  func testFilesThatArentGamesAreNamed() throws {
    let other = try items(in: "Other")
    let outcome = GameImport.run(other, into: folders, move: false)
    XCTAssertEqual(Set(outcome.notGames), Set(other.map(\.lastPathComponent)))
    for system in GameSystem.allCases { XCTAssertTrue(contents(of: system).isEmpty) }
  }

  // MARK: - Files app

  /// Games the Files app put in another system's folder, and archives put in any folder, go where they belong.
  func testTidyMovesStrayGamesAndUnpacksArchives() throws {
    let fm = FileManager.default
    try fm.copyItem(at: fixtures.appendingPathComponent("Wii U/WiiU Test.wua"), to: folders.gameCube.appendingPathComponent("WiiU Test.wua"))
    try fm.copyItem(at: fixtures.appendingPathComponent("Wii U/WiiU Test Folder"), to: folders.wii.appendingPathComponent("WiiU Test Folder"))
    try fm.copyItem(at: fixtures.appendingPathComponent("GameCube/GC Test.rvz"), to: folders.wiiU.appendingPathComponent("GC Test.rvz"))
    try fm.copyItem(at: fixtures.appendingPathComponent("Wii/Wii Test.wbfs"), to: folders.wiiU.appendingPathComponent("Wii Test.wbfs"))
    try fm.copyItem(at: fixtures.appendingPathComponent("Archives/Wii U - WiiU Test (wux).7z"), to: folders.gameCube.appendingPathComponent("wux.7z"))
    try fm.copyItem(at: fixtures.appendingPathComponent("Archives/GameCube - GC Test (gcz).zip"), to: folders.wiiU.appendingPathComponent("gcz.zip"))
    try fm.copyItem(at: fixtures.appendingPathComponent("Archives/Wii - Wii Test (ciso).zip"), to: folders.wii.appendingPathComponent("ciso.zip"))
    let outcome = GameImport.tidy(folders)
    XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    assertOnly("WiiU Test.wua", on: .wiiU, "tidy")
    assertOnly("WiiU Test Folder", on: .wiiU, "tidy")
    assertOnly("GC Test.rvz", on: .gameCube, "tidy")
    assertOnly("Wii Test.wbfs", on: .wii, "tidy")
    assertOnly("WiiU Test.wux", on: .wiiU, "tidy")
    assertOnly("GC Test.gcz", on: .gameCube, "tidy")
    assertOnly("Wii Test.ciso", on: .wii, "tidy")
    for archive in ["wux.7z", "gcz.zip", "ciso.zip"] {
      for system in GameSystem.allCases { XCTAssertFalse(contents(of: system).contains(archive), "\(archive) was left behind") }
    }
  }

  /// An archive is only removed when everything in it was added; otherwise it stays and the player is told which.
  func testArchiveIsKeptWhenAGameInsideFails() throws {
    let fm = FileManager.default
    try fm.copyItem(at: fixtures.appendingPathComponent("Archives/Mixed.zip"), to: folders.gameCube.appendingPathComponent("Mixed.zip"))
    try fm.removeItem(at: folders.wii)
    try Data().write(to: folders.wii)
    let outcome = GameImport.tidy(folders)
    XCTAssertFalse(outcome.errors.isEmpty)
    XCTAssertTrue(contents(of: .gameCube).contains("GC Test.rvz"))
    XCTAssertTrue(contents(of: .gameCube).contains("Mixed.zip"), "the archive was removed though a game in it failed")
    XCTAssertEqual(outcome.keptArchives, ["Mixed.zip"])
    XCTAssertTrue(GameImport.lines(for: outcome, from: .gameCube).problems.contains { $0.contains("Mixed.zip") })
  }

  /// A GameCube or Wii game already in either of their folders stays put: both shelves read both folders.
  func testTidyLeavesGameCubeAndWiiGamesInTheirFolders() throws {
    let fm = FileManager.default
    try fm.copyItem(at: fixtures.appendingPathComponent("Wii/Wii Test.rvz"), to: folders.gameCube.appendingPathComponent("Wii Test.rvz"))
    try fm.copyItem(at: fixtures.appendingPathComponent("GameCube/GC Test.iso"), to: folders.wii.appendingPathComponent("GC Test.iso"))
    let outcome = GameImport.tidy(folders)
    XCTAssertEqual(outcome.addedCount, 0)
    XCTAssertTrue(contents(of: .gameCube).contains("Wii Test.rvz"))
    XCTAssertTrue(contents(of: .wii).contains("GC Test.iso"))
  }

  // MARK: - Check Downloads

  func testCheckDownloadsOffersEachTabOnlyItsGames() throws {
    for (folder, system) in Self.systemFolders {
      for url in try items(in: folder) {
        XCTAssertEqual(GameCubeDownloads.Kind.gameCube.wants(url), system == .gameCube, "GameCube tab, \(url.lastPathComponent)")
        XCTAssertEqual(GameCubeDownloads.Kind.wii.wants(url), system == .wii, "Wii tab, \(url.lastPathComponent)")
        XCTAssertEqual(WiiUDownloads.isWiiUGame(url), system == .wiiU, "Wii U tab, \(url.lastPathComponent)")
      }
    }
    for url in try items(in: "Other") {
      XCTAssertFalse(GameCubeDownloads.Kind.gameCube.wants(url) || GameCubeDownloads.Kind.wii.wants(url) || WiiUDownloads.isWiiUGame(url),
                     url.lastPathComponent)
    }
    // Archives are offered by their list of names; a Wii U one never by the GameCube or Wii tab.
    for archive in try items(in: "Archives") where expectedSystem(ofArchive: archive) == .wiiU && !archive.lastPathComponent.contains("(iso)") {
      XCTAssertFalse(GameCubeDownloads.Kind.gameCube.wants(archive), archive.lastPathComponent)
      XCTAssertFalse(GameCubeDownloads.Kind.wii.wants(archive), archive.lastPathComponent)
      XCTAssertTrue(WiiUDownloads.isWiiUGame(archive), archive.lastPathComponent)
    }
  }

  /// Only files named like games or archives are opened, as in 1.1.5; a game under another name isn't offered.
  func testCheckDownloadsOnlyLooksAtGameNames() throws {
    let game = try XCTUnwrap(try items(in: "GameCube").first { $0.pathExtension == "iso" })
    let renamed = root.appendingPathComponent("photo.pdf")
    try FileManager.default.copyItem(at: game, to: renamed)
    XCTAssertFalse(GameCubeDownloads.Kind.gameCube.wants(renamed))
    XCTAssertFalse(DownloadsFolder.mayHoldGame(renamed, extensions: ImportableFileTypes.softwareExtensions))
    XCTAssertTrue(DownloadsFolder.mayHoldGame(game, extensions: ImportableFileTypes.softwareExtensions))
    XCTAssertFalse(DownloadsFolder.mayHoldGame(root, extensions: ImportableFileTypes.softwareExtensions))
    XCTAssertTrue(DownloadsFolder.mayHoldGame(root, extensions: [], folders: true))
  }

  // MARK: - Messages

  func testGamesForAnotherTabSayWhereTheyWent() {
    var outcome = GameImport.Outcome()
    outcome.added[.wii] = ["Wii Test.rvz"]
    outcome.added[.wiiU] = ["WiiU Test.wua"]
    let fromGameCube = GameImport.lines(for: outcome, from: .gameCube)
    XCTAssertEqual(fromGameCube.news, ["Wii Test.rvz went to the Wii tab.", "WiiU Test.wua went to the Wii U tab."])
    XCTAssertTrue(fromGameCube.problems.isEmpty)
    let fromWii = GameImport.lines(for: outcome, from: .wii)
    XCTAssertEqual(fromWii.news, ["Added Wii Test.rvz.", "WiiU Test.wua went to the Wii U tab."])
    let fromWiiU = GameImport.lines(for: outcome, from: .wiiU)
    XCTAssertEqual(fromWiiU.news, ["Wii Test.rvz went to the Wii tab.", "Added WiiU Test.wua."])
  }

  // MARK: - Player folders

  func testOldLayoutMoveLeavesPlayerFoldersInDocuments() throws {
    let fm = FileManager.default
    let docs = root.appendingPathComponent("Docs"), user = root.appendingPathComponent("User"), games = root.appendingPathComponent("GC")
    for dir in [docs.appendingPathComponent("Config"), docs.appendingPathComponent("My Games"), docs.appendingPathComponent("Software"), user] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try Data([1]).write(to: docs.appendingPathComponent("Software/a.iso"))
    let added = Date(timeIntervalSince1970: 1_700_000_000)
    LibraryAddedDateStore.record(path: docs.appendingPathComponent("Software/a.iso").path, date: added)
    UserFolderUtil.moveOldLayout(docs: docs.path, user: user.path, games: games.path)
    XCTAssertEqual(LibraryAddedDateStore.addedDate(forPath: games.appendingPathComponent("a.iso").path), added)
    XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("My Games").path))
    XCTAssertTrue(fm.fileExists(atPath: user.appendingPathComponent("Config").path))
    XCTAssertTrue(fm.fileExists(atPath: games.appendingPathComponent("a.iso").path))
    XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("Software").path))
  }

  func testHiddenPlayerFoldersAndGamesComeBack() throws {
    let fm = FileManager.default
    let docs = root.appendingPathComponent("Docs"), user = root.appendingPathComponent("User")
    for name in ["Import test", "Config", "StateSaves", "Wii"] {
      try fm.createDirectory(at: user.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try fm.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data([1]).write(to: user.appendingPathComponent("big-disc.7z"))
    try Data([1]).write(to: user.appendingPathComponent("game_profiles.json"))
    UserFolderUtil.restorePlayerItems(docs: docs.path, user: user.path)
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: docs.path).sorted(), ["Import test", "big-disc.7z"])
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: user.path).sorted(), ["Config", "StateSaves", "Wii", "game_profiles.json"])
  }

  /// 1.1.5 hid a player's "GameCube" folder in the user folder. Its games join 1.2's own GameCube folder; a
  /// game whose name is taken is kept next to the one already there.
  func testHiddenGameCubeFolderJoinsTheGameCubeFolder() throws {
    let fm = FileManager.default
    let user = root.appendingPathComponent("User"), games = root.appendingPathComponent("Docs/GameCube")
    let wii = root.appendingPathComponent("Docs/Wii")
    let hidden = user.appendingPathComponent("GameCube")
    try fm.createDirectory(at: hidden.appendingPathComponent("Favourites"), withIntermediateDirectories: true)
    try fm.createDirectory(at: games.appendingPathComponent("Favourites"), withIntermediateDirectories: true)
    try Data([1]).write(to: hidden.appendingPathComponent("Old.iso"))
    try Data([2]).write(to: hidden.appendingPathComponent("Same.rvz"))
    try Data([3]).write(to: hidden.appendingPathComponent("Favourites/Deep.gcm"))
    try Data([4]).write(to: hidden.appendingPathComponent("Favourites/Same.iso"))
    try Data([9]).write(to: games.appendingPathComponent("Same.rvz"))
    try Data([8]).write(to: games.appendingPathComponent("Favourites/Same.iso"))

    UserFolderUtil.restoreGameFolders(user: user.path, games: games.path, wii: wii.path)

    XCTAssertEqual(try fm.contentsOfDirectory(atPath: games.path).sorted(), ["Favourites", "Old.iso", "Same 2.rvz", "Same.rvz"])
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: games.appendingPathComponent("Favourites").path).sorted(),
                   ["Deep.gcm", "Same 2.iso", "Same.iso"])
    XCTAssertEqual(try Data(contentsOf: games.appendingPathComponent("Same.rvz")), Data([9]), "the game already there was replaced")
    XCTAssertEqual(try Data(contentsOf: games.appendingPathComponent("Same 2.rvz")), Data([2]))
    XCTAssertEqual(try Data(contentsOf: games.appendingPathComponent("Favourites/Same.iso")), Data([8]))
    XCTAssertFalse(fm.fileExists(atPath: hidden.path), "the emptied hidden folder is still there")

    UserFolderUtil.restoreGameFolders(user: user.path, games: games.path, wii: wii.path)
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: games.path).count, 4, "a second run changed the folder")
  }

  /// 1.1.5 mixed a player's "Wii" folder into the Wii save storage. The games come out into 1.2's own Wii
  /// folder; the save storage, the key file and anything that isn't a game stay.
  func testGamesHiddenInWiiStorageJoinTheWiiFolder() throws {
    let fm = FileManager.default
    let user = root.appendingPathComponent("User"), games = root.appendingPathComponent("Docs/GameCube")
    let wii = root.appendingPathComponent("Docs/Wii")
    let storage = user.appendingPathComponent("Wii")
    try fm.createDirectory(at: storage.appendingPathComponent("title/00010000"), withIntermediateDirectories: true)
    try fm.createDirectory(at: wii, withIntermediateDirectories: true)
    try Data([1]).write(to: storage.appendingPathComponent("title/00010000/save.bin"))
    try Data([1]).write(to: storage.appendingPathComponent("title/inside.iso"))
    try Data([1]).write(to: storage.appendingPathComponent("keys.bin"))
    try Data([1]).write(to: storage.appendingPathComponent("notes.txt"))
    try Data([2]).write(to: storage.appendingPathComponent("Party.wbfs"))
    try Data([3]).write(to: storage.appendingPathComponent("Same.rvz"))
    try Data([4]).write(to: storage.appendingPathComponent("Pack.7z"))
    try Data([9]).write(to: wii.appendingPathComponent("Same.rvz"))

    UserFolderUtil.restoreGameFolders(user: user.path, games: games.path, wii: wii.path)

    XCTAssertEqual(try fm.contentsOfDirectory(atPath: wii.path).sorted(), ["Pack.7z", "Party.wbfs", "Same 2.rvz", "Same.rvz"])
    XCTAssertEqual(try Data(contentsOf: wii.appendingPathComponent("Same.rvz")), Data([9]), "the game already there was replaced")
    XCTAssertEqual(try Data(contentsOf: wii.appendingPathComponent("Same 2.rvz")), Data([3]))
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: storage.path).sorted(), ["keys.bin", "notes.txt", "title"])
    XCTAssertTrue(fm.fileExists(atPath: storage.appendingPathComponent("title/00010000/save.bin").path))
    XCTAssertTrue(fm.fileExists(atPath: storage.appendingPathComponent("title/inside.iso").path))

    UserFolderUtil.restoreGameFolders(user: user.path, games: games.path, wii: wii.path)
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: wii.path).count, 4, "a second run changed the folder")
  }
}
