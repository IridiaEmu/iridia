// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: -frameMonitor YES logs dropped display frames every 2 seconds, for checking the home screen at 120 Hz
// when Instruments can't reach the phone. A frame counts as dropped when the display link fires late by a whole
// refresh or more (the main thread missed its deadline).

#if os(iOS) && !APPSTORE
import QuartzCore
import UIKit

@MainActor
final class FrameDropMonitor: NSObject {
  static let shared = FrameDropMonitor()

  private var link: CADisplayLink?
  private var last: CFTimeInterval = 0
  private var windowStart: CFTimeInterval = 0
  private var frames = 0
  private var dropped = 0
  private var worst: CFTimeInterval = 0
  private var totalFrames = 0
  private var totalDropped = 0

  static func startIfRequested() {
    guard UserDefaults.standard.bool(forKey: "frameMonitor") || UserDefaults.standard.bool(forKey: "homeTour") else { return }
    shared.start()
  }

  private func start() {
    guard link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
    NSLog("[Frames] monitoring, screen max %ld Hz", UIScreen.main.maximumFramesPerSecond)
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = link.timestamp
    let period = link.targetTimestamp - link.timestamp
    if last > 0, period > 0 {
      let gap = now - last
      let missed = max(0, Int((gap / period).rounded()) - 1)
      dropped += missed
      worst = max(worst, gap)
      frames += 1
    } else {
      windowStart = now
    }
    last = now
    if now - windowStart >= 2 {
      totalFrames += frames
      totalDropped += dropped
      NSLog("[Frames] %.1f s: %d frames, %d dropped, worst %.1f ms, period %.1f ms (total %d frames, %d dropped)",
            now - windowStart, frames, dropped, worst * 1000, period * 1000, totalFrames, totalDropped)
      windowStart = now
      frames = 0
      dropped = 0
      worst = 0
    }
  }
}
#endif
