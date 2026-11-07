// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U screen layouts on iPhone and iPad sizes, upright and sideways: each picture keeps its aspect
// ratio and stays on screen, the GamePad picture stays clear of the top bar's buttons, and GamePad touch maps
// a point in the picture to the same point of the 854 x 480 touch screen.

import CoreGraphics
import XCTest
@testable import iCube

final class WiiULayoutTests: XCTestCase {
  typealias Safe = (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)

  /// Point sizes and safe areas of the Simulator devices the screenshots use.
  static let devices: [(name: String, size: CGSize, safe: Safe, isPad: Bool)] = [
    ("iPhone 18 Pro upright", CGSize(width: 402, height: 874), (62, 0, 34, 0), false),
    ("iPhone 18 Pro sideways", CGSize(width: 874, height: 402), (0, 62, 21, 62), false),
    ("iPhone 18 Pro Max upright", CGSize(width: 440, height: 956), (62, 0, 34, 0), false),
    ("iPad Pro 13 upright", CGSize(width: 1032, height: 1376), (24, 0, 20, 0), true),
    ("iPad Pro 13 sideways", CGSize(width: 1376, height: 1032), (24, 0, 20, 0), true),
    ("iPad Pro 11 sideways", CGSize(width: 1210, height: 834), (24, 0, 20, 0), true),
  ]

  private func allPrefs() -> [WiiUScreenPrefs] {
    var out: [WiiUScreenPrefs] = []
    for mode in WiiULayoutMode.allCases {
      for swap in [false, true] {
        for tvWindow in [false, true] {
          for anchor in WiiUWindowAnchor.allCases {
            var p = WiiUScreenPrefs()
            p.layout = mode; p.swap = swap; p.tvWindowInGamePad = tvWindow; p.anchor = anchor
            p.windowScale = 0.3
            out.append(p)
          }
        }
      }
    }
    return out
  }

