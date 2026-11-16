// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import XCTest
@testable import iCube

/// Unpack timing for big archives, run by hand: TEST_RUNNER_UNPACK_BENCH_DIR=<folder of archives> with an
/// expected.sha256 (shasum -a 256 format) one level up. Each archive is unpacked through the app's own code,
/// every file it held is checked against the expected checksums, and the output is deleted straight away.
/// Skipped when the variable isn't set.
final class UnpackBenchTests: XCTestCase {
  func testUnpackSpeed() throws {
    guard let dir = ProcessInfo.processInfo.environment["UNPACK_BENCH_DIR"] else {
      throw XCTSkip("UNPACK_BENCH_DIR not set")
    }
    let folder = URL(fileURLWithPath: dir, isDirectory: true)
    let expected = try Self.expectedHashes(folder.deletingLastPathComponent().appendingPathComponent("expected.sha256"))
    let only = ProcessInfo.processInfo.environment["UNPACK_BENCH_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
    let archives = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasPrefix(".") && (only == nil || $0.lastPathComponent.contains(only!)) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for archive in archives {
      let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unpack-bench-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: out) }
      let peak = PeakMemory()
      peak.start()
      let start = Date()
      let progress = UnpackProgress()
      let steps = ProgressSteps(progress)
      try ZipImportHelper.extractArchive(at: archive, to: out, progress: progress)
      let seen = steps.stop()
      XCTAssertEqual(progress.fraction, 1)
      XCTAssertGreaterThan(seen, 2, "\(archive.lastPathComponent): progress didn't move while unpacking")
      let seconds = Date().timeIntervalSince(start)
      peak.stop()
      var bytes: Int64 = 0
      var matched = 0
      for file in FileManager.default.enumerator(at: out, includingPropertiesForKeys: [.fileSizeKey])!.compactMap({ $0 as? URL }) {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
        bytes += Int64(size)
        let hash = try Self.sha256(file)
        XCTAssertEqual(hash, expected[file.lastPathComponent], "\(archive.lastPathComponent): \(file.lastPathComponent) differs")
        if hash == expected[file.lastPathComponent] { matched += 1 }
      }
      XCTAssertGreaterThan(matched, 0, "\(archive.lastPathComponent) held no expected file")
      print(String(format: "UNPACK_BENCH %@ %.2f s %.0f MB/s peak %.0f MB added %.0f MB identical %d progress steps %d",
                   archive.lastPathComponent, seconds, Double(bytes) / 1e6 / seconds, peak.megabytes,
                   peak.addedMegabytes, matched, seen))
    }
  }

  /// Cancelling part way through stops the unpack soon after, for every archive in the folder.
  func testCancelStopsUnpacking() throws {
    guard let dir = ProcessInfo.processInfo.environment["UNPACK_BENCH_DIR"] else {
      throw XCTSkip("UNPACK_BENCH_DIR not set")
    }
    let only = ProcessInfo.processInfo.environment["UNPACK_BENCH_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
    let archives = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasPrefix(".") && (only == nil || $0.lastPathComponent.contains(only!)) }
    for archive in archives {
      let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unpack-cancel-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: out) }
      let progress = UnpackProgress()
      var cancelledAt = 0.0
      let canceller = Thread {
        while progress.fraction < 0.2 { Thread.sleep(forTimeInterval: 0.01) }
        cancelledAt = progress.fraction
        progress.cancel()
      }
      canceller.start()
      XCTAssertThrowsError(try ZipImportHelper.extractArchive(at: archive, to: out, progress: progress)) {
        guard case UnpackError.cancelled = $0 else { return XCTFail("\(archive.lastPathComponent): \($0)") }
      }
      print(String(format: "UNPACK_CANCEL %@ cancelled at %.0f%% stopped at %.0f%%",
                   archive.lastPathComponent, cancelledAt * 100, progress.fraction * 100))
      XCTAssertLessThan(progress.fraction, cancelledAt + 0.1, "\(archive.lastPathComponent) kept going after Cancel")
    }
  }

  private static func expectedHashes(_ url: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      result[parts[1].trimmingCharacters(in: .whitespaces)] = String(parts[0])
    }
    return result
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while try autoreleasepool(invoking: {
      guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
      hasher.update(data: chunk)
      return true
    }) {}
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// How many different progress values below 100% showed while unpacking, sampled every 20 ms.
final class ProgressSteps: @unchecked Sendable {
  private let lock = NSLock()
  private var running = true
  private var values = Set<Int>()

  init(_ progress: UnpackProgress) {
    Thread { [self] in
      while lock.withLock({ running }) {
        let percent = Int(progress.fraction * 100)
        if percent < 100 { lock.withLock { _ = values.insert(percent) } }
        Thread.sleep(forTimeInterval: 0.02)
      }
    }.start()
  }

  func stop() -> Int { lock.withLock { running = false; return values.count } }
}

/// The process's highest memory footprint while running, sampled every 20 ms.
final class PeakMemory: @unchecked Sendable {
  private var running = false
  private var peak: UInt64 = 0
  private var base: UInt64 = 0
  private var thread: Thread?

  var megabytes: Double { Double(peak) / 1e6 }
  /// How far above the footprint at start() it went.
  var addedMegabytes: Double { Double(peak &- min(peak, base)) / 1e6 }

  func start() {
    running = true
    base = Self.footprint()
    peak = base
    thread = Thread { [self] in
      while running {
        peak = max(peak, Self.footprint())
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    thread?.start()
  }

  func stop() {
    peak = max(peak, Self.footprint())
    running = false
  }

  static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
