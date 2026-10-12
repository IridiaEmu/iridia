// SPDX-License-Identifier: GPL-2.0-or-later
//
// Iridia's interface sounds, synthesised from scratch (no samples, no downloads).
//   swift Tools/branding/make_sounds.swift <out-dir>
// Each sound is a small "glass bell": a few sine partials with inharmonic ratios (like struck
// glass), exponential decays, and a tiny noise transient for the tap. 44.1 kHz 16-bit mono WAV,
// peaks around -14 dBFS so they sit well under game audio.

import AVFoundation
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rate = 44_100.0

struct Note { var freq: Double; var start: Double; var decay: Double; var gain: Double }

/// Struck-glass partials relative to the fundamental: (ratio, relative gain, decay multiplier).
let glassPartials: [(Double, Double, Double)] = [(1.0, 1.0, 1.0), (2.76, 0.45, 0.55), (5.40, 0.18, 0.35), (8.93, 0.06, 0.2)]

func render(_ name: String, length: Double, notes: [Note], tap: Double = 0.15, peak: Double = 0.2) throws {
  let n = Int(length * rate)
  var buf = [Double](repeating: 0, count: n)
  var seed: UInt64 = 0x1D1A
  func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1 }
  for note in notes {
    let s0 = Int(note.start * rate)
    for i in s0..<n {
      let t = Double(i - s0) / rate
      var v = 0.0
      for (ratio, g, dm) in glassPartials {
        v += g * sin(2 * .pi * note.freq * ratio * t) * exp(-t / (note.decay * dm))
      }
      // A 3 ms soft attack avoids clicks; the noise burst is the "tap" of the strike.
      let attack = min(1, t / 0.003)
      v = v * attack + tap * noise() * exp(-t / 0.004)
      buf[i] += v * note.gain
    }
  }
  let maxAbs = buf.map(abs).max() ?? 1
  let scale = peak / maxAbs
  // Fade the last 10 ms so files end on silence.
  let fade = Int(0.01 * rate)
  for i in 0..<fade { buf[n - 1 - i] *= Double(i) / Double(fade) }

  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
  pcm.frameLength = AVAudioFrameCount(n)
  let ch = pcm.int16ChannelData![0]
  for i in 0..<n { ch[i] = Int16(max(-1, min(1, buf[i] * scale)) * 32767) }
  let url = outDir.appendingPathComponent("\(name).wav")
  try? FileManager.default.removeItem(at: url)
  let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
  try file.write(from: pcm)
  print("wrote \(url.lastPathComponent) \(String(format: "%.0f", length * 1000)) ms")
}

// Browsing the shelf: a tiny, high glass tap.
try render("iridia_tick", length: 0.07, notes: [Note(freq: 2637, start: 0, decay: 0.018, gain: 1)], tap: 0.25, peak: 0.12)
// Pressing a button: a short "tink".
try render("iridia_press", length: 0.16, notes: [Note(freq: 1760, start: 0, decay: 0.045, gain: 1)], tap: 0.2, peak: 0.16)
// A menu opens: two rising notes (E6, B6).
try render("iridia_open", length: 0.32, notes: [Note(freq: 1318.5, start: 0, decay: 0.08, gain: 0.8),
                                                 Note(freq: 1975.5, start: 0.065, decay: 0.12, gain: 1)], tap: 0.1, peak: 0.18)
// A menu closes / back: the same two notes falling.
try render("iridia_close", length: 0.3, notes: [Note(freq: 1975.5, start: 0, decay: 0.07, gain: 0.8),
                                                 Note(freq: 1318.5, start: 0.06, decay: 0.11, gain: 1)], tap: 0.1, peak: 0.16)
// A game starts: a quick sparkle up an E major arpeggio with a longer ring.
try render("iridia_launch", length: 0.9, notes: [Note(freq: 1318.5, start: 0, decay: 0.18, gain: 0.7),
                                                  Note(freq: 1661.2, start: 0.06, decay: 0.2, gain: 0.7),
                                                  Note(freq: 1975.5, start: 0.12, decay: 0.24, gain: 0.8),
                                                  Note(freq: 2637.0, start: 0.18, decay: 0.32, gain: 1)], tap: 0.08, peak: 0.2)
// Something didn't work: a low, soft double knock.
try render("iridia_error", length: 0.3, notes: [Note(freq: 330, start: 0, decay: 0.05, gain: 1),
                                                 Note(freq: 262, start: 0.11, decay: 0.06, gain: 1)], tap: 0.05, peak: 0.18)
