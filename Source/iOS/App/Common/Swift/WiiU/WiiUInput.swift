// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Wii U GamePad input. Touch controls and any connected game controller are combined into one GamePad
// state and sent to the core 120 times a second while a Wii U game runs.

#if os(iOS) && canImport(IridiaCafeCore)
import GameController
import IridiaCafeCore
import SwiftUI

enum PadButton: UInt32 {
  case a = 0x8000, b = 0x4000, x = 0x2000, y = 0x1000
  case l = 0x0020, r = 0x0010, zl = 0x0080, zr = 0x0040
  case plus = 0x0008, minus = 0x0004, home = 0x0002
  case up = 0x0200, down = 0x0100, left = 0x0800, right = 0x0400
  case stickR = 0x0002_0000, stickL = 0x0004_0000
}

@MainActor
final class PadInput: ObservableObject {
  static let shared = PadInput()

  @Published var controllerConnected = false
  // Touch state (main thread). Every change is sent to the core at once (the timer only adds game controllers).
  var touchButtons: UInt32 = 0 { didSet { push() } }
  var touchLeft = CGPoint.zero { didSet { push() } }
  var touchRight = CGPoint.zero { didSet { push() } }

  private var timer: Timer?
  private var observer: NSObjectProtocol?

  /// Controller shortcut: hold Menu and press L (next layout) or R (swap screens). Set by the play screen.
  enum Shortcut { case nextLayout, swap }
  var onShortcut: ((Shortcut) -> Void)?
  private var menuDownAt: Date?
  private var shortcutUsed = false
  private var lastShoulders: UInt32 = 0
  private var held: UInt32 = 0          // L/R kept from the game until released after a shortcut
  private var plusTapUntil: Date?
  /// How long Menu is held back before it reaches the game, to see whether L or R follows.
  private static let shortcutWait: TimeInterval = 0.3

  func start() {
    guard timer == nil else { return }
    // Touch controls stay until a controller is actually used (a connected but idle controller, or the
    // Simulator's built-in one, shouldn't hide them); they come back when the last controller disconnects.
    // Use is seen by polling in push(), so the library's controller handlers are left alone.
    observer = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
      Task { @MainActor in if GCController.controllers().isEmpty { self.controllerConnected = false } }
    }
    // .common: keeps firing while a touch is being tracked (the default mode pauses during touches)
    let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
      Task { @MainActor in self.push() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  /// The game ended: stop sending, release every touch button.
  func stop() {
    timer?.invalidate()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    downAt = [:]
    touchButtons = 0
    touchLeft = .zero
    touchRight = .zero
  }

  /// When each touch button went down: a release comes at least 60 ms (3+ game frames at 60 Hz) after its press,
  /// so a quick tap, or a press reported only at the release, still reaches the game.
  private var downAt: [UInt32: Date] = [:]
  private static let minHold: TimeInterval = 0.06

  func press(_ button: PadButton, _ down: Bool) {
    let bit = button.rawValue
    if down {
      downAt[bit] = Date()
      touchButtons |= bit
      return
    }
    let held = Date().timeIntervalSince(downAt[bit] ?? .distantPast)
    if held >= Self.minHold {
      touchButtons &= ~bit
    } else {
      let pressedAt = downAt[bit]
      DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minHold - held)) {
        // skip if the button was pressed again meanwhile
        if self.downAt[bit] == pressedAt { self.touchButtons &= ~bit }
      }
    }
  }

  private func push() {
    guard timer != nil else { return }
    var buttons: UInt32 = 0
    var lx = Float(touchLeft.x), ly = Float(touchLeft.y), rx = Float(touchRight.x), ry = Float(touchRight.y)
    for controller in GCController.controllers() {
      guard let pad = controller.extendedGamepad else { continue }
      // Wii U layout: A right, B bottom, X top, Y left (Nintendo positions), so swap from Xbox-style naming.
      if pad.buttonB.isPressed { buttons |= PadButton.a.rawValue }
      if pad.buttonA.isPressed { buttons |= PadButton.b.rawValue }
      if pad.buttonY.isPressed { buttons |= PadButton.x.rawValue }
      if pad.buttonX.isPressed { buttons |= PadButton.y.rawValue }
      if pad.leftShoulder.isPressed { buttons |= PadButton.l.rawValue }
      if pad.rightShoulder.isPressed { buttons |= PadButton.r.rawValue }
      if pad.leftTrigger.isPressed { buttons |= PadButton.zl.rawValue }
      if pad.rightTrigger.isPressed { buttons |= PadButton.zr.rawValue }
      if pad.buttonMenu.isPressed { buttons |= PadButton.plus.rawValue }
      if pad.buttonOptions?.isPressed == true { buttons |= PadButton.minus.rawValue }
      if pad.leftThumbstickButton?.isPressed == true { buttons |= PadButton.stickL.rawValue }
      if pad.rightThumbstickButton?.isPressed == true { buttons |= PadButton.stickR.rawValue }
      if pad.dpad.up.isPressed { buttons |= PadButton.up.rawValue }
      if pad.dpad.down.isPressed { buttons |= PadButton.down.rawValue }
      if pad.dpad.left.isPressed { buttons |= PadButton.left.rawValue }
      if pad.dpad.right.isPressed { buttons |= PadButton.right.rawValue }
      func pick(_ a: Float, _ b: Float) -> Float { abs(a) > abs(b) ? a : b }
      lx = pick(lx, pad.leftThumbstick.xAxis.value)
      ly = pick(ly, pad.leftThumbstick.yAxis.value)
      rx = pick(rx, pad.rightThumbstick.xAxis.value)
      ry = pick(ry, pad.rightThumbstick.yAxis.value)
    }
    buttons = shortcuts(buttons)
    // A controller button, or a stick moved while no touch stick is held, means a controller is in use.
    let controllerButtons = buttons != 0
    buttons |= touchButtons
    let controllerStick = touchLeft == .zero && touchRight == .zero && abs(lx) + abs(ly) + abs(rx) + abs(ry) > 0.5
    if (controllerButtons || controllerStick) && !controllerConnected { controllerConnected = true }
    CemuBridge.setButtons(buttons, leftX: lx, leftY: ly, rightX: rx, rightY: ry)
  }
}

