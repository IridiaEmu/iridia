// SPDX-License-Identifier: GPL-2.0-or-later
//
// On-screen GameCube controller. Raw UIKit touch handling (no gesture recognizers
// in play mode) so a touch reaches the pad state in the same run-loop turn.
//
// Per touch event: hit-test a handful of rects, recompute one PadState, publish it
// with a single atomic store if it changed, and flip contents on only the layers
// whose pressed state changed. No allocations on the steady-state path.

#if canImport(UIKit)
import GCControlsCore
import UIKit

public struct TouchControllerSettings: Equatable, Sendable {
  public var hapticsEnabled = true
  /// L/R full press on touch instead of slide-for-pressure.
  public var digitalTriggers = false
  public var stick = AnalogSettings.touchDefault
  public var player = 0
  public init() {}
}

@MainActor
public final class TouchControllerView: UIView {
  // MARK: Public configuration

  public var skin: ControllerSkin = BuiltinSkins.default { didSet { if oldValue != skin { rebuild() } } }
  public var orientation: SkinOrientation = .portrait { didSet { if oldValue != orientation { rebuild() } } }
  public var overrides = LayoutOverrides() { didSet { if oldValue != overrides { rebuild() } } }
  public var settings = TouchControllerSettings()
  public var store: PadStateStore = .shared

  /// Menu button tapped (play mode).
  public var onMenu: (() -> Void)?

  /// Edit mode: touches select/move items instead of producing input.
  public var isEditing = false {
    didSet {
      guard oldValue != isEditing else { return }
      releaseAll()
      pinch.isEnabled = isEditing
      if !isEditing { selectedItemID = nil }
      updateSelectionOutline()
    }
  }
  public private(set) var selectedItemID: String? {
    didSet { if oldValue != selectedItemID { onSelectionChanged?(selectedItemID); updateSelectionOutline() } }
  }
  public var onSelectionChanged: ((String?) -> Void)?
  public var onOverridesChanged: ((LayoutOverrides) -> Void)?

  // MARK: Internals

  private struct Placed {
    let item: SkinItem
    var rect: CGRect
    var hitRect: CGRect
    let layer: CALayer
    var knob: CALayer?
    var dpadArms: [CALayer] = []
    var fill: CALayer?
  }

  private enum Capture {
    case buttons(Set<Int>)  // indices into `placed` currently under this touch
    case stick(Int)
    case trigger(Int, startY: CGFloat)
    case menu(Int)
    case edit(Int, last: CGPoint)
  }

  private var renderer = SkinRenderer(skin: BuiltinSkins.default)
  private var layout: SkinLayout = BuiltinSkins.default.portrait
  private var placed: [Placed] = []
  private var captures: [ObjectIdentifier: (touch: UITouch, capture: Capture)] = [:]
  /// Portrait shell (matte plastic + recessed wells), one prerendered image.
  private let shell = CALayer()
  private var shellKey: String?
  private let selectionOutline = CAShapeLayer()
  private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
  private let haptic = UIImpactFeedbackGenerator(style: .light)
  private let hapticHeavy = UIImpactFeedbackGenerator(style: .rigid)

  private var lastPacked = PadState.neutralPacked
  private var pressedItems = Set<Int>()
  private var dpadIndex: Int?
  private var lastDpad: GCButtons = []
  private var stickVectors: [Int: CGPoint] = [:]
  private var triggerValues: [Int: Double] = [:]
  private var mappingScale: CGFloat = 1

  public override init(frame: CGRect) {
    super.init(frame: frame)
    commonInit()
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    isMultipleTouchEnabled = true
    isExclusiveTouch = false
    backgroundColor = .clear
    shell.contentsGravity = .resize
    layer.addSublayer(shell)
    selectionOutline.fillColor = UIColor.clear.cgColor
    selectionOutline.strokeColor = UIColor.white.cgColor
    selectionOutline.lineWidth = 2
    selectionOutline.lineDashPattern = [6, 4]
    selectionOutline.zPosition = 100
    layer.addSublayer(selectionOutline)
    pinch.isEnabled = false
    addGestureRecognizer(pinch)
    rebuild()
  }

