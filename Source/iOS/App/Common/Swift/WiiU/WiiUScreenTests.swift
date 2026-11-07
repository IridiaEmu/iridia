// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: in-app tests of the Wii U screen layouts (not in App Store builds), started by launch arguments from
// the play screen's test hooks. They go through the real views: the window's hit test decides which view a
// touch reaches, the touch view's own send path turns it into GamePad coordinates, and the result is read back
// from what the game itself read (CemuBridge.lastGameTouch).

#if os(iOS) && canImport(IridiaCafeCore) && !APPSTORE
import IridiaCafeCore
import UIKit

@MainActor
enum WiiUScreenTests {
  nonisolated private static func log(_ s: String) { NSLog("IRIDIA_SCREENTEST %@", s) }

  private static var scene: UIWindowScene? { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first }
  private static var window: UIWindow? { scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first }

  /// Turns the screen. On iPad (windowed apps can't ask for an orientation) the simulated device itself is
  /// turned instead.
  private static func rotate(_ o: UIInterfaceOrientationMask) async {
    let device: UIInterfaceOrientation = o == .portrait ? .portrait : .landscapeRight
    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { _ in
      Task { @MainActor in UIDevice.current.setValue(device.rawValue, forKey: "orientation") }
    }
    try? await Task.sleep(for: .seconds(1.5))
    let b = window?.bounds.size ?? .zero
    if (b.height > b.width) != (o == .portrait) { log("could not turn the screen to \(o == .portrait ? "portrait" : "landscape")") }
  }

  /// The small window and its handle, where a touch is meant to land on them and not on the picture below.
  private static func coveredBySmallWindow(_ p: CGPoint, prefs: WiiUScreenPrefs, window: UIWindow) -> Bool {
    let i = window.safeAreaInsets
    let l = WiiUScreenLayout.compute(prefs: prefs, size: window.bounds.size, safe: (i.top, i.left, i.bottom, i.right),
                                     isPad: UIDevice.current.userInterfaceIdiom == .pad)
    guard let w = l.second, l.secondIsWindow else { return false }
    return w.insetBy(dx: -70, dy: -40).contains(p)
  }

