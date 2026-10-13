// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu benchmark mode. Launch the app with
//   -gcemuBench <seconds> [-gcemuBenchWarmup <seconds>] [-gcemuBenchLabel <text>]
// plus a game (e.g. --payload-url dolphinios://play?id=<game ID>). Once emulation starts it
// waits for the warmup, samples the core's performance counters (frame times at 200 Hz,
// counters at 20 Hz), writes
//   Documents/Benchmarks/<label>-<game>-<timestamp>.json
// and quits. Nothing runs unless -gcemuBench is passed. Sampling is a timer on a utility queue reading
// atomics, so it doesn't perturb the measurement.

import Foundation
import Darwin
import os
#if canImport(UIKit)
import UIKit
#endif

enum GCEmuBenchmark {
  private struct Sample: Codable {
    let t: Double
    let speed: Double
    let maxSpeed: Double
    let fps: Double
    let vps: Double
  }

  private struct Stats: Codable {
    let mean: Double, min: Double, max: Double, p5: Double, p50: Double, p95: Double, p99: Double
    init(_ v: [Double]) {
      let s = v.sorted()
      func q(_ p: Double) -> Double { s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int(Double(s.count - 1) * p))] }
      mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
      self.min = s.first ?? 0; self.max = s.last ?? 0
      p5 = q(0.05); p50 = q(0.5); p95 = q(0.95); p99 = q(0.99)
    }
  }

  private struct Report: Codable {
    let label: String
    let game: String
    let date: Date
    let device: String
    let os: String
    let thermalStateStart: String
    let thermalStateEnd: String
    let warmupSeconds: Double
    let durationSeconds: Double
    let cpuCore: Int
    let speed: Stats
    let maxSpeed: Stats
    let fps: Stats
    let vps: Stats
    /// Per-frame times (ms) from distinct raw frame-time readings.
    let frameTimeMs: Stats
    let onePercentLowFrameTimeMs: Double
    /// Frames that took over 1.5x the median frame time: visible stutters.
    let hitches: Int
    /// Whole-app CPU time over the measured window, as % of one core (a power/heat proxy).
    let cpuPercent: Double
    let frames: Int
    /// Memory as iOS counts it for the jetsam limit (phys_footprint), MB: at the end of the run and
    /// the process lifetime peak.
    let footprintMB: Double
    let peakFootprintMB: Double
    /// What iOS says the app can still allocate before it's killed, MB (os_proc_available_memory).
    let availableMB: Double
    let samples: [Sample]
  }

  private static var observer: NSObjectProtocol?
  private static var timer: DispatchSourceTimer?

  private static var pauseObserver: NSObjectProtocol?

  /// Test hook for UI checks on device: -gcemuShowPauseAfter <seconds> opens the pause menu that long
  /// after a game starts. Does nothing unless passed.
  static func armPauseMenuIfRequested() {
    let delay = UserDefaults.standard.double(forKey: "gcemuShowPauseAfter")
    guard delay > 0, pauseObserver == nil else { return }
    pauseObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main
    ) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
      }
    }
  }

  private static var perfObserver: NSObjectProtocol?

  /// Test hook: -gcemuShowPerformanceAfter <seconds> opens the in-game Performance panel (resolution
  /// slider) that long after a game starts. Does nothing unless passed.
  static func armPerformancePanelIfRequested() {
    let delay = UserDefaults.standard.double(forKey: "gcemuShowPerformanceAfter")
    guard delay > 0, perfObserver == nil else { return }
    perfObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main
    ) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        NotificationCenter.default.post(name: Notification.Name("DOLShowPerformancePanel"), object: nil)
      }
    }
  }

  /// Call once at launch. Does nothing unless -gcemuBench is set.
  static func armIfRequested() {
    armPauseMenuIfRequested()
    armPerformancePanelIfRequested()
    let d = UserDefaults.standard
    let duration = d.double(forKey: "gcemuBench")
    guard duration > 0, observer == nil else { return }
    let warmup = d.object(forKey: "gcemuBenchWarmup") != nil ? d.double(forKey: "gcemuBenchWarmup") : 5
    let label = d.string(forKey: "gcemuBenchLabel") ?? "bench"
    NSLog("[GCEmuBench] armed: %.0fs after %.0fs warmup, label=%@", duration, warmup, label)
    // -gcemuBenchState GZ2E01.s01: start from that save state (in StateSaves) so a real 3D scene is
    // measured the same way every run, instead of the boot logos.
    if let stateFile = d.string(forKey: "gcemuBenchState"), !stateFile.isEmpty {
      let path = (UserFolderUtil.getUserFolder() as NSString)
        .appendingPathComponent("StateSaves").appending("/" + stateFile)
      SaveStateService.pendingBootStatePath = path
      NSLog("[GCEmuBench] will load state %@", stateFile)
    }
    observer = NotificationCenter.default.addObserver(
      forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main
    ) { note in
      let game = (note.userInfo?["gameID"] as? String) ?? (note.userInfo?["title"] as? String) ?? "game"
      start(duration: duration, warmup: warmup, label: label, game: game)
    }
  }

  private static func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  private static func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }

  private static func start(duration: Double, warmup: Double, label: String, game: String) {
    guard timer == nil else { return }
    let queue = DispatchQueue(label: "gcemu.bench", qos: .utility)
    let thermalStart = thermal()
    var samples: [Sample] = []
    var frameTimes: [Double] = []
    var lastRaw = -1.0
    var t0: CFAbsoluteTime = 0
    var cpu0 = 0.0
    let t = DispatchSource.makeTimerSource(queue: queue)
    timer = t
    var tick = 0
    // 5 ms ticks: fast enough to see every frame's raw time (frames are >= 16 ms); counters every 10th tick.
    t.schedule(deadline: .now() + warmup, repeating: .milliseconds(5), leeway: .milliseconds(1))
    t.setEventHandler {
      if t0 == 0 { t0 = CFAbsoluteTimeGetCurrent(); cpu0 = cpuSeconds() }
      let now = CFAbsoluteTimeGetCurrent() - t0
      let snap = DOLPerfBridge.snapshot()
      func v(_ k: String) -> Double { snap[k]?.doubleValue ?? 0 }
      if tick % 10 == 0 {
        samples.append(Sample(t: now, speed: v("speed"), maxSpeed: v("maxSpeed"), fps: v("fps"), vps: v("vps")))
      }
      tick += 1
      let raw = v("rawFrameTimeMs")
      if raw > 0, raw != lastRaw { frameTimes.append(raw); lastRaw = raw }
      guard now >= duration else { return }
      t.cancel()
      let slowest = frameTimes.sorted(by: >).prefix(max(1, frameTimes.count / 100))
      let report = Report(
        label: label, game: game, date: Date(), device: deviceModel(),
        os: ProcessInfo.processInfo.operatingSystemVersionString,
        thermalStateStart: thermalStart, thermalStateEnd: thermal(),
        warmupSeconds: warmup, durationSeconds: now, cpuCore: Int(DOLConfigBridge.mainCpuCore()),
        speed: Stats(samples.map(\.speed)), maxSpeed: Stats(samples.map(\.maxSpeed)),
        fps: Stats(samples.map(\.fps)), vps: Stats(samples.map(\.vps)),
        frameTimeMs: Stats(frameTimes),
        onePercentLowFrameTimeMs: slowest.isEmpty ? 0 : slowest.reduce(0, +) / Double(slowest.count),
        hitches: { let m = Stats(frameTimes).p50; return frameTimes.filter { $0 > m * 1.5 }.count }(),
        cpuPercent: (cpuSeconds() - cpu0) / max(now, 0.001) * 100,
        frames: frameTimes.count,
        footprintMB: memory().now, peakFootprintMB: memory().peak,
        availableMB: Double(os_proc_available_memory()) / 1_048_576,
        samples: samples)
      write(report, label: label, game: game)
    }
    t.resume()
  }

  /// User + system CPU time of the whole process, seconds.
  private static func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return s(u.ru_utime) + s(u.ru_stime)
  }

  /// phys_footprint now and its lifetime max, in MB.
  private static func memory() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
  }

  private static func write(_ r: Report, label: String, game: String) {
    // Hidden user folder (Library/Application Support/Iridia/Benchmarks), not the Files-visible Documents.
    let dir = URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
      .appendingPathComponent("Benchmarks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let safe = { (s: String) in s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    let url = dir.appendingPathComponent("\(safe(label))-\(safe(game))-\(f.string(from: r.date)).json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(r) { try? data.write(to: url, options: .atomic) }
    NSLog("[GCEmuBench] wrote %@ (speed mean %.3f, maxSpeed mean %.3f)", url.lastPathComponent, r.speed.mean, r.maxSpeed.mean)
    // Bench runs are scripted: quit so the next run starts clean. Flush PGO counters first
    // (no-op unless the core is a DOL_PGO=generate build), so training runs always land on disk.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      _ = ICubePGOFlush()
      exit(0)
    }
  }
}