  // MARK: Layout

  public override func layoutSubviews() {
    super.layoutSubviews()
    placeItems()
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    placeItems()
  }

  private func rebuild() {
    releaseAll()
    renderer = SkinRenderer(skin: skin)
    layout = overrides.apply(to: skin.layout(orientation))
    for p in placed { p.layer.removeFromSuperlayer() }
    placed = layout.items.map { item in
      let l = CALayer()
      l.contentsGravity = .resize
      l.opacity = Float(overrides.itemOpacity(item.id))
      layer.addSublayer(l)
      var p = Placed(item: item, rect: .zero, hitRect: .zero, layer: l)
      if item.shape == .stick {
        let k = CALayer()
        k.contentsGravity = .resize
        l.addSublayer(k)
        p.knob = k
      }
      if item.shape == .dpad {
        p.dpadArms = (0..<4).map { _ in
          let a = CALayer()
          a.isHidden = true
          l.addSublayer(a)
          return a
        }
      }
      if item.input == .l || item.input == .r {
        let f = CALayer()
        f.backgroundColor = UIColor.black.withAlphaComponent(0.22).cgColor  // pressure fill reads as the face sinking
        f.isHidden = true
        l.addSublayer(f)
        p.fill = f
      }
      return p
    }
    dpadIndex = placed.firstIndex { $0.item.input == .dpad }
    alpha = CGFloat(layout.defaultOpacity)
    shell.isHidden = !layout.showsBackground
    shellKey = nil
    setNeedsLayout()
  }

  /// Uniform scale from mapping space; each item anchors to the nearest side so
  /// landscape layouts hold on every aspect ratio and respect the safe area.
  private func placeItems() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let ms = layout.mappingSize
    let safe = bounds.inset(by: safeAreaInsets)
    let s = min(safe.width / ms.width, safe.height / ms.height)
    mappingScale = s
    let scale = window?.screen.scale ?? traitCollection.displayScale
    let usedH = ms.height * s
    let originY = safe.minY + (safe.height - usedH) / 2

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shell.frame = bounds