extension PadInput {
  /// Takes the controller's buttons (Menu is +) and handles the shortcut: while Menu is held, L and R go to the
  /// app instead of the game. A quick Menu press on its own still reaches the game as a + press.
  fileprivate func shortcuts(_ pad: UInt32) -> UInt32 {
    let plus = PadButton.plus.rawValue, l = PadButton.l.rawValue, r = PadButton.r.rawValue
    let now = Date()
    var out = pad
    let shoulders = pad & (l | r)
    if pad & plus != 0 {
      if menuDownAt == nil { menuDownAt = now; shortcutUsed = false }
      let pressed = shoulders & ~lastShoulders
      if pressed & l != 0 { shortcutUsed = true; onShortcut?(.nextLayout) }
      if pressed & r != 0 { shortcutUsed = true; onShortcut?(.swap) }
      if shortcutUsed {
        out &= ~(plus | l | r)
        held |= shoulders
      } else if now.timeIntervalSince(menuDownAt!) < Self.shortcutWait {
        out &= ~plus
      }
    } else if let down = menuDownAt {
      // released quickly without a shortcut: send the + press now, as a short tap
      if !shortcutUsed && now.timeIntervalSince(down) < Self.shortcutWait { plusTapUntil = now.addingTimeInterval(0.08) }
      menuDownAt = nil
    }
    held &= shoulders
    out &= ~held
    if let until = plusTapUntil {
      if now < until { out |= plus } else { plusTapUntil = nil }
    }
    lastShoulders = shoulders
    return out
  }
}

// MARK: - Touch controls (GamePad: landscape and portrait)
// The GamePad held sideways: a white grip on each side running off the screen edge, left stick above the D-pad,
// right stick above ABXY, - and + at the top centre (away from ABXY), HOME at the bottom centre, L/ZL and R/ZR as tabs at the top.
// Drawn with PadArt (Iridia's matte-plastic style); images are cached, so play only swaps them.

