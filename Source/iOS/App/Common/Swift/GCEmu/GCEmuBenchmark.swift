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
    let mean: Double, min: Double, max: Double, p5: Double, p50: Double, p95: Double
    init(_ v: [Double]) {
      let s = v.sorted()
      func q(_ p: Double) -> Double { s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int(Double(s.count - 1) * p))] }
      mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
      self.min = s.first ?? 0; self.max = s.last ?? 0
      p5 = q(0.05); p50 = q(0.5); p95 = q(0.95)
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
    let frames: Int
    let samples: [Sample]
  }

  private static var observer: NSObjectProtocol?
  private static var timer: DispatchSourceTimer?

  /// Call once at launch. Does nothing unless -gcemuBench is set.
  static func armIfRequested() {
    let d = UserDefaults.standard
    let duration = d.double(forKey: "gcemuBench")
    guard duration > 0, observer == nil else { return }
    let warmup = d.object(forKey: "gcemuBenchWarmup") != nil ? d.double(forKey: "gcemuBenchWarmup") : 5
    let label = d.string(forKey: "gcemuBenchLabel") ?? "bench"
    NSLog("[GCEmuBench] armed: %.0fs after %.0fs warmup, label=%@", duration, warmup, label)
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
    let t = DispatchSource.makeTimerSource(queue: queue)
    timer = t
    var tick = 0
    // 5 ms ticks: fast enough to see every frame's raw time (frames are >= 16 ms); counters every 10th tick.
    t.schedule(deadline: .now() + warmup, repeating: .milliseconds(5), leeway: .milliseconds(1))
    t.setEventHandler {
      if t0 == 0 { t0 = CFAbsoluteTimeGetCurrent() }
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
        frames: frameTimes.count, samples: samples)
      write(report, label: label, game: game)
    }
    t.resume()
  }

  private static func write(_ r: Report, label: String, game: String) {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