    for i in placed.indices {
      let f = placed[i].item.frame
      let w = f.width * s, h = f.height * s
      let x: CGFloat
      if f.midX < ms.width * 0.42 {
        x = safe.minX + f.x * s
      } else if f.midX > ms.width * 0.58 {
        x = safe.maxX - (ms.width - f.x) * s
      } else {
        x = safe.midX + (f.x - ms.width / 2) * s
      }
      let rect = CGRect(x: x, y: originY + f.y * s, width: w, height: h).integral
      let inset = CGFloat(placed[i].item.hitInset ?? 8) * s
      placed[i].rect = rect
      placed[i].hitRect = rect.insetBy(dx: -inset, dy: -inset)
      // Item images carry a transparent margin for their AO shadow.
      let pad = SkinRenderer.padding(for: rect.size)
      let l = placed[i].layer
      l.frame = rect.insetBy(dx: -pad, dy: -pad)
      let item = placed[i].item
      l.contents = renderer.image(for: item, size: rect.size, scale: scale, variant: .normal).cgImage
      if let k = placed[i].knob {
        let kd = rect.width * 0.62
        let kp = SkinRenderer.padding(for: CGSize(width: kd, height: kd))
        k.bounds = CGRect(x: 0, y: 0, width: kd + kp * 2, height: kd + kp * 2)
        k.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        k.contents = renderer.image(for: item, size: CGSize(width: kd, height: kd), scale: scale, variant: .knob).cgImage
      }
      for (d, arm) in placed[i].dpadArms.enumerated() {
        arm.frame = CGRect(x: pad, y: pad, width: rect.width, height: rect.height)
        arm.contents = renderer.dpadArmHighlight(size: rect.size, scale: scale, direction: d).cgImage
      }
      if let fill = placed[i].fill {
        fill.cornerRadius = rect.height * 0.4
        fill.frame = CGRect(x: pad + 2, y: pad + 2, width: 0, height: rect.height - 4)
      }
    }
    if layout.showsBackground {
      // Re-render the shell only when its size or the item positions change.
      let key = "\(skin.identifier)|\(Int(bounds.width))x\(Int(bounds.height))@\(Int(scale))|" + placed.map { "\($0.item.id):\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width))" }.joined(separator: ";")
      if key != shellKey {
        shellKey = key
        shell.contents = renderer.shellImage(
          size: bounds.size, scale: scale, cornerRadius: orientation == .portrait ? 28 : 0,
          items: placed.map { ($0.item, $0.rect) }).cgImage
      }
    }
    CATransaction.commit()
    updateSelectionOutline()
  }

  // MARK: Hit testing

  /// Landscape overlay: touches that miss every control fall through to the game view.
  public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    if layout.showsBackground || isEditing { return super.point(inside: point, with: event) }
    return placed.contains { $0.hitRect.contains(point) && $0.item.input != .logo }
  }

  private func hit(_ p: CGPoint, buttonsOnly: Bool = false) -> Int? {
    var best: Int?
    var bestDist = CGFloat.greatestFiniteMagnitude
    for i in placed.indices {
      let it = placed[i]
      if it.item.input == .logo { continue }
      if buttonsOnly, it.item.input.button == nil, it.item.input != .dpad { continue }
      guard it.hitRect.contains(p) else { continue }
      if it.rect.contains(p) { return i }  // direct hit wins
      let d = hypot(p.x - it.rect.midX, p.y - it.rect.midY)
      if d < bestDist { bestDist = d; best = i }
    }
    return best
  }

  // MARK: Touches

  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    if settings.hapticsEnabled { haptic.prepare() }
    for t in touches {
      let p = t.location(in: self)
      guard let i = hit(p) else { continue }
      if isEditing {
        selectedItemID = placed[i].item.id
        captures[ObjectIdentifier(t)] = (t, .edit(i, last: p))
        continue
      }
      let capture: Capture
      switch placed[i].item.input {
      case .mainStick, .cStick:
        capture = .stick(i)
        stickVectors[i] = vector(for: p, in: i)
      case .l, .r:
        capture = .trigger(i, startY: p.y)
        triggerValues[i] = settings.digitalTriggers ? 1 : 0.45
      case .menu:
        capture = .menu(i)
      default:
        capture = .buttons([i])
      }
      captures[ObjectIdentifier(t)] = (t, capture)
    }
    update()
  }

  public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      let id = ObjectIdentifier(t)
      guard let entry = captures[id] else {
        // A touch that started on empty glass can slide onto a button.
        if !isEditing, let i = hit(t.location(in: self), buttonsOnly: true) {
          captures[id] = (t, .buttons([i]))
        }
        continue
      }
      let p = t.location(in: self)
      switch entry.capture {
      case .stick(let i):
        stickVectors[i] = vector(for: p, in: i)
      case .trigger(let i, let startY):
        if !settings.digitalTriggers {
          let travel = max(0, p.y - startY)
          triggerValues[i] = min(1, 0.45 + Double(travel / (placed[i].rect.height * 1.6)) * 0.55)
        }
      case .buttons:
        // Slide between buttons without lifting.
        if let i = hit(p, buttonsOnly: true) {
          captures[id] = (t, .buttons([i]))
        } else {
          captures[id] = (t, .buttons([]))
        }
      case .menu:
        break
      case .edit(let i, let last):
        moveItem(i, by: CGPoint(x: p.x - last.x, y: p.y - last.y))
        captures[id] = (t, .edit(i, last: p))
      }
    }
    update()
  }

  public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches {
      let id = ObjectIdentifier(t)
      if case .menu(let i)? = captures[id]?.capture, placed[i].hitRect.contains(t.location(in: self)) {
        onMenu?()
      }
      end(id)
    }
    update()
  }

  public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { end(ObjectIdentifier(t)) }
    update()
  }

  private func end(_ id: ObjectIdentifier) {
    guard let entry = captures.removeValue(forKey: id) else { return }
    switch entry.capture {
    case .stick(let i): stickVectors[i] = nil
    case .trigger(let i, _): triggerValues[i] = nil
    case .edit: commitOverrides()
    default: break
    }
  }

  private func releaseAll() {
    captures.removeAll()
    stickVectors.removeAll()
    triggerValues.removeAll()
    update()
  }

  /// Touch point → stick vector in -1…1 (+y up), relative to the well's center.
  private func vector(for p: CGPoint, in i: Int) -> CGPoint {
    let r = placed[i].rect
    let radius = r.width * 0.42
    var v = CGPoint(x: (p.x - r.midX) / radius, y: -(p.y - r.midY) / radius)
    let m = hypot(v.x, v.y)
    if m > 1 { v = CGPoint(x: v.x / m, y: v.y / m) }
    return v
  }

  // MARK: State → pad + visuals

  private func update() {
    guard !isEditing else { return }
    var st = PadState.neutral
    var nowPressed = Set<Int>()
    var dpadButtons: GCButtons = []

    for (_, entry) in captures {
      switch entry.capture {
      case .buttons(let set):
        for i in set {
          let input = placed[i].item.input
          if input == .dpad {
            let r = placed[i].rect
            let p = entry.touch.location(in: self)
            let dx = Double((p.x - r.midX) / (r.width / 2)), dy = Double(-(p.y - r.midY) / (r.height / 2))
            dpadButtons.formUnion(AnalogMath.dpad(x: dx, y: dy, deadRadius: 0.18))
          } else if let b = input.button {
            st.buttons.insert(b)
            nowPressed.insert(i)
          }
        }
      case .menu(let i):
        nowPressed.insert(i)
      default:
        break
      }
    }
    st.buttons.formUnion(dpadButtons)

    for (i, v) in stickVectors {
      let shaped = AnalogMath.shape(x: Double(v.x), y: Double(v.y), settings.stick)
      if placed[i].item.input == .mainStick {
        st.stickX = AnalogMath.axisByte(shaped.x); st.stickY = AnalogMath.axisByte(shaped.y)
      } else {
        st.cStickX = AnalogMath.axisByte(shaped.x); st.cStickY = AnalogMath.axisByte(shaped.y)
      }
      nowPressed.insert(i)
    }
    for (i, v) in triggerValues {
      let byte = AnalogMath.triggerByte(v)
      let isL = placed[i].item.input == .l
      if isL { st.triggerL = byte } else { st.triggerR = byte }
      if v >= 0.98 { st.buttons.insert(isL ? .l : .r) }
      nowPressed.insert(i)
    }

    let packed = st.packed
    if packed != lastPacked {
      store.publish(packed, player: settings.player, source: .touch)
      if settings.hapticsEnabled {
        let newlyPressed = !nowPressed.subtracting(pressedItems).isEmpty || !dpadButtons.subtracting(lastDpad).isEmpty
        let clicked = st.buttons.intersection([.l, .r]).subtracting(PadState(packed: lastPacked).buttons) != []
        if clicked { hapticHeavy.impactOccurred(intensity: 0.9) } else if newlyPressed { haptic.impactOccurred() }
      }
      lastPacked = packed
    }
    renderVisuals(pressed: nowPressed, dpad: dpadButtons)
  }

  private func renderVisuals(pressed: Set<Int>, dpad: GCButtons) {
    let scale = window?.screen.scale ?? traitCollection.displayScale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for i in pressed.symmetricDifference(pressedItems) where placed[i].knob == nil && placed[i].item.input != .dpad {
      let item = placed[i].item
      let down = pressed.contains(i)
      placed[i].layer.contents = renderer.image(for: item, size: placed[i].rect.size, scale: scale, variant: down ? .pressed : .normal).cgImage
    }
    for i in placed.indices {
      if let k = placed[i].knob {
        let v = stickVectors[i] ?? .zero
        let r = placed[i].rect
        let travel = r.width * 0.24
        let c = placed[i].layer.bounds
        k.position = CGPoint(x: c.midX + v.x * travel, y: c.midY - v.y * travel)
        if pressed.contains(i) != pressedItems.contains(i) {
          k.contents = renderer.image(for: placed[i].item, size: k.bounds.size, scale: scale, variant: pressed.contains(i) ? .knobPressed : .knob).cgImage
        }
      }
      if let fill = placed[i].fill {
        let v = triggerValues[i]
        fill.isHidden = v == nil
        fill.frame.size.width = CGFloat(v ?? 0) * (placed[i].rect.width - 4)
      }
    }
    if dpad != lastDpad, let d = dpadIndex {
      let arms = placed[d].dpadArms
      arms[0].isHidden = !dpad.contains(.dpadUp)
      arms[1].isHidden = !dpad.contains(.dpadDown)
      arms[2].isHidden = !dpad.contains(.dpadLeft)
      arms[3].isHidden = !dpad.contains(.dpadRight)
    }
    CATransaction.commit()
    pressedItems = pressed
    lastDpad = dpad
  }

  // MARK: Editing

  private func moveItem(_ i: Int, by d: CGPoint) {
    guard mappingScale > 0 else { return }
    let id = placed[i].item.id
    var o = overrides.items[id] ?? ItemOverride()
    o.dx += Double(d.x / mappingScale)
    o.dy += Double(d.y / mappingScale)
    // Move the layer directly while dragging; full rebuild on commit.
    placed[i].rect = placed[i].rect.offsetBy(dx: d.x, dy: d.y)
    placed[i].hitRect = placed[i].hitRect.offsetBy(dx: d.x, dy: d.y)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    placed[i].layer.position = CGPoint(x: placed[i].rect.midX, y: placed[i].rect.midY)
    CATransaction.commit()
    pendingOverrides = overridesWith(id: id, o)
    updateSelectionOutline()
  }

  private var pendingOverrides: LayoutOverrides?

  private func overridesWith(id: String, _ o: ItemOverride) -> LayoutOverrides {
    var all = pendingOverrides ?? overrides
    all.items[id] = o
    return all
  }

  private func commitOverrides() {
    guard let p = pendingOverrides else { return }
    pendingOverrides = nil
    overrides = p
    onOverridesChanged?(p)
  }

  @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
    guard isEditing, let id = selectedItemID else { return }
    var o = (pendingOverrides ?? overrides).items[id] ?? ItemOverride()
    o.scale = min(max(o.scale * Double(g.scale), 0.5), 2.0)
    g.scale = 1
    pendingOverrides = overridesWith(id: id, o)
    if g.state == .ended || g.state == .cancelled { commitOverrides() }
    else if let i = placed.firstIndex(where: { $0.item.id == id }) {
      let base = skin.layout(orientation).items.first { $0.id == id }?.frame
      if let base {
        let w = base.width * o.scale * mappingScale, h = base.height * o.scale * mappingScale
        let c = CGPoint(x: placed[i].rect.midX, y: placed[i].rect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pad = SkinRenderer.padding(for: CGSize(width: w, height: h))
        placed[i].layer.bounds = CGRect(x: 0, y: 0, width: w + pad * 2, height: h + pad * 2)
        placed[i].layer.position = c
        CATransaction.commit()
      }
    }
  }

  /// Programmatic edits from the editor panel (size/opacity sliders).
  public func setOverride(_ o: ItemOverride, for id: String) {
    var all = overrides
    all.items[id] = o
    overrides = all
    onOverridesChanged?(all)
  }

  private func updateSelectionOutline() {
    guard isEditing, let id = selectedItemID, let p = placed.first(where: { $0.item.id == id }) else {
      selectionOutline.path = nil
      return
    }
    selectionOutline.path = UIBezierPath(roundedRect: p.rect.insetBy(dx: -4, dy: -4), cornerRadius: 10).cgPath
  }
}
#endif