/// Item frames in a 176 x 334 design box per side (origin top-left), scaled to the screen.
private enum GamePadLayout {
  static let box = CGSize(width: 176, height: 334)
  static let lShoulders = (zl: CGRect(x: 6, y: 0, width: 74, height: 36), l: CGRect(x: 88, y: 0, width: 80, height: 36))
  static let rShoulders = (r: CGRect(x: 8, y: 0, width: 80, height: 36), zr: CGRect(x: 96, y: 0, width: 74, height: 36))
  static let stick = CGRect(x: 30, y: 58, width: 116, height: 116)
  static let dpad = CGRect(x: 40, y: 198, width: 100, height: 100)
  static let x = CGRect(x: 65, y: 181, width: 46, height: 46)
  static let y = CGRect(x: 21, y: 225, width: 46, height: 46)
  static let a = CGRect(x: 109, y: 225, width: 46, height: 46)
  static let b = CGRect(x: 65, y: 269, width: 46, height: 46)
  static let minus = CGRect(x: 16, y: 292, width: 30, height: 30)
  static let plus = CGRect(x: 130, y: 292, width: 30, height: 30)
  /// How far the grip runs past the outer screen edge, and its margin around the controls.
  static let overhang: CGFloat = 70, margin: CGFloat = 14
}

struct WiiUTouchControls: View {
  @ObservedObject var input: PadInput
  var portrait = false
  /// Portrait: the bottom of the game pictures (the controls use the space below it).
  var pictureBottom: CGFloat = 0
  /// Landscape: small controls in the bottom corners, leaving the middle of the screen free (for GamePad touch).
  var compact = false
  /// Landscape: the middle of the top bar's row, where - and + sit (away from ABXY, so they aren't hit by accident).
  var menuRowY: CGFloat = 26

  var body: some View {
    GeometryReader { geo in
      if portrait { portraitBody(geo) } else { landscapeBody(geo) }
    }
  }

  private func landscapeBody(_ geo: GeometryProxy) -> some View {
    // scale to the usable height (the top 52 pt hold the speed label and pause button)
    let full = min(1.0, max(0.6, (geo.size.height - 66) / GamePadLayout.box.height))
    let s = compact ? min(full, 0.62) : full
    return ZStack {
      HStack(alignment: .top, spacing: 0) {
        GamePadSide(left: true, s: s, input: input)
        Spacer(minLength: 0)
        GamePadSide(left: false, s: s, menuButtons: false, input: input)
      }
      .padding(.top, compact ? 0 : 52)
      .padding(.bottom, compact ? 4 : 0)
      .padding(.horizontal, compact ? 0 : 6)
      .frame(maxHeight: .infinity, alignment: compact ? .bottom : .center)
      VStack {
        Spacer()
        PadPartButton(button: .home, shape: .circle, size: CGSize(width: 36 * s, height: 36 * s), base: PadPalette.blue,
                      symbol: "house.fill", input: input)
          .padding(.bottom, 6)
      }
      // - and + at the top centre, in the row of the layout and pause buttons, far from the face buttons
      HStack(spacing: 84) {
        PadPartButton(button: .minus, shape: .circle, size: CGSize(width: 34, height: 34), base: PadPalette.silver, symbol: "minus", input: input)
        PadPartButton(button: .plus, shape: .circle, size: CGSize(width: 34, height: 34), base: PadPalette.silver, symbol: "plus", input: input)
      }
      .position(x: geo.size.width / 2, y: menuRowY)
    }
  }

  // Portrait (like the GameCube app): the menu row (-, HOME, +) just under the picture, then the two halves of
  // the GamePad side by side at the bottom, where the thumbs are.
  private func portraitBody(_ geo: GeometryProxy) -> some View {
    let L = GamePadLayout.self
    let menuRow: CGFloat = 46
    let below = geo.size.height - pictureBottom - menuRow - 16
    let s = min(1.0, max(0.55, min((geo.size.width - 12) / (L.box.width * 2), below / L.box.height)))
    let m = 34 * s
    return VStack(spacing: 0) {
      Color.clear.frame(height: pictureBottom + 10)
      HStack(spacing: 28 * s) {
        PadPartButton(button: .minus, shape: .circle, size: CGSize(width: m, height: m), base: PadPalette.silver, symbol: "minus", input: input)
        PadPartButton(button: .home, shape: .circle, size: CGSize(width: m + 4, height: m + 4), base: PadPalette.blue, symbol: "house.fill", input: input)
        PadPartButton(button: .plus, shape: .circle, size: CGSize(width: m, height: m), base: PadPalette.silver, symbol: "plus", input: input)
      }
      .frame(height: menuRow)
      Spacer(minLength: 0)
      HStack(alignment: .bottom, spacing: 0) {
        GamePadSide(left: true, s: s, input: input)
        Spacer(minLength: 0)
        GamePadSide(left: false, s: s, menuButtons: false, input: input)
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 4)
    }
  }
}