  func testPicturesKeepAspectAndStayOnScreen() {
    for d in Self.devices {
      for p in allPrefs() {
        for expanded in [false, true] {
          let l = WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: d.isPad, expanded: expanded)
          let screen = CGRect(origin: .zero, size: d.size)
          let name = "\(d.name) \(p.mode) swap=\(p.swap) tv=\(p.tvWindowInGamePad) \(p.windowAnchor) expanded=\(expanded)"
          var rects: [(CGRect, WiiUScreen)] = [(l.main, l.mainShows)]
          if let s = l.second { rects.append((s, l.secondShows)) }
          for (r, shows) in rects {
            XCTAssertTrue(screen.contains(r), "\(name): \(r) leaves the screen")
            let aspect = r.width / r.height
            XCTAssertEqual(aspect, WiiUScreenLayout.aspect(shows), accuracy: WiiUScreenLayout.aspect(shows) * 0.01, "\(name): \(r) is stretched")
          }
          if let s = l.second {
            XCTAssertFalse(s.intersection(l.main).width > 1 && !l.secondIsWindow, "\(name): split pictures overlap")
            if l.secondIsWindow {
              // the window stays inside the safe area at the sides and above the home indicator
              XCTAssertGreaterThanOrEqual(s.minX, max(d.safe.left, d.safe.right) - 0.5, name)
              XCTAssertLessThanOrEqual(s.maxX, d.size.width - max(d.safe.left, d.safe.right) + 0.5, name)
              XCTAssertLessThanOrEqual(s.maxY, d.size.height - d.safe.bottom + 0.5, name)
            }
          }
          // Split falls back to TV + GamePad only on an iPhone held sideways
          if p.layout == .split {
            let portrait = d.size.height > d.size.width
            XCTAssertEqual(l.shown, d.isPad || portrait ? .split : .pip, name)
          }
        }
      }
    }
  }

  func testGamePadPictureClearOfTopBarButtons() {
    for d in Self.devices {
      for p in allPrefs() {
        let l = WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: d.isPad)
        guard let pad = l.gamePad else { continue }
        // the layout button (left) and the pause button (right), 44 x 44 pt each, 16 pt from the bar's ends
        let layoutButton = CGRect(x: l.topBar.minX + 16, y: l.topBar.minY + 4, width: 44, height: 44)
        let pauseButton = CGRect(x: l.topBar.maxX - 16 - 44, y: l.topBar.minY + 4, width: 44, height: 44)
        let name = "\(d.name) \(p.mode) swap=\(p.swap) \(p.windowAnchor)"
        XCTAssertFalse(pad.intersects(l.topBar), "\(name): GamePad picture \(pad) under the top bar \(l.topBar)")
        XCTAssertLessThanOrEqual(pad.maxY, d.size.height - d.safe.bottom + 0.5, "\(name): GamePad picture \(pad) under the home indicator")
        XCTAssertFalse(pad.intersects(layoutButton), "\(name): GamePad picture \(pad) under the layout button")
        XCTAssertFalse(pad.intersects(pauseButton), "\(name): GamePad picture \(pad) under the pause button")
        // and the bar itself stays out of the safe areas
        XCTAssertGreaterThanOrEqual(layoutButton.minX, max(d.safe.left, d.safe.right), name)
        XCTAssertGreaterThanOrEqual(layoutButton.minY, 0, name)
      }
    }
  }

  func testWhichPictureGoesWhere() {
    let d = Self.devices[1]
    func layout(_ m: WiiULayoutMode, swap: Bool = false, tv: Bool = false) -> WiiUScreenLayout {
      var p = WiiUScreenPrefs(); p.layout = m; p.swap = swap; p.tvWindowInGamePad = tv
      return WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: d.isPad)
    }
    XCTAssertEqual(layout(.tvOnly).mainShows, .tv); XCTAssertNil(layout(.tvOnly).second)
    XCTAssertEqual(layout(.tvOnly, swap: true).mainShows, .tv)
    XCTAssertEqual(layout(.pip).mainShows, .tv); XCTAssertEqual(layout(.pip).secondShows, .gamePad)
    XCTAssertEqual(layout(.pip, swap: true).mainShows, .gamePad); XCTAssertEqual(layout(.pip, swap: true).secondShows, .tv)
    XCTAssertEqual(layout(.gamePad).mainShows, .gamePad); XCTAssertNil(layout(.gamePad).second)
    XCTAssertEqual(layout(.gamePad, tv: true).secondShows, .tv)
    XCTAssertEqual(layout(.gamePad, swap: true, tv: true).mainShows, .tv)
    var hidden = WiiUScreenPrefs(); hidden.layout = .pip; hidden.windowHidden = true
    XCTAssertNil(WiiUScreenLayout.compute(prefs: hidden, size: d.size, safe: d.safe, isPad: false).second)
    // an enlarged window is larger
    var p = WiiUScreenPrefs(); p.layout = .pip; p.windowScale = 0.2
    let small = WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: false).second!
    let big = WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: false, expanded: true).second!
    XCTAssertGreaterThan(big.width, small.width * 2)
  }

  func testTouchMapsToGamePadPixels() {
    for d in Self.devices {
      for p in allPrefs() {
        let l = WiiUScreenLayout.compute(prefs: p, size: d.size, safe: d.safe, isPad: d.isPad)
        guard let pad = l.gamePad else { continue }
        for (fx, fy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0), (0.5, 0.5)] {
          let local = CGPoint(x: pad.width * fx, y: pad.height * fy)
          let t = WiiUScreenLayout.touch(local, in: pad.size)
          XCTAssertEqual(t.x * 854, fx * 854, accuracy: 0.01)
          XCTAssertEqual(t.y * 480, fy * 480, accuracy: 0.01)
        }
      }
    }
    // a drag that leaves the picture stays at its edge
    XCTAssertEqual(WiiUScreenLayout.touch(CGPoint(x: -20, y: 500), in: CGSize(width: 427, height: 240)), CGPoint(x: 0, y: 1))
  }

  func testCycleOrder() {
    XCTAssertEqual(WiiULayoutMode.tvOnly.next(isPad: false, portrait: true), .pip)
    XCTAssertEqual(WiiULayoutMode.pip.next(isPad: false, portrait: true), .gamePad)
    XCTAssertEqual(WiiULayoutMode.gamePad.next(isPad: false, portrait: true), .split)
    XCTAssertEqual(WiiULayoutMode.split.next(isPad: false, portrait: true), .tvOnly)
    XCTAssertEqual(WiiULayoutMode.gamePad.next(isPad: false, portrait: false), .tvOnly)   // Split skipped
    XCTAssertEqual(WiiULayoutMode.gamePad.next(isPad: true, portrait: false), .split)
  }

  func testNearestAnchor() {
    let s = CGSize(width: 900, height: 400)
    XCTAssertEqual(WiiUScreenLayout.nearestAnchor(to: CGPoint(x: 10, y: 10), in: s), .topLeft)
    XCTAssertEqual(WiiUScreenLayout.nearestAnchor(to: CGPoint(x: 450, y: 50), in: s), .topCenter)
    XCTAssertEqual(WiiUScreenLayout.nearestAnchor(to: CGPoint(x: 890, y: 390), in: s), .bottomRight)
  }

  func testPrefsSavedPerGameWithDefaults() throws {
    let d = try XCTUnwrap(UserDefaults(suiteName: "WiiULayoutTests"))
    d.removePersistentDomain(forName: "WiiULayoutTests")
    // nothing saved: TV only, Kirby and the Rainbow Curse in GamePad full screen
    XCTAssertEqual(WiiUScreenPrefs.load("A", titleId: 0x0005_0000_101C_9400, defaults: d).layout, .tvOnly)
    XCTAssertEqual(WiiUScreenPrefs.load("K", titleId: 0x0005_0000_101A_BC00, defaults: d).layout, .gamePad)
    // the earlier global setting is the default
    d.set("window", forKey: "cafeGamePadScreen")
    XCTAssertEqual(WiiUScreenPrefs.load("A", titleId: 1, defaults: d).layout, .pip)
    d.set(WiiULayoutMode.split.rawValue, forKey: "cafeDefaultLayout")
    XCTAssertEqual(WiiUScreenPrefs.load("A", titleId: 1, defaults: d).layout, .split)
    // saved per game
    var p = WiiUScreenPrefs(); p.layout = .gamePad; p.swap = true; p.anchor = .bottomLeft; p.windowScale = 0.4
    p.save("A", defaults: d)
    XCTAssertEqual(WiiUScreenPrefs.load("A", titleId: 1, defaults: d), p)
    XCTAssertEqual(WiiUScreenPrefs.load("B", titleId: 2, defaults: d).layout, .split)
    d.removePersistentDomain(forName: "WiiULayoutTests")
  }

  // MARK: controller shortcut (hold Menu, press L or R)

  func testShortcutNextLayoutAndSwap() {
    var f = WiiUShortcutFilter()
    let t0 = Date(), plus = WiiUShortcutFilter.plus, l = WiiUShortcutFilter.l, r = WiiUShortcutFilter.r
    var (out, fired) = f.filter(plus, now: t0)
    XCTAssertEqual(out, 0, "Menu is held back at first"); XCTAssertEqual(fired, [])
    (out, fired) = f.filter(plus | l, now: t0 + 0.1)
    XCTAssertEqual(out, 0, "neither + nor L reaches the game"); XCTAssertEqual(fired, [.nextLayout])
    (out, fired) = f.filter(plus | l, now: t0 + 0.5)
    XCTAssertEqual(out, 0); XCTAssertEqual(fired, [], "held L doesn't repeat")
    (out, fired) = f.filter(plus | l | r, now: t0 + 0.6)
    XCTAssertEqual(fired, [.swap])
    (out, fired) = f.filter(l, now: t0 + 0.7)
    XCTAssertEqual(out, 0, "L stays away from the game until it is released")
    (out, fired) = f.filter(0, now: t0 + 0.8)
    XCTAssertEqual(out, 0)
    (out, fired) = f.filter(l, now: t0 + 0.9)
    XCTAssertEqual(out, l, "a new L press reaches the game")
  }

  func testShortcutQuickMenuPressStillReachesGame() {
    var f = WiiUShortcutFilter()
    let t0 = Date(), plus = WiiUShortcutFilter.plus
    XCTAssertEqual(f.filter(plus, now: t0).0, 0)
    XCTAssertEqual(f.filter(0, now: t0 + 0.12).0, plus, "released quickly: sent as a short press")
    XCTAssertEqual(f.filter(0, now: t0 + 0.15).0, plus)
    XCTAssertEqual(f.filter(0, now: t0 + 0.25).0, 0)
    // held longer than the wait: the game sees it held
    XCTAssertEqual(f.filter(plus, now: t0 + 1).0, 0)
    XCTAssertEqual(f.filter(plus, now: t0 + 1.35).0, plus)
    XCTAssertEqual(f.filter(0, now: t0 + 2).0, 0)
  }
}