  /// What the game read last, waiting up to 0.5 s for it to read a new value.
  private static func gameTouch(after: (Float, Float, Bool)?) async -> (Float, Float, Bool)? {
    for _ in 0..<50 {
      var x: Float = 0, y: Float = 0, down: ObjCBool = false
      if CemuBridge.lastGameTouchX(&x, y: &y, down: &down) {
        let v = (x, y, down.boolValue)
        if after == nil || v.0 != after!.0 || v.1 != after!.1 || v.2 != after!.2 { return v }
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
  }

  /// Taps the four corners and the centre of the GamePad picture in every layout, with and without Swap, upright
  /// and sideways, and checks the touch the game read (854 x 480 pixels) against where the tap was.
  static func touchMapping(screens: WiiUScreenModel, hideControls: @escaping (Bool) -> Void) {
    Task { @MainActor in
      let saved = screens.prefs
      screens.persist = false
      hideControls(true)
      var points = 0, worst: Float = 0, routing = 0, missing = 0
      for (oName, o) in [("portrait", UIInterfaceOrientationMask.portrait), ("landscape", .landscapeRight)] {
        await rotate(o)
        for mode in WiiULayoutMode.allCases {
          for swap in [false, true] {
            var p = saved
            p.layout = mode; p.swap = swap; p.windowHidden = false; p.windowScale = 0.45
            p.tvWindowInGamePad = true; p.controlsStyle = .normal
            screens.prefs = p
            try? await Task.sleep(for: .seconds(1.2))
            let name = "\(oName) \(mode.rawValue) swap=\(swap)"
            guard let window, let view = GamePadTouchUIView.live else {
              log("\(name): no GamePad picture on screen")
              continue
            }
            let frame = view.convert(view.bounds, to: window)
            log("\(name): GamePad picture at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) pt, screen \(Int(window.bounds.width))x\(Int(window.bounds.height))")
            let inset: CGFloat = 0.5
            let targets: [(String, CGPoint)] = [
              ("top left", CGPoint(x: frame.minX + inset, y: frame.minY + inset)),
              ("top right", CGPoint(x: frame.maxX - inset, y: frame.minY + inset)),
              ("bottom left", CGPoint(x: frame.minX + inset, y: frame.maxY - inset)),
              ("bottom right", CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)),
              ("centre", CGPoint(x: frame.midX, y: frame.midY)),
            ]
            var last = await gameTouch(after: nil)
            for (label, pt) in targets {
              let hit = window.hitTest(pt, with: nil)
              if hit !== view && coveredBySmallWindow(pt, prefs: screens.prefs, window: window) {
                log("\(name) \(label): under the small window (a touch here belongs to the window)")
                continue
              }
              if hit !== view {
                routing += 1
                log("\(name) \(label): FAIL, a touch here reaches \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                continue
              }
              let local = view.convert(pt, from: window)
              let want = (Float(local.x / view.bounds.width * 854), Float(local.y / view.bounds.height * 480))
              view.send(local, down: true)
              guard let got = await gameTouch(after: last), got.2 else {
                missing += 1; log("\(name) \(label): FAIL, the game didn't read the touch"); continue
              }
              view.send(local, down: false)
              last = await gameTouch(after: got)
              let err = max(abs(got.0 - want.0), abs(got.1 - want.1))
              worst = max(worst, err); points += 1
              log(String(format: "%@ %@: tapped %.1f,%.1f, game read %.1f,%.1f, off by %.2f px", name, label, want.0, want.1, got.0, got.1, err))
            }
            // just outside the picture: must not reach the GamePad touch screen
            for (label, pt) in [("left of it", CGPoint(x: frame.minX - 6, y: frame.midY)), ("below it", CGPoint(x: frame.midX, y: frame.maxY + 6))]
            where window.bounds.contains(pt) {
              if window.hitTest(pt, with: nil) === view { routing += 1; log("\(name) \(label): FAIL, reaches the GamePad touch screen") }
            }
          }
        }
      }
      // a small window: the first tap enlarges it and doesn't reach the game
      await rotate(.landscapeRight)
      var p = saved; p.layout = .pip; p.swap = false; p.windowHidden = false; p.windowScale = 0.25
      screens.prefs = p
      try? await Task.sleep(for: .seconds(1.2))
      if let window, let view = GamePadTouchUIView.live {
        let before = await gameTouch(after: nil)
        let small = view.convert(view.bounds, to: window)
        sendTouch(view: view, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        try? await Task.sleep(for: .seconds(0.6))
        let after = await gameTouch(after: before)
        let big = GamePadTouchUIView.live.map { $0.convert($0.bounds, to: window) } ?? .zero
        log(String(format: "small window %dx%d pt: tap -> %@, window now %dx%d pt, game read %@", Int(small.width), Int(small.height),
                   screens.expanded ? "enlarged" : "NOT enlarged", Int(big.width), Int(big.height),
                   after.map { $0.2 ? "a touch (FAIL)" : "no touch" } ?? "no touch"))
        if !screens.expanded || after?.2 == true { routing += 1 }
      }
      screens.collapse()
      screens.prefs = saved
      screens.persist = true
      hideControls(false)
      log(String(format: "touch mapping done: %d taps, worst %.2f px, %d routing failures, %d not read", points, worst, routing, missing))
    }
  }

  /// A whole touch through the view's own UIKit path (began, ended), as a finger would.
  private static func sendTouch(view: GamePadTouchUIView, at p: CGPoint) {
    // UITouch can't be made by hand; begin the same way touchesBegan does
    if view.onBegin?() ?? true { view.send(p, down: true); view.send(p, down: false) }
  }

  /// Draws a line across the GamePad picture in 1 s (points at 120 Hz, like a ProMotion screen) and records
  /// every distinct point the game read, to check that drawing is smooth: the game should see a new point every
  /// frame, moving forward evenly, with no gaps.
  static func drawLine() {
    guard let view = GamePadTouchUIView.live else { log("draw: no GamePad picture"); return }
    let reads = ReadRecorder()
    reads.start()
    Task { @MainActor in
      let w = view.bounds.width, h = view.bounds.height
      let steps = 120
      let t0 = CACurrentMediaTime()
      for i in 0...steps {
        let f = CGFloat(i) / CGFloat(steps)
        view.send(CGPoint(x: w * (0.15 + 0.7 * f), y: h * (0.5 + 0.2 * sin(f * .pi * 2))), down: true)
        let next = t0 + Double(i + 1) / 120.0
        let wait = next - CACurrentMediaTime()
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      }
      view.send(CGPoint(x: w * 0.85, y: h * 0.5), down: false)
      try? await Task.sleep(for: .milliseconds(200))
      let samples = reads.stop().filter { $0.down }
      guard samples.count > 2 else { log("draw: the game read \(samples.count) points (FAIL)"); return }
      var gaps: [Double] = [], back = 0, maxJump: Float = 0
      for i in 1..<samples.count {
        gaps.append(samples[i].t - samples[i - 1].t)
        if samples[i].x < samples[i - 1].x - 0.5 { back += 1 }
        maxJump = max(maxJump, hypotf(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y))
      }
      let mean = gaps.reduce(0, +) / Double(gaps.count)
      log(String(format: "draw: the game read %d new points in %.2f s, every %.1f ms on average (longest gap %.1f ms), %d steps backwards, largest step %.1f px (the finger moves %.1f px per 1/60 s)",
                 samples.count, samples.last!.t - samples.first!.t, mean * 1000, (gaps.max() ?? 0) * 1000, back, maxJump, 0.7 * 854 / 60))
    }
  }

  /// Polls what the game read, on its own thread every 0.5 ms, and keeps each new value.
  final class ReadRecorder: @unchecked Sendable {
    struct Sample { let t: Double; let x: Float; let y: Float; let down: Bool }
    private var samples: [Sample] = []
    private var running = true
    private let lock = NSLock()
    private var thread: Thread?

    func start() {
      let t = Thread { [self] in
        var last: (Float, Float, Bool)?
        while lock.withLock({ running }) {
          var x: Float = 0, y: Float = 0, down: ObjCBool = false
          if CemuBridge.lastGameTouchX(&x, y: &y, down: &down) {
            if last == nil || last!.0 != x || last!.1 != y || last!.2 != down.boolValue {
              last = (x, y, down.boolValue)
              let s = Sample(t: CACurrentMediaTime(), x: x, y: y, down: down.boolValue)
              lock.withLock { samples.append(s) }
            }
          }
          usleep(500)
        }
      }
      t.qualityOfService = .userInteractive
      thread = t
      t.start()
    }

    func stop() -> [Sample] {
      lock.withLock { running = false }
      return lock.withLock { samples }
    }
  }

  /// Goes through every layout (and the menu and the tip) for screenshots. Each state is written to
  /// Documents/screens-tour.txt when it's on screen, so a script can take the screenshot.
  static func tour(screens: WiiUScreenModel, showTip: @escaping (Bool) -> Void, showPause: @escaping (Bool) -> Void) {
    Task { @MainActor in
      let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("screens-tour.txt")
      func mark(_ s: String) async {
        try? s.write(to: file, atomically: true, encoding: .utf8)
        log("tour: \(s)")
        try? await Task.sleep(for: .seconds(3))
      }
      let saved = screens.prefs
      screens.persist = false
      let isPad = UIDevice.current.userInterfaceIdiom == .pad
      for (oName, o) in [("landscape", UIInterfaceOrientationMask.landscapeRight), ("portrait", .portrait)] {
        await rotate(o)
        for mode in WiiULayoutMode.allCases where mode != .split || WiiULayoutMode.splitOffered(isPad: isPad, portrait: oName == "portrait") {
          var p = saved; p.layout = mode; p.swap = false; p.windowHidden = false; p.windowScale = 0.3
          p.tvWindowInGamePad = mode == .gamePad && oName == "landscape"
          screens.prefs = p
          try? await Task.sleep(for: .seconds(3))
          await mark("\(oName)-\(mode.rawValue)")
          if mode == .pip || mode == .split {
            screens.prefs.swap = true
            try? await Task.sleep(for: .seconds(3))
            await mark("\(oName)-\(mode.rawValue)-swap")
          }
        }
        var p = saved; p.layout = .pip; p.swap = false; p.windowHidden = false
        screens.prefs = p
        try? await Task.sleep(for: .seconds(3))
        screens.showOptions = true
        try? await Task.sleep(for: .seconds(1))
        await mark("\(oName)-menu")
        screens.showOptions = false
        showTip(true)
        try? await Task.sleep(for: .seconds(1))
        await mark("\(oName)-tip")
        showTip(false)
        screens.bannerSeconds = 4
        screens.set(.gamePad)
        try? await Task.sleep(for: .seconds(2.5))
        await mark("\(oName)-label")
        showPause(true)
        try? await Task.sleep(for: .seconds(1.5))
        await mark("\(oName)-pause")
        showPause(false)
        try? await Task.sleep(for: .seconds(1))
      }
      screens.bannerSeconds = 1
      screens.prefs = saved
      screens.persist = true
      await mark("done")
    }
  }
}
#endif