struct GamePadSide: View {
  let left: Bool
  let s: CGFloat
  /// - and + in this side's box (not used now: landscape has them at the top centre, portrait in the menu row).
  var menuButtons = true
  @ObservedObject var input: PadInput

  private func sc(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }

  var body: some View {
    let L = GamePadLayout.self
    let box = CGSize(width: L.box.width * s, height: L.box.height * s)
    ZStack(alignment: .topLeading) {
      // no grip panel: the controls float over the game like the GameCube app's landscape layout
      if left {
        place(sc(L.lShoulders.zl)) { PadPartButton(button: .zl, shape: .tab, size: $0, base: PadPalette.slate, text: "ZL", input: input) }
        place(sc(L.lShoulders.l)) { PadPartButton(button: .l, shape: .tab, size: $0, base: PadPalette.silver, text: "L", input: input) }
        place(sc(L.stick)) { PadStick(size: $0, value: Binding(get: { input.touchLeft }, set: { input.touchLeft = $0 }), click: .stickL, input: input) }
        place(sc(L.dpad)) { PadDPad(size: $0, input: input) }
      } else {
        place(sc(L.rShoulders.r)) { PadPartButton(button: .r, shape: .tab, size: $0, base: PadPalette.silver, text: "R", input: input) }
        place(sc(L.rShoulders.zr)) { PadPartButton(button: .zr, shape: .tab, size: $0, base: PadPalette.slate, text: "ZR", input: input) }
        place(sc(L.stick)) { PadStick(size: $0, value: Binding(get: { input.touchRight }, set: { input.touchRight = $0 }), click: .stickR, input: input) }
        // Wii U positions: X top, Y left, A right, B bottom.
        place(sc(L.x)) { PadPartButton(button: .x, shape: .circle, size: $0, base: PadPalette.silver, text: "X", input: input) }
        place(sc(L.y)) { PadPartButton(button: .y, shape: .circle, size: $0, base: PadPalette.silver, text: "Y", input: input) }
        place(sc(L.a)) { PadPartButton(button: .a, shape: .circle, size: $0, base: PadPalette.silver, text: "A", input: input) }
        place(sc(L.b)) { PadPartButton(button: .b, shape: .circle, size: $0, base: PadPalette.silver, text: "B", input: input) }
        if menuButtons {
          place(sc(L.minus)) { PadPartButton(button: .minus, shape: .circle, size: $0, base: PadPalette.silver, symbol: "minus", input: input) }
          place(sc(L.plus)) { PadPartButton(button: .plus, shape: .circle, size: $0, base: PadPalette.silver, symbol: "plus", input: input) }
        }
      }
    }
    .frame(width: box.width, height: box.height, alignment: .topLeading)
  }

  private func place<V: View>(_ r: CGRect, @ViewBuilder _ content: (CGSize) -> V) -> some View {
    content(r.size).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
  }
}

/// A drawn button: the touch area is the part itself (plus a little slop); the image adds shadow room.
struct PadPartButton: View {
  let button: PadButton
  let shape: PadShape
  let size: CGSize
  let base: UIColor
  var text: String? = nil
  var symbol: String? = nil
  @ObservedObject var input: PadInput
  @State private var down = false

  var body: some View {
    let pad = PadArt.padding(for: size)
    Color.clear
      .frame(width: size.width, height: size.height)
      .overlay {
        Image(uiImage: PadArt.shared.button(shape, size: size, base: base, text: text, symbol: symbol, pressed: down))
          .frame(width: size.width + pad * 2, height: size.height + pad * 2)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle().inset(by: -6))
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { _ in if !down { down = true; input.press(button, true); WiiUHaptics.tap() } }
        .onEnded { _ in down = false; input.press(button, false) })
  }
}

/// The D-pad: one cross; the touch position picks the direction, so sliding works and diagonals are possible.
struct PadDPad: View {
  let size: CGSize
  @ObservedObject var input: PadInput
  @State private var mask: UInt32 = 0
  private static let dirs: [(PadButton, Int)] = [(.up, 0), (.down, 1), (.left, 2), (.right, 3)]

  var body: some View {
    let pad = PadArt.padding(for: size)
    Color.clear
      .frame(width: size.width, height: size.height)
      .overlay {
        ZStack {
          Image(uiImage: PadArt.shared.dpad(size: size, base: PadPalette.slate))
            .frame(width: size.width + pad * 2, height: size.height + pad * 2)
          ForEach(Self.dirs, id: \.1) { b, d in
            if mask & b.rawValue != 0 { Image(uiImage: PadArt.shared.dpadArm(size: size, direction: d)) }
          }
        }
        .allowsHitTesting(false)
      }
      .contentShape(Rectangle().inset(by: -10))
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in set(direction(g.location)) }
        .onEnded { _ in set(0) })
  }

  private func direction(_ p: CGPoint) -> UInt32 {
    let dx = p.x - size.width / 2, dy = p.y - size.height / 2
    if abs(dx) < size.width * 0.10 && abs(dy) < size.height * 0.10 { return 0 }
    var m: UInt32 = 0
    // a direction counts when it's the main one or within about 22 degrees of the diagonal
    if abs(dx) > abs(dy) * 0.42 { m |= dx < 0 ? PadButton.left.rawValue : PadButton.right.rawValue }
    if abs(dy) > abs(dx) * 0.42 { m |= dy < 0 ? PadButton.up.rawValue : PadButton.down.rawValue }
    return m
  }

  private func set(_ m: UInt32) {
    guard m != mask else { return }
    for (b, _) in Self.dirs where (mask & b.rawValue != 0) != (m & b.rawValue != 0) { input.press(b, m & b.rawValue != 0) }
    if m & ~mask != 0 { WiiUHaptics.tap() }
    mask = m
  }
}

/// A stick in its well: drag from anywhere on it; a quick tap without moving clicks the stick.
struct PadStick: View {
  let size: CGSize
  @Binding var value: CGPoint
  let click: PadButton
  @ObservedObject var input: PadInput
  @State private var knob = CGSize.zero
  @State private var started = Date()
  @State private var clicked = false

  var body: some View {
    let cap = CGSize(width: size.width * 0.56, height: size.height * 0.56)
    let pad = PadArt.padding(for: cap)
    let radius = size.width * 0.36
    ZStack {
      Image(uiImage: PadArt.shared.stickWell(size: size))
      Image(uiImage: PadArt.shared.stickCap(size: cap, base: PadPalette.slate, pressed: clicked))
        .frame(width: cap.width + pad * 2, height: cap.height + pad * 2)
        .offset(knob)
    }
    .frame(width: size.width, height: size.height)
    .contentShape(Circle().inset(by: -24))
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { g in
        if knob == .zero && g.translation == .zero { started = Date() }
        var t = g.translation
        let len = sqrt(t.width * t.width + t.height * t.height)
        if len > radius { t = CGSize(width: t.width / len * radius, height: t.height / len * radius) }
        knob = t
        value = CGPoint(x: t.width / radius, y: -t.height / radius)
      }
      .onEnded { g in
        let moved = abs(g.translation.width) + abs(g.translation.height)
        if moved < 6 && Date().timeIntervalSince(started) < 0.25 {
          input.press(click, true); clicked = true; WiiUHaptics.tap()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { input.press(click, false); clicked = false }
        }
        knob = .zero
        value = .zero
      })
  }
}

enum WiiUHaptics {
  static let generator = UIImpactFeedbackGenerator(style: .light)
  static func tap() {
    if UserDefaults.standard.object(forKey: "cafeHaptics") as? Bool ?? true { generator.impactOccurred(intensity: 0.6) }
  }
}
#endif
